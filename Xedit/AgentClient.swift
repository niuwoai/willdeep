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
//  Routing happens here based on `configuration.providerKind`.
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
    /// Finish reason reported by the provider (e.g. "stop", "tool_calls").
    case finishedTurn(String?)
    /// Token usage emitted by the provider on the final streaming chunk
    /// (OpenAI-compatible `usage.total_tokens` / Anthropic `message_delta.usage`
    /// / Gemini `usageMetadata`). Not every provider includes it; absent →
    /// caller falls back to the estimator.
    case usageReported(prompt: Int, completion: Int, total: Int)
}

struct AgentClient {
    private let configuration: AgentConfiguration
    private let session: URLSession?

    init(configuration: AgentConfiguration, session: URLSession? = nil) {
        self.configuration = configuration.normalized
        self.session = session
    }

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        switch configuration.providerKind {
        case .openAIChat:
            try await OpenAIChatAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .anthropicMessages:
            try await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .geminiGenerateContent:
            try await GeminiAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        case .openAIResponses:
            try await OpenAIResponsesAdapter(configuration: configuration, session: session)
                .streamChat(messages: messages, tools: tools, onEvent: onEvent)
        }
    }

    func judgeCommandSafety(command: String) async -> Bool {
        switch configuration.providerKind {
        case .openAIChat:
            return await OpenAIChatAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command)
        case .anthropicMessages:
            return await AnthropicMessagesAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command)
        case .geminiGenerateContent:
            return await GeminiAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command)
        case .openAIResponses:
            return await OpenAIResponsesAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command)
        }
    }

    func fetchModels() async throws -> [String] {
        switch configuration.providerKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: configuration, session: session)
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
