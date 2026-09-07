//
//  AgentPlanProgressNudgePolicy.swift
//  WillDeep
//
//  Host-driven progress reporting for a turn that already has a plan.
//
//  The `update_plan` tool exists, the prompt asks for it at every step
//  change, and forensics still showed four out of five progress reports
//  arriving only when the turn was over: the model treats "report mid-turn"
//  as advice. So the host counts. Once a plan is executing, every
//  `roundThreshold` tool rounds without a successful `update_plan` call get
//  a short notice appended as the newest host instruction, which the next
//  request cannot ignore the way it ignores prose in the system prompt.
//
//  This is deliberately not the plan-on-demand request in
//  AgentPlanOnDemandPolicy: that one fires once per turn to *create* a plan
//  when a turn has grown; this one repeats, and only while a plan is active,
//  to keep the card honest. It is also deliberately a user-role host
//  instruction rather than a system message — every appended `.system`
//  message rewrites the provider's cached system blob.
//

import Foundation

nonisolated enum AgentPlanProgressNudgePolicy {
    /// Tool rounds an executing plan may go without `update_plan` before the
    /// host asks. Six is roughly two small steps of real work; below that the
    /// notice would land inside a step the model has not finished.
    static let roundThreshold = 6

    static func shouldNudge(
        roundsSinceLastUpdate: Int,
        hasActivePlan: Bool,
        isUnattendedDispatchTask: Bool
    ) -> Bool {
        guard hasActivePlan, !isUnattendedDispatchTask else { return false }
        return roundsSinceLastUpdate >= roundThreshold
    }

    /// Model-facing. Names the count so the model can see it is being held
    /// to a rule, and says exactly what to do next so the reply costs one
    /// tool call rather than a paragraph of apology.
    static func notice(roundsSinceLastUpdate: Int) -> String {
        """
        === PROGRESS REPORT DUE ===
        \(roundsSinceLastUpdate) tool rounds have run since the plan was last updated. \
        Before continuing, call `update_plan` with the current status of every step you have \
        started or finished since then (for example `"2: done"`, `"3: in_progress"`). Keep the \
        `note` to one line. Then carry on with the work.
        """
    }
}
