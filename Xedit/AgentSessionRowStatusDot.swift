//
//  AgentSessionRowStatusDot.swift
//  VeilWriter
//
//  Small 5pt circle that lives at the left edge of each Agent-mode
//  sidebar session row. Shows whether that session is the active one,
//  running a turn in the background, or waiting for a tool decision.
//
//  Design constraint: this MUST observe its runtime directly rather
//  than ride AppState's republish chain. Pre-hotfix rc4 forwarded
//  every runtime's `objectWillChange` through AppState so the dot
//  could see background turns — but that turned every stream-token
//  delta into a global SwiftUI invalidation, and combined with
//  scrolling a long transcript + N animating dots it pinned the main
//  thread. Now AppState only forwards the active runtime (for the
//  delegated `agent*` props), and the dot's `ObservedDot` subview
//  observes its specific runtime directly so a background-turn delta
//  only repaints that one row.
//

import SwiftUI

struct AgentSessionRowStatusDot: View {
    /// The session's per-session runtime, if one has been created.
    /// Sessions the user hasn't opened this launch have no runtime —
    /// they always render as idle and skip the @ObservedObject path.
    let runtime: AgentRuntime?
    let isActive: Bool

    var body: some View {
        if let runtime {
            ObservedDot(runtime: runtime, isActive: isActive)
        } else {
            IdleDot(isActive: isActive)
        }
    }
}

/// Variant rendered when there's a real runtime to watch. The
/// @ObservedObject scopes the redraw to this single row, not the
/// whole sidebar.
private struct ObservedDot: View {
    @ObservedObject var runtime: AgentRuntime
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

    private var shouldPulse: Bool {
        runtime.isResponding
    }

    private var color: Color {
        // toolDecisionWaiter is non-Published — we can read it for
        // color tinting but can't drive the pulse off it (SwiftUI
        // wouldn't see the change). isResponding stays the single
        // animation source; the orange tint is best-effort and
        // settles correctly on the next isResponding flip.
        if runtime.toolDecisionWaiter != nil { return .orange }
        if runtime.isResponding { return .green }
        if isActive { return .accentColor }
        return Color.secondary.opacity(0.4)
    }
}

/// Variant rendered when no runtime exists yet — static dot, no
/// animation, no observer overhead.
private struct IdleDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(width: 5, height: 5)
    }
}
