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
        guard var result else { return nil }
        if kind == .terminal, result.resourceID == nil {
            let terminal = prepareLocalTerminalTab(for: owner)
            updatePanelTabs(runtime: owner) {
                $0.updateTabResource(terminal.id, title: terminal.title, tabID: result.id)
            }
            result.resourceID = terminal.id
            result.customTitle = terminal.title
        } else if kind == .embeddedBrowser, result.resourceID == nil {
            let resourceID = UUID()
            updatePanelTabs(runtime: owner) {
                $0.updateTabResource(resourceID, title: nil, tabID: result.id)
            }
            result.resourceID = resourceID
        }
        let id = AgentPanelTabID(sessionID: owner.id, tabID: result.id)
        activatePanelResource(result, runtime: owner)
        AgentDetachedPanelRegistry.shared.focus(id, kind: kind)
        return id
    }

    /// Create another live instance instead of selecting the existing tab of
    /// that kind. Used by the unified workbench "+" menu for terminals and
    /// embedded browsers; singleton panels still use `openPanelTab`.
    @discardableResult
    func createPanelTab(_ kind: AgentSidePanelKind, runtime: AgentRuntime? = nil) -> AgentPanelTabID? {
        guard let owner = runtime ?? activeRuntime else { return nil }
        let resourceID: UUID?
        let title: String?
        if kind == .terminal {
            let terminal = prepareLocalTerminalTab(for: owner, alwaysCreate: true)
            resourceID = terminal.id
            title = terminal.title
        } else if kind == .embeddedBrowser {
            resourceID = UUID()
            let nextIndex = owner.sidePanelState.openTabs.filter { $0.kind == .embeddedBrowser }.count + 1
            title = "\(kind.title) \(nextIndex)"
        } else {
            return openPanelTab(kind, runtime: owner)
        }
        var result: AgentPanelTab?
        updatePanelTabs(runtime: owner) {
            result = $0.createTab(kind: kind, resourceID: resourceID, title: title)
        }
        guard let result else { return nil }
        activatePanelResource(result, runtime: owner)
        return AgentPanelTabID(sessionID: owner.id, tabID: result.id)
    }

    @discardableResult
    func createRemoteTerminalPanelTab(
        _ remoteRuntime: RuntimeDescriptor,
        runtime: AgentRuntime? = nil
    ) -> AgentPanelTabID? {
        guard let owner = runtime ?? activeRuntime else { return nil }
        let settings = editorTerminalSettings.normalized()
        let skin = settings.followsInterfaceSkin
            ? TerminalSkinColors.from(skin: editorSettings.interfaceSkin)
            : nil
        let terminal = agentTerminalController.openSSHTab(
            runtime: remoteRuntime,
            originAgentSessionID: owner.id,
            settings: settings,
            skin: skin
        )
        return openPanelTab(for: terminal, runtime: owner)
    }

    func activatePanelResource(_ tab: AgentPanelTab, runtime: AgentRuntime) {
        guard let resourceID = tab.resourceID else { return }
        switch tab.kind {
        case .terminal:
            agentTerminalController.activateTab(id: resourceID)
        case .embeddedBrowser:
            AgentEmbeddedBrowserController.activate(tabID: resourceID, for: runtime.id)
        default:
            break
        }
    }

    @discardableResult
    func openPanelTab(for terminal: AgentTerminalTab, runtime: AgentRuntime) -> AgentPanelTabID {
        var result: AgentPanelTab?
        updatePanelTabs(runtime: runtime) { state in
            if let existing = state.openTabs.first(where: {
                $0.kind == .terminal && $0.resourceID == terminal.id
            }) {
                state.selectTab(existing.id)
                result = existing
            } else {
                result = state.createTab(
                    kind: .terminal,
                    resourceID: terminal.id,
                    title: terminal.title
                )
            }
        }
        agentTerminalController.activateTab(id: terminal.id)
        guard let panelTab = result else {
            assertionFailure("Creating or selecting a terminal panel tab must produce a result")
            return AgentPanelTabID(sessionID: runtime.id, tabID: terminal.id)
        }
        return AgentPanelTabID(sessionID: runtime.id, tabID: panelTab.id)
    }

    private func prepareLocalTerminalTab(
        for runtime: AgentRuntime,
        alwaysCreate: Bool = false
    ) -> AgentTerminalTab {
        if !alwaysCreate, let existingID = agentTerminalController.ownedTabID(for: runtime.id),
           let existing = agentTerminalController.tab(id: existingID) {
            return existing
        }
        let settings = editorTerminalSettings.normalized()
        let skin = settings.followsInterfaceSkin
            ? TerminalSkinColors.from(skin: editorSettings.interfaceSkin)
            : nil
        return agentTerminalController.openLocalTab(
            originAgentSessionID: runtime.id,
            workingDirectory: runtime.workspaceLocation?.localPath ?? runtime.workspaceRootPath,
            settings: settings,
            skin: skin
        )
    }

    func closePanelTab(_ id: AgentPanelTabID) {
        guard let runtime = loadedRuntime(for: id.sessionID),
              let tab = runtime.sidePanelState.openTabs.first(where: { $0.id == id.tabID }) else { return }
        if tab.kind == .terminal, let resourceID = tab.resourceID,
           agentTerminalController.tab(id: resourceID)?.isAutomationBusy == true {
            return
        }
        AgentDetachedPanelRegistry.shared.closeTab(id)
        if let resourceID = tab.resourceID {
            switch tab.kind {
            case .terminal:
                agentTerminalController.closeTab(id: resourceID)
            case .embeddedBrowser:
                AgentEmbeddedBrowserController.release(tabID: resourceID, for: runtime.id)
            default:
                break
            }
        }
        updatePanelTabs(runtime: runtime) { $0.closeTab(id.tabID) }
    }
}
