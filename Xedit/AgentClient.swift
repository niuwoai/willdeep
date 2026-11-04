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
    /// Gateway request identifier returned in `X-Request-Id`. It contains no
    /// prompt or response content and lets cancellation telemetry correlate a
    /// client-side reason with the matching usage row.
    case requestIdentified(String)
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

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// 裁判问的是哪个问题。两者的**失败方向相反**，所以调用方必须显式选，
/// 不能靠默认值蒙混：
///  - `.developerOperations`：「这是正常的开发/运维操作吗」，拿不准判 NO
///    （智能审核与 Goal 用它，宁可多问一次）；
///  - `.maliciousIntent`：「这条命令是不是在干坏事」，拿不准判 YES
///    （保留给恶意意图分类兼容路径）。
enum AgentSafetyJudgeKind: Equatable, Sendable {
    case developerOperations
    case maliciousIntent
}

struct AgentClient {
    private let configuration: AgentConfiguration
    private let session: URLSession?
    private let someIMContext: SomeIMRequestContext?
    private let requestLedger: AgentModelRequestLedger?
    private let openAIResponsesContinuationState: OpenAIResponsesContinuationState
    private let onRoutedModel: (@MainActor @Sendable (String) -> Void)?

    init(
        configuration: AgentConfiguration,
        session: URLSession? = nil,
        someIMContext: SomeIMRequestContext? = nil,
        openAIResponsesContinuationState: OpenAIResponsesContinuationState = OpenAIResponsesContinuationState(),
        requestLedger: AgentModelRequestLedger? = nil,
        onRoutedModel: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        var effective = configuration.normalized
        if effective.magpieConnection != nil {
            do {
                try effective.validateMagpieConnection()
                effective.baseURL = try AgentMagpieIntegration.validatedBaseURL(effective.baseURL)
            } catch let failure as AgentMagpieIntegration.Failure { effective.magpieFailure = failure }
            catch { effective.magpieFailure = .init(code: .url) }
        }
        self.configuration = effective
        self.session = effective.magpieConnection == nil ? session : AgentMagpieTransport.sharedSession
        self.someIMContext = someIMContext
        self.requestLedger = requestLedger
        self.openAIResponsesContinuationState = openAIResponsesContinuationState
        self.onRoutedModel = onRoutedModel
    }

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        executionBudget: AgentToolExecutionBudget? = nil,
        allowsEmptyTaskTakeover: Bool = false,
        onEmptyResponseRetry: (@MainActor (Int, Int) -> Void)? = nil,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        try configuration.validateMagpieConnection()
        if let executionBudget {
            try await executionBudget.runModelRequest {
                try await streamChatRetryLoop(messages: messages, tools: tools, executionBudget: executionBudget,
                    allowsEmptyTaskTakeover: allowsEmptyTaskTakeover,
                    onEmptyResponseRetry: onEmptyResponseRetry, onEvent: onEvent)
            }
            return
        }
        try await streamChatRetryLoop(messages: messages, tools: tools, executionBudget: nil,
            allowsEmptyTaskTakeover: allowsEmptyTaskTakeover,
            onEmptyResponseRetry: onEmptyResponseRetry, onEvent: onEvent)
    }

    private func streamChatRetryLoop(messages: [AgentMessage], tools: [AgentToolDescriptor],
        executionBudget: AgentToolExecutionBudget?, allowsEmptyTaskTakeover: Bool,
        onEmptyResponseRetry: (@MainActor (Int, Int) -> Void)?,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void) async throws {
        if let broker = AgentRSIApprovedBroker.current {
            try await broker.run(configuration: configuration, messages: messages, tools: tools,
                ledger: requestLedger, ownerGate: executionBudget?.ownerGate, onEvent: onEvent)
            return // No hidden empty-response retry, fallback or alternate adapter.
        }
        try await AgentRoutedModelResponseObserver.$receive.withValue(onRoutedModel) {
            try await AgentEmptyResponseRetry.run(
                providerID: configuration.providerID, model: configuration.model,
                returnsEmptyOutput: allowsEmptyTaskTakeover,
                onEmptyOutput: { openAIResponsesContinuationState.invalidate() },
                onEvent: onEvent, onRetry: { attempt, limit in
                    // An empty Responses completion may already have committed a
                    // response ID. Retry with the intact history, not that empty
                    // continuation checkpoint.
                    openAIResponsesContinuationState.invalidate()
                    onEmptyResponseRetry?(attempt, limit)
                }
            ) { consume in
                try executionBudget?.checkCurrentOwner()
                try await streamChatOnce(messages: messages, tools: tools, executionBudget: executionBudget, onEvent: consume)
            }
        }
    }

    private func streamChatOnce(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        executionBudget: AgentToolExecutionBudget?,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        switch configuration.inferenceProviderKind {
        case .openAIChat:
            try await OpenAIChatAdapter(configuration: configuration, session: session, someIMContext: someIMContext)
                .streamChat(messages: messages, tools: tools, requestLedger: requestLedger, requestOwnerGate: executionBudget?.ownerGate, onEvent: onEvent)
        case .anthropicMessages:
            try await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, requestLedger: requestLedger, requestOwnerGate: executionBudget?.ownerGate, onEvent: onEvent)
        case .geminiGenerateContent:
            try await GeminiAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, requestLedger: requestLedger, requestOwnerGate: executionBudget?.ownerGate, onEvent: onEvent)
        case .openAIResponses:
            try await OpenAIResponsesAdapter(
                configuration: configuration,
                session: session,
                continuationState: openAIResponsesContinuationState,
                someIMContext: someIMContext
            )
                .streamChat(messages: messages, tools: tools, requestLedger: requestLedger, requestOwnerGate: executionBudget?.ownerGate, onEvent: onEvent)
        }
    }

    /// Ask the configured provider whether a command is safe to auto-run.
    /// `historyContext` is an optional, caller-cached block of the
    /// operator's prior hand decisions appended to the local judge system
    /// prompt. The some.im security guard ignores this parameter because its
    /// fixed policy is injected by the gateway and the client sends only the
    /// per-command user message.
    func budgetedSafetyJudge(
        command: String,
        historyContext: String = "",
        toolName: String = "run_command",
        taskContext: String = "",
        environmentTrust: String = "",
        kind: AgentSafetyJudgeKind = .developerOperations,
        executionBudget: AgentToolExecutionBudget? = nil
    ) async throws -> AgentSafetyJudgeResult {
        try configuration.validateMagpieConnection()
        try Task.checkCancellation()
        try executionBudget?.checkCurrentOwner()
        if let requestLedger, let ownerLedger = executionBudget?.requestLedger, requestLedger != ownerLedger {
            throw AgentModelRequestLedger.Failure.ownerMismatch
        }
        let judgeLedger = requestLedger ?? executionBudget?.requestLedger
        switch configuration.inferenceProviderKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: configuration, session: session, someIMContext: someIMContext)
                .judgeCommandSafety(
                    command: command,
                    historyContext: historyContext,
                    toolName: toolName,
                    taskContext: taskContext,
                    environmentTrust: environmentTrust,
                    kind: kind, requestLedger: judgeLedger, executionBudget: executionBudget
                )
        case .anthropicMessages:
            return try await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(
                    command: command,
                    historyContext: historyContext,
                    toolName: toolName,
                    taskContext: taskContext,
                    environmentTrust: environmentTrust,
                    kind: kind, requestLedger: judgeLedger, executionBudget: executionBudget
                )
        case .geminiGenerateContent:
            return try await GeminiAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(
                    command: command,
                    historyContext: historyContext,
                    toolName: toolName,
                    taskContext: taskContext,
                    environmentTrust: environmentTrust,
                    kind: kind, requestLedger: judgeLedger, executionBudget: executionBudget
                )
        case .openAIResponses:
            return try await OpenAIResponsesAdapter(
                configuration: configuration,
                session: session,
                someIMContext: someIMContext
            )
                .judgeCommandSafety(
                    command: command,
                    historyContext: historyContext,
                    toolName: toolName,
                    taskContext: taskContext,
                    environmentTrust: environmentTrust,
                    kind: kind, requestLedger: judgeLedger, executionBudget: executionBudget
                )
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
        try? await budgetedRouteJudge(model: model, systemPrompt: systemPrompt,
            userPayload: userPayload, maxTokens: maxTokens)
    }

    func budgetedRouteJudge(
        model: String, systemPrompt: String, userPayload: String, maxTokens: Int,
        executionBudget: AgentToolExecutionBudget? = nil
    ) async throws -> String? {
        try configuration.validateMagpieConnection()
        try Task.checkCancellation()
        try executionBudget?.checkCurrentOwner()
        if let requestLedger, let ownerLedger = executionBudget?.requestLedger, requestLedger != ownerLedger {
            throw AgentModelRequestLedger.Failure.ownerMismatch
        }
        let judgeLedger = requestLedger ?? executionBudget?.requestLedger
        var judgeConfiguration = configuration
        judgeConfiguration.model = model
        judgeConfiguration = judgeConfiguration.normalized

        switch judgeConfiguration.inferenceProviderKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: judgeConfiguration, session: session, someIMContext: someIMContext)
                .routeJudge(model: model, systemPrompt: systemPrompt, userPayload: userPayload, maxTokens: maxTokens,
                    requestLedger: judgeLedger, executionBudget: executionBudget)
        case .openAIResponses:
            return try await OpenAIResponsesAdapter(
                configuration: judgeConfiguration,
                session: session,
                someIMContext: someIMContext
            ).routeJudge(systemPrompt: systemPrompt, userPayload: userPayload, maxTokens: maxTokens,
                requestLedger: judgeLedger, executionBudget: executionBudget)
        default:
            return nil
        }
    }

    func fetchModels() async throws -> [String] {
        try configuration.validateMagpieConnection()
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
        try configuration.validateMagpieConnection()
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
        supportsImages: Bool = true,
        disableThinking: Bool = false,
        includeOllamaThinkingFlag: Bool = false
    ) throws -> Data {
        try OpenAIChatAdapter.encodeChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            supportsImages: supportsImages,
            disableThinking: disableThinking,
            includeOllamaThinkingFlag: includeOllamaThinkingFlag
        )
    }
}
