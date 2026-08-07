//
//  L10n+ScheduledTask.swift
//  WillDeep
//
//  L10n strings for in-session scheduled tasks (schedule_task tool + transcript
//  card). Separate file to keep L10n.swift under the split threshold.
//

import Foundation

extension L10n {
    enum ScheduledTaskCard {
        static let open = String(
            localized: "scheduled-task-card.open",
            defaultValue: "Open"
        )
        static let badge = String(
            localized: "scheduled-task-card.badge",
            defaultValue: "Scheduled task"
        )
        static let completed = String(
            localized: "scheduled-task-card.completed",
            defaultValue: "Done"
        )
        static let goalPrefix = String(
            localized: "scheduled-task-card.goal-prefix",
            defaultValue: "Goal: "
        )
    }
}
