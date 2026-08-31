import Foundation

/// Each approval belongs to one call and one registration, not one session-wide slot.
/// Delegated executors may request approval while another call is already waiting.
struct AgentToolDecisionRegistration {
    let token: UUID
    let continuation: CheckedContinuation<AgentToolDecision, Never>
}

extension AgentRuntime {
    @discardableResult
    func cancelToolDecisions(reason: String) -> Bool {
        let waiters = toolDecisionWaiters
        toolDecisionWaiters.removeAll()
        var closedAny = !waiters.isEmpty
        for index in toolCalls.indices {
            guard toolCalls[index].status.isBlockingForUserDecision
                    || AgentSerialToolApprovalQueue.contains(toolCalls[index]) else { continue }
            pendingToolDecisions.removeValue(forKey: toolCalls[index].id)
            toolCalls[index].arguments.removeValue(forKey: AgentSerialToolApprovalQueue.argumentKey)
            toolCalls[index].status = .denied
            toolCalls[index].errorMessage = reason
            closedAny = true
        }
        for waiter in waiters.values {
            waiter.continuation.resume(returning: .denied(reason: reason))
        }
        return closedAny
    }

    func cancelToolDecision(id: AgentToolCall.ID, token: UUID, reason: String) {
        guard toolDecisionWaiters[id]?.token == token,
              let waiter = toolDecisionWaiters.removeValue(forKey: id) else { return }
        if let index = toolCalls.firstIndex(where: { $0.id == id }),
           toolCalls[index].status.isBlockingForUserDecision {
            toolCalls[index].status = .denied
            toolCalls[index].errorMessage = reason
        }
        pendingToolDecisions.removeValue(forKey: id)
        waiter.continuation.resume(returning: .denied(reason: reason))
    }
}
