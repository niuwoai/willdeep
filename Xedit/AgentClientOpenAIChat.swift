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
    private let someIMContext: SomeIMRequestContext?

    init(
        configuration: AgentConfiguration,
        session: URLSession? = nil,
        someIMContext: SomeIMRequestContext? = nil
    ) {
        self.configuration = configuration.normalized
        self.session = session ?? AgentNetworkSupport.defaultSession()
        self.someIMContext = someIMContext
    }

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        guard !configuration.requiresAPIKey || !configuration.apiKey.isEmpty else {
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
        SomeIMCreditsResponseObserver.capture(httpResponse, providerID: configuration.providerID)
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
        var toolCallEmissionGate = AgentToolCallStreamEmissionGate()
        // Track whether the stream ever carried a meaningful signal. A 2xx
        // response whose SSE body is empty (or is just `[DONE]`) decodes to
        // zero events and would otherwise return as a silent success — the
        // caller then drops the placeholder assistant message and the user
        // sees nothing happen. We convert that into an explicit error below.
        var didEmitStreamEvent = false

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
                    didEmitStreamEvent = true
                    await onEvent(.reasoningDelta(reasoning))
                }
                if let content = choice.delta.content, !content.isEmpty {
                    didEmitStreamEvent = true
                    await onEvent(.textDelta(content))
                }

                if let calls = choice.delta.tool_calls {
                    didEmitStreamEvent = true
                    for call in calls {
                        let slot = call.index ?? 0
                        var pending = pendingToolCalls[slot] ?? PendingToolCall()
                        if let id = call.id, !id.isEmpty { pending.externalID = id }
                        if let function = call.function {
                            if let name = function.name, !name.isEmpty { pending.toolName = name }
                            if let args = function.arguments { pending.appendArguments(args) }
                        }
                        pendingToolCalls[slot] = pending
                    }
                    let signature = Self.signature(of: pendingToolCalls)
                    if toolCallEmissionGate.shouldEmit(signature: signature) {
                        await onEvent(.toolCallsUpdated(Self.snapshot(of: pendingToolCalls)))
                    }
                }

                if let finishReason = choice.finish_reason {
                    didEmitStreamEvent = true
                    let signature = Self.signature(of: pendingToolCalls)
                    if toolCallEmissionGate.shouldEmit(signature: signature, force: true) {
                        await onEvent(.toolCallsUpdated(Self.snapshot(of: pendingToolCalls)))
                    }
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

        // Zero meaningful events over a 2xx stream. Surface it as an error the
        // caller can present (and retry) instead of a silent no-op. A
        // usage-only final chunk doesn't count as a real reply, so this still
        // fires when the provider sends nothing but token accounting.
        if !didEmitStreamEvent {
            throw AgentClientError.emptyStream(
                providerID: configuration.providerID,
                model: configuration.model
            )
        }
    }

    /// Ask the configured provider whether a shell command is safe to
    /// auto-run. Non-streaming, low-token, single round trip. Returns
    /// `true` only when the model unambiguously answers `YES`. Network
    /// errors return `false` — the caller (AppState) treats that as
    /// "fall back to user approval".
    func judgeCommandSafety(
        command: String,
        historyContext: String = ""
    ) async -> AgentSafetyJudgeResult {
        guard !configuration.requiresAPIKey || !configuration.apiKey.isEmpty else {
            return .unavailable("missing api key")
        }

        let endpoint: URL
        do { endpoint = try chatCompletionsEndpoint(from: configuration.baseURL) }
        catch { return .unavailable("bad endpoint") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentInjectionDefense.judgeTimeout
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = AgentInjectionDefense.judgeSystemPromptText(historyContext: historyContext)
        let userPayload = AgentInjectionDefense.judgeUserPayload(command: command)

        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "max_tokens": AgentInjectionDefense.judgeMaxOutputTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPayload]
            ]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return .unavailable("encode failed")
        }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("no http response")
            }
            SomeIMCreditsResponseObserver.capture(http, providerID: configuration.providerID)
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable("http \(http.statusCode)")
            }
            guard let decoded = try? JSONDecoder().decode(JudgmentResponse.self, from: data),
                  let choice = decoded.choices.first else {
                return .unavailable("decode failed")
            }
            let answer = (choice.message.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch AgentInjectionDefense.judgeVerdict(rawText: answer) {
            case .yes: return .allow
            case .no: return .deny
            case .unclear:
                return .unavailable(answer.isEmpty ? "empty reply" : "no verdict tag")
            }
        } catch {
            return .unavailable("network error")
        }
    }

    /// Non-streaming JSON judge round trip for managed routing (and, later,
    /// output-quality checks). `model` is the judge model (e.g.
    /// `someim-judge`), distinct from `configuration.model`. Returns the raw
    /// assistant text (expected strict JSON) or nil on any missing-key /
    /// endpoint / HTTP / decode / network failure — the strategy layer
    /// applies a local fallback. Mirrors `judgeCommandSafety`'s transport.
    func routeJudge(
        model: String,
        systemPrompt: String,
        userPayload: String,
        maxTokens: Int
    ) async -> String? {
        guard !configuration.requiresAPIKey || !configuration.apiKey.isEmpty else { return nil }

        let endpoint: URL
        do { endpoint = try chatCompletionsEndpoint(from: configuration.baseURL) }
        catch { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentInjectionDefense.judgeTimeout
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "max_tokens": maxTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPayload]
            ]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            SomeIMCreditsResponseObserver.capture(http, providerID: configuration.providerID)
            guard (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(JudgmentResponse.self, from: data),
                  let choice = decoded.choices.first else {
                return nil
            }
            return choice.message.content
        } catch {
            return nil
        }
    }

    func fetchModels() async throws -> [String] {
        guard !configuration.requiresAPIKey || !configuration.apiKey.isEmpty else {
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

    func fetchModelDiscoveries() async throws -> [AgentModelDiscovery] {
        guard !configuration.requiresAPIKey || !configuration.apiKey.isEmpty else {
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
        return responseBody.discoveries
    }

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        applyRelayBrandingHeaders(to: &request)
        applySomeIMContextHeaders(to: &request)
    }

    /// Attach `x-willdeep-session-id` (+ optional `x-willdeep-workspace-id`)
    /// on some.im requests only — the single injection point covers the main
    /// stream, the safety judge, the route judge, and model fetch. Enables
    /// some.im-side routing memory / diagnostics without exposing the headers
    /// to any other provider. Values are opaque session UUIDs, never paths.
    private func applySomeIMContextHeaders(to request: inout URLRequest) {
        guard configuration.providerID == AgentProviderPreset.someIMID,
              let context = someIMContext else { return }
        request.setValue(context.sessionID, forHTTPHeaderField: AgentNetworkSupport.willDeepSessionHeaderName)
        if let workspaceID = context.workspaceID, !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: AgentNetworkSupport.willDeepWorkspaceHeaderName)
        }
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

            if message.isLocalTranscriptEvent {
                index += 1
                continue
            }

            if message.role == .workflowReport || message.role == .widget || message.role == .scheduledTask {
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
        if !hasGeneratedImageDescription(result.content) {
            let notice = "[\(count) image attachment\(count == 1 ? "" : "s") omitted because this provider only accepts text messages.]"
            if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.content = notice
            } else {
                result.content += "\n\n\(notice)"
            }
        }
        result.images = []
        return result
    }

    nonisolated private static func hasGeneratedImageDescription(_ content: String) -> Bool {
        content.contains("[Image description generated by ")
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
        var argumentsFingerprint = AgentStreamingStringFingerprint()

        mutating func appendArguments(_ fragment: String) {
            argumentsJSON += fragment
            argumentsFingerprint.append(fragment)
        }
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

    private static func signature(of pending: [Int: PendingToolCall]) -> String {
        pending.keys.sorted().map { key in
            let entry = pending[key]!
            return "\(key)|\(entry.externalID)|\(entry.toolName)|\(entry.argumentsFingerprint.signatureComponent)"
        }.joined(separator: "||")
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

    var discoveries: [AgentModelDiscovery] {
        data
            .map(\.discovery)
            .filter { !$0.id.isEmpty }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    struct Model: Decodable {
        let id: String
        let isHot: Bool
        let isNew: Bool

        var discovery: AgentModelDiscovery {
            AgentModelDiscovery(
                id: id.trimmingCharacters(in: .whitespacesAndNewlines),
                isHot: isHot,
                isNew: isNew
            )
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            let metadata = try? container.decode(ModelMetadata.self, forKey: .metadata)
            isHot = (try? container.decode(Bool.self, forKey: .isHot)) ?? metadata?.isHot ?? false
            isNew = (try? container.decode(Bool.self, forKey: .isNew)) ?? metadata?.isNew ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case isHot = "is_hot"
            case isNew = "is_new"
            case metadata
        }

        private struct ModelMetadata: Decodable {
            let isHot: Bool?
            let isNew: Bool?

            private enum CodingKeys: String, CodingKey {
                case isHot = "is_hot"
                case isNew = "is_new"
            }
        }
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
        /// Optional on purpose: reasoning-tier models (deepseek-*-flash,
        /// o-series) return `reasoning_content` alongside a `content` that
        /// can be null or absent when the token budget was spent thinking.
        /// A non-optional field made the whole decode throw → silent
        /// fallback to manual approval. Optional lets us surface the real
        /// state ("empty reply") to the judge log instead.
        let content: String?
    }
}
