import Foundation

extension AppState {
    /// Every retry uses the same producer ID and journal dedupe key. This
    /// method deliberately contains no suspension point between ACK and wake.
    func deliverMediaCompletion(_ task: AgentMediaTask) {
        guard let runtimeID = task.runtimeID,
              agentSessions.contains(where: { $0.id == runtimeID && $0.archivedAt == nil }) else { return }
        if let owner = EditorAppStateRegistry.shared.appState(containingSession: runtimeID), owner !== self { return }
        guard let runtime = runtime(for: runtimeID) else { return }
        let store = agentMediaTaskRegistry.completionStore
        do {
            let delivery = try store.prepare(task)
            guard !delivery.settled else { return }
            if let turnID = delivery.task.ownerTurnID,
               try agentJobRegistry.completionOwnerWasStopped(runtimeID: runtimeID, turnID: turnID) {
                // Resolve any already-published event before retiring producer
                // evidence; a stopped owner must not revive on the next launch.
                let ids = Set(agentRuntimeKernel.events.filter {
                    $0.runtimeID == runtimeID && $0.source == .mediaTask
                        && $0.metadata["resource_id"] == task.id.uuidString
                }.map(\.id))
                agentRuntimeKernel.resolveModelDeliveriesAtSource(ids)
                try store.settle(id: task.id)
                return
            }
            guard let event = publishMediaTaskKernelEvent(delivery.task, runtime: runtime,
                requiresDurableHandoff: true) else { return }
            if event.resolvedModelDeliveryState == .handled {
                try store.settle(id: task.id)
                return
            }
            try store.acknowledge(id: task.id)
            if !delivery.handedOff {
                recordAgentMediaTaskCompletion(task: delivery.task, runtimeID: runtimeID)
            }
            schedulePendingAgentKernelEvents(for: runtime)
        } catch {
            runtime.errorMessage = L10n.JobReceipt.recoveryUnavailable
            NSLog("Media completion handoff deferred; producer evidence retained")
        }
    }
}
