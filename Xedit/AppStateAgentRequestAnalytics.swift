import Foundation

extension AppState {
    /// Persist helper-call measurements with the owning conversation. Records
    /// contain no prompt or response content. The cap protects long-lived
    /// sessions from unbounded JSON growth while retaining far more than the
    /// seven-day drill-down normally needs.
    @MainActor
    func recordAuxiliaryModelRequest(
        _ record: AgentAuxiliaryModelRequestRecord,
        runtimeID: UUID
    ) {
        guard let runtime = agentRuntimes[runtimeID],
              let sessionIndex = agentSessions.firstIndex(where: { $0.id == runtimeID }) else { return }
        runtime.session.auxiliaryModelRequests.append(record)
        let maximumRecords = 20_000
        if runtime.session.auxiliaryModelRequests.count > maximumRecords {
            runtime.session.auxiliaryModelRequests.removeFirst(
                runtime.session.auxiliaryModelRequests.count - maximumRecords
            )
        }
        // This metric-only save intentionally skips persistAgentSession's
        // title-summarization trigger; recording a title helper must not start
        // another title helper recursively.
        runtime.persist(touchUpdatedAt: false)
        agentSessions[sessionIndex] = runtime.session
        upsertAgentUsageSnapshot(for: runtime.session)
    }

    /// A managed-routing answer that failed the quality check is deleted
    /// before the escalated retry; without this its tokens vanished from
    /// usage and the "cost including retries" figure under-counted.
    func recordDiscardedEscalationAttempt(
        _ message: AgentMessage,
        configuration: AgentConfiguration,
        runtimeID: UUID
    ) {
        recordAuxiliaryModelRequest(AgentAuxiliaryModelRequestRecord(
            purpose: .discardedEscalationAttempt,
            providerID: message.requestProviderID ?? configuration.providerID,
            modelID: message.requestModelID ?? configuration.model,
            isLocal: false,
            createdAt: message.createdAt,
            promptTokens: message.promptTokens,
            completionTokens: message.completionTokens,
            elapsedSeconds: message.elapsedSeconds ?? 0,
            succeeded: true
        ), runtimeID: runtimeID)
    }

    /// Judge calls used to be invisible to usage: no transcript message, no
    /// auxiliary record. One record per physical judge request, successful
    /// or not — a failed call can still be billed.
    func recordJudgeRequest(
        _ measurement: AgentAuxiliaryRequestMeasurement,
        purpose: AgentAuxiliaryRequestPurpose,
        configuration: AgentConfiguration,
        model: String? = nil,
        succeeded: Bool,
        runtimeID: UUID?
    ) async {
        guard let runtimeID else { return }
        let record = await measurement.record(
            purpose: purpose,
            providerID: configuration.providerID,
            modelID: model ?? configuration.model,
            isLocal: false,
            succeeded: succeeded
        )
        recordAuxiliaryModelRequest(record, runtimeID: runtimeID)
    }
}
