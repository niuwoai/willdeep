//
//  AgentClientGemini.swift
//  Xedit
//
//  Adapter for Google's Gemini generateContent API
//  (`POST {baseURL}/v1beta/models/{model}:streamGenerateContent?alt=sse`).
//
//  This is the most divergent of the four protocols we speak:
//
//    • Model is part of the URL path, not the body — every request
//      rebuilds the endpoint from `configuration.model`.
//    • Auth uses `x-goog-api-key: {key}` header (we keep the key out of
//      URL params on principle — Gemini accepts both forms).
//    • Roles collapse from our 4 (system / user / assistant / tool) to
//      Gemini's 2 (`user` / `model`). System bubbles up into a top-level
//      `systemInstruction` field; tool replies become `functionResponse`
//      parts on a synthetic `user` message after the assistant turn.
//    • Tool calls are matched by `name`, NOT by id. Our internal model
//      threads everything through `AgentMessageToolCall.externalID`
//      (OpenAI-flavoured `call_xxx`); on the encode side we look up
//      the matching tool name by id, on the decode side we synthesize
//      stable IDs (`gemini_fcall_<nonce>_<index>`, nonce unique per
//      response stream) so upstream code keeps working without
//      special-casing the provider. The nonce keeps ids unique across
//      assistant turns — a bare per-stream index would collide from one
//      turn to the next and mispair functionResponse names in history.
//    • Schema types use ALL_CAPS string enums (`STRING` / `INTEGER` /
//      `BOOLEAN` / `OBJECT` / `ARRAY`), not the lowercase JSON Schema
//      shape OpenAI / Anthropic use.
//    • Tools are wrapped under `{function_declarations: [...]}` and the
//      outer `tools` array holds exactly one such block in normal usage.
//    • Streaming with `alt=sse` returns one `GenerateContentResponse`
//      JSON per `data:` line; we accumulate text deltas and
//      functionCall parts the same way the other adapters do.
//
//  Translation work is concentrated in `Self.encodeRequestBody(...)`
//  and the streaming `handleResponse(...)` helper. The caller only ever
//  sees `AgentClientEvent`.
//

import Foundation

struct GeminiAdapter {
    private let configuration: AgentConfiguration
    private let session: URLSession

    /// Gemini's `maxOutputTokens` isn't strictly required (the server
    /// picks a reasonable default), but pinning it keeps long-form
    /// replies bounded the same way the Anthropic adapter does. Lifts
    /// to a settings knob later if it becomes a constraint.
    nonisolated private static let defaultMaxOutputTokens = 8192

    init(configuration: AgentConfiguration, session: URLSession? = nil) {
        self.configuration = configuration.normalized
        self.session = session ?? AgentNetworkSupport.defaultSession()
    }

    // MARK: - streamChat

    func streamChat(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor] = [],
        requestLedger: AgentModelRequestLedger? = nil,
        requestOwnerGate: AgentRequestOwnerGate? = nil,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async throws {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try streamEndpoint(model: configuration.model)
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
        let toolNameByID = Self.buildToolCallIDMap(from: requestMessages)
        let requestBody = try Self.encodeRequestBody(
            messages: requestMessages,
            tools: tools,
            supportsImages: configuration.supportsImageInput,
            toolNameByID: toolNameByID
        )
        request.httpBody = requestBody

        try await AgentModelRequestAccounting.run(ledger: requestLedger, configuration: configuration, request: request, format: .gemini, ownerGate: requestOwnerGate, onEvent: onEvent) { request, onEvent in
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgentClientError.invalidResponse
            }
            if let requestID = AgentNetworkSupport.someIMRequestID(
                from: httpResponse,
                providerID: configuration.providerID
            ) {
                await onEvent(.requestIdentified(requestID))
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

            var state = StreamState()

            for try await line in AgentStreamIdleGuard.lines(bytes.lines) {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst("data: ".count))
                guard !payload.isEmpty,
                      let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(GenerateContentResponse.self, from: data) else {
                    continue
                }
                await handleResponse(chunk, state: &state, onEvent: onEvent)
            }

            // A 2xx stream that produced no text, function call or finishReason
            // is an empty no-op. Surface it as a retryable error rather than
            // silently dropping the turn.
            if !state.didEmitStreamEvent {
                throw AgentClientError.emptyStream(
                    providerID: configuration.providerID,
                    model: configuration.model
                )
            }
        }
    }

    // MARK: - judgeCommandSafety

    /// Non-streaming classifier. Returns `true` only on a clean `YES`;
    /// any network/parse failure means "ask the user".
    func judgeCommandSafety(
        command: String,
        historyContext: String = "",
        toolName: String = "run_command",
        taskContext: String = "",
        environmentTrust: String = "",
        kind: AgentSafetyJudgeKind = .developerOperations,
        requestLedger: AgentModelRequestLedger? = nil,
        executionBudget: AgentToolExecutionBudget? = nil
    ) async throws -> AgentSafetyJudgeResult {
        guard !configuration.apiKey.isEmpty else {
            return .unavailable("missing api key")
        }

        let endpoint: URL
        do { endpoint = try nonStreamEndpoint(model: configuration.model) }
        catch { return .unavailable("bad endpoint") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentInjectionDefense.judgeTimeout
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = AgentInjectionDefense.judgeSystemPromptText(historyContext: historyContext, kind: kind)
        let userPayload = AgentInjectionDefense.judgeUserPayload(
            command: command,
            toolName: toolName,
            taskContext: taskContext,
            environmentTrust: environmentTrust
        )

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": userPayload]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": AgentInjectionDefense.judgeMaxOutputTokens,
                "temperature": 0
            ]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return .unavailable("encode failed")
        }
        request.httpBody = payload

        do {
            let (data, response) = try await AgentNonStreamingModelRequest.run(request: request, session: session,
                configuration: configuration, format: .gemini, ledger: requestLedger,
                executionBudget: executionBudget)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("no http response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable("http \(http.statusCode)")
            }
            guard let decoded = try? JSONDecoder().decode(GenerateContentResponse.self, from: data),
                  let candidate = decoded.candidates?.first else {
                return .unavailable("decode failed")
            }
            let text = (candidate.content?.parts ?? [])
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
            if AgentAuxiliaryRequestStop(error) != nil || error is CancellationError { throw error }
            return .unavailable("network error")
        }
    }

    // MARK: - fetchModels

    /// `GET /v1beta/models` returns `{models: [{name: "models/...",
    /// supportedGenerationMethods: [...]}]}`. We keep only the rows that
    /// can serve `generateContent` (the others are embedders / tuning
    /// targets which would confuse the chat-mode picker) and strip the
    /// `models/` prefix so what the user sees in Settings matches what
    /// they paste into the model field.
    func fetchModels() async throws -> [String] {
        guard !configuration.apiKey.isEmpty else {
            throw AgentClientError.missingAPIKey
        }

        let endpoint = try modelsEndpoint()
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

        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw AgentModelListResponseFormatError.wrapping(
                error,
                data: data,
                expectedSchema: #"{"models":[{"name":"models/model-id","supportedGenerationMethods":["generateContent"]}]}"#
            )
        }
        return decoded.models
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name }
            .map { name -> String in
                // Strip the `models/` namespace so the surface match
                // matches what users type and what we put in the
                // request URL.
                let prefix = "models/"
                if name.hasPrefix(prefix) {
                    return String(name.dropFirst(prefix.count))
                }
                return name
            }
            .filter { !$0.isEmpty }
            .sorted()
    }

    // MARK: - Stream state machine

    private struct StreamState {
        /// Accumulated functionCall blocks, keyed by the (part) index
        /// they showed up at. Gemini does NOT give them ids, so we
        /// synthesize stable ones in `snapshot()`. Each functionCall
        /// arrives whole in a single chunk (unlike OpenAI/Anthropic
        /// which stream the args JSON in fragments), so we just hold
        /// onto the parsed value.
        var functionCalls: [Int: PendingFunctionCall] = [:]
        /// Baked into every synthesized call id for this response stream.
        /// Without it every assistant turn restarts at `gemini_fcall_0`,
        /// and the first-occurrence-wins id→name history map resolves later
        /// turns' slot-0 calls to whichever tool the session used first.
        let callIDNonce = GeminiAdapter.makeCallIDNonce()
        var emittedSignature = ""
        /// True once the stream carries a real signal (text, a function
        /// call, or a finishReason). A 2xx stream that closes with none of
        /// these would look like a silent success; `streamChat` throws
        /// `emptyStream` when this stays false. Usage-only chunks don't count.
        var didEmitStreamEvent = false
    }

    private struct PendingFunctionCall {
        var name: String
        /// Pre-serialized JSON of the `args` object. Stored as a string
        /// so the snapshot matches the shape AppState already expects
        /// (`AgentMessageToolCall.argumentsJSON`). The pretty-print
        /// option keeps it readable in the UI without round-tripping.
        var argumentsJSON: String
    }

    private func handleResponse(
        _ chunk: GenerateContentResponse,
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async {
        guard let candidate = chunk.candidates?.first else {
            // Some chunks carry only `usageMetadata` (no candidate
            // payload) — surface those below and skip the part walk.
            await emitUsageAndFinish(chunk, state: &state, onEvent: onEvent)
            return
        }

        var sawFunctionCallChange = false

        // Each chunk's `content.parts[]` is the cumulative delta for
        // this chunk — text fragments and (occasionally) one or more
        // functionCalls. We index function calls by their position
        // across the whole response so simultaneous parallel calls
        // get distinct slots.
        var functionCallIndex = state.functionCalls.count
        for part in candidate.content?.parts ?? [] {
            if let text = part.text, !text.isEmpty {
                state.didEmitStreamEvent = true
                await onEvent(.textDelta(text))
            }
            if let call = part.functionCall {
                let argsJSON: String
                if let args = call.args,
                   let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
                   let string = String(data: data, encoding: .utf8) {
                    argsJSON = string
                } else {
                    argsJSON = "{}"
                }
                state.functionCalls[functionCallIndex] = PendingFunctionCall(
                    name: call.name,
                    argumentsJSON: argsJSON
                )
                functionCallIndex += 1
                sawFunctionCallChange = true
            }
        }

        if sawFunctionCallChange {
            let snapshot = Self.snapshot(of: state.functionCalls, nonce: state.callIDNonce)
            let signature = Self.signature(of: snapshot)
            if signature != state.emittedSignature {
                state.emittedSignature = signature
                state.didEmitStreamEvent = true
                await onEvent(.toolCallsUpdated(snapshot))
            }
        }

        await emitUsageAndFinish(chunk, state: &state, onEvent: onEvent)
    }

    private func emitUsageAndFinish(
        _ chunk: GenerateContentResponse,
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async {
        if let usage = chunk.usageMetadata {
            let prompt = usage.promptTokenCount ?? 0
            let completion = usage.candidatesTokenCount ?? 0
            let total = usage.totalTokenCount ?? (prompt + completion)
            if total > 0 {
                await onEvent(.usageReported(
                    prompt: prompt,
                    completion: completion,
                    total: total,
                    cachedPrompt: usage.cachedContentTokenCount,
                    cacheWritePrompt: nil,
                    reasoning: usage.thoughtsTokenCount ?? 0
                ))
            }
        }

        if let reason = chunk.candidates?.first?.finishReason {
            // Map Gemini's enum values to the OpenAI-flavoured strings
            // AppState's finish-reason branches already understand.
            // `FINISH_REASON_UNSPECIFIED` and unknown values pass through
            // verbatim — they're informational, not behaviour-changing.
            let mapped: String
            switch reason {
            case "STOP":            mapped = "stop"
            case "MAX_TOKENS":      mapped = "length"
            case "SAFETY":          mapped = "content_filter"
            case "RECITATION":      mapped = "content_filter"
            case "MALFORMED_FUNCTION_CALL": mapped = "tool_calls"
            default:                mapped = reason.lowercased()
            }
            state.didEmitStreamEvent = true
            await onEvent(.finishedTurn(mapped))
        }
    }

    private static func snapshot(of pending: [Int: PendingFunctionCall], nonce: String) -> [AgentMessageToolCall] {
        pending.keys.sorted().map { idx in
            let entry = pending[idx]!
            // Synthesize a stable id so the rest of the app can keep
            // pairing tool_result → tool_call by externalID. The
            // `gemini_fcall_` prefix makes it grep-friendly when
            // debugging chat history JSON.
            return AgentMessageToolCall(
                externalID: syntheticToolCallID(nonce: nonce, index: idx),
                toolName: entry.name,
                argumentsJSON: entry.argumentsJSON
            )
        }
    }

    /// Globally unique per response stream (the nonce), stable within it
    /// (generated once per stream, so streaming snapshots keep identical
    /// ids and persisted history replays byte-identically).
    nonisolated static func syntheticToolCallID(nonce: String, index: Int) -> String {
        "gemini_fcall_\(nonce)_\(index)"
    }

    nonisolated static func makeCallIDNonce() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func signature(of calls: [AgentMessageToolCall]) -> String {
        calls.map { "\($0.externalID)|\($0.toolName)|\($0.argumentsJSON)" }.joined(separator: "||")
    }

    // MARK: - Headers / endpoints

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        // Gemini accepts both `?key=...` query param and `x-goog-api-key`
        // header. We pick the header form so the key never appears in
        // any URL we log (`redactedURLString` in AgentNetworkSupport
        // already strips `key` query items, but skipping the issue
        // entirely is cleaner than scrubbing it after the fact).
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
    }

    private func streamEndpoint(model: String) throws -> URL {
        try modelEndpoint(model: model, action: "streamGenerateContent", queryItems: [
            URLQueryItem(name: "alt", value: "sse")
        ])
    }

    private func nonStreamEndpoint(model: String) throws -> URL {
        try modelEndpoint(model: model, action: "generateContent", queryItems: [])
    }

    /// Gemini puts the model name in the URL path with a `:action`
    /// suffix (e.g. `models/gemini-2.5-flash:streamGenerateContent`).
    /// Build it via `URLComponents` so unusual model ids get
    /// percent-encoded correctly without us touching strings.
    private func modelEndpoint(
        model: String,
        action: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        guard !model.isEmpty else { throw AgentClientError.invalidBaseURL }
        let cleanedModel = model.hasPrefix("models/")
            ? String(model.dropFirst("models/".count))
            : model
        let suffix = "v1beta/models/\(cleanedModel):\(action)"
        // We can't reuse `AgentNetworkSupport.endpoint(from:suffix:)`
        // directly — that one's logic checks `path.hasSuffix(suffix)`
        // which would never match the `:action` segment after a
        // model name. Easier to build URLComponents fresh here.
        let trimmed = configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmed) else {
            throw AgentClientError.invalidBaseURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let separator = basePath.isEmpty ? "" : "/"
        components.path = "/\(basePath)\(separator)\(suffix)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw AgentClientError.invalidBaseURL }
        return url
    }

    private func modelsEndpoint() throws -> URL {
        try AgentNetworkSupport.endpoint(from: configuration.baseURL, suffix: "v1beta/models")
    }

    // MARK: - Request body encoding

    /// Build a map of `externalID -> toolName` by walking the assistant
    /// tool_calls in the conversation history. Gemini's
    /// `functionResponse` parts identify themselves by `name`, not by
    /// id, so when we later emit a tool reply we need to know which
    /// name went with the original call. Built once per request and
    /// passed into `encodeRequestBody`.
    nonisolated static func buildToolCallIDMap(from messages: [AgentMessage]) -> [String: String] {
        var map: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for call in message.toolCalls {
                guard !call.externalID.isEmpty, !call.toolName.isEmpty else { continue }
                // First occurrence wins — a call id appears once.
                if map[call.externalID] == nil {
                    map[call.externalID] = call.toolName
                }
            }
        }
        return map
    }

    /// Translate the chat history + tool descriptors into the Gemini
    /// generateContent wire format.
    ///
    ///   1. Every `role: system` message bubbles into the top-level
    ///      `systemInstruction` field (multi-blob is joined with a
    ///      blank line — Gemini's parts array would also work but a
    ///      single string is simpler and supported).
    ///   2. `role: assistant` becomes `role: "model"`. Tool calls on
    ///      that message turn into one `functionCall` part each,
    ///      sharing the message with any leading text.
    ///   3. A contiguous `role: tool` run becomes one `user` message
    ///      containing the corresponding `functionResponse` parts. The
    ///      `name` comes from
    ///      `toolNameByID[message.toolCallID]`; if we lost the
    ///      mapping we fall back to a placeholder so the request
    ///      doesn't get rejected outright — the model can usually
    ///      reason about a `"unknown_tool"` reply, while a malformed
    ///      request bricks the whole turn.
    ///   4. `role: user` carries text + (optionally) image parts as
    ///      `inlineData` blocks.
    nonisolated static func encodeRequestBody(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        supportsImages: Bool,
        toolNameByID: [String: String]
    ) throws -> Data {
        var systemBlobs: [String] = []
        var contents: [[String: Any]] = []

        var pendingToolResponseParts: [[String: Any]] = []
        var pendingToolVisualParts: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .system:
                // Local-only transcript markers (model-changed, auto-Plan
                // notice, …) ride as `.system` for rendering but must never
                // enter the model's system prompt.
                if message.isLocalTranscriptEvent { continue }
                let text = message.modelContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { systemBlobs.append(text) }

            case .user:
                var parts: [[String: Any]] = []
                let text = message.modelContent
                if !text.isEmpty {
                    parts.append(["text": text])
                }
                if supportsImages {
                    for image in message.images {
                        if let block = imagePart(from: image) {
                            parts.append(block)
                        }
                    }
                }
                if parts.isEmpty {
                    // Gemini rejects empty parts arrays; fall back to
                    // a noop text part so the request validates. This
                    // typically only happens on an image-only turn
                    // against a text-only model that already had
                    // images stripped upstream.
                    parts.append(["text": ""])
                }
                contents.append([
                    "role": "user",
                    "parts": parts
                ])

            case .assistant:
                var parts: [[String: Any]] = []
                let text = message.modelContent
                if !text.isEmpty {
                    parts.append(["text": text])
                }
                for call in message.toolCalls {
                    let args: Any
                    if let data = call.argumentsJSON.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
                        args = parsed
                    } else {
                        args = [String: Any]()
                    }
                    parts.append([
                        "functionCall": [
                            "name": call.toolName,
                            "args": args
                        ]
                    ])
                }
                guard !parts.isEmpty else { continue }
                contents.append([
                    "role": "model",
                    "parts": parts
                ])

            case .tool:
                if let id = message.toolCallID, !id.isEmpty {
                    let name = toolNameByID[id] ?? "unknown_tool"
                    // Gemini wants the tool response wrapped in an object —
                    // free-form so the model gets the full payload. We put
                    // the textual result under a `content` key; some
                    // examples also accept a free `result` key, but
                    // `content` is what the official samples use.
                    let responsePayload: [String: Any] = [
                        "content": message.modelContent
                    ]
                    pendingToolResponseParts.append([
                        "functionResponse": [
                            "name": name,
                            "response": responsePayload
                        ]
                    ])
                    if supportsImages, !message.images.isEmpty {
                        pendingToolVisualParts.append([
                            "text": "Visual output from function \(name):"
                        ])
                        for image in message.images {
                            if let block = imagePart(from: image) {
                                pendingToolVisualParts.append(block)
                            }
                        }
                    }
                }

                // Gemini represents parallel function results as parts of one
                // user turn. Append visual parts only after the complete
                // functionResponse run so images cannot split the responses.
                let nextIsTool = index + 1 < messages.count
                    && messages[index + 1].role == .tool
                if !nextIsTool, !pendingToolResponseParts.isEmpty {
                    contents.append([
                        "role": "user",
                        "parts": pendingToolResponseParts + pendingToolVisualParts
                    ])
                    pendingToolResponseParts.removeAll(keepingCapacity: true)
                    pendingToolVisualParts.removeAll(keepingCapacity: true)
                }

            case .workflowReport, .widget, .scheduledTask:
                // Workflow / widget / scheduled-task card 不发给模型，跳过。
                continue
            }
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": defaultMaxOutputTokens
            ]
        ]
        if !systemBlobs.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": systemBlobs.joined(separator: "\n\n")]]
            ]
        }
        if !tools.isEmpty {
            body["tools"] = [
                [
                    "function_declarations": tools.map(encodeTool)
                ]
            ]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated private static func imagePart(from image: AgentImageAttachment) -> [String: Any]? {
        // Parse our existing `data:image/...;base64,...` URL into
        // Gemini's `inlineData` shape. Same approach as the
        // Anthropic adapter — the in-app representation already has
        // base64 + media type, just rewrap.
        let dataURL = image.dataURL
        guard dataURL.hasPrefix("data:") else { return nil }
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[..<commaIndex]
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        let mediaType: String
        if let slashIdx = header.firstIndex(of: ":"),
           let semiIdx = header.firstIndex(of: ";") {
            mediaType = String(header[header.index(after: slashIdx)..<semiIdx])
        } else {
            mediaType = "image/png"
        }
        return [
            "inlineData": [
                "mimeType": mediaType,
                "data": base64
            ]
        ]
    }

    nonisolated private static func encodeTool(_ descriptor: AgentToolDescriptor) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for parameter in descriptor.parameters {
            properties[parameter.name] = schemaProperty(for: parameter)
            if parameter.required { required.append(parameter.name) }
        }

        var parameterSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": properties
        ]
        if !required.isEmpty {
            parameterSchema["required"] = required
        }

        return [
            "name": descriptor.name,
            "description": descriptor.description,
            "parameters": parameterSchema
        ]
    }

    nonisolated private static func schemaProperty(for parameter: AgentToolParameter) -> [String: Any] {
        switch parameter.type {
        case .string:
            return [
                "type": "STRING",
                "description": parameter.description
            ]
        case .integer:
            return [
                "type": "INTEGER",
                "description": parameter.description
            ]
        case .boolean:
            return [
                "type": "BOOLEAN",
                "description": parameter.description
            ]
        case .stringArray:
            return [
                "type": "ARRAY",
                "items": ["type": "STRING"],
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

// MARK: - Gemini wire format

/// Streaming chunk shape — also covers the non-streaming response,
/// which is just one of these without further chunks. Fields are
/// camelCase as Gemini's official JSON; `JSONDecoder` matches them
/// case-sensitively without a custom CodingKey table.
private struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
        let role: String?
    }

    struct Part: Decodable {
        let text: String?
        let functionCall: FunctionCall?
    }

    struct FunctionCall: Decodable {
        let name: String
        /// `args` is a free-form JSON object. We decode it via an
        /// `AnyCodable`-style shim so the args reach us as a
        /// `[String: Any]` we can serialise back out as
        /// `AgentMessageToolCall.argumentsJSON`.
        let args: [String: Any]?

        enum CodingKeys: String, CodingKey {
            case name
            case args
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            if let raw = try c.decodeIfPresent(JSONValue.self, forKey: .args) {
                if case let .object(dict) = raw {
                    self.args = dict.mapValues { $0.unwrapped }
                } else {
                    self.args = nil
                }
            } else {
                self.args = nil
            }
        }
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let cachedContentTokenCount: Int?
        let candidatesTokenCount: Int?
        let thoughtsTokenCount: Int?
        let totalTokenCount: Int?
    }
}

private struct ModelsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]?
    }
}

/// Minimal `JSONValue` for the one field we need to decode as
/// free-form JSON (`functionCall.args`). Built locally to avoid
/// dragging in a dependency for one field. Round-trips into
/// `Any` via `unwrapped` so we can re-serialise with
/// `JSONSerialization`.
private indirect enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b); return
        }
        // Try Int first to preserve integral round-trips when re-
        // serialising; fall back to Double for fractional values.
        if let i = try? container.decode(Int.self) {
            self = .number(Double(i)); return
        }
        if let d = try? container.decode(Double.self) {
            self = .number(d); return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s); return
        }
        if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr); return
        }
        if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj); return
        }
        self = .null
    }

    var unwrapped: Any {
        switch self {
        case .null:               return NSNull()
        case .bool(let b):        return b
        case .number(let d):
            // Re-prefer Int when the value is exactly integral so the
            // round-trip JSON doesn't gain a `.0`. Gemini's tool
            // arguments are typically integers (line numbers, limits),
            // and `"limit": 120.0` would confuse downstream parsers.
            if d.truncatingRemainder(dividingBy: 1) == 0,
               d >= Double(Int.min), d <= Double(Int.max) {
                return Int(d)
            }
            return d
        case .string(let s):      return s
        case .array(let arr):     return arr.map(\.unwrapped)
        case .object(let obj):    return obj.mapValues(\.unwrapped)
        }
    }
}
