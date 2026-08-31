import Foundation

extension AppState {
    func updatePanelTabs(runtime: AgentRuntime, _ mutate: (inout AgentSidePanelState) -> Void) {
        var state = runtime.sidePanelState
        mutate(&state)
        guard state != runtime.sidePanelState else { return }
        runtime.sidePanelState = state
        persistAgentSidePanelState(runtime: runtime)
    }

    @discardableResult
    func openPanelTab(_ kind: AgentSidePanelKind, file: URL? = nil, runtime: AgentRuntime? = nil,
                      exactFile: Bool = false) -> AgentPanelTabID? {
        guard let owner = runtime ?? activeRuntime else { return nil }
        var result: AgentPanelTab?
        updatePanelTabs(runtime: owner) { result = $0.openTab(kind: kind, file: file, exactFile: exactFile) }
        guard let result else { return nil }
        let id = AgentPanelTabID(sessionID: owner.id, tabID: result.id)
        AgentDetachedPanelRegistry.shared.focus(id, kind: kind)
        return id
    }

    func closePanelTab(_ id: AgentPanelTabID) {
        guard let runtime = loadedRuntime(for: id.sessionID) else { return }
        AgentDetachedPanelRegistry.shared.closeTab(id)
        updatePanelTabs(runtime: runtime) { $0.closeTab(id.tabID) }
    }
}
