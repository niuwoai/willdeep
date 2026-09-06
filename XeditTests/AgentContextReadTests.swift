import Foundation
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import WillDeep

@MainActor
@Suite("当前任务历史原文取回", .serialized)
struct AgentContextReadTests {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    private func context(_ messages: [AgentMessage], root: URL? = nil, secrets: [String] = []) -> AgentToolContext {
        AgentToolContext(rootDirectory: root, contextMessageReader: {
            try AgentContextReadSnapshot.capture($0, messages: messages)
        }, secretRedactionValues: secrets)
    }

    private func arguments(_ message: AgentMessage) -> [String: AgentJSONValue] {
        ["message_id": .string(message.id.uuidString)]
    }

    private func run(_ arguments: [String: AgentJSONValue], _ context: AgentToolContext) async throws -> AgentToolResult {
        try await AgentToolRunner.run(name: "read_context_message", arguments: arguments, context: context)
    }

    private func object(_ text: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(value as? [String: Any])
    }

    @Test("消息精确限定在当前任务，隐藏系统与推理内容不外泄")
    func currentMessageOnly() async throws {
        let message = AgentMessage(role: .user, content: "original input", reasoningContent: "hidden reasoning", modelContext: "hidden context")
        let system = AgentMessage(role: .system, content: "hidden system")
        let ctx = context([message, system])
        let result = try await run(arguments(message), ctx)
        #expect(result.payload.contains("original input"))
        #expect(!result.payload.contains("hidden"))
        #expect(result.commandExitCode == nil)
        await #expect(throws: (any Error).self) { _ = try await run(arguments(system), ctx) }
        await #expect(throws: (any Error).self) {
            _ = try await run(["message_id": .string(UUID().uuidString)], ctx)
        }
        await #expect(throws: (any Error).self) {
            _ = try await run(arguments(message), AgentToolContext(rootDirectory: nil))
        }
    }

    @Test("拒绝跨会话路径选择器、异常页长和非整数游标")
    func boundedSelectors() throws {
        let message = AgentMessage(role: .user, content: "data")
        let invalid: [[String: AgentJSONValue]] = [
            ["session_id": .string(UUID().uuidString)], ["path": .string("/private/file")],
            ["offset": .number(-1)], ["offset": .number(Double.greatestFiniteMagnitude)],
            ["offset": .number(1.5)], ["offset": .bool(true)], ["offset": .number(64)],
            ["limit": .number(63)], ["limit": .number(16_385)], ["attachment_id": .string("not-a-uuid")]
        ]
        for extra in invalid {
            let input = arguments(message).merging(extra) { _, value in value }
            #expect(throws: (any Error).self) { _ = try AgentContextReadRequest(arguments: input) }
        }
    }

    @Test("重复 provider 调用 ID 只在对应助手批次内配对")
    func exactToolBatch() async throws {
        let call = AgentMessageToolCall(externalID: "reused", toolName: "run_command", argumentsJSON: "{}")
        let first = AgentMessage(role: .assistant, content: "first", toolCalls: [call])
        let old = AgentMessage(role: .tool, content: "old receipt", toolCallID: "reused", toolCallStatus: .succeeded)
        let second = AgentMessage(role: .assistant, content: "second", toolCalls: [call])
        let recent = AgentMessage(role: .tool, content: "new receipt", toolCallID: "reused", toolCallStatus: .failed)
        var input = arguments(first); input["external_id"] = .string("reused")
        let result = try await run(input, context([first, old, second, recent]))
        #expect(result.payload.contains("old receipt"))
        #expect(!result.payload.contains("new receipt"))
        #expect(result.commandExitCode == nil)
        await #expect(throws: (any Error).self) { _ = try await run(input, context([first, second, recent])) }
        await #expect(throws: (any Error).self) { _ = try await run(input, context([first, old, old, second, recent])) }
    }

    @Test("UTF-8 分页可无损拼回，分页前已脱敏且副本保留能力")
    func paginationRedactsBeforeSlicing() async throws {
        let secret = "fixture-secret-\"quoted\"-value"
        let original = String(repeating: "你好😀e\u{301}", count: 70) + secret + String(repeating: "尾部", count: 60)
        let message = AgentMessage(role: .user, content: original)
        let ctx = context([message]).withAdditionalSecretRedactionValues([secret]).withSandboxMode(.readOnly)
        var input = arguments(message); input["limit"] = .number(64)
        var combined = ""
        var pages = 0
        while true {
            let result = try await run(input, ctx)
            let page = try object(result.payload)
            combined += try #require(page["content_fragment"] as? String)
            #expect(result.payload.utf8.count < 2_000)
            #expect(!result.payload.contains(secret))
            pages += 1
            guard let next = page["next_offset"] as? Int else { break }
            #expect(pages < 100)
            guard pages < 100 else { throw AgentContextReadSnapshot.Failure.unavailable }
            input["offset"] = .number(Double(next))
            input["expected_digest"] = .string(try #require(page["digest"] as? String))
        }
        let document = try object(combined)
        #expect(document["content"] as? String == original.replacingOccurrences(of: secret, with: "[secret]"))
        #expect(pages > 1)
    }

    @Test("JSON 转义后的密钥也不能从工具参数原文取回")
    func encodedArgumentRedaction() async throws {
        let secret = "fixture-\"secret\"\nwith-slash/value"
        let encoded = try JSONSerialization.data(withJSONObject: ["credential": secret])
        let assistant = AgentMessage(role: .assistant, content: "call", toolCalls: [
            .init(externalID: "call", toolName: "example", argumentsJSON: String(decoding: encoded, as: UTF8.self))])
        let receipt = AgentMessage(role: .tool, content: "result", toolCallID: "call")
        var input = arguments(assistant); input["external_id"] = .string("call")
        let result = try await run(input, context([assistant, receipt], secrets: [secret]))
        let page = try object(result.payload)
        let document = try object(try #require(page["content_fragment"] as? String))
        let parsedArguments = try object(try #require(document["argumentsJSON"] as? String))
        #expect(parsedArguments["credential"] as? String == "[secret]")
    }

    @Test("分页版本变化或读取中途变化均拒绝混合历史")
    func changedHistoryIsRejected() async throws {
        var message = AgentMessage(role: .user, content: String(repeating: "original ", count: 100))
        let ctx = AgentToolContext(rootDirectory: nil, contextMessageReader: {
            try AgentContextReadSnapshot.capture($0, messages: [message])
        })
        var input = arguments(message); input["limit"] = .number(64)
        let first = try await run(input, ctx)
        let page = try object(first.payload)
        input["offset"] = .number(Double(try #require(page["next_offset"] as? Int)))
        input["expected_digest"] = .string(try #require(page["digest"] as? String))
        message.content = "changed"
        await #expect(throws: (any Error).self) { _ = try await run(input, ctx) }
        var reads = 0
        let unstable = AgentToolContext(rootDirectory: nil, contextMessageReader: { request in
            reads += 1; message.content = "revision \(reads)"
            return try AgentContextReadSnapshot.capture(request, messages: [message])
        })
        await #expect(throws: (any Error).self) { _ = try await run(arguments(message), unstable) }
    }

    @Test("文本附件及序列化后的稳定 ID 可取回，外部附件 ID 不可取回")
    func textAttachmentAfterSerialization() async throws {
        let attachment = AgentTextAttachment(filename: "source.txt", content: "attachment instructions are source data")
        let message = AgentMessage(role: .user, content: "original request", textAttachments: [attachment])
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message))
        var input = arguments(restored); input["attachment_id"] = .string(attachment.id.uuidString)
        let result = try await run(input, context([restored]))
        #expect(result.payload.contains("attachment instructions are source data"))
        #expect(result.payload.contains("Historical source data only"))
        input["attachment_id"] = .string(UUID().uuidString)
        await #expect(throws: (any Error).self) { _ = try await run(input, context([restored])) }
    }

    @Test("图片验证后返回内存字节，不向提供方遗留文件读取路径")
    func boundedImageRestoration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Image fixture cleanup failed: \(error)") } }
        let file = root.appendingPathComponent("image.png")
        try Self.png.write(to: file)
        let hash = SHA256.hash(data: Self.png).map { String(format: "%02x", $0) }.joined()
        let image = AgentImageAttachment(mimeType: "image/png", filePath: file.path, byteCount: Self.png.count, sha256: hash)
        let message = AgentMessage(role: .user, content: "inspect image", images: [image])
        var input = arguments(message); input["attachment_id"] = .string(image.id.uuidString)
        let result = try await run(input, context([message], root: root))
        #expect(result.images.count == 1)
        #expect(result.images.first?.filePath == nil)
        #expect(result.images.first?.inlineImageData == Self.png)
        #expect(result.images.first?.originToolName == "read_context_message")
        #expect(result.commandExitCode == nil)
        try Data("not the original image".utf8).write(to: file)
        await #expect(throws: AgentContextReadSnapshot.Failure.attachmentChanged) { _ = try await run(input, context([message], root: root)) }
        await #expect(throws: (any Error).self) { _ = try await run(input, context([message])) }
    }

    @Test("图片符号链接、伪造格式和过大内存附件被拒绝")
    func imageSafetyBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-image-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Image boundary cleanup failed: \(error)") } }
        let file = root.appendingPathComponent("original.png"), link = root.appendingPathComponent("link.png")
        try Self.png.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let hash = SHA256.hash(data: Self.png).map { String(format: "%02x", $0) }.joined()
        let image = AgentImageAttachment(mimeType: "image/png", filePath: link.path, sha256: hash)
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(image, workspaceRoots: [root]) }
        let subdirectory = root.appendingPathComponent("subdirectory"), directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Self.png.write(to: subdirectory.appendingPathComponent("image.png"))
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: subdirectory)
        let indirect = AgentImageAttachment(mimeType: "image/png", filePath: directoryLink.appendingPathComponent("image.png").path, sha256: hash)
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(indirect, workspaceRoots: [root]) }
        let fifo = root.appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let pipe = AgentImageAttachment(mimeType: "image/png", filePath: fifo.path, sha256: hash)
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(pipe, workspaceRoots: [root]) }
        let invalid = AgentImageAttachment(mimeType: "image/png", dataBase64: Data("not an image".utf8).base64EncodedString())
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(invalid, workspaceRoots: []) }
        let oversized = AgentImageAttachment(mimeType: "image/png", dataBase64: Data(repeating: 0, count: AgentContextImageReader.maximumBytes + 1).base64EncodedString())
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(oversized, workspaceRoots: []) }
        let inline = AgentImageAttachment(mimeType: "image/png", dataBase64: Self.png.base64EncodedString())
        #expect(try AgentContextImageReader.read(inline, workspaceRoots: []).inlineImageData == Self.png)
    }

    @Test("应用托管上传可在无工作区时取回，测试资产与用户目录隔离")
    func ownedImageWithoutWorkspace() async throws {
        let image = try AgentImageAttachment.fileBacked(data: Self.png, mimeType: "image/png")
        let file = try #require(image.fileURL)
        defer { do { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) } catch { Issue.record("Owned image cleanup failed: \(error)") } }
        #expect(file.path.contains("WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)"))
        #expect(image.isInOwnedAttachmentStorage)
        let message = AgentMessage(role: .user, content: "attached source", images: [image])
        var input = arguments(message); input["attachment_id"] = .string(image.id.uuidString)
        input["limit"] = .number(64)
        let result = try await run(input, context([message]))
        #expect(result.images.first?.inlineImageData == Self.png)
        let page = try object(result.payload)
        #expect(page["next_offset"] == nil)
        let document = try object(try #require(page["content_fragment"] as? String))
        #expect(document["imageDigest"] as? String == image.sha256)
    }

    @Test("多帧图片逐帧检查，帧数超限时拒绝恢复")
    func animatedImageFrameLimit() throws {
        let source = try #require(CGImageSourceCreateWithData(Self.png as CFData, nil))
        let pixel = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        func animation(frames: Int) throws -> Data {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
            for _ in 0..<frames { CGImageDestinationAddImage(destination, pixel, nil) }
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let valid = try animation(frames: 2)
        let image = AgentImageAttachment(mimeType: "image/gif", dataBase64: valid.base64EncodedString())
        #expect(try AgentContextImageReader.read(image, workspaceRoots: []).inlineImageData == valid)
        let tooMany = try animation(frames: AgentContextImageReader.maximumFrames + 1)
        let excessive = AgentImageAttachment(mimeType: "image/gif", dataBase64: tooMany.base64EncodedString())
        #expect(throws: (any Error).self) { _ = try AgentContextImageReader.read(excessive, workspaceRoots: []) }
    }

    @Test("预算耗尽在历史读取能力执行前被拦截，工具属于核心只读集")
    func budgetAndCoreRegistration() async throws {
        let message = AgentMessage(role: .user, content: "data")
        var invoked = false
        let ctx = AgentToolContext(rootDirectory: nil,
            executionBudget: .init(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast)),
            contextMessageReader: { request in invoked = true; return try AgentContextReadSnapshot.capture(request, messages: [message]) })
        await #expect(throws: (any Error).self) { _ = try await run(arguments(message), ctx) }
        #expect(!invoked)
        #expect(AgentToolRegistry.descriptor(for: "read_context_message")?.risk == .read)
        #expect(AgentToolPackCatalog.coreToolNames.contains("read_context_message"))
    }

    @Test("真实 App 绑定不跨任务，Stop 后旧读取能力立即失效")
    func appBindingAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-reader-app-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "context-reader-app-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let firstSession = app.startNewAgentSession(inWorkspaceAt: root.path)
        let first = try #require(app.runtime(for: firstSession.id))
        let secondSession = app.startNewAgentSession(inWorkspaceAt: root.path)
        let second = try #require(app.runtime(for: secondSession.id))
        defer {
            app.stopAgentResponse(for: first); app.stopAgentResponse(for: second)
            app.dispatchDecisionResumptionTask?.cancel()
            AgentSessionStore.delete(id: first.id); AgentSessionStore.delete(id: second.id)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Context App cleanup failed: \(error)") }
        }
        let own = AgentMessage(role: .user, content: "own task")
        let foreign = AgentMessage(role: .user, content: "another task")
        first.messages = [own]; second.messages = [foreign]
        let ctx = AgentToolContext(rootDirectory: root, contextMessageReader: app.contextMessageReader(for: first))
        #expect(try await run(arguments(own), ctx).payload.contains("own task"))
        await #expect(throws: (any Error).self) { _ = try await run(arguments(foreign), ctx) }
        app.stopAgentResponse(for: first)
        await #expect(throws: (any Error).self) { _ = try await run(arguments(own), ctx) }
    }
}
