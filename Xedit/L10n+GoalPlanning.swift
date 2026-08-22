//
//  L10n+GoalPlanning.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum GoalPlanning {
        static let arbitration = String(localized: "goal-planning.arbitration", defaultValue: "Evidence arbitration")
        static let budgetExhausted = String(localized: "goal-planning.budget-exhausted", defaultValue: "Goal paused: this execution segment ran out of budget. WillDeep asked for a handover snapshot. Press play to grant a new segment and continue.")
        /// 被 Goal 门禁拦下的工具卡上那行字。旧文案是 "Goal planning validation
        /// required"，用户读完既不知道是谁在 validate，也不知道要不要动手——
        /// 而正确答案恰恰是「什么都不用做」。
        static let gateBlockedTool = String(localized: "goal-planning.gate-blocked-tool", defaultValue: "Locked while Goal planning runs — no action needed from you")
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
