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
        case .killed: statusWord = "killed"
        case .timedOut: statusWord = "timed out"
        case .launchFailed: statusWord = "launch failed"
        case .running: return // shouldn't happen — we only fire on finish
        }
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: job)
        // Keep the body short — handle + status is enough to recognize which
        // job finished. The full command used to be dumped here; users found
        // it noisy and it leaked long paths into the banner.
        content.body = "\(job.displayHandle) · \(statusWord) · \(commandSummary(job.command))"
        content.sound = .default
        if let attachment = AgentNotificationIcon.attachment() {
            content.attachments = [attachment]
        }

        let identifier = "willdeep.agent.jobFinished.\(job.id.uuidString)"
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

    private static func titleText(for status: AgentToolCallStatus) -> String {
        switch status {
        case .pendingApproval: return "Agent 需要授权"
        case .awaitingConfirm: return "Agent 需要确认"
        case .awaitingUserAnswer: return "Agent 在等你回答"
        default: return "Agent 需要你"
        }
    }

    /// Returns the notification body, or nil if the status doesn't
    /// warrant a notification (running / succeeded / failed / denied).
    private static func bodyText(
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
    private static func descriptor(toolName: String, arguments: [String: AgentJSONValue]) -> String {
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
            return "\(toolName) · \((path as NSString).lastPathComponent)"
        }
        return toolName
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
        guard let head = tokens.first else { return command.isEmpty ? "命令" : truncated(command, limit: 40) }
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
