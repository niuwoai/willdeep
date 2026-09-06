import Foundation

extension AppState {
    /// No paid request, no model-generated completion claim, no new work.
    /// Keep queued input intact and persist the hold so a launch or background
    /// event cannot reinterpret this handover as permission to continue.
    func stopOnModelAdmissionFailure(_ error: Error, runtime: AgentRuntime, assistantID: UUID) -> Bool {
        guard !Task.isCancelled,
              let failure = error as? AgentModelRequestLedger.Failure else { return false }
        return pauseGoalModelRequests(.admission(failure), runtime: runtime, assistantID: assistantID)
    }

    @discardableResult
    func pauseGoalModelRequests(
        _ stop: AgentAuxiliaryRequestStop, runtime: AgentRuntime, assistantID: UUID? = nil
    ) -> Bool {
        guard !Task.isCancelled, var goal = runtime.currentGoal else { return false }
        let notice = stop.notice
        var budget = goal.continuationBudget ?? .standard
        let firstPause = budget.modelAdmissionPaused != true
        budget.wrapUpDispatched = true
        budget.modelAdmissionPaused = true
        goal.continuationBudget = budget
        runtime.currentGoal = goal
        runtime.pendingContextRunwayResume = false
        runtime.errorMessage = notice
        runtime.errorDetails = nil
        runtime.errorSeverity = .notice
        if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
           runtime.messages[index].content.isEmpty, runtime.messages[index].toolCalls.isEmpty {
            runtime.messages.remove(at: index)
            AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
        }
        if firstPause {
            let remaining = goal.checklist.filter { !$0.done }.map {
                "- " + $0.text.components(separatedBy: .newlines).joined(separator: " ")
                    .replacingOccurrences(of: "`", with: "｀")
            }.joined(separator: "\n")
            runtime.messages.append(AgentMessage(role: .assistant,
                content: notice + "\n\n" + L10n.GoalAdmission.handover + (remaining.isEmpty ? "" : "\n\n" + remaining),
                origin: .hostGenerated))
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return true
    }
}
