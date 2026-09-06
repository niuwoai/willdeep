//
//  AppStateAgentLoopLifecycle.swift
//  WillDeep
//
//  Turn lifecycle and presentation helpers kept out of the streaming loop.
//

import Foundation

extension AppState {
    func clearAgentConversation() {
        agentRequestTask?.cancel()
        if let runtime = activeRuntime {
            for observer in runtime.stopCleanupObservers.values {
                observer.cancel()
            }
            runtime.stopCleanupObservers.removeAll()
            runtime.activeTurnID = nil
            runtime.activeTurnConfiguration = nil
            runtime.userStoppedTurnID = nil
            cancelAllWorkflows(for: runtime)
            agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
        }
        agentMessages.removeAll()
        if let runtime = activeRuntime {
            runtime.contextSummary = nil
            runtime.contextSummaryThroughMessageID = nil
            runtime.contextCheckpoint = nil
            discardContextCheckpointCache(for: runtime)
        }
        agentPatchProposals.removeAll()
        activeRuntime?.clearLocalPanelPreview()
        agentToolCalls.removeAll()
        agentQueuedMessages.removeAll()
        agentPendingImages.removeAll()
        agentPendingTextAttachments.removeAll()
        activeRuntime?.latestComputerUseActivity = nil
        activeRuntime?.clearTurnError()
        activeRuntime?.cancelToolDecisions(reason: "Conversation cleared")
        activeRuntime?.pendingToolDecisions.removeAll()
        isAgentResponding = false
        agentTurnStartedAt = nil
        persistActiveAgentSession()
    }

    /// Stable local key for a runtime's workspace, mirroring
    /// `AgentSession.workspaceSidebarGroupKey` but from the live runtime.
    static func managedWorkspaceKey(for runtime: AgentRuntime) -> String {
        if let sidebarWorkspaceRootPath = runtime.session.sidebarWorkspaceRootPath,
           !sidebarWorkspaceRootPath.isEmpty {
            return sidebarWorkspaceRootPath
        }
        let location = runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) }
        switch location {
        case .local(let path):
            return path.isEmpty ? AgentSession.noWorkspaceSidebarGroupKey : path
        case .remote(let runtimeID, let path):
            return "remote:\(runtimeID.uuidString):\(RemotePathValidator.normalizedWorkspaceRoot(path))"
        case .none:
            return AgentSession.noWorkspaceSidebarGroupKey
        }
    }

    /// Ends a turn that stopped for context runway while preserving any
    /// honest Plan/Goal status carried by the handoff.
    func concludeContextRunwayHandoff(
        for runtime: AgentRuntime,
        finishReason: String?
    ) {
        if canResumeAfterContextCompaction(for: runtime) {
            runtime.pendingContextRunwayResume = true
        }
        _ = captureAgentPlanFromLatestMessage(for: runtime)
        if runtime.interactionMode == .goal {
            _ = captureAgentGoalEvaluationFromLatestMessage(
                for: runtime,
                finishReason: finishReason
            )
        }
    }

    /// Make Agent-driven terminal mutations observable before dispatch.
    @discardableResult
    func revealTerminalPanelForToolExecution(
        toolName: String,
        runtime: AgentRuntime,
        now: Date = Date()
    ) -> Bool {
        guard AgentTerminalAutomationPolicy.requiresVisiblePanel(toolName: toolName) else {
            return false
        }

        let canRevealPanel = activeRuntime != nil
        if canRevealPanel {
            agentSidePanelKind = .terminal
            agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .terminal)
        }

        if let activeTerminal = agentTerminalController.activeTab,
           activeTerminal.originAgentSessionID == runtime.id {
            _ = openPanelTab(for: activeTerminal, runtime: runtime)
        } else {
            _ = openPanelTab(.terminal, runtime: runtime)
        }
        var sidePanelState = runtime.sidePanelState
        sidePanelState.lastViewedAt = now
        runtime.sidePanelState = sidePanelState
        persistAgentSidePanelState(runtime: runtime)
        return canRevealPanel
    }
}
