import Foundation

extension AppState {
    /// Reconcile even ACKed daemon receipts before a model wake or delivery.
    /// Unknown/corrupt ownership stays pending and is excluded from this pass.
    @discardableResult
    func reconcileRevokedKernelDeliveries(for runtime: AgentRuntime) -> Set<UUID> {
        let candidates = agentRuntimeKernel.events.filter {
            $0.runtimeID == runtime.id && $0.source == .backgroundJob
                && ($0.isPendingForModel || $0.isLeasedForModel)
        }
        var cancelled: Set<UUID> = [], blocked: Set<UUID> = []
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
            NSLog("Kernel delivery deferred pending daemon ownership recovery")
        }
        return blocked
    }

    func consumeAdmittedKernelEvents(for runtime: AgentRuntime, leaseID: UUID) -> [AgentKernelEvent] {
        let blocked = reconcileRevokedKernelDeliveries(for: runtime)
        return agentRuntimeKernel.consumePendingModelEvents(for: runtime.id,
            leaseID: leaseID, excluding: blocked)
    }
}
