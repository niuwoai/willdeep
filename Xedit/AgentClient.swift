//
//  AgentClient.swift
//  Xedit
//
//  Facade over the per-protocol provider adapters
//  (OpenAI Chat / OpenAI Responses / Anthropic Messages / Gemini).
//
//  Call sites everywhere in AppState construct `AgentClient(configuration:)`
//  and call `streamChat / judgeCommandSafety / fetchModels` — they don't
//  know or care which transport protocol the configured provider speaks.
//  Routing happens here based on `configuration.inferenceProviderKind`.
//

import Foundation

/// Streamed events surfaced to the caller while a chat completion is in flight.
/// Protocol-agnostic by design — every adapter translates its native wire
/// format into this enum so AppState never sees OpenAI / Anthropic /
/// Gemini shapes directly.
enum AgentClientEvent {
    /// Assistant text delta.
    case textDelta(String)
    /// Reasoning / thinking-mode trace delta. Emitted by DashScope
    /// (qwen3, qwq), DeepSeek-R1, Claude extended thinking, and a few
    /// other providers in addition to `textDelta`. The caller MUST
    /// retain the concatenated value and echo it back on the next
    /// assistant message — DashScope responds with HTTP 400
    /// ("reasoning_content must be passed back") otherwise.
    case reasoningDelta(String)
    /// Cumulative tool calls observed so far. Each provider streams tool call
    /// arguments in fragments; the adapter merges them and re-emits the full
    /// list on every change so the caller always has the latest view.
    case toolCallsUpdated([AgentMessageToolCall])
    /// Cumulative public references reported by provider-hosted tools.
    case sourceReferencesUpdated([AgentSourceReference])
    /// Finish reason reported by the provider (e.g. "stop", "tool_calls").
    case finishedTurn(String?)
    /// Token usage emitted by the provider on the final streaming chunk
    /// (OpenAI-compatible `usage.total_tokens` / Anthropic `message_delta.usage`
    /// / Gemini `usageMetadata`). Not every provider includes it; absent →
    /// caller falls back to the estimator.
    case usageReported(
        prompt: Int,
        completion: Int,
        total: Int,
        cachedPrompt: Int?,
        cacheWritePrompt: Int?,
        reasoning: Int
    )
}

struct AgentStreamingStringFingerprint {
    private static let offsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    private(set) var byteCount = 0
    private(set) var value = Self.offsetBasis

    mutating func append(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        for byte in fragment.utf8 {
            value ^= UInt64(byte)
            value &*= Self.prime
            byteCount += 1
        }
    }

    mutating func replace(with string: String) {
        byteCount = 0
        value = Self.offsetBasis
        append(string)
    }

    var signatureComponent: String {
        "\(byteCount):\(value)"
    }
}

struct AgentToolCallStreamEmissionGate {
    private static let minimumIntervalNanoseconds: UInt64 = 100_000_000

    private var emittedSignature = ""
    private var lastEmissionNanoseconds: UInt64 = 0

    mutating func shouldEmit(signature: String, force: Bool = false) -> Bool {
        guard signature != emittedSignature else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force
            || lastEmissionNanoseconds == 0
            || now >= lastEmissionNanoseconds + Self.minimumIntervalNanoseconds else {
            return false
        }
        emittedSignature = signature
        lastEmissionNanoseconds = now
        return true
    }
}

/// Outcome of a one-shot auto-approve safety judge round trip.
/// `.allow` = model returned a clean YES; `.deny` = a clean NO (it
/// classified and refused); `.unavailable` = we never got a usable
/// verdict (missing key, network/parse error, or a reply with no verdict
/// tag — e.g. a reasoning model truncated before answering). All non-allow
/// outcomes fall back to human approval; the associated string is a short
/// reason kept for the judge audit log.
enum AgentSafetyJudgeResult: Equatable {
    case allow
    case deny
    case unavailable(String)
}

struct AgentClient {
    private let configuration: AgentConfiguration
    private let session: URLSession?
    private let someIMContext: SomeIMRequestContext?
    private let openAIResponsesContinuationState: OpenAIResponsesContinuationState

    init(
        configuration: AgentConfiguration,
        session: URLSession? = nil,
        someIMContext: SomeIMRequestContext? = nil,
        openAIResponsesContinuationState: OpenAIResponsesContinuationState = OpenAIResponsesContinuationState()
    ) {
        self.configuration = configuration.normalized
        self.session = session
        self.someIMContext = someIMContext
        self.openAIResponsesContinuationState = openAIResponsesContinuationState
    }

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        switch configuration.inferenceProviderKind {
        case .openAIChat:
            try await OpenAIChatAdapter(configuration: configuration, session: session, someIMContext: someIMContext)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .anthropicMessages:
            try await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .geminiGenerateContent:
            try await GeminiAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .openAIResponses:
            try await OpenAIResponsesAdapter(
                configuration: configuration,
                session: session,
                continuationState: openAIResponsesContinuationState,
                someIMContext: someIMContext
            )
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        }
    }

    /// Ask the configured provider whether a command is safe to auto-run.
    /// `historyContext` is an optional, caller-cached block of the
    /// operator's prior hand decisions appended to the local judge system
    /// prompt. The some.im security guard ignores this parameter because its
    /// fixed policy is injected by the gateway and the client sends only the
    /// per-command user message.
    func judgeCommandSafety(
        command: String,
        historyContext: String = ""
    ) async -> AgentSafetyJudgeResult {
        switch configuration.inferenceProviderKind {
        case .openAIChat:
            return await OpenAIChatAdapter(configuration: configuration, session: session, someIMContext: someIMContext)
                .judgeCommandSafety(command: command, historyContext: historyContext)
        case .anthropicMessages:
            return await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command, historyContext: historyContext)
        case .geminiGenerateContent:
            return await GeminiAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command, historyContext: historyContext)
        case .openAIResponses:
            return await OpenAIResponsesAdapter(
                configuration: configuration,
                session: session,
                someIMContext: someIMContext
            )
                .judgeCommandSafety(command: command, historyContext: historyContext)
        }
    }

    /// Non-streaming JSON judge round trip for some.im managed routing.
    /// Returns the raw assistant text (expected strict JSON), or nil on any
    /// failure so the caller can apply a local fallback. Resolve the transport
    /// from the judge model itself: the session's main model may speak Chat
    /// while `someim-judge` is backed by DeepSeek V4 Flash and requires the
    /// Responses wire format.
    func routeJudge(
        model: String,
        systemPrompt: String,
        userPayload: String,
        maxTokens: Int
    ) async -> String? {
        var judgeConfiguration = configuration
        judgeConfiguration.model = model
        judgeConfiguration = judgeConfiguration.normalized

        switch judgeConfiguration.inferenceProviderKind {
        case .openAIChat:
            return await OpenAIChatAdapter(configuration: judgeConfiguration, session: session, someIMContext: someIMContext)
                .routeJudge(model: model, systemPrompt: systemPrompt, userPayload: userPayload, maxTokens: maxTokens)
        case .openAIResponses:
            return await OpenAIResponsesAdapter(
                configuration: judgeConfiguration,
                session: session,
                someIMContext: someIMContext
            ).routeJudge(systemPrompt: systemPrompt, userPayload: userPayload, maxTokens: maxTokens)
        default:
            return nil
        }
    }

    func fetchModels() async throws -> [String] {
        switch configuration.providerKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: configuration, session: session, someIMContext: someIMContext)
                .fetchModels()
        case .anthropicMessages:
            return try await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .fetchModels()
        case .geminiGenerateContent:
            return try await GeminiAdapter(configuration: configuration, session: session)
                .fetchModels()
        case .openAIResponses:
            return try await OpenAIResponsesAdapter(configuration: configuration, session: session)
                .fetchModels()
        }
    }

    func fetchModelDiscoveries() async throws -> [AgentModelDiscovery] {
        switch configuration.providerKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: configuration, session: session)
                .fetchModelDiscoveries()
        case .openAIResponses:
            return try await OpenAIResponsesAdapter(configuration: configuration, session: session)
                .fetchModelDiscoveries()
        case .anthropicMessages, .geminiGenerateContent:
            return try await fetchModels().map {
                AgentModelDiscovery(id: $0, isHot: false, isNew: false)
            }
        }
    }

    /// Fold tool calls + their tool-result replies into a contiguous
    /// assistant→tool→tool… sub-sequence and drop orphaned tool
    /// messages. Used by AppState both as a pre-request normalization
    /// step and as a denominator for the token-count estimator. The
    /// rules originated in the OpenAI Chat dialect (tool_call_id must
    /// pair with a preceding `tool_calls[]`) but apply equally to
    /// Anthropic and Gemini after their respective adapters lower
    /// `AgentMessage` into wire format — so it's a protocol-agnostic
    /// pre-flight pass and lives on the facade.
    nonisolated static func providerReadyMessages(
        _ messages: [AgentMessage],
        supportsImages: Bool = true
    ) -> [AgentMessage] {
        OpenAIChatAdapter.providerReadyMessages(messages, supportsImages: supportsImages)
    }

    /// OpenAI Chat-shaped request body builder. Only meaningful for
    /// OpenAI-compatible providers; Anthropic / Gemini / Responses
    /// build their wire format internally and the test target should
    /// not be calling this for them. Lives on the facade as a
    /// back-compat forward so existing `XeditTests/AgentClientEncodingTests`
    /// (and any other call site that wants to assert OpenAI body
    /// shape) keeps compiling.
    nonisolated static func encodeChatRequest(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        supportsImages: Bool = true
    ) throws -> Data {
        try OpenAIChatAdapter.encodeChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            supportsImages: supportsImages
        )
    }
}
