//
//  AgentClientOpenAIChat.swift
//  Xedit
//
//  Adapter for the OpenAI Chat Completions dialect
//  (`POST {baseURL}/chat/completions`, SSE-encoded streaming).
//
//  This is the protocol family spoken by:
//    OpenAI, DashScope, DeepSeek, Kimi, Moonshot,
//    OpenRouter, SiliconFlow, AnyRouter, some.im, Custom.
//
//  Everything OpenAI-shaped lives here. Translate the wire format into
//  the protocol-agnostic `AgentClientEvent` stream and the caller
//  (`AgentClient` facade and AppState) doesn't care which vendor we're
//  talking to.
//

import Foundation

struct OpenAIChatAdapter {
    private let configuration: AgentConfiguration
    private let session: URLSession

    init(configuration: AgentConfiguration, session: URLSession? = nil) {
        self.configuration = configuration.normalized
        self.session = session ?? AgentNetworkSupport.defaultSession()
    }

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try chatCompletionsEndpoint(from: configuration.baseURL)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = AgentNetworkSupport.requestTimeout
        request.httpMethod = "POST"
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let requestMessages = Self.providerReadyMessages(
            messages,
            supportsImages: configuration.supportsImageInput
        )
        let requestBody = try Self.encodeChatRequest(
            model: configuration.model,
            messages: requestMessages,
            tools: tools,
            supportsImages: configuration.supportsImageInput
        )
        request.httpBody = requestBody

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = try await AgentNetworkSupport.collectBody(from: bytes)
            throw AgentClientError.serverStatus(
                httpError(
                    statusCode: httpResponse.statusCode,
                    method: request.httpMethod ?? "POST",
                    url: endpoint,
                    requestBody: requestBody,
                    responseBody: responseBody,
                    messages: requestMessages
                )
            )
        }

        var pendingToolCalls: [Int: PendingToolCall] = [:]
        var emittedSignature = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data) else {
                continue
            }

            for choice in chunk.choices {
                if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                    await onEvent(.reasoningDelta(reasoning))
                }
                if let content = choice.delta.content, !content.isEmpty {
                    await onEvent(.textDelta(content))
                }

                if let calls = choice.delta.tool_calls {
                    for call in calls {
                        let slot = call.index ?? 0
                        var pending = pendingToolCalls[slot] ?? PendingToolCall()
                        if let id = call.id, !id.isEmpty { pending.externalID = id }
                        if let function = call.function {
                            if let name = function.name, !name.isEmpty { pending.toolName = name }
                            if let args = function.arguments { pending.argumentsJSON += args }
                        }
                        pendingToolCalls[slot] = pending
                    }
                    let snapshot = Self.snapshot(of: pendingToolCalls)
                    let signature = Self.signature(of: snapshot)
                    if signature != emittedSignature {
                        emittedSignature = signature
                        await onEvent(.toolCallsUpdated(snapshot))
                    }
                }

                if let finishReason = choice.finish_reason {
                    await onEvent(.finishedTurn(finishReason))
                }
            }

            // Top-level `usage` arrives on the final chunk for providers
            // that include it. We surface it once so the caller can stamp
            // the last assistant message with real token counts.
            if let usage = chunk.usage,
               let total = usage.total_tokens, total > 0 {
                await onEvent(.usageReported(
                    prompt: usage.prompt_tokens ?? 0,
                    completion: usage.completion_tokens ?? 0,
                    total: total,
                    cachedPrompt: usage.cachedPromptTokens,
                    cacheWritePrompt: usage.cacheWritePromptTokens,
                    reasoning: usage.reasoningTokens
                ))
            }
        }
    }

    /// Ask the configured provider whether a shell command is safe to
    /// auto-run. Non-streaming, low-token, single round trip. Returns
    /// `true` only when the model unambiguously answers `YES`. Network
    /// errors return `false` — the caller (AppState) treats that as
    /// "fall back to user approval".
    func judgeCommandSafety(command: String) async -> Bool {
        guard !configuration.apiKey.isEmpty else { return false }

        let endpoint: URL
        do { endpoint = try chatCompletionsEndpoint(from: configuration.baseURL) }
        catch { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = AgentInjectionDefense.judgeSystemPrompt
        let userPayload = AgentInjectionDefense.judgeUserPayload(command: command)

        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "max_tokens": 16,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPayload]
            ]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return false
        }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            guard let decoded = try? JSONDecoder().decode(JudgmentResponse.self, from: data),
                  let choice = decoded.choices.first else {
                return false
            }
            let answer = choice.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentInjectionDefense.judgeVerdictIsYes(rawText: answer)
        } catch {
            return false
        }
    }

    func fetchModels() async throws -> [String] {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try modelsEndpoint(from: configuration.baseURL)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = AgentNetworkSupport.requestTimeout
        request.httpMethod = "GET"
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentClientError.serverStatus(
                httpError(
                    statusCode: httpResponse.statusCode,
                    method: request.httpMethod ?? "GET",
                    url: endpoint,
                    requestBody: nil,
                    responseBody: String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>",
                    messages: []
                )
            )
        }

        let responseBody = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return responseBody.data.map(\.id).filter { !$0.isEmpty }.sorted()
    }

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        applyRelayBrandingHeaders(to: &request)
    }

    /// OpenRouter ranks apps on its public leaderboard by these two
    /// headers. Setting them advertises WillDeep / willdeep.com; other
    /// relays ignore the headers harmlessly so the call site is
    /// switched by `providerID` rather than dropped behind a feature
    /// flag. If a future relay wants different branding, fan this out
    /// into a `relayHeaders(for:)` table.
    private func applyRelayBrandingHeaders(to request: inout URLRequest) {
        switch configuration.providerID {
        case "openrouter":
            request.setValue("https://willdeep.com", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("WillDeep", forHTTPHeaderField: "X-Title")
        default:
            break
        }
    }

    private func chatCompletionsEndpoint(from baseURL: String) throws -> URL {
        try AgentNetworkSupport.endpoint(from: baseURL, suffix: "chat/completions")
    }

    private func modelsEndpoint(from baseURL: String) throws -> URL {
        try AgentNetworkSupport.endpoint(from: baseURL, suffix: "models")
    }

    // MARK: - Request encoding

    /// Encodes the chat completion request via `JSONSerialization` because the
    /// `tools` + `tool_calls` payloads are heterogeneous JSON dictionaries that
    /// don't model cleanly as `Encodable` types.
    nonisolated static func encodeChatRequest(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        supportsImages: Bool = true
    ) throws -> Data {
        let providerMessages = providerReadyMessages(messages, supportsImages: supportsImages)
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            // OpenAI requires this flag to include the final `usage`
            // chunk in a streaming response. DashScope / DeepSeek / Kimi
            // all ignore it harmlessly when they already emit usage by
            // default, so it's safe to send unconditionally.
            "stream_options": ["include_usage": true],
            "messages": providerMessages.map { encodeMessage($0, supportsImages: supportsImages) }
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(encodeTool)
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated static func providerReadyMessages(
        _ messages: [AgentMessage],
        supportsImages: Bool = true
    ) -> [AgentMessage] {
        var result: [AgentMessage] = []
        var index = 0

        while index < messages.count {
            let message = messages[index]

            if message.role == .workflowReport || message.role == .widget {
                index += 1
                continue
            }

            if message.role == .tool {
                index += 1
                continue
            }

            // A fully-empty assistant message (no text, no tool calls) is
            // not representable on the wire — OpenAI-compatible servers
            // reject it with HTTP 400 "content or tool_calls must be set".
            // These appear when a stream terminated without producing
            // anything and the placeholder stayed in persisted history.
            if message.role == .assistant, message.toolCalls.isEmpty, message.modelContent.isEmpty {
                index += 1
                continue
            }

            if message.role == .assistant, !message.toolCalls.isEmpty {
                let expectedIDs = message.toolCalls.map(\.externalID).filter { !$0.isEmpty }
                guard !expectedIDs.isEmpty else {
                    index += 1
                    continue
                }

                var collectedByID: [String: AgentMessage] = [:]
                var cursor = index + 1
                while cursor < messages.count, messages[cursor].role == .tool {
                    if let toolCallID = messages[cursor].toolCallID,
                       expectedIDs.contains(toolCallID),
                       !collectedByID.keys.contains(toolCallID) {
                        collectedByID[toolCallID] = messages[cursor]
                    }
                    cursor += 1
                }

                if expectedIDs.allSatisfy({ collectedByID[$0] != nil }) {
                    result.append(providerReadyMessage(message, supportsImages: supportsImages))
                    for expectedID in expectedIDs {
                        if let toolMessage = collectedByID[expectedID] {
                            result.append(toolMessage)
                        }
                    }
                }
                index = cursor
                continue
            }

            result.append(providerReadyMessage(message, supportsImages: supportsImages))
            index += 1
        }

        return result
    }

    nonisolated private static func providerReadyMessage(
        _ message: AgentMessage,
        supportsImages: Bool
    ) -> AgentMessage {
        guard message.role == .user, !supportsImages, !message.images.isEmpty else {
            return message
        }

        var result = message
        let count = result.images.count
        let notice = "[\(count) image attachment\(count == 1 ? "" : "s") omitted because this provider only accepts text messages.]"
        if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.content = notice
        } else {
            result.content += "\n\n\(notice)"
        }
        result.images = []
        return result
    }

    nonisolated private static func encodeMessage(
        _ message: AgentMessage,
        supportsImages: Bool
    ) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]
        let content = message.modelContent

        if supportsImages, message.role == .user, !message.images.isEmpty {
            // OpenAI multimodal: content is an array of typed parts.
            var parts: [[String: Any]] = []
            if !content.isEmpty {
                parts.append(["type": "text", "text": content])
            }
            for image in message.images {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": image.dataURL]
                ])
            }
            dict["content"] = parts
        } else if !content.isEmpty {
            dict["content"] = content
        } else if message.role != .assistant {
            dict["content"] = ""
        }

        if message.role == .tool, let id = message.toolCallID {
            dict["tool_call_id"] = id
        }
        if message.role == .assistant, !message.toolCalls.isEmpty {
            dict["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                return [
                    "id": call.externalID,
                    "type": "function",
                    "function": [
                        "name": call.toolName,
                        "arguments": call.argumentsJSON
                    ]
                ]
            }
        }
        // Echo back the assistant's reasoning trace if we captured one
        // last turn. DashScope's thinking-mode contract requires it
        // (returns HTTP 400 otherwise); other providers ignore the
        // unknown field, so it's safe to always emit.
        if message.role == .assistant,
           let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            dict["reasoning_content"] = reasoning
        }
        return dict
    }

    nonisolated private static func encodeTool(_ descriptor: AgentToolDescriptor) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for parameter in descriptor.parameters {
            properties[parameter.name] = schemaProperty(for: parameter)
            if parameter.required { required.append(parameter.name) }
        }

        var parameterSchema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            parameterSchema["required"] = required
        }

        return [
            "type": "function",
            "function": [
                "name": descriptor.name,
                "description": descriptor.description,
                "parameters": parameterSchema
            ]
        ]
    }

    nonisolated private static func schemaProperty(for parameter: AgentToolParameter) -> [String: Any] {
        switch parameter.type {
        case .string, .integer, .boolean:
            return [
                "type": parameter.type.rawValue,
                "description": parameter.description
            ]
        case .stringArray:
            return [
                "type": "array",
                "items": ["type": "string"],
                "description": parameter.description
            ]
        }
    }

    // MARK: - Pending tool call helpers

    private struct PendingToolCall {
        var externalID: String = ""
        var toolName: String = ""
        var argumentsJSON: String = ""
    }

    private static func snapshot(of pending: [Int: PendingToolCall]) -> [AgentMessageToolCall] {
        pending.keys.sorted().map { key in
            let entry = pending[key]!
            return AgentMessageToolCall(
                externalID: entry.externalID,
                toolName: entry.toolName,
                argumentsJSON: entry.argumentsJSON
            )
        }
    }

    private static func signature(of calls: [AgentMessageToolCall]) -> String {
        calls.map { "\($0.externalID)|\($0.toolName)|\($0.argumentsJSON)" }.joined(separator: "||")
    }

    private func httpError(
        statusCode: Int,
        method: String,
        url: URL,
        requestBody: Data?,
        responseBody: String,
        messages: [AgentMessage]
    ) -> AgentProviderHTTPError {
        AgentProviderHTTPError(
            statusCode: statusCode,
            method: method,
            url: AgentNetworkSupport.redactedURLString(url),
            providerID: configuration.providerID,
            model: configuration.model,
            requestSummary: AgentNetworkSupport.requestSummary(for: messages),
            requestBody: AgentNetworkSupport.redactedJSONString(from: requestBody),
            responseBody: AgentNetworkSupport.limitDebugText(responseBody)
        )
    }
}

// MARK: - OpenAI-shaped wire format

private struct ChatCompletionChunk: Decodable {
    let choices: [Choice]
    /// OpenAI-compatible usage block. Only the final streaming chunk
    /// carries it (and only when `stream_options.include_usage = true`
    /// or the provider sends it by default — DashScope/DeepSeek do).
    let usage: Usage?

    struct Choice: Decodable {
        let delta: Delta
        let finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
        let reasoning_content: String?
        let tool_calls: [ToolCallDelta]?
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_cache_hit_tokens: Int?
        let prompt_cache_miss_tokens: Int?
        let prompt_tokens_details: PromptTokensDetails?
        let completion_tokens_details: CompletionTokensDetails?

        var cachedPromptTokens: Int {
            prompt_tokens_details?.cached_tokens ?? prompt_cache_hit_tokens ?? 0
        }

        var cacheWritePromptTokens: Int {
            prompt_cache_miss_tokens ?? 0
        }

        var reasoningTokens: Int {
            completion_tokens_details?.reasoning_tokens ?? 0
        }

        struct PromptTokensDetails: Decodable {
            let cached_tokens: Int?
        }

        struct CompletionTokensDetails: Decodable {
            let reasoning_tokens: Int?
        }
    }
}

private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

/// Minimal non-streaming chat completion shape used only by
/// `judgeCommandSafety`. Tolerates the small differences between
/// OpenAI / Anthropic-via-compat / DashScope by reading the first
/// choice's message.content as plain text.
private struct JudgmentResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}
