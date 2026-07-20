//
//  L10n+AgentTurnProgress.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum AgentTurnProgress {
        static let title = String(
            localized: "agent-turn-progress.title",
            defaultValue: "Turn progress"
        )
        static let viewFullPlan = String(
            localized: "agent-turn-progress.view-full-plan",
            defaultValue: "View full plan"
        )
        static let expanded = String(
            localized: "agent-turn-progress.expanded",
            defaultValue: "Expanded"
        )
        static let collapsed = String(
            localized: "agent-turn-progress.collapsed",
            defaultValue: "Collapsed"
        )
        static let statusDone = String(
            localized: "agent-turn-progress.status.done",
            defaultValue: "Done"
        )
        static let statusInProgress = String(
            localized: "agent-turn-progress.status.in-progress",
            defaultValue: "In progress"
        )
        static let statusFailed = String(
            localized: "agent-turn-progress.status.failed",
            defaultValue: "Failed"
        )
        static let statusPending = String(
            localized: "agent-turn-progress.status.pending",
            defaultValue: "Pending"
        )
        static let statusSkipped = String(
            localized: "agent-turn-progress.status.skipped",
            defaultValue: "Skipped"
        )

        static func completed(_ count: Int) -> String {
            let template = String(
                localized: "agent-turn-progress.completed",
                defaultValue: "%d done"
            )
            return String(format: template, count)
        }

        static func inProgress(_ count: Int) -> String {
            let template = String(
                localized: "agent-turn-progress.in-progress",
                defaultValue: "%d active"
            )
            return String(format: template, count)
        }

        static func failed(_ count: Int) -> String {
            let template = String(
                localized: "agent-turn-progress.failed",
                defaultValue: "%d failed"
            )
            return String(format: template, count)
        }

        static func pending(_ count: Int) -> String {
            let template = String(
                localized: "agent-turn-progress.pending",
                defaultValue: "%d pending"
            )
            return String(format: template, count)
        }

        static func stepNumber(_ index: Int) -> String {
            let template = String(
                localized: "agent-turn-progress.step-number",
                defaultValue: "Step %d"
            )
            return String(format: template, index)
        }
    }
}
