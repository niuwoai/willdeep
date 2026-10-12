import Foundation

/// Retries one provider request, never a tool step or an entire agent run.
enum AgentEmptyResponseRetry {
    static let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]
    typealias Consumer = @Sendable (AgentClientEvent) async -> Void

    @MainActor
    static func run(
        providerID: String,
        model: String,
        returnsEmptyOutput: Bool = false,
        onEmptyOutput: (@MainActor () -> Void)? = nil,
        onEvent: @escaping Consumer,
        onRetry: (@MainActor (Int, Int) -> Void)? = nil,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        stream: (@escaping Consumer) async throws -> Void
    ) async throws {
        var accumulated = EmptyResponseAttempt.Usage()
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            let collector = EmptyResponseAttempt(onEvent: onEvent)
            var failure: Error?
            do {
                try await stream { await collector.consume($0) }
                try Task.checkCancellation()
            } catch {
                failure = error
            }
            let state = await collector.snapshot()
            accumulated.add(state.usage)
            if failure == nil, !state.hasPayload, state.allowsRetry {
                failure = AgentClientError.emptyStream(providerID: providerID, model: model)
            }
            // Managed tasks own the one allowed takeover retry. Surface only
            // a typed empty completion; transport/auth/partial-output failures
            // keep their existing error and never enter this path.
            if returnsEmptyOutput, let failure,
               case AgentClientError.emptyStream = failure,
               !state.hasPayload, state.allowsRetry {
                onEmptyOutput?()
                if let event = accumulated.event { await onEvent(event) }
                if state.didFinish { await onEvent(.finishedTurn(state.finishReason)) }
                return
            }
            guard let failure else {
                if let event = accumulated.event { await onEvent(event) }
                if state.didFinish { await onEvent(.finishedTurn(state.finishReason)) }
                return
            }
            // Once text, reasoning, references or even partial tool arguments
            // escape, replay is unsafe. HTTP/auth/parse errors are not empties.
            guard case AgentClientError.emptyStream = failure,
                  !state.hasPayload, state.allowsRetry, attempt < delays.count else {
                if let event = accumulated.event { await onEvent(event) }
                throw failure
            }
            try Task.checkCancellation()
            onRetry?(attempt + 1, delays.count)
            // Account for usage even if Stop interrupts the backoff.
            do {
                try await sleep(delays[attempt])
            } catch {
                if let event = accumulated.event { await onEvent(event) }
                throw error
            }
        }
    }
}

/// Each attempt owns fresh metadata. Failed empty finish markers cannot mark
/// the caller finished, and cumulative usage chunks count once per attempt.
private actor EmptyResponseAttempt {
    struct Usage {
        var reported = false
        var prompt = 0
        var completion = 0
        var total = 0
        var cached: Int?
        var cacheWrite: Int?
        var reasoning = 0

        mutating func add(_ other: Self) {
            guard other.reported else { return }
            reported = true
            prompt += other.prompt
            completion += other.completion
            total += other.total
            if let value = other.cached { cached = (cached ?? 0) + value }
            if let value = other.cacheWrite { cacheWrite = (cacheWrite ?? 0) + value }
            reasoning += other.reasoning
        }

        var event: AgentClientEvent? {
            guard reported else { return nil }
            return .usageReported(prompt: prompt, completion: completion, total: total,
                cachedPrompt: cached, cacheWritePrompt: cacheWrite, reasoning: reasoning)
        }
    }

    struct State {
        var hasPayload = false
        var didFinish = false
        var finishReason: String?
        var usage = Usage()
        var allowsRetry: Bool {
            // Explicit filters/refusals, length limits and tool termination
            // are not evidence of a transient empty transport response.
            guard let reason = finishReason?.lowercased(), !reason.isEmpty else { return true }
            return ["stop", "end_turn", "completed"].contains(reason)
        }
    }

    private var state = State()
    private let onEvent: AgentEmptyResponseRetry.Consumer

    init(onEvent: @escaping AgentEmptyResponseRetry.Consumer) { self.onEvent = onEvent }

    func consume(_ event: AgentClientEvent) async {
        switch event {
        case .requestIdentified:
            break
        case .textDelta(let text), .reasoningDelta(let text):
            state.hasPayload = state.hasPayload || !text.isEmpty
        case .toolCallsUpdated(let calls):
            state.hasPayload = state.hasPayload || !calls.isEmpty
        case .sourceReferencesUpdated(let references):
            state.hasPayload = state.hasPayload || !references.isEmpty
        case .finishedTurn(let reason):
            state.didFinish = true
            state.finishReason = reason
            return
        case .usageReported(let prompt, let completion, let total, let cached, let cacheWrite, let reasoning):
            state.usage = Usage(reported: true, prompt: prompt, completion: completion,
                total: total, cached: cached, cacheWrite: cacheWrite, reasoning: reasoning)
            return
        }
        await onEvent(event)
    }

    func snapshot() -> State { state }
}
