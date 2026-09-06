import Foundation

/// Routing's optional-text contract remains useful for ordinary network
/// fallback. Host budget refusal is carried separately and checked before
/// the parent sends another request or discards a useful partial answer.
@MainActor
final class AgentGoalRouteJudge {
    private let client: AgentClient
    private let executionBudget: AgentToolExecutionBudget?
    private(set) var requestStop: AgentAuxiliaryRequestStop?
    private(set) var ownerCancelled = false

    init(client: AgentClient, executionBudget: AgentToolExecutionBudget?) {
        self.client = client
        self.executionBudget = executionBudget
    }

    func text(model: String, system: String, user: String, maxTokens: Int) async -> String? {
        guard requestStop == nil, !ownerCancelled, !Task.isCancelled else { return nil }
        do {
            return try await client.budgetedRouteJudge(model: model, systemPrompt: system,
                userPayload: user, maxTokens: maxTokens, executionBudget: executionBudget)
        } catch {
            // A routing timeout/Stop is not permission to reset the budget.
            // Only typed admission/deadline failures create a persisted hold.
            ownerCancelled = error is CancellationError || Task.isCancelled
            requestStop = AgentAuxiliaryRequestStop(error)
            return nil
        }
    }
}

extension AppState {
    func stopAfterRouteJudge(_ judge: AgentGoalRouteJudge, runtime: AgentRuntime) -> Bool {
        if Task.isCancelled || judge.ownerCancelled { return true }
        guard let stop = judge.requestStop else { return false }
        pauseGoalModelRequests(stop, runtime: runtime)
        return true
    }
}
