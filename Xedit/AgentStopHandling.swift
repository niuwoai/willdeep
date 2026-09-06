//
//  AgentStopHandling.swift
//  WillDeep
//
//  User-initiated Agent turn interruption and current-turn process cleanup.
//

import Foundation

extension AppState {
    @MainActor
    static func isStoppedTurnCancellation(
        _ error: Error,
        runtime: AgentRuntime,
        turnID: UUID
    ) -> Bool {
        guard runtime.userStoppedTurnID == turnID else { return false }
        if error is CancellationError || Task.isCancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    @MainActor
    func finalizeInterruptedAssistantMessage(
        id: AgentMessage.ID,
        in runtime: AgentRuntime,
        startedAt: Date
    ) {
        guard let index = runtime.messages.firstIndex(where: { $0.id == id }) else { return }
        let message = runtime.messages[index]
        let isEmptyPlaceholder = message.content.isEmpty
            && message.images.isEmpty
            && message.toolCalls.isEmpty
            && (message.reasoningContent ?? "").isEmpty
        if isEmptyPlaceholder {
            runtime.messages.remove(at: index)
            AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
        } else {
            runtime.messages[index].elapsedSeconds = Date().timeIntervalSince(startedAt)
        }
    }

    @MainActor
    func appendStoppedTurnEvent(to runtime: AgentRuntime, content: String) -> AgentMessage.ID {
        let event = AgentMessage(
            role: .system,
            content: content,
            transcriptEvent: .responseStopped
        )
        runtime.messages.append(event)
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return event.id
    }

    @MainActor
    func updateStoppedTurnEvent(
        id: AgentMessage.ID,
        in runtime: AgentRuntime,
        content: String
    ) {
        guard let index = runtime.messages.firstIndex(where: { $0.id == id }) else { return }
        runtime.messages[index].content = content
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Stop is a host decision over registered ownership, never another paid
    /// model request. Observe actual local exits without polling or waking AI.
    @MainActor
    func startStoppedTurnProcessCleanup(
        runtime: AgentRuntime,
        turnID: UUID,
        eventID: AgentMessage.ID
    ) {
        guard runtime.userStoppedTurnID == turnID,
              runtime.stopCleanupObservers[turnID] == nil else { return }
        let jobs = agentJobRegistry.aliveJobs(forRuntime: runtime.id, originatingTurnID: turnID)
        let owned = jobs.filter { !$0.survivesTurnStop }
        let retained = jobs.count - owned.count
        let localIDs = Set(owned.filter { agentJobRegistry.hasLocalProcessExitReceipt(id: $0.id) }.map(\.id))
        let managed = owned.count - localIDs.count
        updateStoppedTurnEvent(id: eventID, in: runtime, content: L10n.StopLifecycle.status(
            pendingLocal: localIDs.count, stoppedLocal: 0, managedRequested: managed, retained: retained))
        if !localIDs.isEmpty {
            let observer = AgentStopCleanupObserver(jobIDs: localIDs) { [weak self, weak runtime] in
                guard let self, let runtime else { return }
                runtime.stopCleanupObservers.removeValue(forKey: turnID)
                self.updateStoppedTurnEvent(id: eventID, in: runtime, content: L10n.StopLifecycle.status(
                    pendingLocal: 0, stoppedLocal: localIDs.count, managedRequested: managed, retained: retained))
            }
            runtime.stopCleanupObservers[turnID] = observer
            observer.start(registry: agentJobRegistry)
        }
        for job in owned {
            agentJobRegistry.requestStop(id: job.id, runtimeID: runtime.id, turnID: turnID)
        }
    }
}
