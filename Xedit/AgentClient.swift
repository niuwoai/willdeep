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

        request.httpBody = try Self.encodeChatRequest(
            model: configuration.model,
            messages: messages,
            tools: tools
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentClientError.serverStatus(httpResponse.statusCode)
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
            throw AgentClientError.serverStatus(httpResponse.statusCode)
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
        tools: [AgentToolDescriptor]
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map(encodeMessage)
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(encodeTool)
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated private static func encodeMessage(_ message: AgentMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]

        if message.role == .user, !message.images.isEmpty {
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
}

private struct ChatCompletionChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
        let finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
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
