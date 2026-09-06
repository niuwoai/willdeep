import Foundation

nonisolated struct AgentDispatchOutcomeOverride: Codable, Equatable {
    let goalStatement: String
    let title: String
    let acceptanceCriteria: [String]
}

nonisolated struct AgentDispatchOutcomeRevision {
    let goalID: UUID
    let taskID: UUID
    let outcome: AgentDispatchOutcomeOverride
    let definitions: [UUID: String]
    let originalStates: [UUID: AgentDispatchTaskState]
    let resumesStartedProject: Bool
    let isNoOp: Bool
}

extension AgentDispatchCoordinator {
    func prepareOutcomeRevision(goalID: UUID, taskID: UUID, title: String,
                                acceptanceCriteria: [String]) -> AgentDispatchOutcomeRevision? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let goal = goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID }) else { return nil }
        let trimmed = acceptanceCriteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let criteria = trimmed.isEmpty ? [L10n.Dispatch.defaultAcceptanceCriterion] : trimmed
        var affected: Set<UUID> = [taskID]
        while true {
            let descendants = Set(goal.tasks.filter { !affected.isDisjoint(with: $0.dependencyIDs) }.map(\.id))
            let expanded = affected.union(descendants)
            if expanded == affected { break }
            affected = expanded
        }
        var definitions: [UUID: String] = [:]
        for node in goal.tasks where affected.contains(node.id) {
            guard let digest = try? AgentDispatchDecision.contractDigest(goal: goal, task: node) else { return nil }
            definitions[node.id] = digest
        }
        return .init(goalID: goalID, taskID: taskID,
            outcome: .init(goalStatement: goal.statement, title: title, acceptanceCriteria: criteria),
            definitions: definitions,
            originalStates: Dictionary(uniqueKeysWithValues: goal.tasks.filter { affected.contains($0.id) }.map { ($0.id, $0.state) }),
            resumesStartedProject: goal.hasStartedExecution,
            isNoOp: task.title == title && task.acceptanceCriteria == criteria)
    }

    @discardableResult
    func applyOutcomeRevision(_ revision: AgentDispatchOutcomeRevision) -> Bool {
        guard let current = goals.first(where: { $0.id == revision.goalID }),
              revision.definitions.allSatisfy({ id, digest in
                  guard let task = current.tasks.first(where: { $0.id == id }) else { return false }
                  return (try? AgentDispatchDecision.contractDigest(goal: current, task: task)) == digest
              }) else { return false }
        if revision.isNoOp { return true }
        updateGoal(id: revision.goalID) { goal in
            for index in goal.tasks.indices where revision.originalStates[goal.tasks[index].id] != nil {
                let id = goal.tasks[index].id
                if id == revision.taskID {
                    goal.tasks[index].outcomeOverride = revision.outcome
                    goal.tasks[index].title = revision.outcome.title
                    goal.tasks[index].acceptanceCriteria = revision.outcome.acceptanceCriteria
                }
                goal.tasks[index].deliveryRevisionID = UUID()
                goal.tasks[index].integrationCandidate = nil
                goal.tasks[index].integrationReceipt = nil
                goal.tasks[index].operatorAcceptedAt = nil
                goal.tasks[index].pendingDecisionIDs = nil
                goal.tasks[index].resumedDecisionIDs = nil
                goal.tasks[index].attemptedProfileIDs = []
                let cancelled = revision.originalStates[id] == .cancelled
                goal.tasks[index].state = cancelled ? .cancelled : .blocked
                goal.tasks[index].pendingOutcomeRevision = revision.resumesStartedProject && !cancelled
                goal.tasks[index].updatedAt = Date()
            }
            let merged = Set(goal.tasks.filter { $0.state == .merged }.map(\.id))
            for index in goal.tasks.indices where revision.originalStates[goal.tasks[index].id] != nil {
                if goal.tasks[index].state == .blocked,
                   Set(goal.tasks[index].dependencyIDs).isSubset(of: merged) {
                    goal.tasks[index].state = .queued
                }
            }
            goal.updatedAt = Date()
        }
        return true
    }
}

extension AppState {
    @discardableResult
    func reviseDispatchTaskOutcome(goalID: UUID, taskID: UUID, title: String,
                                   acceptanceCriteria: [String]) -> Bool {
        guard let revision = agentDispatchCoordinator.prepareOutcomeRevision(goalID: goalID,
            taskID: taskID, title: title, acceptanceCriteria: acceptanceCriteria) else { return false }
        if revision.isNoOp { return true }
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }) else { return false }
        for task in goal.tasks where revision.originalStates[task.id] != nil {
            invalidateDispatchMonitor(taskID: task.id)
            if [.running, .reviewing, .accepted].contains(task.state) || dispatchTaskHasLiveWork(task) {
                _ = stopDispatchTask(goalID: goalID, taskID: task.id)
            } else { stopDispatchDelivery(goalID: goalID, taskID: task.id) }
        }
        guard agentDispatchCoordinator.applyOutcomeRevision(revision) else { return false }
        scheduleDispatchDecisionResumption()
        return true
    }

    func resumePendingOutcomeRevisions(goalID: UUID) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }), !goal.isPaused else { return }
        let pending = Set(goal.tasks.filter { $0.pendingOutcomeRevision == true }.map(\.id))
        guard !pending.isEmpty else { return }
        let capacity = AgentDispatchParallelismPolicy.taskLimit(providerConcurrencyLimit: perProviderConcurrencyLimit)
        for id in readyDispatchTaskIDs(goalID: goalID, capacity: capacity) where pending.contains(id) {
            _ = launchDispatchTask(goalID: goalID, taskID: id, explicitlyRequested: false)
        }
    }
}
