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
    /// `fallback` is the session's own configuration: the model used when
    /// local acceleration is off, or is on but not preferred for routing.
    func refineRouteDecisionWithModelIfNeeded(
        for runtime: AgentRuntime,
        requestText: String,
        fallback: AgentConfiguration
    ) async {
        guard let keyword = runtime.currentTurnRouteDecision else { return }
        // 操作员点了名就别再问模型了：模型是用来补关键词认不出的意图的，
        // 不是用来推翻明确指令的。
        guard !keyword.isOperatorPinned else { return }
        guard AgentWorkerRoutingModel.shouldConsultModel(for: keyword) else { return }
        guard let verdict = await routingVerdict(for: requestText, fallback: fallback) else { return }

        let merged = AgentWorkerRoutingModel.merged(keyword: keyword, verdict: verdict)
        guard merged.profileID != keyword.profileID else { return }

        runtime.currentTurnRouteDecision = merged
        runtime.currentTurnRouteSteering = merged.steering
        Self.workerRoutingLog.info(
            """
            routing model overrode keyword verdict: \
            keyword=\(keyword.profileID ?? "none", privacy: .public) \
            model=\(merged.profileID ?? "none", privacy: .public) \
            confidence=\(verdict.confidence, privacy: .public)
            """
        )
    }

    /// Ask the first usable routing model. Returns nil when no candidate
    /// answers usably — the caller then keeps the keyword decision.
    private func routingVerdict(
        for requestText: String,
        fallback: AgentConfiguration
    ) async -> AgentWorkerRoutingModel.Verdict? {
        let candidates = workerRoutingConfigurationCandidates(fallback: fallback)
        for configuration in candidates {
            do {
                let raw = try await Self.requestRoutingVerdict(
                    requestText: requestText,
                    configuration: configuration
                )
                if let verdict = AgentWorkerRoutingModel.parseVerdict(raw) {
                    return verdict
                }
                // An empty or unparsable body is the documented local-model
                // failure mode, not an exception. Try the next candidate.
                Self.workerRoutingLog.info(
                    "routing model returned an unusable reply; model=\(configuration.model, privacy: .public)"
                )
            } catch is CancellationError {
                return nil
            } catch {
                Self.workerRoutingLog.info(
                    """
                    routing model call failed; model=\(configuration.model, privacy: .public) \
                    error=\(String(describing: type(of: error)), privacy: .public)
                    """
                )
            }
        }
        return nil
    }

    /// One bounded, non-streaming-shaped call. The turn is already waiting
    /// on this, so it is capped by `AgentWorkerRoutingModel.timeout` rather
    /// than the provider's own generous defaults.
    private nonisolated static func requestRoutingVerdict(
        requestText: String,
        configuration: AgentConfiguration
    ) async throws -> String {
        let messages = [
            AgentMessage(role: .system, content: AgentWorkerRoutingModel.systemPrompt()),
            AgentMessage(role: .user, content: AgentWorkerRoutingModel.userPrompt(for: requestText))
        ]
        let collector = AgentTextCollector()
        let work = Task {
            try await AgentClient(configuration: configuration.normalized)
                .streamChat(messages: messages) { event in
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(AgentWorkerRoutingModel.timeout * 1_000_000_000))
            work.cancel()
        }
        defer { timeoutTask.cancel() }
        try await work.value
        return await collector.value
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
