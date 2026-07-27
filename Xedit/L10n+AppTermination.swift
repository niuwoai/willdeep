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
    }
}
