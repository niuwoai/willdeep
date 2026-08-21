//
//  AgentClientAnthropic.swift
//  Xedit
//
//  Adapter for Anthropic's native Messages API
//  (`POST {baseURL}/v1/messages`, SSE-encoded streaming).
//
//  Shape differs from OpenAI Chat Completions in several places that
//  *can't* be papered over by a header bump (which is why the previous
//  "claude preset on the OpenAI adapter" stance never actually worked):
//
//    • Auth header is `x-api-key`, not `Authorization: Bearer`.
//      `anthropic-version: 2023-06-01` is required.
//    • `system` is a top-level field, not a `role: system` message.
//    • `messages` must alternate user/assistant; tool results come back
//      inside the next user message as `content: [tool_result blocks]`.
//    • Assistant tool calls are `content: [tool_use blocks]`, not a
//      sibling `tool_calls` array.
//    • `max_tokens` is REQUIRED. We pick a generous default (4096).
//    • Tool schema is `{name, description, input_schema}` — no
//      `{type: function, function: {...}}` wrapper.
//    • Streaming events are typed: `message_start` / `content_block_start`
//      / `content_block_delta` / `content_block_stop` / `message_delta`
//      / `message_stop`. Each `data:` line carries a JSON payload that
//      MUST be paired with the preceding `event:` line for routing.
//
//  Translation work between `AgentMessage` (the protocol-agnostic
//  in-app shape) and the Anthropic wire format is concentrated in
//  `Self.encodeRequestBody(...)`. The streaming loop translates back
//  into `AgentClientEvent` so the caller never sees Anthropic types.
//

import Foundation

struct AnthropicMessagesAdapter {
    private let configuration: AgentConfiguration
    private let session: URLSession

    /// Anthropic's `max_tokens` is mandatory. Default 32K (user-adjustable
    /// in Settings → AI) so long documents and large refactor replies stop
    /// truncating with finish_reason=length. Legacy Claude 3.x models
    /// hard-reject values above their output caps with a 400, so the
    /// configured value is clamped per model family at request time.
    nonisolated static func maxOutputTokens(forModel model: String) -> Int {
        maxOutputTokens(forModel: model, configured: AgentSettingsStore.loadAnthropicMaxOutputTokens())
    }

    nonisolated static func maxOutputTokens(forModel model: String, configured: Int) -> Int {
        let lower = model.lowercased()
        if lower.contains("claude-3-opus") || lower.contains("claude-3-haiku") || lower.contains("claude-3-sonnet") {
            return min(configured, 4096)
        }
        if lower.contains("claude-3-5") || lower.contains("claude-3.5") || lower.contains("claude-3-7") {
            return min(configured, 8192)
        }
        return configured
    }

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

        let endpoint = try messagesEndpoint(from: configuration.baseURL)
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

        // Anthropic SSE is line-pair driven: `event: <type>` followed
        // by `data: <json>`. We hold the last event name and route the
        // next data payload accordingly. Anything else (blank lines
        // between pairs, the trailing `: ping` comment Anthropic
        // occasionally sends as keepalive) is skipped silently.
        var pendingEventName: String = ""
        var streamState = StreamState()

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
                state: &streamState,
                onEvent: onEvent
            )

            // Reset so a misformatted stream (`data:` without preceding
            // `event:`) doesn't get misrouted to whatever the previous
            // event happened to be.
            pendingEventName = ""
        }

        // A 2xx stream that carried no text, reasoning, tool call, stop_reason
        // or error is an empty no-op (e.g. an expired relay token answered
        // with an empty body instead of 401). Surface it so the caller shows
        // an actionable, retryable error rather than silently dropping the
        // turn.
        if !streamState.didEmitStreamEvent {
            throw AgentClientError.emptyStream(
                providerID: configuration.providerID,
                model: configuration.model
            )
        }
    }

    // MARK: - judgeCommandSafety

    /// Non-streaming, low-token classifier. Returns `true` only on a
    /// clean `YES`; any network/parse failure means "ask the user".
    /// Anthropic flavoured: `system` is top-level and `user` is the
    /// only message in this single round trip.
    func judgeCommandSafety(
        command: String,
        historyContext: String = "",
        toolName: String = "run_command",
        taskContext: String = "",
        environmentTrust: String = ""
    ) async -> AgentSafetyJudgeResult {
        guard !configuration.apiKey.isEmpty else {
            return .unavailable("missing api key")
        }

        let endpoint: URL
        do { endpoint = try messagesEndpoint(from: configuration.baseURL) }
        catch { return .unavailable("bad endpoint") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentInjectionDefense.judgeTimeout
        applyAuthenticationHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = AgentInjectionDefense.judgeSystemPromptText(historyContext: historyContext)
        let userPayload = AgentInjectionDefense.judgeUserPayload(
            command: command,
            toolName: toolName,
            taskContext: taskContext,
            environmentTrust: environmentTrust
        )

        // System block carries the fixed rules + the caller's stable history
        // block, so mark it `cache_control: ephemeral` — the identical prefix
        // is served from Anthropic's prompt cache across judge calls; only
        // the per-call <command> in the user message is uncached.
        // Anthropic rejects a `max_tokens` above the model's own ceiling, and
        // the judge budget (8192) sits above what the claude-3 tier accepts
        // (4096). An out-of-range value is a 400, which the judge reports as
        // `unavailable` — the whole judge would go dark on those models
        // instead of degrading. Clamp to the model's ceiling; a shorter
        // rationale that still closes its tag beats no verdict at all.
        let judgeBudget = min(
            AgentInjectionDefense.judgeMaxOutputTokens,
            Self.maxOutputTokens(
                forModel: configuration.model,
                configured: AgentInjectionDefense.judgeMaxOutputTokens
            )
        )
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": judgeBudget,
            "temperature": 0,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
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
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable("http \(http.statusCode)")
            }
            guard let decoded = try? JSONDecoder().decode(NonStreamMessage.self, from: data) else {
                return .unavailable("decode failed")
            }
            let textBlobs = decoded.content.compactMap { block -> String? in
                guard block.type == "text" else { return nil }
                return block.text
            }
            let answer = textBlobs.joined()
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

    // MARK: - fetchModels

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

        let decoded: ModelsResponse
        do {
            decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            throw AgentModelListResponseFormatError.wrapping(
                error,
                data: data,
                expectedSchema: #"{"data":[{"id":"model-id"}]}"#
            )
        }
        return decoded.data.map(\.id).filter { !$0.isEmpty }.sorted()
    }

    // MARK: - Stream state machine

    /// Aggregates partial fragments of a single streaming response
    /// before they're flushed as `AgentClientEvent`s. Anthropic streams
    /// text and tool calls as a sequence of content blocks; we map
    /// each block index to a slot so out-of-order deltas don't blend.
    private struct StreamState {
        /// Tool-use blocks indexed by their content_block index.
        var toolBlocks: [Int: PendingToolCall] = [:]
        var toolCallEmissionGate = AgentToolCallStreamEmissionGate()
        /// Set the moment the stream carries a real signal (text, reasoning,
        /// a tool block, a stop_reason, or a mid-stream error). A 2xx
        /// response that closes with none of these — an expired relay token
        /// answered with an empty body, an upstream hiccup — would otherwise
        /// look like a silent success; `streamChat` throws `emptyStream` when
        /// this stays false. `message_start` (usage only) does NOT count.
        var didEmitStreamEvent = false
        /// Carried from `message_start` (Anthropic emits input_tokens
        /// up front) so the final `usageReported` can include both
        /// halves once `message_delta` brings output_tokens.
        var promptTokens: Int = 0
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
    }

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

    private func handleEvent(
        name: String,
        payload: Data,
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void
    ) async {
        switch name {
        case "message_start":
            if let event = try? JSONDecoder().decode(MessageStartEvent.self, from: payload) {
                state.promptTokens = event.message.usage?.input_tokens ?? 0
                state.cacheReadTokens = event.message.usage?.cache_read_input_tokens
                state.cacheWriteTokens = event.message.usage?.cache_creation_input_tokens
            }

        case "content_block_start":
            guard let event = try? JSONDecoder().decode(ContentBlockStartEvent.self, from: payload) else { return }
            if event.content_block.type == "tool_use" {
                state.didEmitStreamEvent = true
                var pending = PendingToolCall()
                pending.externalID = event.content_block.id ?? ""
                pending.toolName = event.content_block.name ?? ""
                state.toolBlocks[event.index] = pending
                await emitToolCallsIfChanged(state: &state, onEvent: onEvent, force: true)
            }

        case "content_block_delta":
            guard let event = try? JSONDecoder().decode(ContentBlockDeltaEvent.self, from: payload) else { return }
            switch event.delta.type {
            case "text_delta":
                if let text = event.delta.text, !text.isEmpty {
                    state.didEmitStreamEvent = true
                    await onEvent(.textDelta(text))
                }
            case "thinking_delta":
                // Extended thinking trace. We're not requesting it yet
                // (no `thinking` field in the request body), but
                // forward through the reasoning channel for symmetry
                // with DashScope/DeepSeek if a future preset opts in.
                if let trace = event.delta.thinking, !trace.isEmpty {
                    state.didEmitStreamEvent = true
                    await onEvent(.reasoningDelta(trace))
                }
            case "input_json_delta":
                if let partial = event.delta.partial_json, var pending = state.toolBlocks[event.index] {
                    state.didEmitStreamEvent = true
                    pending.appendArguments(partial)
                    state.toolBlocks[event.index] = pending
                    await emitToolCallsIfChanged(state: &state, onEvent: onEvent)
                }
            default:
                // signature_delta and any future delta type — silently
                // skip rather than crash on a forward-compat addition.
                break
            }

        case "content_block_stop":
            await emitToolCallsIfChanged(state: &state, onEvent: onEvent, force: true)

        case "message_delta":
            guard let event = try? JSONDecoder().decode(MessageDeltaEvent.self, from: payload) else { return }
            if let reason = event.delta.stop_reason {
                // Map Anthropic stop_reason to the OpenAI-flavoured
                // values AppState already knows. "tool_use" → "tool_calls"
                // keeps the existing per-finish-reason branching working.
                let mapped: String
                switch reason {
                case "tool_use":    mapped = "tool_calls"
                case "end_turn":    mapped = "stop"
                case "max_tokens":  mapped = "length"
                case "stop_sequence": mapped = "stop"
                default:            mapped = reason
                }
                state.didEmitStreamEvent = true
                await onEvent(.finishedTurn(mapped))
            }
            if let usage = event.usage {
                state.promptTokens = usage.input_tokens ?? state.promptTokens
                state.cacheReadTokens = usage.cache_read_input_tokens ?? state.cacheReadTokens
                state.cacheWriteTokens = usage.cache_creation_input_tokens ?? state.cacheWriteTokens
                let output = usage.output_tokens ?? 0
                // Anthropic reports uncached input, cache reads, and cache
                // creation as separate buckets. Normalize `prompt` to the same
                // total-input meaning used by OpenAI/Gemini before persisting it.
                let totalPrompt = Self.normalizedPromptTokens(
                    uncached: state.promptTokens,
                    cacheRead: state.cacheReadTokens,
                    cacheWrite: state.cacheWriteTokens
                )
                let total = totalPrompt + output
                if total > 0 {
                    await onEvent(.usageReported(
                        prompt: totalPrompt,
                        completion: output,
                        total: total,
                        cachedPrompt: state.cacheReadTokens,
                        cacheWritePrompt: state.cacheWriteTokens,
                        reasoning: 0
                    ))
                }
            }

        case "message_stop":
            await emitToolCallsIfChanged(state: &state, onEvent: onEvent, force: true)

        case "error":
            // Anthropic sends an `event: error` with `{ type: "error",
            // error: { type, message } }` if it bails mid-stream
            // (overload, invalid_request_error after the headers have
            // already been flushed). We don't have a clean way to
            // bubble this into the existing `AgentClientError`
            // taxonomy mid-stream — surface it as a finishedTurn with
            // a descriptive reason so the caller can render an error
            // bubble. Status-code-shaped errors stay on the pre-stream
            // path in `serverStatus`.
            let reason: String
            if let event = try? JSONDecoder().decode(ErrorEvent.self, from: payload),
               let msg = event.error?.message {
                reason = "anthropic_error: \(msg)"
            } else {
                reason = "anthropic_error"
            }
            state.didEmitStreamEvent = true
            await onEvent(.finishedTurn(reason))

        default:
            // `ping` keepalive and any future event type — skip.
            break
        }
    }

    nonisolated static func normalizedPromptTokens(
        uncached: Int,
        cacheRead: Int?,
        cacheWrite: Int?
    ) -> Int {
        max(0, uncached) + max(0, cacheRead ?? 0) + max(0, cacheWrite ?? 0)
    }

    private func emitToolCallsIfChanged(
        state: inout StreamState,
        onEvent: @escaping @Sendable (AgentClientEvent) async -> Void,
        force: Bool = false
    ) async {
        let signature = Self.signature(of: state.toolBlocks)
        if state.toolCallEmissionGate.shouldEmit(signature: signature, force: force) {
            await onEvent(.toolCallsUpdated(Self.snapshot(of: state.toolBlocks)))
        }
    }

    private static func snapshot(of pending: [Int: PendingToolCall]) -> [AgentMessageToolCall] {
        pending.keys.sorted().map { idx in
            let entry = pending[idx]!
            return AgentMessageToolCall(
                externalID: entry.externalID,
                toolName: entry.toolName,
                argumentsJSON: entry.argumentsJSON
            )
        }
    }

    private static func signature(of pending: [Int: PendingToolCall]) -> String {
        pending.keys.sorted().map { idx in
            let entry = pending[idx]!
            return "\(idx)|\(entry.externalID)|\(entry.toolName)|\(entry.argumentsFingerprint.signatureComponent)"
        }.joined(separator: "||")
    }

    // MARK: - Headers / endpoints

    private func applyAuthenticationHeaders(to request: inout URLRequest) {
        // Anthropic does NOT accept `Authorization: Bearer`. The native
        // header is `x-api-key`, and `anthropic-version` is required
        // (server returns 400 otherwise).
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
    }

    private func messagesEndpoint(from baseURL: String) throws -> URL {
        try AgentNetworkSupport.endpoint(from: Self.stripTrailingV1(baseURL), suffix: "v1/messages")
    }

    private func modelsEndpoint(from baseURL: String) throws -> URL {
        try AgentNetworkSupport.endpoint(from: Self.stripTrailingV1(baseURL), suffix: "v1/models")
    }

    /// The current `claude` preset ships its base URL without `/v1`
    /// (the adapter appends `v1/messages` / `v1/models` itself, so the
    /// same field works for proxies that mount Anthropic at a custom
    /// prefix). Users carried over from earlier builds, though, still
    /// have `https://api.anthropic.com/v1` saved — concatenating that
    /// against `v1/messages` would produce a doubled `/v1/v1/messages`
    /// 404. Trim a trailing `/v1` (or `/v1/`) defensively so legacy
    /// entries keep working without manual editing in Settings.
    nonisolated private static func stripTrailingV1(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        if trimmed.hasSuffix("/v1") {
            return String(trimmed.dropLast(3))
        }
        return trimmed
    }

    // MARK: - Request body encoding

    /// Translate the chat history + tool descriptors into the
    /// Anthropic Messages wire format. Three reshapes happen here:
    ///
    ///   1. Every `role: system` message bubbles up into the top-level
    ///      `system` field as a cacheable text block.
    ///   2. `role: tool` results get re-attached as a `tool_result`
    ///      block on the FOLLOWING `role: user` message. If there's no
    ///      following user message we synthesize one — leaving an
    ///      orphan tool_result would be rejected at the API.
    ///   3. Assistant messages with `toolCalls[]` become a content
    ///      array with an optional leading `text` block plus one
    ///      `tool_use` block per call.
    ///
    /// Input is expected to have already been through
    /// `AgentClient.providerReadyMessages(...)` which folds tool
    /// replies to their parent assistant turn and drops orphans.
    nonisolated static func encodeRequestBody(
        model: String,
        messages: [AgentMessage],
        tools: [AgentToolDescriptor],
        supportsImages: Bool
    ) throws -> Data {
        var systemBlobs: [String] = []
        var anthropicMessages: [[String: Any]] = []

        // Two-pass: first collect system text into a side buffer, then
        // walk the rest building up user/assistant messages while
        // capturing tool replies to splice onto the next user turn.
        var pendingToolResults: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                // Local-only transcript markers (model-changed, auto-Plan
                // notice, …) ride as `.system` for rendering but must never
                // enter the model's system prompt.
                if message.isLocalTranscriptEvent { continue }
                let content = message.modelContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { systemBlobs.append(content) }

            case .tool:
                // Buffer for the next user message. (Inputs from
                // providerReadyMessages already guarantee tool
                // replies come AFTER the assistant message that
                // requested them and BEFORE the next user turn —
                // see OpenAIChatAdapter.providerReadyMessages.)
                guard let id = message.toolCallID, !id.isEmpty else { continue }
                // A tool_result's `content` may be a plain string OR an
                // array of blocks (text + image). Attach images inline so
                // vision-capable models see tool-produced screenshots
                // directly; text-only models never reach this branch
                // because `supportsImages` is false there.
                let imageBlocks: [[String: Any]]
                if supportsImages {
                    imageBlocks = message.images.compactMap { imageBlock(from: $0) }
                } else {
                    imageBlocks = []
                }
                if imageBlocks.isEmpty {
                    pendingToolResults.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": message.modelContent
                    ])
                } else {
                    var blocks: [[String: Any]] = []
                    let text = message.modelContent
                    if !text.isEmpty {
                        blocks.append(["type": "text", "text": text])
                    }
                    blocks.append(contentsOf: imageBlocks)
                    pendingToolResults.append([
                        "type": "tool_result",
                        "tool_use_id": id,
                        "content": blocks
                    ])
                }

            case .user:
                var content: [[String: Any]] = pendingToolResults
                pendingToolResults.removeAll()

                let text = message.modelContent
                if !text.isEmpty {
                    content.append(["type": "text", "text": text])
                }
                if supportsImages {
                    for image in message.images {
                        if let block = imageBlock(from: image) {
                            content.append(block)
                        }
                    }
                }
                // Anthropic rejects an empty content array. If we
                // somehow get here with nothing — e.g. an image-only
                // turn on a text-only model that already had its
                // images stripped — fall back to an explicit empty
                // string so the request still validates.
                if content.isEmpty {
                    content.append(["type": "text", "text": ""])
                }
                anthropicMessages.append([
                    "role": "user",
                    "content": content
                ])

            case .assistant:
                var content: [[String: Any]] = []
                let text = message.modelContent
                if !text.isEmpty {
                    content.append(["type": "text", "text": text])
                }
                for call in message.toolCalls {
                    // input_schema came back as a JSON string from the
                    // model; re-parse so we can embed it as a proper
                    // object. Best-effort: if parsing fails (mid-stream
                    // snapshot, model emitted invalid JSON), fall back
                    // to an empty input — better than failing the whole
                    // request and forcing the user to manually delete
                    // the broken turn.
                    let input: Any
                    if let data = call.argumentsJSON.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data, options: []) {
                        input = parsed
                    } else {
                        input = [String: Any]()
                    }
                    content.append([
                        "type": "tool_use",
                        "id": call.externalID,
                        "name": call.toolName,
                        "input": input
                    ])
                }
                guard !content.isEmpty else { continue }
                anthropicMessages.append([
                    "role": "assistant",
                    "content": content
                ])

            case .workflowReport, .widget, .scheduledTask:
                // Workflow / widget / scheduled-task card 不发给模型，跳过。
                continue
            }
        }

        // If we ran out of input messages with un-spliced tool results
        // (no following user turn), tack them onto a synthetic
        // continuation so Anthropic accepts the conversation. This
        // mirrors what `providerReadyMessages` does on the OpenAI
        // side when a tool reply has no parent.
        if !pendingToolResults.isEmpty {
            anthropicMessages.append([
                "role": "user",
                "content": pendingToolResults
            ])
        }

        // Anthropic prompt caching is explicit. Preserve one breakpoint at
        // the end of stable history (immediately before the latest user turn)
        // and another at the request tail. Together with the system breakpoint
        // below this stays within the API's four-breakpoint limit and lets a
        // changing per-turn reminder avoid invalidating older conversation.
        var messageBreakpointIndices: Set<Int> = []
        if let lastIndex = anthropicMessages.indices.last {
            messageBreakpointIndices.insert(lastIndex)
        }
        if let latestUserIndex = anthropicMessages.lastIndex(where: { message in
            message["role"] as? String == "user"
        }), latestUserIndex > anthropicMessages.startIndex {
            messageBreakpointIndices.insert(anthropicMessages.index(before: latestUserIndex))
        }
        for index in messageBreakpointIndices {
            addEphemeralCacheControl(to: &anthropicMessages[index])
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxOutputTokens(forModel: model),
            "stream": true,
            "messages": anthropicMessages
        ]
        if !systemBlobs.isEmpty {
            body["system"] = [[
                "type": "text",
                "text": systemBlobs.joined(separator: "\n\n"),
                "cache_control": ["type": "ephemeral"]
            ]]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map(encodeTool)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    nonisolated private static func addEphemeralCacheControl(to message: inout [String: Any]) {
        guard var content = message["content"] as? [[String: Any]],
              let lastIndex = content.indices.last else {
            return
        }
        content[lastIndex]["cache_control"] = ["type": "ephemeral"]
        message["content"] = content
    }

    nonisolated private static func imageBlock(from image: AgentImageAttachment) -> [String: Any]? {
        // Two valid source shapes on Anthropic: `base64` (we already
        // hold the data URL inline) and `url` (only Claude 3.5+ on
        // some endpoints). Parse the data URL we already produce for
        // OpenAI and convert to the base64 shape — works everywhere.
        let dataURL = image.dataURL
        guard dataURL.hasPrefix("data:") else { return nil }
        guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[..<commaIndex]
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        // header looks like `data:image/png;base64`
        let mediaType: String
        if let slashIdx = header.firstIndex(of: ":"),
           let semiIdx = header.firstIndex(of: ";") {
            mediaType = String(header[header.index(after: slashIdx)..<semiIdx])
        } else {
            mediaType = "image/png"
        }
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
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

        var inputSchema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            inputSchema["required"] = required
        }

        // Anthropic's tool shape — note no `{type: function, function: {...}}`
        // wrapper; `name` / `description` / `input_schema` sit at the top.
        return [
            "name": descriptor.name,
            "description": descriptor.description,
            "input_schema": inputSchema
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

// MARK: - Anthropic-shaped wire format

/// `event: message_start` — initial metadata block. Carries the initial
/// `usage.input_tokens` so we can stamp final usage even though the
/// completion side comes through `message_delta`.
private struct MessageStartEvent: Decodable {
    let message: MessageMeta

    struct MessageMeta: Decodable {
        let usage: UsageMeta?
    }
    struct UsageMeta: Decodable {
        let input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
}

/// `event: content_block_start` — start of a text / tool_use / etc
/// block. We only care about `tool_use` (to capture id+name before
/// the JSON deltas arrive). Text blocks just open a stream of
/// `text_delta` events.
private struct ContentBlockStartEvent: Decodable {
    let index: Int
    let content_block: Block

    struct Block: Decodable {
        let type: String
        let id: String?
        let name: String?
    }
}

/// `event: content_block_delta` — text fragment or partial tool input
/// JSON. The `delta.type` discriminator picks which.
private struct ContentBlockDeltaEvent: Decodable {
    let index: Int
    let delta: Delta

    struct Delta: Decodable {
        let type: String
        let text: String?
        let partial_json: String?
        let thinking: String?
    }
}

/// `event: message_delta` — final stop_reason + usage.output_tokens.
private struct MessageDeltaEvent: Decodable {
    let delta: Delta
    let usage: Usage?

    struct Delta: Decodable {
        let stop_reason: String?
        let stop_sequence: String?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
    }
}

/// `event: error` — server bailed mid-stream after the headers were
/// already flushed. Anthropic shape: `{ type: "error", error: { type,
/// message } }`.
private struct ErrorEvent: Decodable {
    let error: ErrorDetail?

    struct ErrorDetail: Decodable {
        let type: String?
        let message: String?
    }
}

/// Non-streaming /v1/messages response shape, used only by the
/// command-safety classifier.
private struct NonStreamMessage: Decodable {
    let content: [Block]

    struct Block: Decodable {
        let type: String
        let text: String?
    }
}

/// `GET /v1/models` response — Anthropic returns the same `{data: [{id}]}`
/// shape as OpenAI, so the parser is identical in spirit.
private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}
