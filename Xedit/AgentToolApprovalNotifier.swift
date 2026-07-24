//
//  AgentToolApprovalNotifier.swift
//  WillDeep
//
//  Posts a system banner when a tool call enters an interactive state
//  (pendingApproval / awaitingConfirm / awaitingUserAnswer) and the
//  user isn't looking at the app. Added in 1.56.1-rc2 — before this,
//  a backgrounded session that hit a Write-tier MCP tool just sat
//  silently on the Allow/Deny card until the user happened to flip
//  back to the window.
//
//  Behavior:
//   - No-op when NSApp.isActive — the user sees the card already.
//   - Lazily requests UNUserNotification authorization the first time
//     we'd actually post; if the user denies, we silently drop future
//     posts (the in-app card still works fine).
//   - One notification per call (de-duped by the tool externalID would
//     be nice, but the call site only has the in-memory record so we
//     just stamp the system time into the identifier — UN will collapse
//     bursts under the same title on its own).
//   - Distinguishes the three interactive states in the body so the
//     user reads "需要授权 / 需要确认 / 需要回答" without opening the
//     app.
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

enum AgentToolApprovalNotifier {
    @MainActor
    static func notifyIfBackgrounded(
        toolName: String,
        arguments: [String: AgentJSONValue],
        status: AgentToolCallStatus
    ) {
        guard let body = bodyText(for: toolName, arguments: arguments, status: status) else {
            return
        }
        // App is the foreground app and a window is key — the user is
        // already looking at the card, no banner needed.
        if NSApp.isActive {
            return
        }

        let title = titleText(for: status)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let attachment = AgentNotificationIcon.attachment() {
            content.attachments = [attachment]
        }

        let identifier = "willdeep.agent.toolApproval.\(Int(Date().timeIntervalSince1970 * 1000))"
        postNotificationWhenAuthorized(identifier: identifier, content: content)
    }

    /// Background `run_command` job finished while the user wasn't
    /// looking. Re-uses the same auth + delivery path as the approval
    /// notifier — see header comment for rationale.
    @MainActor
    static func notifyJobFinished(job: AgentBackgroundJob) {
        if NSApp.isActive, !job.needsAttention { return }

        let statusWord: String
        switch job.status {
        case .completed: statusWord = "exit 0"
        case .failed: statusWord = "exit \(job.exitCode ?? -1)"
        case .killed: statusWord = L10n.AgentJobs.statusKilled
        case .timedOut: statusWord = L10n.AgentJobs.statusTimedOut
        case .launchFailed: statusWord = L10n.AgentJobs.statusLaunchFailed
        case .running: return // shouldn't happen — we only fire on finish
        }
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: job)
        // Keep the body short — handle + status is enough to recognize which
        // job finished. The full command used to be dumped here; users found
        // it noisy and it leaked long paths into the banner.
        content.body = "\(job.displayHandle) · \(statusWord) · \(commandSummary(job.command))"
        content.sound = .default
        // Deep-link: tapping the banner jumps to the session that owns this
        // job (see AgentNotificationResponder).
        content.userInfo = [AgentNotificationUserInfoKey.runtimeID: job.runtimeID.uuidString]
        if let attachment = AgentNotificationIcon.attachment() {
            content.attachments = [attachment]
        }

        let identifier = "willdeep.agent.jobFinished.\(job.id.uuidString)"
        postNotificationWhenAuthorized(identifier: identifier, content: content)
    }

    /// A complex task parked its send behind the Plan-mode suggestion banner
    /// while the user is away. Same auth + delivery + deep-link path as the
    /// approval notifier; no-op in the foreground (the banner is visible).
    @MainActor
    static func notifyPlanModeSuggestionIfBackgrounded(runtimeID: UUID) {
        if NSApp.isActive { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.AgentNotifications.planSuggestionTitle
        content.body = L10n.AgentNotifications.planSuggestionBody
        content.sound = .default
        content.userInfo = [AgentNotificationUserInfoKey.runtimeID: runtimeID.uuidString]
        if let attachment = AgentNotificationIcon.attachment() {
            content.attachments = [attachment]
        }
        let identifier = "willdeep.agent.planSuggestion.\(runtimeID.uuidString)"
        postNotificationWhenAuthorized(identifier: identifier, content: content)
    }

    @MainActor
    private static func postNotificationWhenAuthorized(
        identifier: String,
        content: UNMutableNotificationContent
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                addNotification(center: center, identifier: identifier, content: content)
            case .notDetermined:
                requestAuthorizationIfNeeded { granted in
                    guard granted else { return }
                    addNotification(center: center, identifier: identifier, content: content)
                }
            case .denied, .ephemeral:
                return
            @unknown default:
                return
            }
        }
    }

    private static func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    private static func addNotification(
        center: UNUserNotificationCenter,
        identifier: String,
        content: UNMutableNotificationContent
    ) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    static func titleText(for status: AgentToolCallStatus) -> String {
        switch status {
        case .pendingApproval: return L10n.AgentNotifications.approvalTitle
        case .awaitingConfirm: return L10n.AgentNotifications.confirmationTitle
        case .awaitingUserAnswer: return L10n.AgentNotifications.answerTitle
        default: return L10n.AgentNotifications.attentionTitle
        }
    }

    /// Returns the notification body, or nil if the status doesn't
    /// warrant a notification (running / succeeded / failed / denied).
    static func bodyText(
        for toolName: String,
        arguments: [String: AgentJSONValue],
        status: AgentToolCallStatus
    ) -> String? {
        switch status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            break
        default:
            return nil
        }
        return descriptor(toolName: toolName, arguments: arguments)
    }

    /// Short human-readable summary for the body. Deliberately terse — the
    /// banner is a "come look" nudge, not the full transcript. For shell
    /// commands we surface just the program (and its subcommand for wrappers
    /// like `git`/`go`), never the full argument line, which used to spill
    /// long paths and flags into the notification.
    static func descriptor(toolName: String, arguments: [String: AgentJSONValue]) -> String {
        if toolName == "run_command", let command = arguments["command"]?.stringValue() {
            return commandSummary(command)
        }
        if toolName == "call_mcp_tool" {
            let server = arguments["server"]?.stringValue() ?? "?"
            let tool = arguments["tool"]?.stringValue() ?? "?"
            return "\(server).\(tool)"
        }
        if let path = arguments["path"]?.stringValue() {
            // Just the filename, not the whole path.
            return L10n.AgentNotifications.toolWithFile(
                localizedToolName(for: toolName),
                fileName: (path as NSString).lastPathComponent
            )
        }
        return localizedToolName(for: toolName)
    }

    private static func localizedToolName(for toolName: String) -> String {
        switch toolName {
        case "run_command":
            return L10n.AgentNotifications.toolRunCommand
        case "terminal_send_command":
            return L10n.AgentNotifications.toolTerminalCommand
        case "terminal_send_control":
            return L10n.AgentNotifications.toolTerminalControl
        case "edit_file":
            return L10n.AgentNotifications.toolEditFile
        case "create_file":
            return L10n.AgentNotifications.toolCreateFile
        case "apply_patch":
            return L10n.AgentNotifications.toolApplyPatch
        case "web_fetch":
            return L10n.AgentNotifications.toolFetchWebpage
        case "ask_user":
            return L10n.AgentNotifications.toolAskUser
        default:
            if toolName.hasPrefix("computer_use_") {
                return L10n.AgentNotifications.toolComputerUse
            }
            if toolName.hasPrefix("chrome_") || toolName.hasPrefix("browser_") {
                return L10n.AgentNotifications.toolBrowserControl
            }
            // Preserve unknown provider/MCP tool IDs so the notification is
            // still actionable for diagnostics instead of inventing a label.
            return toolName
        }
    }

    private static func notificationTitle(for job: AgentBackgroundJob) -> String {
        switch job.status {
        case .completed:
            return L10n.AgentJobs.notificationTitleCompleted
        case .failed, .timedOut, .launchFailed:
            return L10n.AgentJobs.notificationTitleFailed
        case .killed:
            return L10n.AgentJobs.notificationTitleStopped
        case .running:
            return L10n.AgentJobs.notificationTitleCompleted
        }
    }

    /// Condense a shell command to "program" or "program subcommand" so the
    /// banner stays recognizable without exposing the full command line.
    /// e.g. `git commit -m "..."` → `git commit`, `mkdir -p a/b/c` → `mkdir`.
    private static func commandSummary(_ command: String) -> String {
        let tokens = SafeCommand.tokenize(command)
        guard let head = tokens.first else {
            return command.isEmpty
                ? L10n.AgentNotifications.command
                : truncated(command, limit: 40)
        }
        let wrappers: Set<String> = [
            "git", "go", "npm", "pnpm", "yarn", "cargo", "make", "swift",
            "python", "python3", "node", "ruby", "rake", "docker", "kubectl", "brew"
        ]
        if wrappers.contains(head.lowercased()),
           let sub = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return truncated("\(head) \(sub)", limit: 40)
        }
        return truncated(head, limit: 40)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= limit { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "…"
    }
}
