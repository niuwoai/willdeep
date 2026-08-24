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
/// This policy inverts the decision: nothing plans upfront, and the only
/// ground truth for "complex" is the turn actually running long. Crossing a
/// threshold injects one host instruction asking for a plan that covers the
/// remaining work.
///
/// Deliberately out of scope: Goal mode (the plan is the acceptance loop's
/// skeleton) and unattended dispatch tasks (the dispatch board projects node
/// state from plans) keep their own always-plan contracts, and a user who
/// asks for a plan gets one regardless of size.
nonisolated enum AgentPlanOnDemandPolicy {
    /// Completed tool rounds before the host asks for a checklist. Four full
    /// rounds of tool calls is past every quick lookup-and-fix; the request
    /// lands at the top of the fifth.
    static let toolRoundThreshold = 4

    /// Succeeded write-tier (write/danger) tool calls that mark a turn as
    /// multi-step even before the round threshold: three landed mutations is
    /// no longer a small edit.
    static let succeededWriteCallThreshold = 3

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
        return toolRound >= toolRoundThreshold
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
        This turn has already run \(toolRound) tool rounds without a visible checklist, so the user cannot see progress or remaining scope. In this reply, first emit exactly one complete numbered `plan` fenced block covering the REMAINING work — do not restate finished stages as pending steps — then continue executing immediately in the same reply. Planning is not a stopping point and needs no approval. From then on, report step statuses with the `update_plan` tool as they change.
        """
    }
}
