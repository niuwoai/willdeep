//
//  L10n+GoalWake.swift
//  WillDeep
//
//  Copy for a Goal that is waiting to resume on its own, and for the Goal
//  segment limit in Settings.
//

import Foundation

extension L10n {
    enum GoalWake {
        static func notice(for wake: AgentGoalScheduledWake, now: Date) -> String {
            let minutes = "\(AgentGoalWakePolicy.displayedMinutesRemaining(until: wake.dueAt, now: now))"
            let attempt = "\(wake.attempt)"
            let template: String
            switch wake.reason {
            case .providerOutage:
                template = String(
                    localized: "goal-wake.provider-outage",
                    defaultValue: "Model service temporarily unavailable. Retrying automatically in %1$@ min (attempt %2$@)."
                )
            case .noProgressBackoff:
                template = String(
                    localized: "goal-wake.no-progress-backoff",
                    defaultValue: "No progress for several rounds. Continuing in %1$@ min (backoff %2$@)."
                )
            case .compressionRetry:
                template = String(
                    localized: "goal-wake.compression-retry",
                    defaultValue: "Context compression failed temporarily. Retrying in %1$@ min (attempt %2$@)."
                )
            }
            return String(format: template, minutes, attempt)
        }

        static let stopHint = String(
            localized: "goal-wake.stop-hint",
            defaultValue: "Press pause to stop waiting, or send a message to continue now."
        )
    }

    enum GoalRunSettings {
        static let section = String(localized: "goal-run-settings.section", defaultValue: "Goal")
        static let segmentLimitLabel = String(
            localized: "goal-run-settings.segment-limit",
            defaultValue: "Run time per segment"
        )
        static let segmentLimitDescription = String(
            localized: "goal-run-settings.segment-limit-description",
            defaultValue: "How long a Goal keeps working on its own before it pauses with a handover snapshot. Applies to the next segment: a new Goal, or pressing play to continue one."
        )
        static let overnightDescription = String(
            localized: "goal-run-settings.overnight-description",
            defaultValue: "While a Goal runs, WillDeep keeps the Mac from idle sleep (closing the lid still sleeps it) and retries on its own when the model service is temporarily unavailable."
        )

        static func hours(_ count: Int) -> String {
            if count == 1 {
                return String(localized: "goal-run-settings.one-hour", defaultValue: "1 hour")
            }
            let template = String(localized: "goal-run-settings.hours", defaultValue: "%@ hours")
            return String(format: template, "\(count)")
        }
    }
}
