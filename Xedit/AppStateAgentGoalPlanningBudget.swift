import Foundation

extension AppState {
    /// Block before cancelling siblings: their completion callbacks must not
    /// see an all-finished collecting round and start a paid arbitration.
    @discardableResult
    func stopGoalPlanningOnRequestFailure(_ error: Error, runtime: AgentRuntime) -> Bool {
        guard let stop = AgentAuxiliaryRequestStop(error) else { return false }
        return stopGoalPlanningOnRequestStop(stop, runtime: runtime)
    }

    @discardableResult
    func stopGoalPlanningOnRequestStop(_ stop: AgentAuxiliaryRequestStop, runtime: AgentRuntime) -> Bool {
        guard !Task.isCancelled, runtime.currentGoal != nil else { return false }
        var runIDs = Set<UUID>()
        if var state = runtime.goalPlanningState {
            runIDs = Set(state.members.compactMap(\.runID))
            for index in state.members.indices where [.pending, .running].contains(state.members[index].status) {
                state.members[index].status = .interrupted
            }
            state.phase = .blocked
            state.arbitration = .init(status: .failed, errorMessage: stop.notice)
            runtime.goalPlanningState = state
        }
        pauseGoalModelRequests(stop, runtime: runtime)
        agentSubagentRegistry.cancelGoalPlanningRuns(runIDs)
        return true
    }
}
