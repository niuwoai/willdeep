//
//  AppStateAgentRepeatedCallGuard.swift
//  WillDeep
//
//  Hooks for `AgentRepeatedCallGuard`: every real tool result is observed as
//  it is appended to the transcript, and the Goal continuation decision asks
//  whether the round was spent repeating itself. Ordinary conversations only
//  get the note; Goal rounds past the stall threshold also stop counting as
//  progress, which moves the Goal up its backoff ladder.
//

import Foundation

extension AppState {
    /// Observe one tool result and return the note to append to it (empty
    /// when there is nothing to say). Denied calls and host notices without a
    /// matching model call are not observations of the tool.
    func repeatedToolCallNote(
        for runtime: AgentRuntime,
        toolCallID: String,
        payload: String,
        outcomeStatus: AgentToolCallStatus?
    ) -> String {
        let outcome: AgentRepeatedCallLedger.Outcome
        switch outcomeStatus {
        case .succeeded?: outcome = .succeeded(resultDigest: AgentRepeatedCallGuard.digest(payload))
        case .failed?: outcome = .failed
        default: return ""
        }
        guard let call = runtime.messages.reversed().lazy.compactMap({ message in
            message.role == .assistant ? message.toolCalls.first { $0.externalID == toolCallID } : nil
        }).first else { return "" }

        let tracksGoal = runtime.interactionMode == .goal && runtime.currentGoal != nil
        var ledger = tracksGoal
            ? runtime.currentGoal?.repeatedCallLedger ?? AgentRepeatedCallLedger()
            : runtime.currentTurnRepeatedCallLedger
        let count = ledger.observe(toolName: call.toolName, argumentsJSON: call.argumentsJSON, outcome: outcome)
        if tracksGoal {
            runtime.currentGoal?.repeatedCallLedger = ledger
        } else {
            runtime.currentTurnRepeatedCallLedger = ledger
        }
        guard let count, count >= AgentRepeatedCallGuard.hintThreshold else { return "" }
        let stalls = tracksGoal && count >= AgentRepeatedCallGuard.stallThreshold
        if stalls { runtime.repeatedCallStallSinceLastContinuationDecision = true }
        return "\n\n" + AgentRepeatedCallGuard.note(toolName: call.toolName, count: count,
            failed: outcome == .failed, countsAgainstGoalProgress: stalls)
    }

    /// A new dispatch starts a fresh per-turn ledger. A human message also
    /// clears the Goal's ledger: the operator changing course is new input.
    func resetRepeatedCallGuardForDispatch(for runtime: AgentRuntime, source: AgentMessageSource?) {
        runtime.currentTurnRepeatedCallLedger = AgentRepeatedCallLedger()
        if source == .operatorInput {
            runtime.repeatedCallStallSinceLastContinuationDecision = false
            if runtime.currentGoal?.repeatedCallLedger != nil { runtime.currentGoal?.repeatedCallLedger = nil }
        }
    }

    /// Called once per continuation decision. Returns true when this round's
    /// tool activity must not count as progress: a Goal call repeated past
    /// the stall threshold and the checklist did not move. While the Plan is
    /// still executing nothing else feeds the Goal ladder, so the round is
    /// counted here; once the Plan is done the acceptance loop counts it.
    func settleRepeatedCallStallForContinuationDecision(
        for runtime: AgentRuntime,
        checklistAdvanced: Bool
    ) -> Bool {
        let stalled = runtime.repeatedCallStallSinceLastContinuationDecision
        runtime.repeatedCallStallSinceLastContinuationDecision = false
        guard stalled, runtime.interactionMode == .goal, !checklistAdvanced,
              runtime.currentGoal?.checklist.allSatisfy(\.done) != true else { return false }
        if runtime.currentPlan?.status != .done {
            runtime.consecutiveGoalRoundsWithoutChecklistProgress += 1
        }
        return true
    }
}
