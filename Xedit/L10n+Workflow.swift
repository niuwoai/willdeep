//
//  L10n+Workflow.swift
//  WillDeep
//
//  L10n strings for the Workflow feature shipped in 1.81.0-rc1.
//  Separate file — keeps L10n.swift under the 2000-line split threshold.
//

import Foundation

extension L10n {
    enum WorkflowCard {
        static let workflowBadge = String(
            localized: "workflow-card.badge",
            defaultValue: "Workflow"
        )
        static let statusPlanning = String(
            localized: "workflow-card.status.planning",
            defaultValue: "Planning"
        )
        static let statusRunning = String(
            localized: "workflow-card.status.running",
            defaultValue: "Running"
        )
        static let statusDone = String(
            localized: "workflow-card.status.done",
            defaultValue: "Done"
        )
        static let statusFailed = String(
            localized: "workflow-card.status.failed",
            defaultValue: "Failed"
        )
        static let statusCancelled = String(
            localized: "workflow-card.status.cancelled",
            defaultValue: "Cancelled"
        )
        static let collapse = String(
            localized: "workflow-card.collapse",
            defaultValue: "Collapse sub-agent list"
        )
        static let expand = String(
            localized: "workflow-card.expand",
            defaultValue: "Show sub-agent list"
        )

        static func agentsLabel(done: Int, total: Int) -> String {
            let template = String(
                localized: "workflow-card.agents",
                defaultValue: "%d / %d agents"
            )
            return String(format: template, done, total)
        }

        static func totalTokens(_ tokens: Int) -> String {
            let template = String(
                localized: "workflow-card.total-tokens",
                defaultValue: "%@ tokens"
            )
            return String(format: template, formatTokens(tokens))
        }

        static func tokensShort(_ tokens: Int) -> String {
            formatTokens(tokens)
        }

        private static func formatTokens(_ tokens: Int) -> String {
            if tokens >= 1_000 {
                let k = Double(tokens) / 1_000.0
                return String(format: "%.1fk", k)
            }
            return "\(tokens)"
        }
    }

    enum WorkflowComposer {
        static let paletteHeader = String(
            localized: "workflow-composer.palette-header",
            defaultValue: "Workflows"
        )
        static let startedNoticePrefix = String(
            localized: "workflow-composer.started-notice-prefix",
            defaultValue: "Workflow started: "
        )
    }
}
