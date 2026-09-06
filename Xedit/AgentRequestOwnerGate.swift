import Foundation

/// A live host check, deliberately absent from provider/model arguments.
/// Envelopes retain this gate, not the runtime; deleting a runtime revokes it.
@MainActor
final class AgentRequestOwnerGate: Equatable {
    private let validate: () throws -> Void
    init(validate: @escaping () throws -> Void) { self.validate = validate }
    func check() throws { try Task.checkCancellation(); try validate() }
    nonisolated static func == (lhs: AgentRequestOwnerGate, rhs: AgentRequestOwnerGate) -> Bool { lhs === rhs }
}

extension AppState {
    func requestOwnerGate(for runtime: AgentRuntime) -> AgentRequestOwnerGate {
        let revision = runtime.goalAuthorizationRevision
        let owner = runtime.session.dispatchParentProjectID ?? runtime.id
        return AgentRequestOwnerGate { [weak runtime] in
            guard let runtime, runtime.goalAuthorizationRevision == revision,
                  runtime.interactionMode == .goal, let goal = runtime.currentGoal,
                  (runtime.session.dispatchParentProjectID ?? runtime.id) == owner else { throw CancellationError() }
            try AgentToolExecutionBudget(budget: goal.continuationBudget ?? .standard).check()
            if goal.continuationBudget?.modelAdmissionPaused == true { throw AgentToolExecutionBudgetError.exhausted }
        }
    }
}
