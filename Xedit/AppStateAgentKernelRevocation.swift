import Foundation

extension AppState {
    /// Reconcile daemon receipts and recorded media owners before model delivery.
    /// Unknown/corrupt ownership stays pending and is excluded from this pass.
    @discardableResult
    func reconcileRevokedKernelDeliveries(for runtime: AgentRuntime) -> Set<UUID> {
        let candidates = agentRuntimeKernel.events.filter {
            $0.runtimeID == runtime.id && $0.source == .backgroundJob
                && ($0.isPendingForModel || $0.isLeasedForModel)
        }
        var cancelled: Set<UUID> = [], blocked = reconcileMediaKernelDeliveryOwners(for: runtime)
        for event in candidates {
            guard let resource = event.metadata["resource_id"], let id = UUID(uuidString: resource) else {
                if event.hasOutstandingDurableDelivery { blocked.insert(event.id) }
                continue
            }
            do {
                guard let ownership = try agentJobRegistry.daemonStartJournal.executionOwnership(
                    id: id, runtimeID: runtime.id) else {
                    if event.hasOutstandingDurableDelivery { blocked.insert(event.id) }
                    continue
                }
                if ownership.cancellationRequested
                    || !agentJobRegistry.allowsDaemonTerminalDelivery(ownership.receipt) {
                    cancelled.insert(event.id)
                }
            } catch {
                blocked.insert(event.id)
            }
        }
        agentRuntimeKernel.resolveModelDeliveriesAtSource(cancelled)
        for event in candidates where cancelled.contains(event.id) || blocked.contains(event.id) {
            if let resource = event.metadata["resource_id"], let id = UUID(uuidString: resource) {
                // The visible kernel event retains responsibility. Its legacy
                // duplicate cannot bypass a cancelled or blocked delivery.
                agentJobRegistry.markCompletionSurfaced(id: id, forRuntime: runtime.id)
            }
        }
        if !cancelled.isEmpty {
            Task { @MainActor [weak self] in await self?.retryDeferredDaemonTerminalDeliveries() }
        }
        if !blocked.isEmpty {
            runtime.errorMessage = L10n.JobReceipt.recoveryUnavailable
            NSLog("Kernel delivery deferred pending producer ownership recovery")
        }
        return blocked
    }

    func consumeAdmittedKernelEvents(for runtime: AgentRuntime, leaseID: UUID) -> [AgentKernelEvent] {
        let blocked = reconcileRevokedKernelDeliveries(for: runtime)
        return agentRuntimeKernel.consumePendingModelEvents(for: runtime.id,
            leaseID: leaseID, excluding: blocked)
    }

    private func reconcileMediaKernelDeliveryOwners(for runtime: AgentRuntime) -> Set<UUID> {
        let candidates = agentRuntimeKernel.events.filter {
            $0.runtimeID == runtime.id && $0.source == .mediaTask
                && ($0.isPendingForModel || $0.isLeasedForModel)
        }
        var cancelled: Set<UUID> = [], blocked: Set<UUID> = []
        for event in candidates {
            if event.metadata["completion_outbox"] != nil {
                do {
                    guard event.metadata["completion_outbox"] == "1",
                          let rawID = event.metadata["resource_id"], let id = UUID(uuidString: rawID),
                          let delivery = try agentMediaTaskRegistry.completionStore.delivery(id: id),
                          delivery.task.runtimeID == runtime.id,
                          delivery.task.ownerTurnID?.uuidString == event.metadata["owner_turn_id"] else {
                        blocked.insert(event.id)
                        continue
                    }
                    if delivery.settled {
                        cancelled.insert(event.id)
                        continue
                    }
                    guard delivery.handedOff else {
                        blocked.insert(event.id)
                        continue
                    }
                } catch {
                    blocked.insert(event.id)
                    continue
                }
            }
            // Legacy/manual media did not record an owner. Do not invent one
            // from the currently active turn, which may be a later request.
            guard let rawOwner = event.metadata["owner_turn_id"] else { continue }
            guard let owner = UUID(uuidString: rawOwner) else {
                blocked.insert(event.id)
                continue
            }
            do {
                if try agentJobRegistry.completionOwnerWasStopped(runtimeID: runtime.id, turnID: owner) {
                    cancelled.insert(event.id)
                }
            } catch {
                blocked.insert(event.id)
            }
        }
        agentRuntimeKernel.resolveModelDeliveriesAtSource(cancelled)
        for event in candidates where cancelled.contains(event.id) || blocked.contains(event.id) {
            if let rawID = event.metadata["resource_id"], let id = UUID(uuidString: rawID) {
                agentMediaTaskRegistry.markCompletionSurfaced(id: id, forRuntime: runtime.id)
            }
        }
        return blocked
    }
}
