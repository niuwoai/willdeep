//
//  AgentToolResultImageEncodingTests.swift
//  XeditTests
//
//  Locks tool-result screenshots into each provider's legal multimodal
//  history shape while preserving parallel tool-call/output ordering.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentToolResultImageEncodingTests {
    @Test
    func gptModelsUseChatCompletionsForOpenAICompatibleInference() throws {
        let gptFamilyModels = [
            "gpt-4.1",
            "gpt-5",
            "gpt-5.4",
            "gpt-5.5",
            "gpt5.5",
            "gpt-5.6-sol",
            "chatgpt-4o-latest",
            "openai/gpt-5.4-codex",
            "vendor/GPT-5.6-sol"
        ]
        let explicitResponsesConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.customID,
            baseURL: "https://example.com/v1",
            model: "gpt-5.6-luna",
            apiKey: "test",
            customKindOverride: .openAIResponses
        ).normalized
        let nativeAnthropicConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.customID,
            baseURL: "https://example.com",
            model: "gpt-5-compatible-alias",
            apiKey: "test",
            customKindOverride: .anthropicMessages
        ).normalized

        for model in gptFamilyModels {
            let configuration = AgentConfiguration(
                providerID: AgentProviderPreset.openAIID,
                baseURL: "https://api.openai.com/v1",
                model: model,
                apiKey: "test"
            ).normalized
            #expect(configuration.inferenceProviderKind == .openAIChat)
            #expect(AgentConfiguration.isGPTFamilyModel(model))
        }
        #expect(explicitResponsesConfiguration.inferenceProviderKind == .openAIChat)
        #expect(nativeAnthropicConfiguration.inferenceProviderKind == .anthropicMessages)
        #expect(!AgentConfiguration.isGPTFamilyModel("deepseek-v4-flash"))

        let chatRequest = try OpenAIChatAdapter.encodeChatRequest(
            model: "gpt-5.6-luna",
            messages: [AgentMessage(role: .user, content: "Hello")],
            tools: []
        )
        let chatBody = try #require(
            JSONSerialization.jsonObject(with: chatRequest) as? [String: Any]
        )
        #expect(chatBody["model"] as? String == "gpt-5.6-luna")
        #expect(chatBody["store"] == nil)
    }

    @Test
    func deepSeekV4UsesResponsesOnlyOnSupportedProviders() {
        let directFlash = AgentConfiguration(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKey: "test"
        ).normalized
        let gatewayFlash = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            model: "deepseek-v4-flash",
            apiKey: "test"
        ).normalized
        let directPro = AgentConfiguration(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-pro",
            apiKey: "test"
        ).normalized
        let gatewayPro = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            model: "deepseek-v4-pro",
            apiKey: "test"
        ).normalized
        let someIMDeepSeekAliases = [
            "someim-judge",
            SomeIMManagedModel.securityGuard,
            "someim-auto-flash",
            "someim-auto-pro",
            "someim-code-low",
            "someim-code-high",
            "someim-coding-plan",
            "someim-coding-plan-low",
            "someim-coding-plan-high"
        ]
        // Premium aliases resolve to non-DeepSeek backends and stay on Chat.
        let nonDeepSeekSomeIMModels = [
            "someim-coding-plan-premium",
            "someim-code-premium",
            "someim-auto-premium"
        ]

        #expect(directFlash.inferenceProviderKind == .openAIResponses)
        #expect(directFlash.usesStatelessDeepSeekResponses)
        #expect(gatewayFlash.inferenceProviderKind == .openAIResponses)
        #expect(gatewayFlash.usesWillDeepGatewayResponsesState)
        #expect(directPro.inferenceProviderKind == .openAIResponses)
        #expect(directPro.usesStatelessDeepSeekResponses)
        #expect(gatewayPro.inferenceProviderKind == .openAIResponses)
        #expect(gatewayPro.usesWillDeepGatewayResponsesState)

        for model in someIMDeepSeekAliases {
            let configuration = AgentConfiguration(
                providerID: AgentProviderPreset.someIMID,
                baseURL: "https://some.im/v1",
                model: model,
                apiKey: "test"
            ).normalized
            #expect(configuration.inferenceProviderKind == .openAIResponses)
            #expect(configuration.usesWillDeepGatewayResponsesState)
            #expect(
                configuration.usesServerManagedSafetyJudge
                    == (model == SomeIMManagedModel.securityGuard)
            )

            let customConfiguration = AgentConfiguration(
                providerID: AgentProviderPreset.customID,
                baseURL: "https://example.com/v1",
                model: model,
                apiKey: "test"
            ).normalized
            #expect(customConfiguration.inferenceProviderKind == .openAIChat)
            #expect(!customConfiguration.isDeepSeekV4ResponsesModel)
        }

        for model in nonDeepSeekSomeIMModels {
            let configuration = AgentConfiguration(
                providerID: AgentProviderPreset.someIMID,
                baseURL: "https://some.im/v1",
                model: model,
                apiKey: "test"
            ).normalized
            #expect(configuration.inferenceProviderKind == .openAIChat)
            #expect(!configuration.usesWillDeepGatewayResponsesState)
        }
    }

    @Test
    @MainActor
    func someIMRouteJudgeUsesResponsesRequestShape() async throws {
        let recorder = WillDeepResponsesFallbackRecorder()
        let stub = managedJudgeTestSession()
        defer { stub.tearDown() }
        stub.install { request in
            _ = recorder.record(request)
            let url = try #require(request.url)
            return try willDeepResponsesHTTPResult(
                url: url,
                statusCode: 200,
                body: #"{"id":"resp_judge","output":[{"type":"message","content":[{"type":"output_text","text":"{\"domain\":\"coding\"}"}]}]}"#
            )
        }

        let configuration = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            model: SomeIMManagedModel.autoPro,
            apiKey: "test"
        )
        let response = await AgentClient(
            configuration: configuration,
            session: stub.session,
            someIMContext: SomeIMRequestContext(
                sessionID: "managed-session",
                workspaceID: "managed-workspace"
            )
        ).routeJudge(
            model: SomeIMManagedModel.judge,
            systemPrompt: "Return strict JSON.",
            userPayload: "Classify this request.",
            maxTokens: 256
        )

        #expect(response == #"{"domain":"coding"}"#)
        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.path == "/v1/responses")
        #expect(request.sessionID == "managed-session")
        let bodyData = try #require(request.body.data(using: .utf8))
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == SomeIMManagedModel.judge)
        #expect(body["instructions"] as? String == "Return strict JSON.")
        #expect(body["max_output_tokens"] as? Int == 256)
        #expect(body["stream"] as? Bool == false)
        #expect(body["store"] as? Bool == false)
        #expect(body["messages"] == nil)
    }

    @Test
    @MainActor
    func someIMSecurityGuardSendsOnlyUserMessage() async throws {
        let recorder = WillDeepResponsesFallbackRecorder()
        let stub = managedJudgeTestSession()
        defer { stub.tearDown() }
        stub.install { request in
            _ = recorder.record(request)
            let url = try #require(request.url)
            return try willDeepResponsesHTTPResult(
                url: url,
                statusCode: 200,
                body: #"{"id":"resp_guard","output":[{"type":"message","content":[{"type":"output_text","text":"<verdict>YES</verdict>"}]}]}"#
            )
        }

        let configuration = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            model: SomeIMManagedModel.securityGuard,
            apiKey: "test"
        )
        let result = await AgentClient(
            configuration: configuration,
            session: stub.session
        ).judgeCommandSafety(
            command: "yarn test",
            historyContext: "THIS HISTORY MUST NOT BE SENT",
            toolName: "run_command",
            taskContext: "Run the project's test suite"
        )

        #expect(result == .allow)
        let request = try #require(recorder.requests.first)
        #expect(request.path == "/v1/responses")
        let bodyData = try #require(request.body.data(using: .utf8))
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == SomeIMManagedModel.securityGuard)
        #expect(body["instructions"] == nil)
        #expect(body["messages"] == nil)
        #expect(request.body.contains("yarn test"))
        #expect(request.body.contains("run_command"))
        #expect(request.body.contains("Run the project's test suite"))
        #expect(!request.body.contains("THIS HISTORY MUST NOT BE SENT"))
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
    }

    @Test
    func openAIResponsesUsesPreviousResponseForStrictlyAppendedToolOutput() throws {
        let state = OpenAIResponsesContinuationState()
        let initialMessages = [
            AgentMessage(role: .system, content: "You are a coding agent."),
            AgentMessage(role: .user, content: "Inspect the project.")
        ]
        let initialBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: initialMessages,
            tools: [],
            supportsImages: true
        )
        let initialRequest = try state.prepare(fullBody: initialBody)
        #expect(!initialRequest.usesPreviousResponse)
        state.commit(responseID: "resp_first", preparedRequest: initialRequest)

        let appendedMessages = initialMessages + [
            AgentMessage(
                role: .assistant,
                content: "",
                reasoningContent: "Inspecting the repository.",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_read",
                        toolName: "read_file",
                        argumentsJSON: #"{"path":"README.md"}"#
                    )
                ]
            ),
            AgentMessage(
                role: .tool,
                content: "Project readme",
                toolCallID: "call_read"
            )
        ]
        let appendedBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: appendedMessages,
            tools: [],
            supportsImages: true
        )
        let continuedRequest = try state.prepare(fullBody: appendedBody)
        let continuedObject = try toolResultImageJSONObject(continuedRequest.body)
        let deltaInput = try #require(continuedObject["input"] as? [[String: Any]])

        #expect(continuedRequest.usesPreviousResponse)
        #expect(continuedObject["previous_response_id"] as? String == "resp_first")
        #expect(continuedObject["store"] as? Bool == true)
        #expect(deltaInput.count == 1)
        #expect(deltaInput[0]["type"] as? String == "function_call_output")
        #expect(deltaInput[0]["call_id"] as? String == "call_read")
    }

    @Test
    func openAIResponsesRestoresCursorAndSendsOnlyNewUserInput() throws {
        let state = OpenAIResponsesContinuationState()
        let initialMessages = [
            AgentMessage(role: .system, content: "You are a coding agent."),
            AgentMessage(role: .user, content: "Inspect the project.")
        ]
        let initialBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: initialMessages,
            tools: [],
            supportsImages: true
        )
        let initialRequest = try state.prepare(fullBody: initialBody)
        state.commit(responseID: "resp_first", preparedRequest: initialRequest)

        let persistedSession = AgentSession(
            openAIResponsesContinuation: try #require(state.persistedSnapshot)
        )
        let persistedData = try JSONEncoder().encode(persistedSession)
        let restoredSession = try JSONDecoder().decode(AgentSession.self, from: persistedData)
        let restoredState = OpenAIResponsesContinuationState(
            persistedSnapshot: restoredSession.openAIResponsesContinuation
        )

        // Recreate the earlier messages with fresh UUIDs/timestamps, as happens
        // when the app rebuilds its system message after a restart.
        let replayedMessages = [
            AgentMessage(role: .system, content: "You are a coding agent."),
            AgentMessage(role: .user, content: "Inspect the project.")
        ]
        let appendedMessages = replayedMessages + [
            AgentMessage(
                role: .assistant,
                content: "The project uses Swift.",
                reasoningContent: "Reviewing the project files."
            ),
            AgentMessage(role: .user, content: "Now inspect its tests.")
        ]
        let appendedBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: appendedMessages,
            tools: [],
            supportsImages: true
        )
        let continuedRequest = try restoredState.prepare(fullBody: appendedBody)
        let continuedObject = try toolResultImageJSONObject(continuedRequest.body)
        let deltaInput = try #require(continuedObject["input"] as? [[String: Any]])
        let userContent = try #require(deltaInput.first?["content"] as? [[String: Any]])

        #expect(continuedRequest.usesPreviousResponse)
        #expect(continuedObject["previous_response_id"] as? String == "resp_first")
        #expect(deltaInput.count == 1)
        #expect(deltaInput[0]["role"] as? String == "user")
        #expect(userContent.first?["text"] as? String == "Now inspect its tests.")
    }

    @Test
    func openAIResponsesFallsBackWhenContextOrTransportChanges() throws {
        let state = OpenAIResponsesContinuationState()
        let initialMessages = [
            AgentMessage(role: .system, content: "Original instructions"),
            AgentMessage(role: .user, content: "First question")
        ]
        let initialBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: initialMessages,
            tools: [],
            supportsImages: true
        )
        let initialRequest = try state.prepare(
            fullBody: initialBody,
            transportIdentity: "relay-a"
        )
        state.commit(responseID: "resp_first", preparedRequest: initialRequest)

        let stableAppendedMessages = initialMessages + [
            AgentMessage(role: .assistant, content: "First answer"),
            AgentMessage(role: .user, content: "Follow-up")
        ]
        let stableAppendedBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: stableAppendedMessages,
            tools: [],
            supportsImages: true
        )
        let transportFallbackRequest = try state.prepare(
            fullBody: stableAppendedBody,
            transportIdentity: "relay-b"
        )
        let transportFallbackObject = try toolResultImageJSONObject(
            transportFallbackRequest.body
        )

        let changedMessages = [
            AgentMessage(role: .system, content: "Changed instructions"),
            initialMessages[1],
            AgentMessage(role: .assistant, content: "First answer"),
            AgentMessage(role: .user, content: "Follow-up")
        ]
        let changedBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-5",
            messages: changedMessages,
            tools: [],
            supportsImages: true
        )
        let fallbackRequest = try state.prepare(
            fullBody: changedBody,
            transportIdentity: "relay-a"
        )
        let fallbackObject = try toolResultImageJSONObject(fallbackRequest.body)
        let fullInput = try #require(fallbackObject["input"] as? [[String: Any]])

        #expect(!transportFallbackRequest.usesPreviousResponse)
        #expect(transportFallbackObject["previous_response_id"] == nil)
        #expect(!fallbackRequest.usesPreviousResponse)
        #expect(fallbackObject["previous_response_id"] == nil)
        #expect(fullInput.count == 3)
    }

    @Test
    func willDeepGatewayResponsesStopsUsingCursorBeforeServerExpiry() throws {
        let state = OpenAIResponsesContinuationState()
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        let initialMessages = [
            AgentMessage(role: .user, content: "First question")
        ]
        let initialBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "deepseek-v4-flash",
            messages: initialMessages,
            tools: [],
            supportsImages: false,
            store: false
        )
        let initialRequest = try state.prepare(
            fullBody: initialBody,
            maximumContinuationAge: OpenAIResponsesAdapter.willDeepGatewayContinuationMaxAge,
            now: epoch
        )
        state.commit(responseID: "resp_first", preparedRequest: initialRequest)
        let persistedData = try JSONEncoder().encode(AgentSession(
            openAIResponsesContinuation: try #require(state.persistedSnapshot)
        ))
        let restoredSession = try JSONDecoder().decode(AgentSession.self, from: persistedData)
        let restoredState = OpenAIResponsesContinuationState(
            persistedSnapshot: restoredSession.openAIResponsesContinuation
        )

        let appendedMessages = initialMessages + [
            AgentMessage(role: .assistant, content: "First answer"),
            AgentMessage(role: .user, content: "Follow-up")
        ]
        let appendedBody = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "deepseek-v4-flash",
            messages: appendedMessages,
            tools: [],
            supportsImages: false,
            store: false
        )
        let withinWindow = try restoredState.prepare(
            fullBody: appendedBody,
            maximumContinuationAge: OpenAIResponsesAdapter.willDeepGatewayContinuationMaxAge,
            now: epoch.addingTimeInterval(22 * 60 * 60)
        )
        let atSafetyBoundary = try restoredState.prepare(
            fullBody: appendedBody,
            maximumContinuationAge: OpenAIResponsesAdapter.willDeepGatewayContinuationMaxAge,
            now: epoch.addingTimeInterval(23 * 60 * 60)
        )

        #expect(withinWindow.usesPreviousResponse)
        #expect(!atSafetyBoundary.usesPreviousResponse)
        let fullObject = try toolResultImageJSONObject(atSafetyBoundary.body)
        #expect(fullObject["previous_response_id"] == nil)
        #expect((fullObject["input"] as? [[String: Any]])?.count == 3)
    }

    @Test
    func deepSeekResponsesFullHistoryIncludesReasoningAndDisablesStore() throws {
        let data = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "deepseek-v4-flash",
            messages: [
                AgentMessage(role: .user, content: "Question"),
                AgentMessage(
                    role: .assistant,
                    content: "Answer",
                    reasoningContent: "Private chain"
                )
            ],
            tools: [],
            supportsImages: false,
            store: false
        )
        let body = try toolResultImageJSONObject(data)
        let input = try #require(body["input"] as? [[String: Any]])

        #expect(body["store"] as? Bool == false)
        #expect(input.compactMap { $0["type"] as? String } == [
            "message", "reasoning", "message"
        ])
        let reasoningContent = try #require(input[1]["content"] as? [[String: Any]])
        #expect(reasoningContent.count == 1)
        #expect(reasoningContent[0]["type"] as? String == "reasoning_text")
        #expect(reasoningContent[0]["text"] as? String == "Private chain")
    }

    @Test
    func deepSeekResponsesEncodesWebSearchAsHostedToolOnlyWhenRequested() throws {
        let webSearch = try #require(AgentToolRegistry.descriptor(for: "web_search"))
        let searchFiles = try #require(AgentToolRegistry.descriptor(for: "search_files"))
        let data = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "deepseek-v4-flash",
            messages: [AgentMessage(role: .user, content: "Search current news")],
            tools: [webSearch, searchFiles],
            supportsImages: false,
            store: false,
            useHostedWebSearch: true
        )
        let body = try toolResultImageJSONObject(data)
        let tools = try #require(body["tools"] as? [[String: Any]])

        #expect(tools.count == 2)
        #expect(tools[0]["type"] as? String == "web_search")
        #expect(tools[0]["name"] == nil)
        #expect(tools[1]["type"] as? String == "function")
        #expect(tools[1]["name"] as? String == "search_files")
    }

    @Test
    func deepSeekHostedWebSearchFallsBackLocallyAndPreservesCitations() async throws {
        let configuration = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://example.com/v1",
            model: "deepseek-v4-flash",
            apiKey: "test"
        )
        let webSearch = try #require(AgentToolRegistry.descriptor(for: "web_search"))
        let requestRecorder = WillDeepResponsesFallbackRecorder()
        let eventRecorder = HostedSearchEventRecorder()
        let stub = hostedSearchTestSession()
        defer { stub.tearDown() }

        stub.install { request in
            let attempt = requestRecorder.record(request)
            let url = try #require(request.url)
            if attempt == 1 {
                return try willDeepResponsesHTTPResult(
                    url: url,
                    statusCode: 422,
                    body: #"{"error":{"message":"unsupported web_search tool"}}"#
                )
            }
            let body = """
            event: response.created
            data: {"response":{"id":"resp_search"}}

            event: response.output_text.delta
            data: {"delta":"answer"}

            event: response.output_text.annotation.added
            data: {"annotation":{"type":"url_citation","url":"https://example.org/source","title":"Example source"}}

            event: response.completed
            data: {"response":{"id":"resp_search","status":"completed","output":[]}}

            """
            return try willDeepResponsesHTTPResult(
                url: url,
                statusCode: 200,
                body: body,
                headers: ["Content-Type": "text/event-stream"]
            )
        }

        let adapter = OpenAIResponsesAdapter(
            configuration: configuration,
            session: stub.session,
            someIMContext: SomeIMRequestContext(sessionID: "hosted-search")
        )
        try await adapter.streamChat(
            messages: [AgentMessage(role: .user, content: "Search current news")],
            tools: [webSearch]
        ) { event in
            await eventRecorder.record(event)
        }

        let requests = requestRecorder.requests
        try #require(requests.count == 2)
        #expect(requests[0].body.contains(#""type":"web_search""#))
        #expect(!requests[0].body.contains(#""name":"web_search""#))
        #expect(requests[1].body.contains(#""type":"function""#))
        #expect(requests[1].body.contains(#""name":"web_search""#))
        let references = await eventRecorder.references
        #expect(references == [
            AgentSourceReference(
                title: "Example source",
                url: "https://example.org/source",
                toolName: "web_search"
            )
        ])
    }

    @Test
    func willDeepGatewayStateFailuresFallBackWithoutDuplicatingOutput() async throws {
        let stateProtocol = AgentNetworkSupport.willDeepResponsesStateProtocol
        let configuration = AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://example.com/v1",
            model: "deepseek-v4-flash",
            apiKey: "test"
        )
        // A request-time 503 is safe to replay immediately because no output
        // has reached the user. Retry once with full history and no state opt-in.
        do {
            let recorder = WillDeepResponsesFallbackRecorder()
            let stub = willDeepResponsesTestSession()
            defer { stub.tearDown() }
            let continuationState = OpenAIResponsesContinuationState()
            stub.install { request in
                let attempt = recorder.record(request)
                let url = try #require(request.url)
                if attempt == 1 {
                    return try willDeepResponsesHTTPResult(
                        url: url,
                        statusCode: 503,
                        body: #"{"error":{"code":"state_backend_unavailable","message":"Responses state unavailable"}}"#
                    )
                }
                return try willDeepResponsesSSE(
                    url: url,
                    responseID: "resp_full",
                    stateActive: false
                )
            }

            let adapter = OpenAIResponsesAdapter(
                configuration: configuration,
                session: stub.session,
                continuationState: continuationState,
                someIMContext: SomeIMRequestContext(sessionID: "session-503")
            )
            try await adapter.streamChat(
                messages: [AgentMessage(role: .user, content: "Keep all history")]
            ) { _ in }

            let requests = recorder.requests
            #expect(requests.count == 2)
            #expect(requests[0].stateHeader == stateProtocol)
            #expect(requests[0].sessionID == "session-503")
            #expect(requests[0].userAgent?.hasPrefix("some.im/WillDeep-") == true)
            #expect(requests[0].path == "/v1/responses")
            #expect(requests[1].stateHeader == nil)
            #expect(requests.allSatisfy { !$0.body.contains("previous_response_id") })
            #expect(continuationState.persistedSnapshot == nil)
        }

        // A 410 proves the cursor is gone. Older nodes may report the same
        // condition as 422 response_affinity_not_found; both must keep state
        // opt-in enabled, resend full history, and establish a fresh epoch.
        let cursorRecoveryErrors = [
            (
                statusCode: 410,
                body: #"{"error":{"code":"previous_response_expired","message":"previous_response_id expired"}}"#
            ),
            (
                statusCode: 422,
                body: #"{"error":{"code":"response_affinity_not_found","message":"response affinity not found"}}"#
            )
        ]
        for recoveryError in cursorRecoveryErrors {
            let recorder = WillDeepResponsesFallbackRecorder()
            let stub = willDeepResponsesTestSession()
            defer { stub.tearDown() }
            let continuationState = OpenAIResponsesContinuationState()
            stub.install { request in
                let attempt = recorder.record(request)
                let url = try #require(request.url)
                if attempt == 2 {
                    return try willDeepResponsesHTTPResult(
                        url: url,
                        statusCode: recoveryError.statusCode,
                        body: recoveryError.body
                    )
                }
                return try willDeepResponsesSSE(
                    url: url,
                    responseID: attempt == 1 ? "resp_first" : "resp_recovered",
                    stateActive: true
                )
            }
            let adapter = OpenAIResponsesAdapter(
                configuration: configuration,
                session: stub.session,
                continuationState: continuationState,
                someIMContext: SomeIMRequestContext(
                    sessionID: "session-\(recoveryError.statusCode)"
                )
            )
            let firstMessages = [AgentMessage(role: .user, content: "First question")]
            try await adapter.streamChat(messages: firstMessages) { _ in }
            let appendedMessages = firstMessages + [
                AgentMessage(role: .assistant, content: "First answer"),
                AgentMessage(role: .user, content: "Follow-up")
            ]
            try await adapter.streamChat(messages: appendedMessages) { _ in }

            let requests = recorder.requests
            #expect(requests.count == 3)
            #expect(!requests[0].body.contains("previous_response_id"))
            #expect(requests[1].body.contains(#""previous_response_id":"resp_first""#))
            #expect(!requests[2].body.contains("previous_response_id"))
            #expect(requests[2].body.contains("First question"))
            #expect(requests[2].body.contains("First answer"))
            #expect(requests[2].body.contains("Follow-up"))
            #expect(requests.allSatisfy {
                $0.stateHeader == stateProtocol
            })
            #expect(continuationState.persistedSnapshot?.responseID == "resp_recovered")
        }

        // Once deltas are visible, replay would duplicate text. A terminal
        // state_unavailable marker therefore preserves this answer but drops
        // its cursor so the next user turn starts from complete local history.
        do {
            let recorder = WillDeepResponsesFallbackRecorder()
            let stub = willDeepResponsesTestSession()
            defer { stub.tearDown() }
            let continuationState = OpenAIResponsesContinuationState()
            stub.install { request in
                _ = recorder.record(request)
                let url = try #require(request.url)
                return try willDeepResponsesSSE(
                    url: url,
                    responseID: "resp_unstored",
                    stateActive: true,
                    stateUnavailableBeforeTerminal: true
                )
            }
            let adapter = OpenAIResponsesAdapter(
                configuration: configuration,
                session: stub.session,
                continuationState: continuationState,
                someIMContext: SomeIMRequestContext(sessionID: "session-stream-loss")
            )
            try await adapter.streamChat(
                messages: [AgentMessage(role: .user, content: "Do not duplicate this")]
            ) { _ in }

            #expect(recorder.requests.count == 1)
            #expect(continuationState.persistedSnapshot == nil)
        }
    }

    @Test
    func openAIChatPlacesToolImagesAfterCompleteToolOutputGroup() throws {
        let data = try OpenAIChatAdapter.encodeChatRequest(
            model: "gpt-4.1",
            messages: toolResultImageTranscript(),
            tools: [],
            supportsImages: true
        )
        let body = try toolResultImageJSONObject(data)
        let messages = try #require(body["messages"] as? [[String: Any]])

        #expect(messages.compactMap { $0["role"] as? String } == [
            "assistant", "tool", "tool", "user"
        ])
        #expect(messages[1]["content"] as? String == "first result")
        #expect(messages[2]["content"] as? String == "second result")
        #expect(messages[1]["tool_call_id"] as? String == "call_first")
        #expect(messages[2]["tool_call_id"] as? String == "call_second")

        let visualParts = try #require(messages[3]["content"] as? [[String: Any]])
        #expect(visualParts.compactMap { $0["type"] as? String } == [
            "text", "image_url", "text", "image_url"
        ])
        #expect(toolResultImageURL(fromChatPart: visualParts[1]) == firstToolImage.dataURL)
        #expect(toolResultImageURL(fromChatPart: visualParts[3]) == secondToolImage.dataURL)
    }

    @Test
    func openAIChatOmitsToolImagesForTextOnlyModels() throws {
        let data = try OpenAIChatAdapter.encodeChatRequest(
            model: "text-only",
            messages: toolResultImageTranscript(),
            tools: [],
            supportsImages: false
        )
        let body = try toolResultImageJSONObject(data)
        let messages = try #require(body["messages"] as? [[String: Any]])

        #expect(messages.compactMap { $0["role"] as? String } == [
            "assistant", "tool", "tool"
        ])
        #expect(!String(decoding: data, as: UTF8.self).contains("image_url"))
        #expect(!String(decoding: data, as: UTF8.self).contains(firstToolImage.dataBase64))
    }

    @Test
    func openAIResponsesKeepsImagesInMatchingFunctionCallOutputs() throws {
        let data = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "gpt-4.1",
            messages: toolResultImageTranscript(),
            tools: [],
            supportsImages: true
        )
        let body = try toolResultImageJSONObject(data)
        let input = try #require(body["input"] as? [[String: Any]])

        #expect(input.compactMap { $0["type"] as? String } == [
            "function_call",
            "function_call",
            "function_call_output",
            "function_call_output"
        ])
        #expect(input[0]["call_id"] as? String == "call_first")
        #expect(input[1]["call_id"] as? String == "call_second")
        #expect(input[2]["call_id"] as? String == "call_first")
        #expect(input[3]["call_id"] as? String == "call_second")
        let firstOutput = try #require(input[2]["output"] as? [[String: Any]])
        #expect(firstOutput.compactMap { $0["type"] as? String } == [
            "input_text", "input_image"
        ])
        #expect(firstOutput[0]["text"] as? String == "first result")
        #expect(firstOutput[1]["image_url"] as? String == firstToolImage.dataURL)

        let secondOutput = try #require(input[3]["output"] as? [[String: Any]])
        #expect(secondOutput.compactMap { $0["type"] as? String } == [
            "input_text", "input_image"
        ])
        #expect(secondOutput[0]["text"] as? String == "second result")
        #expect(secondOutput[1]["image_url"] as? String == secondToolImage.dataURL)
    }

    @Test
    func openAIResponsesOmitsToolImagesForTextOnlyModels() throws {
        let data = try OpenAIResponsesAdapter.encodeRequestBody(
            model: "text-only",
            messages: toolResultImageTranscript(),
            tools: [],
            supportsImages: false
        )
        let body = try toolResultImageJSONObject(data)
        let input = try #require(body["input"] as? [[String: Any]])

        #expect(input.compactMap { $0["type"] as? String } == [
            "function_call",
            "function_call",
            "function_call_output",
            "function_call_output"
        ])
        #expect(input[2]["output"] as? String == "first result")
        #expect(input[3]["output"] as? String == "second result")
        #expect(!String(decoding: data, as: UTF8.self).contains("input_image"))
        #expect(!String(decoding: data, as: UTF8.self).contains(firstToolImage.dataBase64))
    }

    @Test
    func geminiPlacesInlineDataAfterCompleteFunctionResponseGroup() throws {
        let transcript = toolResultImageTranscript()
        let data = try GeminiAdapter.encodeRequestBody(
            messages: transcript,
            tools: [],
            supportsImages: true,
            toolNameByID: GeminiAdapter.buildToolCallIDMap(from: transcript)
        )
        let body = try toolResultImageJSONObject(data)
        let contents = try #require(body["contents"] as? [[String: Any]])

        #expect(contents.compactMap { $0["role"] as? String } == ["model", "user"])

        let responseParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(responseParts.count == 6)
        #expect(toolResultFunctionResponseName(in: responseParts[0]) == "capture_first")
        #expect(toolResultFunctionResponseName(in: responseParts[1]) == "capture_second")
        #expect(responseParts[2]["text"] as? String == "Visual output from function capture_first:")
        #expect(toolResultInlineData(responseParts[3])?["mimeType"] as? String == "image/png")
        #expect(toolResultInlineData(responseParts[3])?["data"] as? String == firstToolImage.dataBase64)
        #expect(responseParts[4]["text"] as? String == "Visual output from function capture_second:")
        #expect(toolResultInlineData(responseParts[5])?["data"] as? String == secondToolImage.dataBase64)
        #expect(String(decoding: data, as: UTF8.self).contains("inline_data") == false)
    }

    @Test
    func geminiOmitsToolImagesForTextOnlyModels() throws {
        let transcript = toolResultImageTranscript()
        let data = try GeminiAdapter.encodeRequestBody(
            messages: transcript,
            tools: [],
            supportsImages: false,
            toolNameByID: GeminiAdapter.buildToolCallIDMap(from: transcript)
        )
        let body = try toolResultImageJSONObject(data)
        let contents = try #require(body["contents"] as? [[String: Any]])

        #expect(contents.compactMap { $0["role"] as? String } == ["model", "user"])
        let responseParts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect(responseParts.count == 2)
        #expect(toolResultFunctionResponseName(in: responseParts[0]) == "capture_first")
        #expect(toolResultFunctionResponseName(in: responseParts[1]) == "capture_second")
        #expect(!String(decoding: data, as: UTF8.self).contains("inlineData"))
        #expect(!String(decoding: data, as: UTF8.self).contains(firstToolImage.dataBase64))
    }

    @Test
    func providerHistoryKeepsFourRecentToolImageGroups() {
        var transcript: [AgentMessage] = []
        for index in 0..<5 {
            transcript.append(contentsOf: toolResultImageTranscript())
            transcript.append(
                AgentMessage(
                    role: .assistant,
                    content: "I inspected screenshot group \(index)."
                )
            )
        }
        transcript.append(
            AgentMessage(
                role: .user,
                content: "Continue",
                images: [firstToolImage]
            )
        )

        let prepared = AgentClient.providerReadyMessages(
            transcript,
            supportsImages: true
        )

        #expect(prepared.filter { $0.role == .tool }.map { $0.images.count } == [
            0, 0,
            1, 1,
            1, 1,
            1, 1,
            1, 1,
        ])
        #expect(prepared.last?.images.map(\.id) == [firstToolImage.id])

        let trailingPrepared = AgentClient.providerReadyMessages(
            toolResultImageTranscript(),
            supportsImages: true
        )
        #expect(
            trailingPrepared
                .filter { $0.role == .tool }
                .flatMap { $0.images }
                .map(\.id) == [firstToolImage.id, secondToolImage.id]
        )
    }
}

private final class WillDeepResponsesFallbackRecorder: @unchecked Sendable {
    struct RecordedRequest {
        let stateHeader: String?
        let sessionID: String?
        let userAgent: String?
        let path: String?
        let body: String
    }

    private let lock = NSLock()
    private var storage: [RecordedRequest] = []

    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            storage.append(RecordedRequest(
                stateHeader: request.value(
                    forHTTPHeaderField: AgentNetworkSupport.willDeepResponsesStateHeaderName
                ),
                sessionID: request.value(
                    forHTTPHeaderField: AgentNetworkSupport.willDeepSessionHeaderName
                ),
                userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                path: request.url?.path,
                body: Self.bodyString(from: request)
            ))
            return storage.count
        }
    }

    var requests: [RecordedRequest] {
        lock.withLock { storage }
    }

    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor HostedSearchEventRecorder {
    private(set) var references: [AgentSourceReference] = []

    func record(_ event: AgentClientEvent) {
        if case .sourceReferencesUpdated(let updated) = event {
            references = updated
        }
    }
}

/// Routes stubbed responses to the one test that installed them.
///
/// These stubs used to key off a single `static var handler` per protocol
/// class. Swift Testing runs a suite's tests concurrently, so two tests that
/// each installed a handler raced on that one slot: whichever assigned last
/// served *both* tests' requests, and whichever `defer` ran first tore the stub
/// out from under the other. That is how `someIMRouteJudgeUsesResponsesRequestShape`
/// came to receive the security guard's `<verdict>YES</verdict>` while its own
/// recorder stayed empty.
///
/// Handlers now live in a locked table keyed by a token that each stub session
/// carries in its own default headers, so concurrent tests cannot see — or
/// clear — each other's stubs.
private final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static let tokenHeader = "X-WillDeep-Stub-Token"

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var issuedTokens = 0

    static func makeToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        issuedTokens += 1
        return "stub-\(issuedTokens)"
    }

    static func install(_ handler: @escaping Handler, for token: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers[token] = handler
    }

    static func remove(for token: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers[token] = nil
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let token = request.value(forHTTPHeaderField: tokenHeader) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlers[token]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A missing token means the session was not built by `StubSession`, or
        // its handler was already removed. Failing loudly beats silently
        // serving another test's stub.
        guard let handler = Self.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A stubbed `URLSession` plus the token its handlers are registered under.
private final class StubSession {
    let session: URLSession
    private let token: String

    init() {
        let token = StubURLProtocol.makeToken()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.tokenHeader: token]
        self.token = token
        session = URLSession(configuration: configuration)
    }

    func install(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.install(handler, for: token)
    }

    func tearDown() {
        StubURLProtocol.remove(for: token)
        session.invalidateAndCancel()
    }
}

private func willDeepResponsesTestSession() -> StubSession {
    StubSession()
}

private func hostedSearchTestSession() -> StubSession {
    StubSession()
}

private func managedJudgeTestSession() -> StubSession {
    StubSession()
}

private func willDeepResponsesHTTPResult(
    url: URL,
    statusCode: Int,
    body: String,
    headers: [String: String] = ["Content-Type": "application/json"]
) throws -> (HTTPURLResponse, Data) {
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
    ))
    return (response, Data(body.utf8))
}

private func willDeepResponsesSSE(
    url: URL,
    responseID: String,
    stateActive: Bool,
    stateUnavailableBeforeTerminal: Bool = false
) throws -> (HTTPURLResponse, Data) {
    var headers = ["Content-Type": "text/event-stream"]
    if stateActive {
        headers[AgentNetworkSupport.willDeepResponsesStateHeaderName] = "v1; active"
    }
    let stateUnavailable = stateUnavailableBeforeTerminal ? """
    event: response.state_unavailable
    data: {"type":"response.state_unavailable","error":{"code":"state_backend_unavailable"}}

    """ : ""
    let body = """
    event: response.created
    data: {"response":{"id":"\(responseID)"}}

    event: response.output_text.delta
    data: {"delta":"ok"}

    \(stateUnavailable)event: response.completed
    data: {"response":{"id":"\(responseID)","status":"completed","output":[]}}

    """
    return try willDeepResponsesHTTPResult(
        url: url,
        statusCode: 200,
        body: body,
        headers: headers
    )
}

private let firstToolImage = AgentImageAttachment(
    mimeType: "image/png",
    dataBase64: Data("first-image".utf8).base64EncodedString()
)

private let secondToolImage = AgentImageAttachment(
    mimeType: "image/jpeg",
    dataBase64: Data("second-image".utf8).base64EncodedString()
)

private func toolResultImageTranscript() -> [AgentMessage] {
    [
        AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(
                    externalID: "call_first",
                    toolName: "capture_first",
                    argumentsJSON: "{}"
                ),
                AgentMessageToolCall(
                    externalID: "call_second",
                    toolName: "capture_second",
                    argumentsJSON: "{}"
                )
            ]
        ),
        AgentMessage(
            role: .tool,
            content: "first result",
            images: [firstToolImage],
            toolCallID: "call_first"
        ),
        AgentMessage(
            role: .tool,
            content: "second result",
            images: [secondToolImage],
            toolCallID: "call_second"
        )
    ]
}

private func toolResultImageJSONObject(_ data: Data) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: data, options: [])
    return try #require(value as? [String: Any])
}

private func toolResultImageURL(fromChatPart part: [String: Any]) -> String? {
    (part["image_url"] as? [String: Any])?["url"] as? String
}

private func toolResultFunctionResponseName(in part: [String: Any]) -> String? {
    guard let functionResponse = part["functionResponse"] as? [String: Any] else { return nil }
    return functionResponse["name"] as? String
}

private func toolResultInlineData(_ part: [String: Any]) -> [String: Any]? {
    part["inlineData"] as? [String: Any]
}
