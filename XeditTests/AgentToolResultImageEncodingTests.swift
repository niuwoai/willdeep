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
    func gpt5ModelsUseResponsesForOpenAICompatibleInference() {
        let gpt5FamilyModels = [
            "gpt-5",
            "gpt-5.4",
            "gpt-5.5",
            "gpt-5.6-sol",
            "openai/gpt-5.4-codex",
            "vendor/GPT-5.6-sol"
        ]
        let legacyConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.openAIID,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1",
            apiKey: "test"
        ).normalized
        let nativeAnthropicConfiguration = AgentConfiguration(
            providerID: AgentProviderPreset.customID,
            baseURL: "https://example.com",
            model: "gpt-5-compatible-alias",
            apiKey: "test",
            customKindOverride: .anthropicMessages
        ).normalized

        for model in gpt5FamilyModels {
            let configuration = AgentConfiguration(
                providerID: AgentProviderPreset.openAIID,
                baseURL: "https://api.openai.com/v1",
                model: model,
                apiKey: "test"
            ).normalized
            #expect(configuration.inferenceProviderKind == .openAIResponses)
        }
        #expect(legacyConfiguration.inferenceProviderKind == .openAIChat)
        #expect(nativeAnthropicConfiguration.inferenceProviderKind == .anthropicMessages)
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
            AgentMessage(role: .assistant, content: "The project uses Swift."),
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
