//
//  AppStateAgentRuntimeWakeups.swift
//  WillDeep
//
//  Queue draining and host-triggered runtime wakeups. Keeping these lifecycle
//  transitions outside the provider loop makes the kernel boundary explicit.
//

import Foundation

extension AppState {
    func consumeNextQueuedMessageIfNeeded(for runtime: AgentRuntime) {
        // Wait for any in-flight compression to finish — otherwise the
        // user's queued message would race a compression that just got
        // kicked off in the same defer block.
        guard !runtime.isResponding, !runtime.isCompressingContext else { return }
        guard let next = runtime.queuedMessages.first else { return }
        runtime.queuedMessages.removeFirst()
        // Re-stage the queued turn's delegation directive: dispatch reads it
        // off the runtime, and it was cleared when the previous turn started.
        runtime.pendingDelegationPolicy = next.delegationPolicy
        dispatchAgentMessageUsingSelectedExecutor(
            next.executionAgent,
            for: runtime,
            text: next.text,
            images: next.images,
            textAttachments: next.textAttachments,
            attachedSkills: next.attachedSkills,
            source: next.source
        )
    }

    /// Auto-resume an idle agent after an event reaches the host runtime.
    /// Active turns drain at their next boundary, so this path never creates
    /// a phantom user message and never races a live provider request.
    @MainActor
    func resumeAgentLoopForPendingBackgroundCompletions(for runtime: AgentRuntime) {
        guard !runtime.isResponding,
              !runtime.isAwaitingProviderSlot,
              !runtime.isCompressingContext,
              runtime.requestTask == nil else { return }
        guard hasPendingBackgroundWakeups(for: runtime) else { return }

        repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID
        guard acquireProviderSlotIfPossible(providerID: providerID) else { return }

        runtime.isAwaitingProviderSlot = false
        runtime.clearTurnError()
        runtime.latestComputerUseActivity = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        let turnID = UUID()
        runtime.activeTurnID = turnID
        runtime.activeTurnConfiguration = configuration
        runtime.userStoppedTurnID = nil
        let providerSlotClaim = claimProviderSlot(for: runtime, providerID: providerID)

        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self else { return }
            guard let runtime else {
                self.releaseProviderSlot(providerID: providerID)
                return
            }
            await self.runAgentLoop(
                for: runtime,
                configuration: configuration,
                providerSlotClaimID: providerSlotClaim.id,
                turnID: turnID
            )
        }
    }

    @MainActor
    func hasPendingBackgroundWakeups(for runtime: AgentRuntime) -> Bool {
        agentRuntimeKernel.pendingModelEventCount(for: runtime.id) > 0
            || agentJobRegistry.pendingCompletionCount(forRuntime: runtime.id) > 0
            || agentMediaTaskRegistry.pendingCompletionCount(forRuntime: runtime.id) > 0
            || agentSubagentRegistry.pendingReportCount(forParentRuntime: runtime.id) > 0
            || !runtime.pendingWorkflowCompletionReportIDs.isEmpty
    }

    /// Retry stranded wakeups whenever provider capacity becomes available.
    @MainActor
    func resumeAgentLoopsWithPendingBackgroundCompletions() {
        for runtime in agentRuntimes.values where hasPendingBackgroundWakeups(for: runtime) {
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
    }
}
