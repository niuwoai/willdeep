//
//  AgentPlanContinuation.swift
//  WillDeep
//
//  Plan execution continuity and explicit plan-only intent.
//

import Foundation

nonisolated enum AgentPlanContinuationPolicy {
    /// An active Plan remains the execution contract until progress marks
    /// it done or the operator explicitly requests a revision. A complex
    /// follow-up must not silently replace it.
    ///
    /// A user-interrupted plan is no longer the contract: the operator
    /// pressed Stop, so their next message may start a different task and
    /// its plan must be allowed to take over. Resuming the old plan (a
    /// progress report against it) clears the interruption and restores
    /// the contract.
    static func hasActiveExecutionContract(_ plan: AgentPlan?) -> Bool {
        guard let plan, !plan.isInterrupted else { return false }
        return plan.status == .approved || plan.status == .executing
    }

    /// Delegated CLI executors cannot rely on the native system prompt, so
    /// carry the approved Plan in the task text that is handed to them.
    static func delegatedExecutionTask(
        userText: String,
        currentPlan: AgentPlan?
    ) -> String {
        if AgentExecutionIntentPolicy.requestsPlanningOnly(userText) {
            return """
            \(userText)

            === PLANNING ONLY — READ-ONLY ===
            Inspect only what is necessary, return a concrete plan, and do not edit files, run mutating commands, or change external state.
            """
        }
        // hasActiveExecutionContract, not a raw status check: after the
        // user interrupts a plan, their next task must reach the delegated
        // executor verbatim instead of being rewritten into "execute the
        // old plan, do not re-plan".
        guard let currentPlan, hasActiveExecutionContract(currentPlan) else {
            return userText
        }

        let steps = currentPlan.steps.enumerated()
            .map { "\($0.offset + 1). [\($0.element.status.rawValue)] \($0.element.text)" }
            .joined(separator: "\n")
        let summary = currentPlan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryBlock = summary.isEmpty ? "" : "\nPlan summary: \(summary)"
        return """
        \(userText)

        === ACTIVE WILLDEEP PLAN — EXECUTE, DO NOT RE-PLAN ===\(summaryBlock)
        \(steps)

        Execute these steps end-to-end and report verified progress; do not replace them with another plan.
        """
    }

}

nonisolated enum AgentExecutionIntentPolicy {
    private static let executionOverrides = [
        "不要只规划", "不要只分析", "不用只规划", "直接执行", "直接做",
        "don't just plan", "do not just plan", "execute directly", "just do it",
    ]
    private static let planningOnlyHints = [
        "只规划", "只要计划", "只给计划", "仅规划", "仅给计划",
        "先给计划", "先列计划", "先分析不要执行", "不要执行", "暂不执行",
        "先别执行", "不要修改", "不要动代码",
        "plan only", "only plan", "planning only", "do not execute",
        "don't execute", "do not implement", "don't implement",
        "without executing", "without implementation",
    ]

    static func requestsPlanningOnly(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              !executionOverrides.contains(where: normalized.contains) else {
            return false
        }
        return planningOnlyHints.contains(where: normalized.contains)
    }

    static func blocksExecution(risk: AgentToolRisk) -> Bool {
        risk == .write || risk == .danger
    }
}
