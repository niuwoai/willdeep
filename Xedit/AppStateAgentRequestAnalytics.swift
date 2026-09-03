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
}
