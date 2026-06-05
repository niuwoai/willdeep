//
//  AgentClientEncodingTests.swift
//  XeditTests
//
//  Covers the pure encoding helpers in AgentClient — the request body
//  shape, the assistant↔tool message reordering, and the image fallback
//  for text-only providers. The network/stream code path is not
//  exercised here (it requires a URLSession stub); we lock in only the
//  pieces a downstream model run actually depends on.
//

import Testing
import Foundation
@testable import VeilWriter

@Suite
struct AgentClientEncodingTests {

    // MARK: - encodeChatRequest

    /// Top-level request must carry the model id, `stream=true`, the
    /// `stream_options.include_usage=true` flag (OpenAI requires it for
    /// usage delivery on streaming), and the messages array.
    @Test
    func encodeChatRequestProducesExpectedTopLevelShape() throws {
        let data = try AgentClient.encodeChatRequest(
            model: "gpt-4o-mini",
            messages: [AgentMessage(role: .user, content: "hi")],
            tools: []
        )
        let dict = try parseJSONObject(data)
        #expect(dict["model"] as? String == "gpt-4o-mini")
        #expect(dict["stream"] as? Bool == true)
        let streamOpts = dict["stream_options"] as? [String: Any]
        #expect(streamOpts?["include_usage"] as? Bool == true)
        let messages = dict["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 1)
    }

    /// With no tools, the request omits both `tools` and `tool_choice`
    /// — DashScope rejects an empty tools array on some models.
    @Test
    func encodeChatRequestOmitsToolsKeysWhenEmpty() throws {
        let data = try AgentClient.encodeChatRequest(
            model: "x",
            messages: [AgentMessage(role: .user, content: "ping")],
            tools: []
        )
        let dict = try parseJSONObject(data)
        #expect(dict["tools"] == nil)
        #expect(dict["tool_choice"] == nil)
    }

    /// With tools, `tool_choice` is set to "auto" so the model decides
    /// whether to invoke one. Tools are encoded as an array of dicts.
    @Test
    func encodeChatRequestIncludesToolsAndAutoChoice() throws {
        let descriptor = AgentToolDescriptor(
            name: "search_files",
            description: "search the workspace",
            risk: .read,
            parameters: [
                AgentToolParameter(
                    name: "query",
                    type: .string,
                    description: "search text",
                    required: true
                )
            ]
        )
        let data = try AgentClient.encodeChatRequest(
            model: "x",
            messages: [AgentMessage(role: .user, content: "find readme")],
            tools: [descriptor]
        )
        let dict = try parseJSONObject(data)
        #expect(dict["tool_choice"] as? String == "auto")
        let tools = dict["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1)
    }

    // MARK: - providerReadyMessages

    /// A pure user → assistant exchange passes through unmodified.
    @Test
    func providerReadyMessagesPassesPlainTextExchange() {
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "hi"),
            AgentMessage(role: .assistant, content: "hello")
        ]
        let out = AgentClient.providerReadyMessages(messages)
        #expect(out.count == 2)
        #expect(out[0].role == .user)
        #expect(out[1].role == .assistant)
    }

    /// Orphan tool messages (no matching assistant tool_call ancestor)
    /// are dropped — the provider would 400 if we sent a tool message
    /// without the corresponding tool_call directly above it.
    @Test
    func providerReadyMessagesDropsOrphanToolMessages() {
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "hi"),
            AgentMessage(role: .tool,  content: "orphan",
                         toolCallID: "nonexistent")
        ]
        let out = AgentClient.providerReadyMessages(messages)
        #expect(out.count == 1)
        #expect(out.first?.role == .user)
    }

    /// An assistant message that emits tool_calls is paired with the
    /// matching tool reply ONLY when every expected id has a reply.
    /// Partial coverage drops the whole assistant turn so we don't
    /// send a half-resolved tool_call back.
    @Test
    func providerReadyMessagesDropsPartiallyResolvedToolCalls() {
        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(externalID: "call_a", toolName: "x", argumentsJSON: "{}"),
                AgentMessageToolCall(externalID: "call_b", toolName: "y", argumentsJSON: "{}")
            ]
        )
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "go"),
            assistant,
            AgentMessage(role: .tool, content: "result-a", toolCallID: "call_a")
            // call_b never resolved
        ]
        let out = AgentClient.providerReadyMessages(messages)
        #expect(out.count == 1) // only the user message survives
        #expect(out.first?.role == .user)
    }

    /// Fully-resolved tool_calls keep the assistant turn AND the
    /// matched tool messages, in id order.
    @Test
    func providerReadyMessagesKeepsFullyResolvedToolTurn() {
        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                AgentMessageToolCall(externalID: "call_a", toolName: "x", argumentsJSON: "{}"),
                AgentMessageToolCall(externalID: "call_b", toolName: "y", argumentsJSON: "{}")
            ]
        )
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "go"),
            assistant,
            AgentMessage(role: .tool, content: "result-b", toolCallID: "call_b"),
            AgentMessage(role: .tool, content: "result-a", toolCallID: "call_a")
        ]
        let out = AgentClient.providerReadyMessages(messages)
        #expect(out.count == 4)
        #expect(out[0].role == .user)
        #expect(out[1].role == .assistant)
        // Tool replies are emitted in the assistant's call order, NOT
        // the original transcript order — that's the providerReady
        // contract.
        #expect(out[2].toolCallID == "call_a")
        #expect(out[3].toolCallID == "call_b")
    }

    /// When the provider doesn't accept images, user messages with
    /// attached images get a "[N image attachment(s) omitted ...]"
    /// notice appended and `images` cleared — text providers must not
    /// see image payloads they can't decode.
    @Test
    func providerReadyMessagesStripsImagesForTextOnlyProvider() {
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: "AAA")
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "what's in this?", images: [image])
        ]
        let out = AgentClient.providerReadyMessages(messages, supportsImages: false)
        #expect(out.count == 1)
        #expect(out[0].images.isEmpty)
        #expect(out[0].content.contains("image attachment"))
        #expect(out[0].content.contains("omitted"))
    }

    /// With image support enabled, the user message passes through
    /// untouched — images are encoded into the message dict by
    /// `encodeMessage`, not by `providerReadyMessages`.
    @Test
    func providerReadyMessagesKeepsImagesWhenProviderSupportsThem() {
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: "AAA")
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "hi", images: [image])
        ]
        let out = AgentClient.providerReadyMessages(messages, supportsImages: true)
        #expect(out.first?.images.count == 1)
        #expect(out.first?.content == "hi")
    }

    /// Empty-content user message with images on a text-only provider
    /// turns the notice into the message body so there's no empty
    /// content field (some providers 400 on empty user content).
    @Test
    func providerReadyMessagesUsesNoticeAsContentWhenOriginalWasEmpty() {
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: "AAA")
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "", images: [image])
        ]
        let out = AgentClient.providerReadyMessages(messages, supportsImages: false)
        #expect(out.first?.content.contains("image attachment") == true)
        #expect(out.first?.content.hasPrefix("[") == true)
    }
}

// MARK: - Helpers

private func parseJSONObject(_ data: Data) throws -> [String: Any] {
    let raw = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = raw as? [String: Any] else {
        throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected dict"])
    }
    return dict
}
