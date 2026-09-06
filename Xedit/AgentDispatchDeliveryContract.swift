import Foundation

/// A live delivery attempt binds evidence to the same requested outcome and
/// authorized inputs across suspension points. This is not a persisted proof.
@MainActor
struct AgentDispatchDeliveryContract: Equatable {
    let definition: String
    let runtimeGoal: String?
    let runtimeWorkspace: WorkspaceLocation?
    let inputRevision: String?
    let integrationBase: String?
    let operatorAcceptedAt: Date?
    let deliveryRevisionID: UUID?

    init(goal: AgentDispatchGoal, task: AgentDispatchTask, runtime: AgentRuntime) throws {
        definition = try AgentDispatchDecision.contractDigest(goal: goal, task: task)
        runtimeGoal = runtime.currentGoal.map(AgentGoalVerification.contractDigest)
        runtimeWorkspace = runtime.workspaceLocation
        inputRevision = task.inputRevision
        integrationBase = goal.resolvedWorkspaceBinding(for: task).flatMap { goal.integrationBaseRevisions?[$0.id] }
        operatorAcceptedAt = task.operatorAcceptedAt
        deliveryRevisionID = task.deliveryRevisionID
    }
}
