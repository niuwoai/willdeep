//
//  AppStateAgentLoopLifecycle.swift
//  WillDeep
//
//  Turn lifecycle and presentation helpers kept out of the streaming loop.
//

import Foundation

extension AppState {
    @MainActor
    func telemetryCancellationReason(
        for runtime: AgentRuntime,
        turnID: UUID
    ) -> TelemetryCancellationReason {
        if runtime.userStoppedTurnID == turnID {
            return .userStop
        }
        if runtime.shouldConsumeQueueAfterStop {
            return .queuedMessageTakeover
        }
        if runtime.activeTurnID != turnID {
            return .runtimeReplaced
        }
        return .taskCancelled
    }

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
            runtime.contextSummaryInstalledAt = nil
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

    /// Show the session's own side-panel browser before an embedded-browser
    /// tool runs. Unlike Terminal the browser belongs to one session, so a
    /// background session only records the tab in its own panel state and
    /// never takes over the panel of the session on screen.
    @discardableResult
    func revealEmbeddedBrowserPanelForToolExecution(
        toolName: String,
        runtime: AgentRuntime,
        now: Date = Date()
    ) -> Bool {
        guard AgentEmbeddedBrowserAutomationPolicy.requiresVisiblePanel(toolName: toolName) else {
            return false
        }
        // Show the browser tab the tool will drive. With no such tab yet,
        // opening one also activates its resource, so the tool below and the
        // panel share one web view.
        let activeResourceID = AgentEmbeddedBrowserController.activeTabID(for: runtime.id)
        if let activeTab = runtime.sidePanelState.openTabs.first(where: {
            $0.kind == .embeddedBrowser && $0.resourceID != nil && $0.resourceID == activeResourceID
        }) {
            updatePanelTabs(runtime: runtime) { $0.selectTab(activeTab.id) }
        } else {
            _ = openPanelTab(.embeddedBrowser, runtime: runtime)
        }
        var sidePanelState = runtime.sidePanelState
        sidePanelState.lastViewedAt = now
        runtime.sidePanelState = sidePanelState
        persistAgentSidePanelState(runtime: runtime)

        guard activeRuntime === runtime else { return false }
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .embeddedBrowser)
        return true
    }

    /// A cancelled transport may unwind after the stop fallback started a new turn.
    /// Only the current owner may clear runtime state or schedule continuations.
    func finishAgentLoopTurn(
        for runtime: AgentRuntime, turnID: UUID, providerSlotClaimID: UUID,
        providerID: String, shouldResumePendingEvents: Bool
    ) {
        guard runtime.activeTurnID == turnID else {
            releaseProviderSlot(for: runtime, claimID: providerSlotClaimID, providerID: providerID)
            return
        }
        let shouldConsumeQueueAfterStop = runtime.shouldConsumeQueueAfterStop
        let wasUserStopped = runtime.userStoppedTurnID == turnID
        let wasRuntimeBudgetStopped = runtime.feedbackBudgetStopReason != nil
        runtime.isResponding = false
        runtime.turnStartedAt = nil
        runtime.requestTask = nil
        runtime.activeTurnID = nil
        runtime.activeTurnConfiguration = nil
        // A Goal parked on a wait is still executing; its checkpoint must
        // survive a crash during the wait (AppStateAgentGoalWakes.swift).
        if runtime.currentGoal?.scheduledWake == nil { runtime.goalTurnRecoveryCheckpoint = nil }
        runtime.shouldConsumeQueueAfterStop = false
        auditDelegationPolicyForFinishedTurn(in: runtime)
        // Turn finished — one fewer concurrent worker on this checkout.
        refreshAgentWorkspaceCollision()
        if !wasUserStopped && !wasRuntimeBudgetStopped {
            captureAgentPlanFromLatestMessage(for: runtime)
            let didDefineGoal = captureAgentGoalDefinitionFromLatestMessage(for: runtime)
            // Only the successful prose-only reply path may evaluate a
            // completed Plan and advance it into a fresh planning cycle.
            startAgentGoalPlanningAfterCaptureIfNeeded(didDefineGoal, for: runtime)
        }
        // A turn that ended with a tool call nobody executed is not a
        // finished turn. Say so and resume it; see AgentTurnWatchdog.
        noteAgentTurnEnded(for: runtime, turnID: turnID)
        // The watchdog must observe the stop marker before it is cleared;
        // otherwise pending tool calls are mistaken for a crash and resumed.
        runtime.userStoppedTurnID = nil
        persistAgentSession(runtime: runtime)
        noteIndependentLaneFinished(runtime)
        // Runs after the persist so the record reads the same settled
        // state the session file just captured. No-op for anything a
        // human started.
        recordRoutineRunCompletionIfNeeded(for: runtime)
        if !wasUserStopped, !wasRuntimeBudgetStopped, !shouldConsumeQueueAfterStop {
            // A runway stop means the window is already at 90%, well past
            // the ordinary 75% trigger — but `shouldAutoCompressNow` can
            // still refuse (too few messages, a tail that will not split).
            // Ask for it explicitly so the ordered stop is always followed
            // by the compression it promised the model.
            if runtime.pendingContextRunwayResume {
                compressAgentContext(for: runtime, keepRecent: 2)
            } else {
                maybeAutoCompressContext(for: runtime)
            }
        }
        consumeNextQueuedMessageIfNeeded(for: runtime)
        // Always release the provider slot last so the queue drain
        // sees a fully cleared `isResponding` and won't refuse to
        // dispatch a queued user message that's for the same runtime.
        releaseProviderSlot(
            for: runtime,
            claimID: providerSlotClaimID,
            providerID: providerID
        )
        // A background job can finish in the tiny window between this
        // turn's last drain and its end. If one did — and no queued
        // user message just claimed the runtime above — kick a fresh
        // turn so the completion isn't stranded until the next message.
        let wasKernelPreempted = agentKernelPreemptedRuntimeIDs.remove(runtime.id) != nil
        if !wasUserStopped && (shouldResumePendingEvents || wasKernelPreempted) {
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
        // 放在最后：排队消息或后台完成若已经拉起新一轮，这里看到的是
        // isResponding == true，自然不预测。
        if !wasUserStopped && !wasRuntimeBudgetStopped {
            requestAgentInputSuggestionIfNeeded(for: runtime)
        }
        noteGoalTurnFinished(for: runtime, turnID: turnID)
        scheduleDeferredHumanGateWork(for: runtime)
    }
}
