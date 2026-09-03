//
//  AppStateAgentHostWorkerLedger.swift
//  WillDeep
//
//  Durable accounting for workers dispatched by the host runtime. Provider-
//  requested workers persist on their `spawn_agent` tool call; preflights and
//  automatic repairs do not have one, so they use this session ledger.
//

import Foundation

extension AppState {
    private static let maximumPersistedHostWorkerRuns = 500

    @discardableResult
    func beginHostWorkerRun(
        profileID: String,
        source: AgentHostWorkerRunRecord.Source,
        userMessageID: UUID?,
        model: String?,
        providerID: String?,
        runtime: AgentRuntime
    ) -> UUID {
        let record = AgentHostWorkerRunRecord(
            userMessageID: userMessageID,
            profileID: profileID,
            source: source,
            model: model,
            providerID: providerID
        )
        var records = runtime.session.hostWorkerRuns ?? []
        records.append(record)
        if records.count > Self.maximumPersistedHostWorkerRuns {
            records.removeFirst(records.count - Self.maximumPersistedHostWorkerRuns)
        }
        runtime.session.hostWorkerRuns = records
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return record.id
    }

    func markHostWorkerRunStarted(_ id: UUID, runtime: AgentRuntime) {
        updateHostWorkerRun(id, runtime: runtime) { record in
            record.status = .running
            record.startedAt = record.startedAt ?? Date()
        }
    }

    /// `recordsTiming` is false only for the parallel scout, whose timing line
    /// is written once its delivery outcome is known rather than at finish.
    func finishHostWorkerRun(
        _ id: UUID,
        status: AgentHostWorkerRunRecord.Status,
        outcome: AgentSubagentRunner.Outcome? = nil,
        runtime: AgentRuntime,
        recordsTiming: Bool = true
    ) {
        let finishedAt = Date()
        defer {
            if recordsTiming,
               let record = runtime.session.hostWorkerRuns?.first(where: { $0.id == id }) {
                AgentWorkerTimingLog.record(AgentWorkerTimingLog.WorkerRunEntry(
                    hostRecord: record,
                    sessionID: runtime.id,
                    finishedAt: finishedAt
                ))
            }
        }
        updateHostWorkerRun(id, runtime: runtime) { record in
            record.status = status
            record.finishedAt = finishedAt
            guard let outcome else { return }
            record.usage = AgentSubagentRunUsage(
                profileID: record.profileID,
                model: record.model ?? "unknown-model",
                providerID: record.providerID,
                usageTokens: outcome.usageTokens,
                promptTokens: outcome.usageSplit.prompt,
                completionTokens: outcome.usageSplit.completion,
                cachedPromptTokens: outcome.usageSplit.cachedPrompt,
                roundCount: outcome.roundCount,
                toolInvocationCount: outcome.toolInvocationCount,
                verifierPassed: outcome.verifierPassed,
                citationsChecked: outcome.citationsChecked > 0 ? outcome.citationsChecked : nil,
                citationsUnverifiable: outcome.citationsChecked > 0
                    ? outcome.citationsUnverifiable
                    : nil
            )
        }
    }

    func markHostWorkerDelivery(
        _ id: UUID,
        accepted: Bool,
        requiredParentRepair: Bool,
        runtime: AgentRuntime
    ) {
        updateHostWorkerRun(id, runtime: runtime) { record in
            record.acceptedOutput = accepted
            record.requiredParentRepair = requiredParentRepair
        }
    }

    private func updateHostWorkerRun(
        _ id: UUID,
        runtime: AgentRuntime,
        mutate: (inout AgentHostWorkerRunRecord) -> Void
    ) {
        guard var records = runtime.session.hostWorkerRuns,
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        runtime.session.hostWorkerRuns = records
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }
}
