//
//  AgentComposerGoalWakeNotice.swift
//  WillDeep
//
//  The line under the Goal card while the Goal waits to resume on its own:
//  "Model service temporarily unavailable. Retrying automatically in 4 min
//  (attempt 2)." The card's pause button is the way out (Stop cancels the
//  wait); sending a message cancels it too.
//

import SwiftUI

struct AgentComposerGoalWakeNotice: View {
    let wake: AgentGoalScheduledWake

    /// The text counts whole minutes, so a ten-second refresh keeps it honest
    /// without a per-second tick — the fastest TimelineView paces the layout
    /// pass of every window in the app.
    private static let refreshInterval: TimeInterval = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.GoalWake.notice(for: wake, now: context.date))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-wake-notice")
    }

    private var helpText: String {
        [wake.failureSummary, L10n.GoalWake.stopHint]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}
