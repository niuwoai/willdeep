//
//  AgentClient.swift
//  VeilWriter
//
//  Minimal OpenAI-compatible streaming chat client with optional
//  function-calling (tools) support.
//

import Foundation

/// Streamed events surfaced to the caller while a chat completion is in flight.
enum AgentClientEvent {
    /// Assistant text delta.
    case textDelta(String)
    /// Reasoning / thinking-mode trace delta. Emitted by DashScope
    /// (qwen3, qwq), DeepSeek-R1, and a few other providers in addition
    /// to `textDelta`. The caller MUST retain the concatenated value and
    /// echo it back on the next assistant message — DashScope responds
    /// with HTTP 400 ("reasoning_content must be passed back") otherwise.
    case reasoningDelta(String)
    /// Cumulative tool calls observed so far. Each provider streams tool call
    /// arguments in fragments; the client merges them and re-emits the full
    /// list on every change so the caller always has the latest view.
    case toolCallsUpdated([AgentMessageToolCall])
    /// Finish reason reported by the provider (e.g. "stop", "tool_calls").
    case finishedTurn(String?)
}

struct AgentClient {
    nonisolated private static let requestTimeout: TimeInterval = 45
    nonisolated private static let resourceTimeout: TimeInterval = 10 * 60

    private let configuration: AgentConfiguration
    private let session: URLSession

    init(configuration: AgentConfiguration, session: URLSession? = nil) {
        self.configuration = configuration.normalized
        self.session = session ?? Self.defaultSession()
    }

    nonisolated private static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
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
        request.timeoutInterval = Self.requestTimeout
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
            let responseBody = try await Self.collectBody(from: bytes)
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

        let systemPrompt = """
        You are a strict shell-command safety classifier. \
        Reply with a single word: YES if the command is read-only and \
        cannot delete files, modify state outside its process, send \
        data over the network in a write capacity, or escalate \
        privileges. Otherwise reply NO. \
        Treat anything that writes files, mutates VCS state, installs \
        software, opens network sockets to write, signals processes, \
        or changes permissions as NO. \
        Do not explain. Do not add punctuation. Output exactly YES or NO.
        """

        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "max_tokens": 4,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Command:\n\(command)"]
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
                .uppercased()
            return answer.hasPrefix("YES")
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
        request.timeoutInterval = Self.requestTimeout
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
        if configuration.providerID == "claude" {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    private func chatCompletionsEndpoint(from baseURL: String) throws -> URL {
        try endpoint(from: baseURL, suffix: "chat/completions")
    }

    private func modelsEndpoint(from baseURL: String) throws -> URL {
        try endpoint(from: baseURL, suffix: "models")
    }

    private func endpoint(from baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmed) else {
            throw AgentClientError.invalidBaseURL
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(suffix) {
            guard let url = components.url else { throw AgentClientError.invalidBaseURL }
            return url
        }

        let separator = path.isEmpty ? "" : "/"
        components.path = "/\(path)\(separator)\(suffix)"
        guard let url = components.url else {
            throw AgentClientError.invalidBaseURL
        }
        return url
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

            if message.role == .tool {
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

        if supportsImages, message.role == .user, !message.images.isEmpty {
            // OpenAI multimodal: content is an array of typed parts.
            var parts: [[String: Any]] = []
            if !message.content.isEmpty {
                parts.append(["type": "text", "text": message.content])
            }
            for image in message.images {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": image.dataURL]
                ])
            }
            dict["content"] = parts
        } else if !message.content.isEmpty {
            dict["content"] = message.content
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
            url: url.absoluteString,
            providerID: configuration.providerID,
            model: configuration.model,
            requestSummary: Self.requestSummary(for: messages),
            requestBody: Self.redactedJSONString(from: requestBody),
            responseBody: Self.limitDebugText(responseBody)
        )
    }

    private static func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        let limit = 64 * 1024
        for try await byte in bytes {
            if data.count < limit {
                data.append(byte)
            } else {
                break
            }
        }
        let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
        return data.count >= limit ? "\(text)\n\n[truncated]" : text
    }

    private static func requestSummary(for messages: [AgentMessage]) -> String {
        guard !messages.isEmpty else { return "(no chat messages)" }
        return messages.enumerated().map { index, message in
            let text = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = text.isEmpty ? "(empty)" : String(text.prefix(240))
            let imageText = message.images.isEmpty ? "" : " + \(message.images.count) image\(message.images.count == 1 ? "" : "s")"
            return "\(index + 1). \(message.role.rawValue): \(preview)\(text.count > 240 ? "..." : "")\(imageText)"
        }.joined(separator: "\n")
    }

    private static func redactedJSONString(from data: Data?) -> String {
        guard let data else { return "(no request body)" }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 request body>")
        }
        let redacted = redactImages(in: object)
        guard let pretty = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 request body>")
        }
        return limitDebugText(text)
    }

    private static func redactImages(in value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, raw) in dict {
                if key == "url",
                   let string = raw as? String,
                   string.hasPrefix("data:image/") {
                    result[key] = "[redacted image data URL]"
                } else {
                    result[key] = redactImages(in: raw)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { redactImages(in: $0) }
        }
        return value
    }

    private static func limitDebugText(_ text: String) -> String {
        let limit = 32_000
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n\n[truncated]"
    }
}

private struct ChatCompletionChunk: Decodable {
    let choices: [Choice]

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
