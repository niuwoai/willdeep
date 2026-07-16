//
//  AgentSessionRowStatusDot.swift
//  WillDeep
//
//  Small 5pt circle that lives at the trailing edge of each Agent-mode
//  sidebar session row. It stays hidden for ordinary idle rows and shows
//  whether a session is active, running in the background, or waiting for
//  a tool decision.
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
    let accentColor: Color

    var body: some View {
        if let runtime {
            ObservedDot(runtime: runtime, isActive: isActive, accentColor: accentColor)
        } else {
            IdleDot(isActive: isActive, accentColor: accentColor)
        }
    }
}

/// Variant rendered when there's a real runtime to watch. The
/// @ObservedObject scopes the redraw to this single row, not the
/// whole sidebar.
private struct ObservedDot: View {
    @ObservedObject var runtime: AgentRuntime
    let isActive: Bool
    let accentColor: Color

    var body: some View {
        // Sidebar rows only need state, not motion. A sampled macOS 26.5
        // hang showed RBSymbolAnimator feeding repeated AttributeGraph and
        // display-list updates while the user tried to switch sessions.
        // A static circle keeps the same active/running/waiting semantics
        // without a permanent per-row animation source.
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(shouldShow ? 1 : 0)
    }

    private var shouldShow: Bool {
        isActive || runtime.isResponding || runtime.toolDecisionWaiter != nil
    }

    private var color: Color {
        // toolDecisionWaiter is non-Published, so its orange tint is
        // best-effort and settles on the next published runtime change.
        if runtime.toolDecisionWaiter != nil { return .orange }
        if runtime.isResponding { return .green }
        if isActive { return accentColor }
        return Color.clear
    }
}

/// Variant rendered when no runtime exists yet — static dot, no
/// animation, no observer overhead.
private struct IdleDot: View {
    let isActive: Bool
    let accentColor: Color

    var body: some View {
        Circle()
            .fill(isActive ? accentColor : Color.clear)
            .frame(width: 5, height: 5)
    }
}
