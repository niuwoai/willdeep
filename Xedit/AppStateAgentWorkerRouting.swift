//
//  AppStateAgentWorkerRouting.swift
//  WillDeep
//
//  Running the model half of worker routing.
//
//  The keyword router decides first and always has an answer. This layer
//  only runs when that answer came from a fallback branch, and it can only
//  ever improve the routed trade — never block the turn, never widen what
//  the turn is allowed to do. Anything that goes wrong returns the keyword
//  decision untouched.
//

import Foundation
import OSLog

extension AppState {
    private static let workerRoutingLog = Logger(
        subsystem: "com.willdeep.app",
        category: "worker-routing"
    )

    /// Refine this turn's already-computed keyword decision with a model,
    /// in place. Runs inside the turn's async region, before the read-only
    /// preflight reads `currentTurnRouteDecision`.
    ///
    /// No-ops when routing is disabled for this turn, when the keyword
    /// decision already matched a marker, or when no model answers usably —
    /// the keyword decision then stands exactly as it was.
    ///
    func refineRouteDecisionWithModelIfNeeded(
        for runtime: AgentRuntime,
        requestText: String
    ) async {
        guard let keyword = runtime.currentTurnRouteDecision else { return }
        // 操作员点了名就别再问模型了：模型是用来补关键词认不出的意图的，
        // 不是用来推翻明确指令的。
        guard !keyword.isOperatorPinned else { return }
        guard AgentWorkerRoutingModel.shouldConsultModel(for: keyword) else { return }
        guard let verdict = await routingVerdict(
            for: requestText,
            runtimeID: runtime.id
        ) else { return }

        let merged = AgentWorkerRoutingModel.merged(keyword: keyword, verdict: verdict)
        guard merged.profileID != keyword.profileID else { return }

        runtime.currentTurnRouteDecision = merged
        runtime.currentTurnRouteSteering = merged.steering(
            for: runtime.currentTurnDelegationPolicy
        )
        Self.workerRoutingLog.notice(
            """
            routing model overrode keyword verdict: \
            keyword=\(keyword.profileID ?? "none", privacy: .public) \
            model=\(merged.profileID ?? "none", privacy: .public) \
            confidence=\(verdict.confidence, privacy: .public)
            """
        )
    }

    // MARK: - 特权档否决

    /// Start the veto confirmation for a privileged keyword route, without
    /// waiting for it.
    ///
    /// Fire-and-store: the turn keeps the ticket and collects it either
    /// before the serial preflight (which would otherwise dispatch the
    /// worker under the unrevised decision) or at the first tool boundary,
    /// whichever comes first. Nothing here blocks the first token — that is
    /// invariant 1 in `docs/NEXT_TASKS_2026-09-03_WORKER_LATENCY.md` §4.
    func startRouteVetoIfNeeded(for runtime: AgentRuntime, requestText: String) async {
        runtime.pendingRouteVeto = nil
        guard let keyword = runtime.currentTurnRouteDecision else { return }
        guard AgentWorkerRoutingVeto.shouldRequestVeto(for: keyword) else { return }
        // `/no-subagent` 时 guard 本就不生效，没有可否决的强制。
        guard runtime.currentTurnDelegationPolicy != .forbidden else { return }
        guard let configuration = await readyWorkerRoutingConfiguration() else { return }

        let runtimeID = runtime.id
        let startedAt = Date()
        let task = Task { [weak self] () -> Result<
            AgentWorkerRoutingVeto.Verdict,
            AgentWorkerRoutingVeto.Unusable
        > in
            guard let self else { return .failure(.emptyContent) }
            do {
                let raw = try await self.requestAuxiliaryVerdict(
                    systemPrompt: AgentWorkerRoutingVeto.systemPrompt(),
                    userPrompt: AgentWorkerRoutingVeto.userPrompt(for: requestText),
                    configuration: configuration,
                    runtimeID: runtimeID
                )
                return AgentWorkerRoutingVeto.parseVerdict(raw)
            } catch {
                // 取消与失败都归为「读不到答案」，两者的处置完全相同：维持。
                return .failure(.emptyContent)
            }
        }

        runtime.pendingRouteVeto = AgentWorkerRoutingVeto.Ticket(
            requestText: requestText,
            keywordDecision: keyword,
            startedAt: startedAt,
            model: configuration.normalized.model,
            task: task
        )
    }

    /// Collect the veto if one is in flight, and downgrade when it says so.
    ///
    /// Idempotent: the ticket is cleared on the way in, so the preflight and
    /// the tool boundary can both call it and only the first one waits.
    /// Every outcome except an explicit `upheld == false` leaves the keyword
    /// decision untouched.
    func resolveRouteVetoIfPending(for runtime: AgentRuntime) async {
        guard let ticket = runtime.pendingRouteVeto else { return }
        runtime.pendingRouteVeto = nil

        let budget = ticket.remainingBudget
        guard budget > 0 else {
            ticket.task.cancel()
            recordRouteVeto(ticket: ticket, outcome: .timedOut, runtime: runtime)
            return
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            ticket.task.cancel()
        }
        defer { timeoutTask.cancel() }

        switch await ticket.task.value {
        case .failure(let reason):
            recordRouteVeto(ticket: ticket, outcome: .unusable(reason), runtime: runtime)
        case .success(let verdict) where verdict.upheld:
            recordRouteVeto(ticket: ticket, outcome: .upheld(verdict), runtime: runtime)
        case .success(let verdict):
            guard let downgraded = AgentWorkerRoutingVeto.downgradedDecision(
                for: ticket.requestText,
                delegationPolicy: runtime.currentTurnDelegationPolicy
            ) else {
                // 关键词表在跳过特权分支后什么都没给出——没有可降级的目标，
                // 维持原判比凭空造一个安全。
                recordRouteVeto(ticket: ticket, outcome: .upheldWithoutTarget(verdict), runtime: runtime)
                return
            }
            runtime.currentTurnRouteDecision = downgraded
            runtime.currentTurnRouteSteering = downgraded.steering(
                for: runtime.currentTurnDelegationPolicy
            )
            recordRouteVeto(
                ticket: ticket,
                outcome: .downgraded(verdict, to: downgraded),
                runtime: runtime
            )
            Self.workerRoutingLog.notice(
                """
                routing veto downgraded privileged route: \
                keyword=\(ticket.keywordDecision.profileID ?? "none", privacy: .public) \
                downgraded=\(downgraded.profileID ?? "none", privacy: .public) \
                confidence=\(verdict.confidence, privacy: .public)
                """
            )
        }
    }

    private func recordRouteVeto(
        ticket: AgentWorkerRoutingVeto.Ticket,
        outcome: AgentRouteVetoAuditLog.Outcome,
        runtime: AgentRuntime
    ) {
        AgentRouteVetoAuditLog.record(
            ticket: ticket,
            outcome: outcome,
            sessionID: runtime.id
        )
    }

    /// Ask the warm local routing model. Cold/unavailable local models are
    /// skipped and warmed in the background; there is no remote judge call.
    private func routingVerdict(
        for requestText: String,
        runtimeID: UUID
    ) async -> AgentWorkerRoutingModel.Verdict? {
        guard let configuration = await readyWorkerRoutingConfiguration() else { return nil }
        do {
            let raw = try await requestRoutingVerdict(
                requestText: requestText,
                configuration: configuration,
                runtimeID: runtimeID
            )
            guard let verdict = AgentWorkerRoutingModel.parseVerdict(raw) else {
                Self.workerRoutingLog.notice(
                    "routing model returned an unusable reply; model=\(configuration.model, privacy: .public)"
                )
                return nil
            }
            return verdict
        } catch is CancellationError {
            return nil
        } catch {
            Self.workerRoutingLog.notice(
                """
                routing model call failed; model=\(configuration.model, privacy: .public) \
                error=\(String(describing: type(of: error)), privacy: .public)
                """
            )
            return nil
        }
    }

    /// One bounded, non-streaming-shaped call. The turn is already waiting
    /// on this, so it is capped by `AgentWorkerRoutingModel.timeout` rather
    /// than the provider's own generous defaults.
    private func requestRoutingVerdict(
        requestText: String,
        configuration: AgentConfiguration,
        runtimeID: UUID
    ) async throws -> String {
        try await requestAuxiliaryVerdict(
            systemPrompt: AgentWorkerRoutingModel.systemPrompt(),
            userPrompt: AgentWorkerRoutingModel.userPrompt(for: requestText),
            configuration: configuration,
            runtimeID: runtimeID
        )
    }

    /// The shared call shape for both routing questions — "which trade?" and
    /// "is this really operations work?". Same budget, same accounting, same
    /// residency restore, so a second question cannot quietly acquire
    /// different timeout semantics than the first.
    private func requestAuxiliaryVerdict(
        systemPrompt: String,
        userPrompt: String,
        configuration: AgentConfiguration,
        runtimeID: UUID
    ) async throws -> String {
        let normalized = configuration.normalized
        let messages = [
            AgentMessage(role: .system, content: systemPrompt),
            AgentMessage(role: .user, content: userPrompt)
        ]
        let collector = AgentTextCollector()
        let measurement = AgentAuxiliaryRequestMeasurement()
        let keepAlive = AgentLocalModelRoutingReadiness.routingKeepAlive(
            warmOnLaunchAndKeepResident: AgentSettingsStore
                .loadLocalModelSettings()
                .warmOnLaunchAndKeepResident
        )
        let baseURL = normalized.baseURL
        let model = normalized.model
        let work = Task {
            try await AgentClient(configuration: normalized)
                .streamChat(messages: messages) { event in
                    await measurement.consume(event)
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(AgentWorkerRoutingModel.timeout * 1_000_000_000))
            work.cancel()
        }
        defer {
            timeoutTask.cancel()
            // Ollama's OpenAI-compatible endpoint resets residency to its
            // five-minute default. Restore the lazy 10-minute window (or
            // permanent residency) out of band so routing adds no new wait.
            Task.detached(priority: .utility) {
                _ = await AgentLocalModelResidency.shared.assertResident(
                    baseURL: baseURL,
                    model: model,
                    keepAlive: keepAlive
                )
            }
        }
        do {
            try await work.value
            recordAuxiliaryModelRequest(
                await measurement.record(
                    purpose: .workerRouting,
                    providerID: normalized.providerID,
                    modelID: normalized.model,
                    isLocal: AgentLocalModelPrompting.isLocalProvider(normalized),
                    succeeded: true
                ),
                runtimeID: runtimeID
            )
            return await collector.value
        } catch {
            recordAuxiliaryModelRequest(
                await measurement.record(
                    purpose: .workerRouting,
                    providerID: normalized.providerID,
                    modelID: normalized.model,
                    isLocal: AgentLocalModelPrompting.isLocalProvider(normalized),
                    succeeded: false
                ),
                runtimeID: runtimeID
            )
            throw error
        }
    }
}

/// Minimal actor so the streaming callback can accumulate text without
/// crossing isolation boundaries.
actor AgentTextCollector {
    private var buffer = ""

    func append(_ delta: String) {
        buffer += delta
    }

    var value: String { buffer }
}
