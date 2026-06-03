//
//  AgentSessionRowStatusDot.swift
//  VeilWriter
//
//  Small 5pt circle that lives at the left edge of each Agent-mode
//  sidebar session row. Shows whether that session is the active one,
//  running a turn in the background, or waiting for a tool decision.
//
//  Pulled out of AgentModeView so the file stays under the 3000-line
//  soft cap and so the pulse animation lives in one place. The state
//  the dot reads (`isResponding`, `toolDecisionWaiter`) comes from
//  the per-session AgentRuntime; AppState republishes every runtime's
//  `objectWillChange` into its own publisher, so a parent view that
//  observes AppState (the sidebar) is automatically dirtied whenever
//  any runtime's state changes — even background ones.
//

import SwiftUI

struct AgentSessionRowStatusDot: View {
    /// The session's per-session runtime, if one has been created.
    /// Sessions the user hasn't opened yet have no runtime — they
    /// always render as idle.
    let runtime: AgentRuntime?
    let isActive: Bool

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .scaleEffect(shouldPulse && pulse ? 1.6 : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear {
                if shouldPulse { pulse = true }
            }
            .onChange(of: shouldPulse) { _, newValue in
                pulse = newValue
            }
    }

    private var isResponding: Bool {
        runtime?.isResponding ?? false
    }

    private var isAwaitingApproval: Bool {
        // Tool waiter is non-nil only while the runtime is paused on
        // a user decision (Allow/Deny/Confirm/answer ask_user).
        runtime?.toolDecisionWaiter != nil
    }

    private var shouldPulse: Bool {
        isResponding || isAwaitingApproval
    }

    private var color: Color {
        if isAwaitingApproval { return .orange }
        if isResponding { return .green }
        if isActive { return .accentColor }
        return Color.secondary.opacity(0.4)
    }
}
