import Foundation

extension AppState {
    func restoreDaemonStartReceipts(descriptors: [RuntimeDescriptor]? = nil,
        backendFactory: (RuntimeDescriptor) -> DaemonRuntimeBackend = { DaemonRuntimeBackend(descriptor: $0) }) async {
        do {
            let journal = agentJobRegistry.daemonStartJournal
            await agentRuntimeKernel.ensurePersistedEventsLoaded()
            let deliveries = try await Task.detached(priority: .utility) { try journal.deliveries() }.value
            let pending = try await Task.detached(priority: .utility) { try journal.pending() }.value
            let sessionIDs = Set(agentSessions.map(\.id))
            let descriptors = descriptors ?? AgentRuntimeStore.loadDescriptors()
            for delivery in deliveries where sessionIDs.contains(delivery.receipt.runtimeID) {
                guard !Task.isCancelled else { return }
                let job = try agentJobRegistry.restoreDaemonTerminal(delivery)
                guard let runtime = runtime(for: job.runtimeID) else { continue }
                if delivery.terminal.publishesCompletion == true {
                    deliverDaemonTerminalIfNeeded(job, runtime: runtime)
                }
                // Suppressed/foreground results remain visible in the registry,
                // but cannot become an unsolicited model wakeup on restart.
            }
            for record in pending where sessionIDs.contains(record.receipt.runtimeID) {
                guard !Task.isCancelled else { return }
                guard let descriptor = descriptors.first(where: { $0.id == record.receipt.remoteRuntimeID }) else {
                    agentJobRegistry.retainUnavailableDaemonStart(record.receipt)
                    runtime(for: record.receipt.runtimeID)?.errorMessage = L10n.JobReceipt.recoveryUnavailable
                    continue
                }
                do { try await backendFactory(descriptor).restoreStartReceipt(record, registry: agentJobRegistry) }
                catch {
                    agentJobRegistry.retainUnavailableDaemonStart(record.receipt)
                    runtime(for: record.receipt.runtimeID)?.errorMessage = L10n.JobReceipt.recoveryUnavailable
                }
            }
        } catch {
            // Never delete corrupt evidence or infer an empty recovery queue.
            activeRuntime?.errorMessage = L10n.JobReceipt.recoveryUnavailable
            NSLog("Daemon receipt recovery failed; persisted evidence retained")
        }
    }

    func deliverDaemonTerminalIfNeeded(_ job: AgentBackgroundJob, runtime: AgentRuntime) {
        do {
            let journal = agentJobRegistry.daemonStartJournal
            guard let delivery = try journal.delivery(id: job.id) else {
                publishBackgroundJobKernelEvent(job, runtime: runtime)
                return
            }
            guard delivery.terminal.publishesCompletion == true else { return }
            guard publishBackgroundJobKernelEvent(job, runtime: runtime, requiresDurableHandoff: true) else {
                throw AgentDaemonStartJournalError.unsafeStorage
            }
            try journal.acknowledge(delivery)
            schedulePendingAgentKernelEvents(for: runtime)
        } catch {
            runtime.errorMessage = L10n.JobReceipt.recoveryUnavailable
            NSLog("Daemon terminal handoff failed; persisted evidence retained")
        }
    }
}
