import Foundation

/// Source-plan commands are distinct from commands inferred by the host at launch.
/// Remembering the source avoids treating every ordinary synchronization as an edit.
nonisolated struct AgentDispatchPlanCommands: Codable, Equatable {
    let commands: [String]?
}

extension AgentDispatchCoordinator {
    nonisolated static func reviseProjectedTasks(_ tasks: inout [AgentDispatchTask],
                                                previous: AgentDispatchGoal?, parentDigest: String,
                                                statement: String) {
        guard let previous else { return }
        let old = Dictionary(uniqueKeysWithValues: previous.tasks.map { ($0.id, $0) })
        let parentChanged = previous.statement != statement
            || previous.sourceGoalContractDigest.map { $0 != parentDigest } == true
        let currentIDs = Set(tasks.map(\.id))
        var affected = Set(previous.tasks.filter { !currentIDs.contains($0.id) }.map(\.id))
        for task in tasks {
            guard let prior = old[task.id] else { affected.insert(task.id); continue }
            if parentChanged || task.title != prior.title || task.acceptanceCriteria != prior.acceptanceCriteria
                || task.dependencyIDs != prior.dependencyIDs
                || (prior.sourcePlanCommands != nil && task.sourcePlanCommands != prior.sourcePlanCommands) {
                affected.insert(task.id)
            }
        }
        // The old graph matters too: removing an edge does not make evidence
        // produced with the old prerequisite valid under the new definition.
        let graph = previous.tasks + tasks
        while true {
            let expanded = affected.union(graph.filter { !affected.isDisjoint(with: $0.dependencyIDs) }.map(\.id))
            if expanded == affected { break }
            affected = expanded
        }
        for index in tasks.indices where affected.contains(tasks[index].id) {
            let prior = old[tasks[index].id]
            if prior == nil && !previous.hasStartedExecution { continue }
            tasks[index].deliveryRevisionID = UUID()
            tasks[index].integrationCandidate = nil
            tasks[index].integrationReceipt = nil
            tasks[index].operatorAcceptedAt = nil
            tasks[index].pendingDecisionIDs = nil
            tasks[index].resumedDecisionIDs = nil
            tasks[index].attemptedProfileIDs = []
            let cancelled = prior?.state == .cancelled || tasks[index].state == .cancelled
            tasks[index].state = cancelled ? .cancelled : .blocked
            tasks[index].pendingOutcomeRevision = previous.hasStartedExecution && !cancelled
            tasks[index].updatedAt = Date()
        }
    }
}

extension AppState {
    /// Called on the main actor before publishing a projected graph. The old
    /// task/journal identity is still current, so Stop cannot target a new epoch.
    func stopSupersededDispatchProjection(previous: [AgentDispatchGoal], projected: [AgentDispatchGoal]) {
        let next = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        for goal in previous {
            let tasks = Dictionary(uniqueKeysWithValues: (next[goal.id]?.tasks ?? []).map { ($0.id, $0) })
            for task in goal.tasks {
                guard tasks[task.id] == nil || tasks[task.id]?.deliveryRevisionID != task.deliveryRevisionID else { continue }
                invalidateDispatchMonitor(taskID: task.id)
                if [.running, .reviewing, .accepted].contains(task.state) || dispatchTaskHasLiveWork(task) {
                    _ = stopDispatchTask(goalID: goal.id, taskID: task.id)
                } else { stopDispatchDelivery(goalID: goal.id, taskID: task.id) }
            }
        }
    }
}
