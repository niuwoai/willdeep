import Foundation

extension AppState {
    func checkApprovalExecutionBudget(_ runtime: AgentRuntime) throws {
        try Task.checkCancellation()
        try auxiliaryModelExecutionBudget(for: runtime)?.checkCurrentOwner()
    }

    /// A host stop is neither a security verdict nor a human rejection.
    /// Never turn it into a new approval card or retry with another judge.
    func handleApprovalRequestStop(_ error: Error, runtime: AgentRuntime) -> String {
        if Task.isCancelled || error is CancellationError { return L10n.Dispatch.cancelled }
        if let stop = AgentAuxiliaryRequestStop(error) {
            if !pauseGoalModelRequests(stop, runtime: runtime) {
                runtime.errorMessage = stop.notice
                runtime.errorSeverity = .notice
            }
            return stop.notice
        }
        // Adapters normalize ordinary provider failures. An unexpected host
        // failure remains visible but must not expose raw request credentials.
        runtime.errorMessage = L10n.GoalAdmission.unavailable
        runtime.errorSeverity = .error
        return L10n.GoalAdmission.unavailable
    }

    func settleHostStoppedApprovals(_ ids: [UUID], notice: String, runtime: AgentRuntime, includeStaged: Bool = false) {
        for id in ids {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == id }),
                  runtime.toolCalls[index].status.isBlockingForUserDecision
                    || (runtime.toolCalls[index].status == .running
                        && (includeStaged || AgentSerialToolApprovalQueue.contains(runtime.toolCalls[index]))) else { continue }
            runtime.toolCalls[index].status = .failed
            runtime.toolCalls[index].errorMessage = notice
            runtime.toolCalls[index].approvalSource = nil
            runtime.toolCalls[index].arguments.removeValue(forKey: AgentSerialToolApprovalQueue.argumentKey)
            runtime.pendingToolDecisions.removeValue(forKey: id)
            // Do not feed budget failures into the human-decision history.
            runtime.toolDecisionWaiters.removeValue(forKey: id)?.continuation.resume(returning: .denied(reason: notice))
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Stage one has not executed any queued tools. Preserve already-recorded
    /// static denials and pair every remaining provider call exactly once.
    func stopApprovalToolRound(_ error: Error, runtime: AgentRuntime, assistantID: UUID) {
        let notice = error is CancellationError || Task.isCancelled ? L10n.Dispatch.cancelled
            : AgentAuxiliaryRequestStop(error)?.notice ?? L10n.GoalAdmission.unavailable
        settleStoppedToolRound(runtime: runtime, assistantID: assistantID, notice: notice)
        _ = handleApprovalRequestStop(error, runtime: runtime)
    }

    /// Re-evaluation already handled the owner hold. Its waiter must not
    /// reinterpret a stale/cancelled decision as a new Goal's budget failure.
    func finishHostStoppedToolRound(runtime: AgentRuntime, assistantID: UUID, recordID: UUID) {
        let notice = runtime.toolCalls.first(where: { $0.id == recordID })?.errorMessage ?? L10n.GoalAdmission.unavailable
        settleStoppedToolRound(runtime: runtime, assistantID: assistantID, notice: notice)
    }

    private func settleStoppedToolRound(runtime: AgentRuntime, assistantID: UUID, notice: String) {
        guard let assistant = runtime.messages.first(where: { $0.id == assistantID }) else { return }
        let answered = Set(runtime.messages.compactMap(\.toolCallID))
        let ids = runtime.toolCalls.filter { $0.messageID == assistantID }.map(\.id)
        settleHostStoppedApprovals(ids, notice: notice, runtime: runtime, includeStaged: true)
        for call in assistant.toolCalls where !answered.contains(call.externalID) {
            appendToolMessage(for: runtime, toolCallID: call.externalID, payload: notice,
                source: .systemNotice, outcomeStatus: .failed, errorMessage: notice)
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }
}
