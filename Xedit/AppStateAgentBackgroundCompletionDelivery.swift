import Foundation

extension AppState {
    func appendPendingBackgroundJobCompletions(for runtime: AgentRuntime, excluding resourceKeys: Set<String>) {
        let pending = agentJobRegistry.consumePendingCompletions(forRuntime: runtime.id)
        for job in pending {
            guard !mustDeferLegacyDaemonCompletion(job),
                  !resourceKeys.contains("background_job:\(job.id.uuidString)"),
                  !agentRuntimeKernel.hasPendingEvent(runtimeID: runtime.id,
                    source: .backgroundJob, resourceID: job.id) else { continue }
            runtime.messages.append(AgentMessage(role: .system,
                content: renderBackgroundJobCompletionNotice(for: job)))
        }
    }

    private func mustDeferLegacyDaemonCompletion(_ job: AgentBackgroundJob) -> Bool {
        guard job.remoteRuntimeID != nil else { return false }
        do {
            // A durable result awaiting admission cannot bypass its receipt
            // through the legacy, unleased completion channel.
            return try agentJobRegistry.daemonStartJournal.delivery(id: job.id) != nil
        } catch {
            NSLog("Daemon completion retained pending receipt reconciliation")
            return true
        }
    }
}
