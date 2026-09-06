import Foundation

private enum BackgroundCompletionLimits {
    static let tailLines = 40
    static let outputCharacters = 4_000
}

extension AppState {
    func appendPendingBackgroundJobCompletions(for runtime: AgentRuntime, excluding resourceKeys: Set<String>) {
        let pending = agentJobRegistry.consumePendingCompletions(forRuntime: runtime.id)
        for job in pending {
            guard !mustDeferLegacyDaemonCompletion(job),
                  !resourceKeys.contains("background_job:\(job.id.uuidString)"),
                  !agentRuntimeKernel.hasPendingEvent(runtimeID: runtime.id,
                    source: .backgroundJob, resourceID: job.id) else { continue }
            runtime.messages.append(AgentMessage(role: .system,
                content: Self.backgroundJobCompletionNotice(for: job,
                    recentOutput: backgroundCompletionOutput(job))))
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

    private func backgroundCompletionOutput(_ job: AgentBackgroundJob) -> String? {
        guard job.needsAttention, job.outputByteCount > 0 else { return nil }
        let tail = agentJobRegistry.output(id: job.id, tailLines: BackgroundCompletionLimits.tailLines)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        let scrubbed = AgentSandboxPolicy.scrub(tail)
        let maximum = BackgroundCompletionLimits.outputCharacters
        return scrubbed.count > maximum ? "…" + String(scrubbed.suffix(maximum)) : scrubbed
    }
}
