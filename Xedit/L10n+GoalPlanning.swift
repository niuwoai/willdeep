//
//  L10n+GoalPlanning.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum GoalPlanning {
        static let arbitration = String(localized: "goal-planning.arbitration", defaultValue: "Evidence arbitration")
        static let header = String(localized: "goal-planning.header", defaultValue: "Goal Teams planning")
        static let phaseArbitrating = String(localized: "goal-planning.phase.arbitrating", defaultValue: "Arbitrating")
        static let phaseAwaitingApproval = String(localized: "goal-planning.phase.awaiting-approval", defaultValue: "Awaiting approval")
        static let phaseBlocked = String(localized: "goal-planning.phase.blocked", defaultValue: "Blocked")
        static let phaseCollecting = String(localized: "goal-planning.phase.collecting", defaultValue: "Independent review")
        static let phaseCompleted = String(localized: "goal-planning.phase.completed", defaultValue: "Completed")
        static let phaseExecuting = String(localized: "goal-planning.phase.executing", defaultValue: "Executing")
        static let phaseSynthesizing = String(localized: "goal-planning.phase.synthesizing", defaultValue: "Synthesizing proposal")
        static let retry = String(localized: "goal-planning.retry", defaultValue: "Retry planning")
        static let statusCompleted = String(localized: "goal-planning.status.completed", defaultValue: "Completed")
        static let statusFailed = String(localized: "goal-planning.status.failed", defaultValue: "Failed")
        static let statusInterrupted = String(localized: "goal-planning.status.interrupted", defaultValue: "Interrupted")
        static let statusPending = String(localized: "goal-planning.status.pending", defaultValue: "Pending")
        static let statusRunning = String(localized: "goal-planning.status.running", defaultValue: "Running")
    }
}
