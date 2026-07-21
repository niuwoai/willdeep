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
@testable import WillDeep

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

    /// Long pasted text is stored as a compact attachment in the UI,
    /// but the provider payload must still include its full body.
    @Test
    func encodeChatRequestIncludesPastedTextAttachmentBody() throws {
        let attachment = AgentTextAttachment(
            filename: "crash.txt",
            content: "Exception Type: EXC_BAD_ACCESS\nThread 0 Crashed"
        )
        let data = try AgentClient.encodeChatRequest(
            model: "x",
            messages: [
                AgentMessage(
                    role: .user,
                    content: "请看这段崩溃日志",
                    textAttachments: [attachment]
                )
            ],
            tools: []
        )
        let dict = try parseJSONObject(data)
        let messages = dict["messages"] as? [[String: Any]] ?? []
        let first = messages.first
        let content = first?["content"] as? String ?? ""
        #expect(content.contains("请看这段崩溃日志"))
        #expect(content.contains("### Attached text: crash.txt"))
        #expect(content.contains("Exception Type: EXC_BAD_ACCESS"))
    }

    @Test
    func encodeChatRequestKeepsGeneratedImageDescriptionForTextOnlyProviders() throws {
        let image = AgentImageAttachment(mimeType: "image/png", dataBase64: "aW1hZ2U=")
        let content = AppState.contentByAppendingImageDescription(
            to: "图片说的是啥",
            description: "Image 1: a compact UI screenshot.",
            imageCount: 1,
            providerID: "dashscope",
            model: "qwen3-vl-plus"
        )

        let data = try AgentClient.encodeChatRequest(
            model: "deepseek-v4-flash",
            messages: [
                AgentMessage(role: .user, content: content, images: [image])
            ],
            tools: [],
            supportsImages: false
        )
        let dict = try parseJSONObject(data)
        let messages = dict["messages"] as? [[String: Any]] ?? []
        let first = messages.first
        let encodedContent = first?["content"] as? String ?? ""
        #expect(encodedContent.contains("Image 1: a compact UI screenshot."))
        #expect(encodedContent.contains("[Image description generated by dashscope / qwen3-vl-plus"))
        #expect(encodedContent.contains("omitted because this provider only accepts text messages") == false)
    }

    @Test
    func fileBackedImageAttachmentEncodesPathMetadataWithoutInlineBase64() throws {
        let data = Data("image-bytes".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-file-backed-image-\(UUID().uuidString).png")
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        let image = AgentImageAttachment(
            mimeType: "image/png",
            filePath: url.path,
            byteCount: data.count,
            sha256: "test-sha"
        )

        let encoded = try JSONEncoder().encode(image)
        let object = try parseJSONObject(encoded)
        #expect(object["filePath"] as? String == url.path)
        #expect(object["byteCount"] as? Int == data.count)
        #expect(object["sha256"] as? String == "test-sha")
        #expect(object["dataBase64"] == nil)

        let decoded = try JSONDecoder().decode(AgentImageAttachment.self, from: encoded)
        #expect(decoded.dataBase64 == data.base64EncodedString())
        #expect(decoded.dataURL == "data:image/png;base64,\(data.base64EncodedString())")
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

    @Test
    func providerReadyMessagesDropsLocalOnlyCards() throws {
        let widget = AgentWidget(title: "Demo", html: "<p>local only</p>")
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "please continue"),
            AgentMessage(role: .widget, content: "", widget: widget),
            AgentMessage(role: .workflowReport, content: ""),
            AgentMessage(role: .assistant, content: "ok")
        ]
        let out = AgentClient.providerReadyMessages(messages)
        #expect(out.map(\.role) == [.user, .assistant])

        let data = try AgentClient.encodeChatRequest(model: "x", messages: messages, tools: [])
        let dict = try parseJSONObject(data)
        let encoded = dict["messages"] as? [[String: Any]] ?? []
        #expect(encoded.map { $0["role"] as? String } == ["user", "assistant"])
    }

    @Test
    func pastedTextThresholdOnlyCapturesLargeInput() {
        #expect(AgentTextAttachment.shouldCapturePaste("普通一小段文本") == false)
        let longText = String(repeating: "a", count: AgentTextAttachment.largePasteCharacterThreshold)
        #expect(AgentTextAttachment.shouldCapturePaste(longText) == true)
        let manyLines = Array(repeating: "line", count: AgentTextAttachment.largePasteLineThreshold)
            .joined(separator: "\n")
        #expect(AgentTextAttachment.shouldCapturePaste(manyLines) == true)
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

@Suite
struct GeminiToolCallIDTests {

    /// Gemini pairs functionResponse to functionCall by name, resolved
    /// through the id→name history map. Ids therefore must be unique across
    /// assistant turns — a bare per-stream index restarts at 0 every turn
    /// and makes first-occurrence-wins resolve later slot-0 calls to
    /// whichever tool the session used first.
    @Test
    func syntheticIDsAreUniquePerStreamNonce() {
        let nonceA = GeminiAdapter.makeCallIDNonce()
        let nonceB = GeminiAdapter.makeCallIDNonce()
        #expect(nonceA != nonceB)
        #expect(
            GeminiAdapter.syntheticToolCallID(nonce: nonceA, index: 0)
                != GeminiAdapter.syntheticToolCallID(nonce: nonceB, index: 0)
        )
        #expect(GeminiAdapter.syntheticToolCallID(nonce: nonceA, index: 0).hasPrefix("gemini_fcall_"))
    }

    @Test
    func historyMapResolvesSameSlotAcrossTurnsToDifferentTools() {
        let turnOne = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(
                externalID: GeminiAdapter.syntheticToolCallID(nonce: "aaaa1111", index: 0),
                toolName: "read_file",
                argumentsJSON: "{}"
            )]
        )
        let turnTwo = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(
                externalID: GeminiAdapter.syntheticToolCallID(nonce: "bbbb2222", index: 0),
                toolName: "run_command",
                argumentsJSON: "{}"
            )]
        )
        let map = GeminiAdapter.buildToolCallIDMap(from: [turnOne, turnTwo])
        #expect(map[turnOne.toolCalls[0].externalID] == "read_file")
        #expect(map[turnTwo.toolCalls[0].externalID] == "run_command")
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
