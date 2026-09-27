//
//  AgentMCPToolResultContentTests.swift
//  XeditTests
//
//  MCP `tools/call` 结果里的图片 / 音频 / 资源二进制块，给模型之前要剥出来。
//
//  修之前宿主把整段结果 JSON 原样当工具输出：base64 被当成文本塞进上下文，
//  模型看不到图，工具输出截断以后留下的只是一段 base64 垃圾。
//
//  守的几件事：给模型的文本里不留 base64；图片挂成附件、按截图规则限边；
//  音频和资源落盘、路径写进文本；坏数据、超限、超数量都不崩并写明原因；
//  没有二进制块的结果一个字节都不变；插件页面拿到的仍是原始 MCP result。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WillDeep

@Suite
struct AgentMCPToolResultContentTests {
    // MARK: - Images

    @Test("图片块变成附件：限边到 1568、编成 JPEG，文本里只剩说明")
    func imageBlockBecomesAttachment() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 2_000, height: 1_000)
        let base64 = png.base64EncodedString()
        let input = try Fixture.json(["content": [["type": "image", "data": base64, "mimeType": "image/png"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(!extraction.payload.contains(base64))
        #expect(!extraction.payload.contains(String(base64.prefix(64))))
        let image = try #require(extraction.images.first)
        #expect(extraction.images.count == 1)
        #expect(image.mimeType == "image/jpeg")
        #expect(image.source == .capture)
        let previewURL = try #require(image.fileURL)
        #expect(previewURL.path.hasPrefix(sandbox.captures.path), "与截图落在同一处：\(previewURL.path)")
        #expect(previewURL.lastPathComponent == AgentCaptureTools.previewFilename)
        let size = try Fixture.pixelSize(of: previewURL)
        #expect(size.width == 1_568 && size.height == 784, "长边按截图的上限收：\(size)")

        let block = try Fixture.contentBlocks(extraction.payload)[0]
        #expect(block["type"] as? String == "image")
        #expect(block["mimeType"] as? String == "image/png")
        let note = try #require(block["data"] as? String)
        #expect(note.hasPrefix("[image 1: image/png, 2000×1000, attached (downscaled to 1568×784); original saved to "))
        let originalURL = URL(fileURLWithPath: try Fixture.savedPath(in: note, marker: "original saved to "))
        #expect(try Data(contentsOf: originalURL) == png, "原图原样保留")
        #expect(originalURL.deletingLastPathComponent().path == previewURL.deletingLastPathComponent().path)
    }

    @Test("文本与图片混排：文本块和顺序原样保留，小图不缩")
    func mixedTextAndImageKeepsTextAndOrder() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 40, height: 30)
        let input = try Fixture.json(["content": [
            ["type": "text", "text": "hello"],
            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": "world"],
        ]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        let blocks = try Fixture.contentBlocks(extraction.payload)
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"] as? String == "hello")
        #expect(blocks[2]["text"] as? String == "world")
        let note = try #require(blocks[1]["data"] as? String)
        #expect(note.hasPrefix("[image 1: image/png, 40×30, attached; original saved to "), "没缩就不说缩了：\(note)")
        #expect(extraction.images.count == 1)
    }

    /// 真实场景：插件出的图 base64 轻松过 48000 字符——模型那份 `prettyJSON`
    /// 恰好在这里截断。解析器必须拿到完整结果。
    @Test("大图（base64 超过 48000 字符）照样剥得干净")
    func largeImageBeyondModelTruncationIsExtracted() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.noisePNG(width: 200, height: 200)
        let base64 = png.base64EncodedString()
        #expect(base64.count > 48_000)
        let input = try Fixture.json(["content": [["type": "image", "data": base64, "mimeType": "image/png"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.images.count == 1)
        #expect(!extraction.payload.contains(String(base64.prefix(64))))
        #expect(!extraction.payload.contains("[truncated]"))
    }

    @Test("单次结果最多挂 8 张图，第 9 张写明略过")
    func imageCountIsCapped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        #expect(AgentMCPToolResultContent.Limits.standard.maximumImages == 8)
        let png = try Fixture.solidPNG(width: 4, height: 4).base64EncodedString()
        let blocks = (0..<9).map { _ in ["type": "image", "data": png, "mimeType": "image/png"] }
        let input = try Fixture.json(["content": blocks])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.images.count == 8)
        #expect(Set(extraction.images.compactMap(\.filePath)).count == 8, "每张图各有各的文件")
        let rendered = try Fixture.contentBlocks(extraction.payload)
        #expect(rendered[8]["data"] as? String == "[image 9 skipped: this result already carries 8 images, the per-result limit]")
        #expect(!extraction.payload.contains(png))
    }

    @Test("声明成非图片类型的图片块略过并写明原因")
    func unsupportedImageTypeIsSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 4, height: 4).base64EncodedString()
        let input = try Fixture.json(["content": [["type": "image", "data": png, "mimeType": "application/x-foo"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.images.isEmpty)
        #expect(try Fixture.contentBlocks(extraction.payload)[0]["data"] as? String
            == "[image 1 skipped: unsupported image type application/x-foo]")
        #expect(!extraction.payload.contains(png))
        #expect(Fixture.regularFiles(under: sandbox.root).isEmpty)
    }

    @Test("解不出图的数据略过，不崩")
    func undecodableImageIsSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let notAnImage = Data("definitely not pixels".utf8).base64EncodedString()
        let input = try Fixture.json(["content": [["type": "image", "data": notAnImage, "mimeType": "image/png"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.images.isEmpty)
        #expect(try Fixture.contentBlocks(extraction.payload)[0]["data"] as? String
            == "[image 1 skipped: could not decode the image data]")
    }

    // MARK: - Audio & resources

    @Test("音频块落盘，文本里写类型、体积和路径")
    func audioBlockIsSavedToFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let bytes = Data((0..<3_000).map { UInt8($0 % 251) })
        let base64 = bytes.base64EncodedString()
        let input = try Fixture.json(["content": [["type": "audio", "data": base64, "mimeType": "audio/mpeg"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.images.isEmpty)
        let saved = try #require(extraction.savedFiles.first)
        #expect(saved.kind == .audio)
        #expect(saved.url.lastPathComponent == "audio.mp3")
        #expect(saved.url.path.hasPrefix(sandbox.captures.path))
        #expect(try Data(contentsOf: saved.url) == bytes)
        #expect(!extraction.payload.contains(base64))
        #expect(try Fixture.contentBlocks(extraction.payload)[0]["data"] as? String
            == "[audio 1: audio/mpeg, 3 KB, saved to \(saved.url.path)]")
    }

    @Test("认不出的音频类型略过")
    func unknownAudioTypeIsSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let base64 = Data([1, 2, 3, 4]).base64EncodedString()
        let input = try Fixture.json(["content": [
            ["type": "audio", "data": base64, "mimeType": "audio/x-willdeep-unknown"],
            ["type": "audio", "data": base64, "mimeType": "text/plain"],
        ]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        let blocks = try Fixture.contentBlocks(extraction.payload)
        #expect(blocks[0]["data"] as? String == "[audio 1 skipped: unsupported audio type audio/x-willdeep-unknown]")
        #expect(blocks[1]["data"] as? String == "[audio 2 skipped: unsupported audio type text/plain]")
        #expect(extraction.savedFiles.isEmpty)
        #expect(Fixture.regularFiles(under: sandbox.root).isEmpty)
    }

    @Test("资源 blob 落盘，文件名取自 URI；文本资源原样")
    func resourceBlobIsSaved() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let pdf = Data("%PDF-1.4 fake body".utf8)
        let raw = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let input = try Fixture.json(["content": [
            ["type": "resource", "resource": [
                "uri": "file:///tmp/reports/Q3%20report.pdf",
                "mimeType": "application/pdf",
                "blob": pdf.base64EncodedString(),
            ]],
            ["type": "resource", "resource": ["uri": "file:///tmp/notes.txt", "mimeType": "text/plain", "text": "plain"]],
            ["type": "resource", "resource": ["blob": raw.base64EncodedString()]],
        ]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        #expect(extraction.savedFiles.count == 2)
        let report = extraction.savedFiles[0]
        #expect(report.kind == .resource)
        #expect(report.url.lastPathComponent == "Q3_report.pdf")
        #expect(try Data(contentsOf: report.url) == pdf)
        let unnamed = extraction.savedFiles[1]
        #expect(unnamed.url.lastPathComponent == "resource.bin", "没有 URI、没有类型也照样落盘")
        #expect(try Data(contentsOf: unnamed.url) == raw)

        let blocks = try Fixture.contentBlocks(extraction.payload)
        let first = try #require(blocks[0]["resource"] as? [String: Any])
        #expect(first["blob"] as? String == "[resource 1: application/pdf, 18 B, saved to \(report.url.path)]")
        #expect(first["uri"] as? String == "file:///tmp/reports/Q3%20report.pdf")
        let text = try #require(blocks[1]["resource"] as? [String: Any])
        #expect(text["text"] as? String == "plain")
        let third = try #require(blocks[2]["resource"] as? [String: Any])
        #expect(third["blob"] as? String == "[resource 2: unknown type, 4 B, saved to \(unnamed.url.path)]")
    }

    @Test("资源文件名收敛成安全字符，不会带出目录或藏成点文件")
    func resourceFilenamesAreSanitized() {
        #expect(AgentMCPToolResultContent.resourceFilename(uri: nil, mime: "application/pdf") == "resource.pdf")
        #expect(AgentMCPToolResultContent.resourceFilename(uri: "file:///x/.hidden", mime: "") == "hidden.bin")
        #expect(AgentMCPToolResultContent.resourceFilename(uri: "ui://server/widget", mime: "text/html") == "widget.html")
        for uri in ["file:///a/..%2F..%2Fetc%2Fpasswd", "res://x/a b:c?.png", "file:///..", "://"] {
            let name = AgentMCPToolResultContent.resourceFilename(uri: uri, mime: "")
            #expect(!name.contains("/"), "\(uri) → \(name)")
            #expect(!name.hasPrefix("."), "\(uri) → \(name)")
            #expect(!name.isEmpty)
        }
    }

    // MARK: - Failures & limits

    @Test("坏 base64 略过并写明原因，原文不进文本")
    func invalidBase64IsSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let garbage = "%%%garbage%%%"
        let input = try Fixture.json(["content": [
            ["type": "image", "data": garbage, "mimeType": "image/png"],
            ["type": "audio", "data": garbage, "mimeType": "audio/wav"],
            ["type": "resource", "resource": ["uri": "file:///x.bin", "blob": garbage]],
        ]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        let blocks = try Fixture.contentBlocks(extraction.payload)
        #expect(blocks[0]["data"] as? String == "[image 1 skipped: data is not valid base64]")
        #expect(blocks[1]["data"] as? String == "[audio 1 skipped: data is not valid base64]")
        #expect((blocks[2]["resource"] as? [String: Any])?["blob"] as? String
            == "[resource 1 skipped: data is not valid base64]")
        #expect(!extraction.payload.contains(garbage))
        #expect(extraction.images.isEmpty && extraction.savedFiles.isEmpty)
        #expect(Fixture.regularFiles(under: sandbox.root).isEmpty)
    }

    @Test("超过单块上限的略过，不写文件")
    func oversizedBlocksAreSkipped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        #expect(AgentMCPToolResultContent.Limits.standard.maximumBlockBytes == 20 * 1_024 * 1_024)
        var limits = AgentMCPToolResultContent.Limits.standard
        limits.maximumBlockBytes = 1_024
        let wayOver = Data(repeating: 7, count: 5_000).base64EncodedString()
        let justOver = Data(repeating: 7, count: 1_050).base64EncodedString()
        let png = try Fixture.noisePNG(width: 64, height: 64)
        #expect(png.count > 1_024)
        let input = try Fixture.json(["content": [
            ["type": "audio", "data": wayOver, "mimeType": "audio/mpeg"],
            ["type": "audio", "data": justOver, "mimeType": "audio/mpeg"],
            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
        ]])

        let extraction = AgentMCPToolResultContent.extract(
            resultJSON: input, style: .indented, storage: sandbox.storage, limits: limits
        )

        let blocks = try Fixture.contentBlocks(extraction.payload)
        let first = try #require(blocks[0]["data"] as? String)
        #expect(first.hasPrefix("[audio 1 skipped: about "), "明显超限的不解码，按字符数估：\(first)")
        #expect(first.hasSuffix("over the 1 KB per-block limit]"))
        #expect(blocks[1]["data"] as? String == "[audio 2 skipped: 1 KB, over the 1 KB per-block limit]")
        let third = try #require(blocks[2]["data"] as? String)
        #expect(third.hasPrefix("[image 1 skipped: "))
        #expect(third.hasSuffix("over the 1 KB per-block limit]"))
        #expect(extraction.images.isEmpty && extraction.savedFiles.isEmpty)
        #expect(Fixture.regularFiles(under: sandbox.root).isEmpty)
    }

    @Test("截图目录写不进去时退到 App 自己的附件目录")
    func fallsBackWhenCapturesRootIsNotWritable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        // 截图根目录的位置上是个普通文件，建不了子目录。
        let blocked = sandbox.root.appendingPathComponent("blocked-captures")
        try Data("x".utf8).write(to: blocked)
        let storage = AgentMCPToolResultContent.Storage(
            capturesRoot: blocked,
            fallbackDirectory: { [fallback = sandbox.fallback] id in
                fallback.appendingPathComponent(id.uuidString, isDirectory: true)
            }
        )
        let png = try Fixture.solidPNG(width: 8, height: 8).base64EncodedString()
        let audio = Data([9, 9, 9]).base64EncodedString()
        let input = try Fixture.json(["content": [
            ["type": "image", "data": png, "mimeType": "image/png"],
            ["type": "audio", "data": audio, "mimeType": "audio/wav"],
        ]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: storage)

        let image = try #require(extraction.images.first)
        #expect(image.filePath?.hasPrefix(sandbox.fallback.path) == true, "\(image.filePath ?? "nil")")
        let saved = try #require(extraction.savedFiles.first)
        #expect(saved.url.path.hasPrefix(sandbox.fallback.path))
        #expect(saved.url.lastPathComponent == "audio.wav")
        #expect(try Data(contentsOf: blocked) == Data("x".utf8), "挡路的文件不能被动")
    }

    @Test("两处都写不进去：略过并写明原因")
    func bothLocationsFailingSkipsBlock() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let blocked = sandbox.root.appendingPathComponent("blocked-captures")
        try Data("x".utf8).write(to: blocked)
        struct NoFallback: Error {}
        let storage = AgentMCPToolResultContent.Storage(capturesRoot: blocked, fallbackDirectory: { _ in throw NoFallback() })
        let png = try Fixture.solidPNG(width: 8, height: 8).base64EncodedString()
        let input = try Fixture.json(["content": [["type": "image", "data": png, "mimeType": "image/png"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: storage)

        #expect(extraction.images.isEmpty)
        let note = try #require(try Fixture.contentBlocks(extraction.payload)[0]["data"] as? String)
        #expect(note.hasPrefix("[image 1 skipped: could not save it ("), "\(note)")
        #expect(!extraction.payload.contains(png))
    }

    // MARK: - Pass-through

    @Test("没有 content 的结果原样通过")
    func resultWithoutContentPassesThrough() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let object: [String: Any] = ["structuredContent": ["ok": true, "count": 2], "_meta": ["trace": "t-1"]]
        let input = try Fixture.json(object)

        let indented = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)
        #expect(indented.payload == AgentMCPBridge.prettyJSON(object), "与改动前模型那份一模一样")
        #expect(indented.images.isEmpty && indented.savedFiles.isEmpty)

        let compact = AgentMCPToolResultContent.extract(resultJSON: input, style: .compact, storage: sandbox.storage)
        #expect(compact.payload == input, "紧凑那份一个字节都不变")
        #expect(Fixture.regularFiles(under: sandbox.root).isEmpty)
    }

    @Test("只有文本块的结果原样通过")
    func textOnlyResultPassesThrough() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let object: [String: Any] = ["content": [["type": "text", "text": "just words"]]]
        let input = try Fixture.json(object)

        #expect(AgentMCPToolResultContent.extract(resultJSON: input, style: .compact, storage: sandbox.storage).payload == input)
        #expect(AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage).payload
            == AgentMCPBridge.prettyJSON(object))
    }

    @Test("不是 JSON 的输入原样交出去，不崩")
    func nonJSONInputPassesThrough() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let input = "not json at all"
        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)
        #expect(extraction.payload == input)
        #expect(extraction.images.isEmpty)
    }

    @Test("isError 结果：标记和文本原样保留，图片照样剥")
    func isErrorResultIsKept() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 6, height: 6).base64EncodedString()
        let input = try Fixture.json([
            "isError": true,
            "content": [
                ["type": "text", "text": "boom"],
                ["type": "image", "data": png, "mimeType": "image/png"],
            ],
        ])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .indented, storage: sandbox.storage)

        let object = try Fixture.object(extraction.payload)
        #expect(object["isError"] as? Bool == true)
        let blocks = try #require(object["content"] as? [[String: Any]])
        #expect(blocks[0]["text"] as? String == "boom")
        #expect((blocks[1]["data"] as? String)?.hasPrefix("[image 1: image/png, 6×6, attached") == true)
        #expect(extraction.images.count == 1)
        #expect(!extraction.payload.contains(png))

        let errorOnly = try Fixture.json(["isError": true, "content": [["type": "text", "text": "nope"]]])
        let plain = AgentMCPToolResultContent.extract(resultJSON: errorOnly, style: .compact, storage: sandbox.storage)
        #expect(plain.payload == errorOnly)
    }

    @Test("紧凑风格剥完仍是紧凑、可解析的 JSON")
    func compactStyleStaysCompact() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 5, height: 5).base64EncodedString()
        let input = try Fixture.json(["content": [["type": "image", "data": png, "mimeType": "image/png"]]])

        let extraction = AgentMCPToolResultContent.extract(resultJSON: input, style: .compact, storage: sandbox.storage)

        #expect(!extraction.payload.contains("\n"))
        #expect((try Fixture.contentBlocks(extraction.payload)[0]["data"] as? String)?.hasPrefix("[image 1:") == true)
    }

    @Test("紧凑风格剥完仍超上限就报错并删掉已落盘的图；缩进风格不受这道闸影响")
    func compactPayloadLimitSurvivesStripping() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let png = try Fixture.solidPNG(width: 5, height: 5).base64EncodedString()
        let bulkyText = String(repeating: "x", count: 4_096)
        let input = try Fixture.json(["content": [
            ["type": "text", "text": bulkyText],
            ["type": "image", "data": png, "mimeType": "image/png"]
        ]])
        let compact = AgentMCPToolResultContent.extract(resultJSON: input, style: .compact, storage: sandbox.storage)
        let compactResult = AgentToolResult(summary: "s", payload: compact.payload, images: compact.images)
        #expect(compact.images.count == 1)
        var discarded: [AgentImageAttachment] = []

        #expect(throws: AgentToolError.self) {
            try AgentMCPToolResultContent.enforcePayloadLimit(
                compactResult, style: .compact, limit: 1_024, discardImages: { discarded += $0 }
            )
        }
        #expect(discarded == compact.images, "报错的结果不该留下孤儿图片文件")

        discarded = []
        let withinLimit = try AgentMCPToolResultContent.enforcePayloadLimit(
            compactResult, style: .compact, limit: 1_000_000, discardImages: { discarded += $0 }
        )
        #expect(withinLimit == compactResult)
        let indentedResult = AgentToolResult(summary: "s", payload: compact.payload, images: compact.images)
        let indented = try AgentMCPToolResultContent.enforcePayloadLimit(
            indentedResult, style: .indented, limit: 1_024, discardImages: { discarded += $0 }
        )
        #expect(indented == indentedResult)
        #expect(discarded.isEmpty, "没超限、或缩进风格时不动已落盘的图")
    }

    @Test("data URL 与折行的 base64 也认；坏字符不放过")
    func base64Variants() throws {
        let bytes = Data((0..<200).map { UInt8($0) })
        let base64 = bytes.base64EncodedString()
        #expect(AgentMCPToolResultContent.decodeBase64("data:audio/mpeg;base64,\(base64)") == bytes)
        let wrapped = bytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        #expect(wrapped.contains("\n"))
        #expect(AgentMCPToolResultContent.decodeBase64(wrapped) == bytes)
        #expect(AgentMCPToolResultContent.decodeBase64("%%%garbage%%%") == nil)
    }

    // MARK: - End to end

    /// 同一个 stdio 服务、同一次 `tools/call`：插件页面那条路拿到原始 result
    /// （base64 原样，`executeCommand` 的既有契约），模型那条路拿到剥过的文本
    /// 加一张图片附件。
    @Test("端到端：页面那条路原样，模型那条路剥掉二进制")
    func pagePathStaysRawWhileModelPathStrips() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let script = sandbox.root.appendingPathComponent("server.rb")
        try Self.imageServerScript.write(to: script, atomically: true, encoding: .utf8)
        let pluginID = "mcp-result-content-test-\(UUID().uuidString.prefix(8).lowercased())"
        let server = AgentMCPServerConfig(
            id: "plugin:\(pluginID):render",
            name: "render", source: .plugin, transport: .stdio,
            command: "/usr/bin/ruby", args: [script.path], startupTimeout: 10
        )
        defer { AgentMCPBridge.invalidatePluginConnections(pluginID: pluginID) }
        let base64 = try Fixture.noisePNG(width: 200, height: 200).base64EncodedString()

        let raw = try await AgentMCPBridge.requestForTesting(
            server: server, method: "tools/call",
            params: ["name": "render", "arguments": ["png": base64]]
        )
        let rawBlocks = try Fixture.contentBlocks(raw)
        #expect(rawBlocks[1]["data"] as? String == base64, "页面拿到的是原始 MCP result")

        for style in [AgentMCPToolResultContent.PayloadStyle.indented, .compact] {
            let result = try await AgentMCPBridge.callToolForModelTesting(
                server: server, toolName: "render", arguments: ["png": base64],
                style: style, storage: sandbox.storage
            )
            #expect(!result.payload.contains(String(base64.prefix(64))), "\(style)")
            #expect(result.images.count == 1, "\(style)")
            let blocks = try Fixture.contentBlocks(result.payload)
            #expect(blocks[0]["text"] as? String == "rendered")
            #expect((blocks[1]["data"] as? String)?.hasPrefix("[image 1: image/png, 200×200, attached") == true)
        }
    }

    private static let imageServerScript = #"""
    require "json"
    $stdout.sync = true
    while (line = $stdin.gets)
      message = JSON.parse(line) rescue next
      next unless message["id"]
      case message["method"]
      when "initialize"
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => { "capabilities" => {} })
      when "tools/call"
        arguments = message.dig("params", "arguments") || {}
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => {
          "content" => [
            { "type" => "text", "text" => "rendered" },
            { "type" => "image", "data" => arguments["png"], "mimeType" => "image/png" }
          ]
        })
      else
        puts JSON.generate("jsonrpc" => "2.0", "id" => message["id"], "result" => {})
      end
    end
    """#
}

// MARK: - Fixtures

private struct Sandbox {
    let root: URL
    let captures: URL
    let fallback: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tool-result-content-\(UUID().uuidString)", isDirectory: true)
        captures = root.appendingPathComponent("captures", isDirectory: true)
        fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storage: AgentMCPToolResultContent.Storage {
        AgentMCPToolResultContent.Storage(
            capturesRoot: captures,
            fallbackDirectory: { [fallback] id in fallback.appendingPathComponent(id.uuidString, isDirectory: true) }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum Fixture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ payload: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw Failure(description: "payload is not a JSON object: \(payload.prefix(200))")
        }
        return object
    }

    static func contentBlocks(_ payload: String) throws -> [[String: Any]] {
        guard let blocks = try object(payload)["content"] as? [[String: Any]] else {
            throw Failure(description: "payload has no content array: \(payload.prefix(200))")
        }
        return blocks
    }

    /// 从 `...; original saved to <路径>]` 这样的说明里取出路径。
    static func savedPath(in note: String, marker: String) throws -> String {
        guard let range = note.range(of: marker), note.hasSuffix("]") else {
            throw Failure(description: "no \(marker) in \(note)")
        }
        return String(note[range.upperBound...].dropLast())
    }

    static func regularFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw Failure(description: "unreadable image at \(url.path)")
        }
        return (width, height)
    }

    static func solidPNG(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure(description: "no context") }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure(description: "no image") }
        return try png(image)
    }

    /// 压不小的噪点图，用来造体积。
    static func noisePNG(width: Int, height: Int) throws -> Data {
        var state: UInt32 = 0x2545_F491
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in bytes.indices where index % 4 != 3 {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw Failure(description: "no noise image") }
        return try png(image)
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "no PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "PNG encode failed") }
        return data as Data
    }
}
