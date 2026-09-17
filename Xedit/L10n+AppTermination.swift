//
//  L10n+AppTermination.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum AppTermination {
        static let title = String(
            localized: "app-termination.active-task.title",
            defaultValue: "Tasks are still running"
        )
        static let message = String(
            localized: "app-termination.active-task.message",
            defaultValue: "Quitting now may interrupt active work and stop progress updates. Do you still want to quit WillDeep?"
        )
        static let keepWorking = String(
            localized: "app-termination.active-task.keep-working",
            defaultValue: "Keep Working"
        )
        static let quitAnyway = String(
            localized: "app-termination.active-task.quit-anyway",
            defaultValue: "Quit Anyway"
        )
        /// `%@` is a bulleted list of job labels, one per line.
        static func detachedJobsKeepRunning(_ list: String) -> String {
            String(
                format: String(
                    localized: "app-termination.detached-jobs.keep-running",
                    defaultValue: "These background tasks will keep running after WillDeep quits and reconnect on next launch:\n%@"
                ),
                list
            )
        }
    }
}
