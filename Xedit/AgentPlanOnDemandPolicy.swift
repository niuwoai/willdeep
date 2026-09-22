//
//  AgentPlanOnDemandPolicy.swift
//  WillDeep
//
//  Plans on demand: measure task size instead of predicting it.
//

import Foundation

/// Decides when a plan-less turn has demonstrably grown multi-step and the
/// host should ask for a visible checklist.
///
/// The previous contract asked the model to judge upfront whether a task was
/// "genuinely multi-step" and plan accordingly. Models systematically
/// over-trigger on that judgment — planning looks diligent — so every small
/// task paid for a plan block plus the machinery that follows one
/// (`update_plan` reporting rounds, format corrections, reconciliation).
/// This policy inverts the decision: nothing plans upfront. A long read-only
/// investigation remains evidence gathering; only a turn that has entered
/// write execution can cross the threshold that asks for a remaining-work
/// plan.
///
/// Deliberately out of scope: Goal mode (the plan is the acceptance loop's
/// skeleton) and unattended dispatch tasks (the dispatch board projects node
/// state from plans) keep their own always-plan contracts. An ordinary user
/// request for planning still obeys the visible three-step minimum below.
nonisolated enum AgentPlanOnDemandPolicy {
    /// Ordinary visible checklists need enough independent work to justify
    /// their own lifecycle and progress chrome. One or two actions are an
    /// execution note, not a plan.
    static let minimumVisibleStepCount = 3

    /// Completed tool rounds before the host asks for a checklist. Four full
    /// rounds of tool calls is past every quick lookup-and-fix; the request
    /// lands at the top of the fifth.
    static let toolRoundThreshold = 4

    /// Succeeded write-tier (write/danger) tool calls that mark a turn as
    /// multi-step even before the round threshold: three landed mutations is
    /// no longer a small edit.
    static let succeededWriteCallThreshold = 3

    /// Whether a succeeded call counts toward the write threshold. Browser
    /// tools are write-tier for approval (they load pages and click), but
    /// navigating a page to look something up is evidence gathering, not
    /// execution: a single Baidu lookup tripped "PLAN REQUESTED" at round 4.
    static func countsAsExecutionWrite(toolName: String, risk: AgentToolRisk) -> Bool {
        guard risk != .read else { return false }
        return !toolName.hasPrefix("embedded_browser_") && !toolName.hasPrefix("chrome_")
    }

    static func shouldRequestPlan(
        toolRound: Int,
        succeededWriteCalls: Int,
        hasActivePlan: Bool,
        interactionMode: AgentInteractionMode,
        isUnattendedDispatchTask: Bool
    ) -> Bool {
        guard interactionMode == .normal,
              !isUnattendedDispatchTask,
              !hasActivePlan else {
            return false
        }
        // Read-only rounds alone never earn a plan. Research, analysis,
        // diagnosis, log inspection, and operations troubleshooting often
        // need many evidence-gathering calls, but turning that exploration
        // into a checklist adds ceremony without clarifying execution. Once
        // a mutation succeeds, a long turn has crossed into execution and a
        // remaining-work checklist can become useful.
        return (succeededWriteCalls > 0 && toolRound >= toolRoundThreshold)
            || succeededWriteCalls >= succeededWriteCallThreshold
    }

    /// Host instruction injected once per turn when the threshold trips.
    ///
    /// The plan must be forward-looking and must not become a stopping
    /// point — the whole point of lazy planning is that the visible
    /// checklist arrives without costing the small-task path anything, so
    /// the big-task path must not pay an approval pause either.
    static func requestNotice(toolRound: Int) -> String {
        """
        === PLAN REQUESTED — TASK HAS GROWN MULTI-STEP ===
        This turn has already crossed from evidence gathering into multi-step execution after \(toolRound) tool rounds. If at least \(minimumVisibleStepCount) independent steps still remain, first emit exactly one complete numbered `plan` fenced block covering only that REMAINING work — do not restate finished stages as pending steps — then continue executing immediately in the same reply. If fewer than \(minimumVisibleStepCount) independent steps remain, do not emit a plan block; continue directly. Planning is not a stopping point and needs no approval. From then on, report step statuses with the `update_plan` tool as they change.
        """
    }
}
