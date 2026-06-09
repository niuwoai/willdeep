//
//  AgentToolApprovalNotifier.swift
//  VeilWriter
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
import UserNotifications

enum AgentToolApprovalNotifier {
    private static var hasRequestedAuthorization = false

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

        requestAuthorizationIfNeeded()

        let title = titleText(for: status)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
                return
            }
            let identifier = "veilwriter.agent.toolApproval.\(Int(Date().timeIntervalSince1970 * 1000))"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }

    private static func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

    /// Short human-readable summary for the body — same shape the user
    /// sees on the card so it's recognizable when they flip back.
    private static func descriptor(toolName: String, arguments: [String: AgentJSONValue]) -> String {
        if toolName == "run_command", let command = arguments["command"]?.stringValue() {
            return truncated(command, limit: 120)
        }
        if toolName == "call_mcp_tool" {
            let server = arguments["server"]?.stringValue() ?? "?"
            let tool = arguments["tool"]?.stringValue() ?? "?"
            return "\(server).\(tool)"
        }
        if let path = arguments["path"]?.stringValue() {
            return "\(toolName) · \(truncated(path, limit: 100))"
        }
        return toolName
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
