//
//  AgentNotificationResponder.swift
//  WillDeep
//
//  Handles taps on the system notifications posted by
//  AgentToolApprovalNotifier. Tapping a "needs authorization / needs
//  you" banner should bring the app forward AND jump straight to the
//  session that needs the user — not dump them into whatever session
//  happened to be focused and make them hunt for the one that fired the
//  banner.
//

import AppKit
import Foundation
@preconcurrency import UserNotifications

enum AgentNotificationUserInfoKey {
    /// uuidString of the AgentRuntime/session that posted the banner.
    static let runtimeID = "willdeep.agent.runtimeID"
}

extension Notification.Name {
    /// Posted after the responder has selected the target session; an
    /// open SwiftUI window observes it to open/focus the Agent window.
    static let willDeepRevealAgentSession = Notification.Name("willdeep.agent.revealSession")
}

final class AgentNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationResponder()

    /// Show the banner even if the app became active between posting and
    /// presentation (we only post when backgrounded, but timing races
    /// happen). Harmless when foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let runtimeID = (response.notification.request.content.userInfo[AgentNotificationUserInfoKey.runtimeID] as? String)
            .flatMap { UUID(uuidString: $0) }
        Task { @MainActor in
            Self.reveal(runtimeID: runtimeID)
            completionHandler()
        }
    }

    /// Bring the app forward and select the session that needs the user.
    /// Uses the runtimeID baked into the notification when present (e.g.
    /// a finished background job); otherwise falls back to scanning for a
    /// runtime with a pending approval/confirm/answer — which covers the
    /// mid-turn authorization banner whose call site doesn't carry an id.
    @MainActor
    static func reveal(runtimeID: UUID?) {
        NSApp.activate(ignoringOtherApps: true)

        let registry = EditorAppStateRegistry.shared
        let target: (appState: AppState, sessionID: AgentSession.ID)?
        if let runtimeID, let appState = registry.appState(forRuntime: runtimeID) {
            target = (appState, runtimeID)
        } else {
            target = registry.appStateWithPendingAttention()
        }

        if let target {
            registry.setCurrent(target.appState)
            target.appState.selectAgentSession(id: target.sessionID)
        }

        // Open / focus the Agent window via a SwiftUI observer (only it
        // has access to the openWindow action).
        NotificationCenter.default.post(name: .willDeepRevealAgentSession, object: nil)
    }
}
