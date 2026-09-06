import Foundation

extension AppState {
    func contextMessageReader(for runtime: AgentRuntime) -> (@MainActor (AgentContextReadRequest) throws -> AgentContextReadSnapshot) {
        let revision = runtime.goalAuthorizationRevision
        let turn = runtime.activeTurnID
        let workspace = runtime.workspaceLocation
        let root = runtime.workspaceRootPath
        let executor = runtime.executionAgent
        return { [weak self, weak runtime] request in
            try Task.checkCancellation()
            guard let self, let runtime, self.agentRuntimes[runtime.id] === runtime,
                  runtime.goalAuthorizationRevision == revision, runtime.activeTurnID == turn,
                  runtime.workspaceLocation == workspace, runtime.workspaceRootPath == root,
                  runtime.executionAgent == executor else { throw AgentContextReadSnapshot.Failure.unavailable }
            return try AgentContextReadSnapshot.capture(request, messages: runtime.messages)
        }
    }
}
