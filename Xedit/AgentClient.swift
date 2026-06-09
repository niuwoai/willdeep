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
        case .openAIResponses, .anthropicMessages, .geminiGenerateContent:
            // Adapters land in Phase C / D / E. Until then any preset
            // configured with a non-Chat kind would be unreachable —
            // currently the preset table only marks Chat kinds, so this
            // branch is dead code that exists to make the switch
            // exhaustive and to make the upcoming wiring obvious.
            throw AgentClientError.unsupportedProviderKind(configuration.providerKind)
        }
    }

    func judgeCommandSafety(command: String) async -> Bool {
        switch configuration.providerKind {
        case .openAIChat:
            return await OpenAIChatAdapter(configuration: configuration, session: session)
                .judgeCommandSafety(command: command)
        case .openAIResponses, .anthropicMessages, .geminiGenerateContent:
            // Match the pre-refactor behaviour: any failure path
            // (unsupported provider here counts) falls back to "ask
            // the user" rather than silently auto-running the command.
            return false
        }
    }

    func fetchModels() async throws -> [String] {
        switch configuration.providerKind {
        case .openAIChat:
            return try await OpenAIChatAdapter(configuration: configuration, session: session)
                .fetchModels()
        case .openAIResponses, .anthropicMessages, .geminiGenerateContent:
            throw AgentClientError.unsupportedProviderKind(configuration.providerKind)
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
}
