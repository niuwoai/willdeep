//
//  AgentClientOpenAIResponses.swift
//  Xedit
//
//  Adapter for OpenAI's newer Responses API
//  (`POST {baseURL}/responses`, SSE-encoded streaming).
//
//  Same upstream as the Chat Completions adapter (OpenAI's own API key
//  works) but the wire format is genuinely different:
//
//    • Endpoint: `/responses` (not `/chat/completions`).
//    • Body uses `input` instead of `messages`; `instructions` carries
//      the system prompt as a top-level string.
//    • `input` items are *typed*: text messages, function_calls (the
//      assistant's tool invocations), and function_call_outputs (the
//      tool's replies) — flat list, not nested.
//    • Tool schema drops the `{type, function: {...}}` wrapper: each
//      entry is `{type: "function", name, description, parameters}`.
//    • Streaming events are typed and arrive as `event: <name>` /
//      `data: <json>` pairs (like Anthropic). The event names start
//      with `response.` and cover text deltas, function-call argument
//      streaming, reasoning summary, and final completion with usage.
//    • Reasoning trace (o-series only) comes through
//      `response.reasoning.delta` and `response.reasoning_summary.delta`
//      — we route both into the existing `.reasoningDelta` channel so
//      DashScope/DeepSeek-style UI handling just works.
//
//  Tool call ids are stable across the stream — `function_call.call_id`
//  on the assistant turn pairs with `function_call_output.call_id` on
//  the reply, mirroring the OpenAI Chat externalID model. No id
//  synthesis needed (unlike the Gemini adapter).
//

import Foundation

struct OpenAIResponsesAdapter {
    private let configuration: AgentConfiguration
    private let session: URLSession

    init(configuration: AgentConfiguration, session: URLSession? = nil) {
        self.configuration = configuration.normalized
        self.session = session ?? AgentNetworkSupport.defaultSession()
    }

    // MARK: - streamChat

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try responsesEndpoint(from: configuration.baseURL)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = AgentNetworkSupport.requestTimeout
        request.httpMethod = "POST"
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let requestMessages = AgentClient.providerReadyMessages(
            messages,
            supportsImages: configuration.supportsImageInput
        )
        let requestBody = try Self.encodeRequestBody(
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

        // Same line-pair SSE pattern as Anthropic: each `event: <name>`
        // line pre-announces the type of the next `data: <json>` line.
        // Hold onto the name and route the next payload accordingly.
        var pendingEventName: String = ""
        var state = StreamState()

        for try await line in bytes.lines {
            try Task.checkCancellation()

            if line.hasPrefix("event: ") {
                pendingEventName = String(line.dropFirst("event: ".count))
                continue
            }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8) else { continue }

            await handleEvent(
                name: pendingEventName,
                payload: data,
                state: &state,
                onEvent: onEvent
            )

            // Reset so an unpaired `data:` (shouldn't happen but the
            // line-pair contract assumes pairing) doesn't get
            // misrouted to whatever event we last saw.
            pendingEventName = ""
        }

        // A 2xx stream that produced no text, reasoning, function call,
        // completion or error is an empty no-op. Surface it as a retryable
        // error instead of a silent dropped turn.
        if !state.didEmitStreamEvent {
            throw AgentClientError.emptyStream(
                providerID: configuration.providerID,
                model: configuration.model
            )
        }
    }

    // MARK: - judgeCommandSafety

    /// Non-streaming, low-token classifier. Returns `true` only on a
    /// clean `YES`. Failure path = "ask the user".
    func judgeCommandSafety(
        command: String,
        historyContext: String = ""
    ) async -> AgentSafetyJudgeResult {
        guard !configuration.apiKey.isEmpty else {
            return .unavailable("missing api key")
        }

        let endpoint: URL
        do { endpoint = try responsesEndpoint(from: configuration.baseURL) }
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
            "instructions": systemPrompt,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPayload]
                    ]
                ]
            ],
            // Responses reasoning (o-series) can spend more before the tag.
            "max_output_tokens": AgentInjectionDefense.judgeMaxReasoningOutputTokens,
            "stream": false
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
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable("http \(http.statusCode)")
            }
            guard let decoded = try? JSONDecoder().decode(NonStreamResponse.self, from: data) else {
                return .unavailable("decode failed")
            }
            let text = (decoded.output ?? [])
                .compactMap { $0.content }
                .flatMap { $0 }
                .compactMap(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch AgentInjectionDefense.judgeVerdict(rawText: text) {
            case .yes: return .allow
            case .no: return .deny
            case .unclear:
                return .unavailable(text.isEmpty ? "empty reply" : "no verdict tag")
            }
        } catch {
            return .unavailable("network error")
        }
    }

    // MARK: - fetchModels

    /// `GET /models` is identical across OpenAI's Chat and Responses
    /// surfaces — same auth, same response shape — so we reuse the
    /// shared `models` endpoint resolver instead of duplicating
    /// parsing logic. Caller sees the same model id list either way.
    func fetchModels() async throws -> [String] {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try AgentNetworkSupport.endpoint(
            from: configuration.baseURL,
            suffix: "models"
        )
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

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id).filter { !$0.isEmpty }.sorted()
    }

    func fetchModelDiscoveries() async throws -> [AgentModelDiscovery] {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try AgentNetworkSupport.endpoint(
            from: configuration.baseURL,
            suffix: "models"
        )
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

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.discoveries
    }

    // MARK: - Stream state machine

    /// State carried across the SSE stream: function-call accumulators
    /// (one per item_id), plus a cache of (item_id → display index) so
    /// successive `function_call_arguments.delta` events for the same
    /// call merge into the right slot.
    private struct StreamState {
        var functionCalls: [String: PendingFunctionCall] = [:]
        var orderedItemIDs: [String] = []
        var toolCallEmissionGate = AgentToolCallStreamEmissionGate()
        /// True once the stream carries a real signal (text, reasoning, a
        /// function call, a completion, or a mid-stream error). A 2xx
        /// response that closes with none of these would look like a silent
        /// success; `streamChat` throws `emptyStream` when this stays false.
        var didEmitStreamEvent = false
    }

    private struct PendingFunctionCall {
        /// `call_id` — what `function_call_output.call_id` will reference
        /// on the reply. Stable across the stream.
        var externalID: String
        var name: String
        var argumentsJSON: String
        var argumentsFingerprint = AgentStreamingStringFingerprint()

        init(externalID: String, name: String, argumentsJSON: String) {
            self.externalID = externalID
            self.name = name
            self.argumentsJSON = argumentsJSON
            self.argumentsFingerprint.replace(with: argumentsJSON)
        }

        mutating func appendArguments(_ fragment: String) {
            argumentsJSON += fragment
            argumentsFingerprint.append(fragment)
        }

        mutating func replaceArguments(with arguments: String) {
            argumentsJSON = arguments
            argumentsFingerprint.replace(with: arguments)
        }
    }

    private func handleEvent(
        name: String,
        payload: Data,
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async {
        switch name {
        case "response.output_text.delta":
            if let event = try? JSONDecoder().decode(OutputTextDeltaEvent.self, from: payload),
               let delta = event.delta, !delta.isEmpty {
                state.didEmitStreamEvent = true
                await onEvent(.textDelta(delta))
            }

        case "response.reasoning.delta",
             "response.reasoning_summary.delta",
             "response.reasoning_summary_text.delta":
            // o-series reasoning trace. Route to the same channel that
            // DashScope/DeepSeek thinking output uses so existing UI
            // affordances (reasoning banner, the "thinking…" indicator)
            // light up without per-provider branching upstream.
            if let event = try? JSONDecoder().decode(ReasoningDeltaEvent.self, from: payload),
               let delta = event.delta, !delta.isEmpty {
                state.didEmitStreamEvent = true
                await onEvent(.reasoningDelta(delta))
            }

        case "response.output_item.added":
            // A new output item appeared. Function calls arrive here
            // with their call_id and name; we seed an accumulator so
            // subsequent `function_call_arguments.delta` events have
            // somewhere to merge into. Text items also flow through
            // this event but we don't need to act on the announcement
            // — the `output_text.delta` stream covers them.
            if let event = try? JSONDecoder().decode(OutputItemAddedEvent.self, from: payload),
               event.item?.type == "function_call",
               let itemID = event.item?.id,
               !itemID.isEmpty {
                state.didEmitStreamEvent = true
                let callID = event.item?.call_id ?? itemID
                let pending = PendingFunctionCall(
                    externalID: callID,
                    name: event.item?.name ?? "",
                    argumentsJSON: event.item?.arguments ?? ""
                )
                if state.functionCalls[itemID] == nil {
                    state.orderedItemIDs.append(itemID)
                }
                state.functionCalls[itemID] = pending
                await emitToolCallsIfChanged(state: &state, onEvent: onEvent)
            }

        case "response.function_call_arguments.delta":
            if let event = try? JSONDecoder().decode(FunctionCallArgumentsDeltaEvent.self, from: payload),
               let itemID = event.item_id,
               let delta = event.delta,
               !delta.isEmpty {
                if var pending = state.functionCalls[itemID] {
                    pending.appendArguments(delta)
                    state.functionCalls[itemID] = pending
                } else {
                    // `output_item.added` should always precede this,
                    // but in case the server reordered (or a future
                    // protocol revision skips the precursor), create
                    // the slot lazily with the item_id doubling as the
                    // externalID until we learn better.
                    state.orderedItemIDs.append(itemID)
                    state.functionCalls[itemID] = PendingFunctionCall(
                        externalID: itemID,
                        name: "",
                        argumentsJSON: delta
                    )
                }
                await emitToolCallsIfChanged(state: &state, onEvent: onEvent)
            }

        case "response.function_call_arguments.done":
            // Authoritative final value — replace whatever we
            // accumulated to guard against any mismatched fragment
            // boundaries (e.g. UTF-8 split across SSE chunks).
            if let event = try? JSONDecoder().decode(FunctionCallArgumentsDoneEvent.self, from: payload),
               let itemID = event.item_id {
                if var pending = state.functionCalls[itemID] {
                    if let final = event.arguments {
                        pending.replaceArguments(with: final)
                    }
                    state.functionCalls[itemID] = pending
                    await emitToolCallsIfChanged(state: &state, onEvent: onEvent, force: true)
                }
            }

        case "response.completed":
            await emitToolCallsIfChanged(state: &state, onEvent: onEvent, force: true)
            // Final event — carries the full Response object including
            // usage and stop reason. Translate the OpenAI Responses
            // `status` / `incomplete_details.reason` into the
            // OpenAI-flavoured finish_reason strings AppState already
            // understands.
            if let event = try? JSONDecoder().decode(ResponseCompletedEvent.self, from: payload) {
                if let usage = event.response?.usage {
                    let prompt = usage.input_tokens ?? 0
                    let completion = usage.output_tokens ?? 0
                    let total = usage.total_tokens ?? (prompt + completion)
                    if total > 0 {
                        await onEvent(.usageReported(
                            prompt: prompt,
                            completion: completion,
                            total: total,
                            cachedPrompt: usage.input_tokens_details?.cached_tokens,
                            cacheWritePrompt: nil,
                            reasoning: usage.output_tokens_details?.reasoning_tokens ?? 0
                        ))
                    }
                }
                state.didEmitStreamEvent = true
                let reason = Self.finishReason(from: event.response)
                await onEvent(.finishedTurn(reason))
            }

        case "response.failed", "response.error":
            // Mid-stream failure. Same approach as Anthropic — we
            // surface a descriptive `finishedTurn` so the caller can
            // render an error tail without us needing to invent a
            // mid-stream throwable. Pre-stream status-code errors
            // still go through `serverStatus`.
            let reason: String
            if let event = try? JSONDecoder().decode(ErrorEvent.self, from: payload),
               let message = event.error?.message ?? event.response?.error?.message {
                reason = "openai_responses_error: \(message)"
            } else {
                reason = "openai_responses_error"
            }
            state.didEmitStreamEvent = true
            await onEvent(.finishedTurn(reason))

        default:
            // `response.created` / `response.in_progress` / `response.
            // output_item.done` / various block-level start/stop
            // events — informational only. Skip silently for
            // forward-compatibility with future event types.
            break
        }
    }

    private func emitToolCallsIfChanged(
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
        force: Bool = false
    ) async {
        let signature = Self.signature(of: state)
        if state.toolCallEmissionGate.shouldEmit(signature: signature, force: force) {
            await onEvent(.toolCallsUpdated(Self.snapshot(of: state)))
        }
    }

    private static func snapshot(of state: StreamState) -> [AgentMessageToolCall] {
        state.orderedItemIDs.compactMap { itemID -> AgentMessageToolCall? in
            guard let pending = state.functionCalls[itemID] else { return nil }
            return AgentMessageToolCall(
                externalID: pending.externalID,
                toolName: pending.name,
                argumentsJSON: pending.argumentsJSON
            )
        }
    }

    private static func signature(of state: StreamState) -> String {
        state.orderedItemIDs.compactMap { itemID -> String? in
            guard let pending = state.functionCalls[itemID] else { return nil }
            return "\(itemID)|\(pending.externalID)|\(pending.name)|\(pending.argumentsFingerprint.signatureComponent)"
        }.joined(separator: "||")
    }

    /// Translate the Response object's terminal state into one of the
    /// finish_reason strings the rest of the app already branches on.
    /// Unknown / unmapped statuses pass through so we don't silently
    /// drop information.
    private static func finishReason(from response: ResponseCompletedEvent.ResponseBody?) -> String? {
        guard let response else { return nil }
        if let incomplete = response.incomplete_details?.reason {
            switch incomplete {
            case "max_output_tokens", "max_tokens": return "length"
            case "content_filter":                  return "content_filter"
            default:                                return incomplete
            }
        }
        // Walk the output list — if any function_call items exist,
        // the model paused for tool use rather than finishing free
        // text. AppState's `tool_calls` branch handles that.
        if let outputs = response.output {
            for item in outputs where item.type == "function_call" {
                return "tool_calls"
            }
        }
        switch response.status {
        case "completed":   return "stop"
        case "incomplete":  return "length"
        case "failed":      return "stop"
        case .some(let s):  return s
        case .none:         return "stop"
        }
    }

    // MARK: - Headers / endpoints

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        // Same as Chat Completions: Bearer-key auth. The Responses
        // surface accepts the OpenAI-org `OpenAI-Organization` and
        // `OpenAI-Project` headers too, but neither is required for
        // a personal key and adding them risks 401s on org-less
        // accounts — leave those for a future settings knob.
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
    }

    private func responsesEndpoint(from baseURL: String) throws -> URL {
        try AgentNetworkSupport.endpoint(from: baseURL, suffix: "responses")
    }

    // MARK: - Request body encoding

    /// Translate the chat history + tools into the OpenAI Responses
    /// `input` shape. The reshape mirrors what other adapters do, but
    /// against a flat typed-item list rather than role-grouped
    /// messages.
    ///
    ///   1. `role: system` bubbles up into the top-level `instructions`
    ///      string (Responses accepts a single string, simpler than
    ///      array form).
    ///   2. `role: user` becomes a `{type: "message", role: "user",
    ///      content: [...]}` item with `input_text` / `input_image`
    ///      parts.
    ///   3. `role: assistant` becomes a `{type: "message", role:
    ///      "assistant", content: [{type: "output_text", text}]}` item
    ///      if there's text, plus one `{type: "function_call", call_id,
    ///      name, arguments}` item per tool invocation.
    ///   4. `role: tool` becomes a `{type: "function_call_output",
    ///      call_id, output}` item.
    nonisolated static func encodeRequestBody(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        supportsImages: Bool
    ) throws -> Data {
        var systemBlobs: [String] = []
        var input: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                let text = message.modelContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { systemBlobs.append(text) }

            case .user:
                var content: [[String: Any]] = []
                let text = message.modelContent
                if !text.isEmpty {
                    content.append(["type": "input_text", "text": text])
                }
                if supportsImages {
                    for image in message.images {
                        // Responses carries the image URL directly on
                        // an `input_image` part.
                        content.append([
                            "type": "input_image",
                            "image_url": image.dataURL
                        ])
                    }
                }
                if content.isEmpty {
                    content.append(["type": "input_text", "text": ""])
                }
                input.append([
                    "type": "message",
                    "role": "user",
                    "content": content
                ])

            case .assistant:
                let text = message.modelContent
                if !text.isEmpty {
                    input.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": text]
                        ]
                    ])
                }
                for call in message.toolCalls {
                    // Responses puts the JSON args under `arguments`
                    // as a string (not parsed object — matches the
                    // Chat Completions convention so we don't need
                    // to re-parse).
                    input.append([
                        "type": "function_call",
                        "call_id": call.externalID,
                        "name": call.toolName,
                        "arguments": call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON
                    ])
                }

            case .tool:
                guard let callID = message.toolCallID, !callID.isEmpty else { continue }
                let output: Any
                if supportsImages, !message.images.isEmpty {
                    // Unlike Chat Completions, Responses explicitly allows a
                    // function_call_output to contain text/image input parts.
                    var outputContent: [[String: Any]] = []
                    if !message.modelContent.isEmpty {
                        outputContent.append([
                            "type": "input_text",
                            "text": message.modelContent
                        ])
                    }
                    for image in message.images {
                        outputContent.append([
                            "type": "input_image",
                            "image_url": image.dataURL
                        ])
                    }
                    output = outputContent
                } else {
                    output = message.modelContent
                }
                input.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ])

            case .workflowReport, .widget, .scheduledTask:
                // Workflow report / widget / scheduled-task 卡片不发给模型 —— 用户直接看
                // 渲染出的卡片就好；模型如果要看可以在 transcript 里被
                // 引用，由 user 自己 quote 进下一条消息。
                continue
            }
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "stream": true
        ]
        if !systemBlobs.isEmpty {
            body["instructions"] = systemBlobs.joined(separator: "\n\n")
        }
        if !tools.isEmpty {
            body["tools"] = tools.map(encodeTool)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
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

        // Responses flattens the Chat Completions
        // `{type: "function", function: {name, ...}}` into a single
        // level — name/description/parameters sit beside `type`.
        return [
            "type": "function",
            "name": descriptor.name,
            "description": descriptor.description,
            "parameters": parameterSchema
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

    // MARK: - HTTP error helper

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

// MARK: - Responses wire format (streaming)

private struct OutputTextDeltaEvent: Decodable {
    let delta: String?
    let item_id: String?
    let output_index: Int?
    let content_index: Int?
}

private struct ReasoningDeltaEvent: Decodable {
    let delta: String?
    let item_id: String?
}

private struct OutputItemAddedEvent: Decodable {
    let item: Item?

    struct Item: Decodable {
        let id: String?
        let type: String?
        let call_id: String?
        let name: String?
        let arguments: String?
    }
}

private struct FunctionCallArgumentsDeltaEvent: Decodable {
    let item_id: String?
    let delta: String?
    let output_index: Int?
}

private struct FunctionCallArgumentsDoneEvent: Decodable {
    let item_id: String?
    let arguments: String?
}

private struct ResponseCompletedEvent: Decodable {
    let response: ResponseBody?

    struct ResponseBody: Decodable {
        let status: String?
        let usage: Usage?
        let output: [Output]?
        let incomplete_details: IncompleteDetails?
        let error: ErrorPayload?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
        let input_tokens_details: InputTokensDetails?
        let output_tokens_details: OutputTokensDetails?
    }

    struct InputTokensDetails: Decodable {
        let cached_tokens: Int?
    }

    struct OutputTokensDetails: Decodable {
        let reasoning_tokens: Int?
    }

    struct Output: Decodable {
        let type: String?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct ErrorPayload: Decodable {
        let message: String?
    }
}

private struct ErrorEvent: Decodable {
    let error: ResponseCompletedEvent.ErrorPayload?
    let response: ResponseCompletedEvent.ResponseBody?
}

// MARK: - Non-streaming response (only used by judgeCommandSafety)

private struct NonStreamResponse: Decodable {
    let output: [OutputItem]?

    struct OutputItem: Decodable {
        let type: String?
        let content: [Content]?
    }

    struct Content: Decodable {
        let type: String?
        let text: String?
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
