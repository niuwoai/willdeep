import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WillDeep

/// 插件页面问模型时附带图片 / 视频（桥 2.6.0 `ai.images` / `ai.videos`）。
///
/// 守三件事：页面递来的附件字段在进模型前被收干净；路径钳制和参照图那条路
/// 一样严——出了插件生成目录、符号链接一律拒；图片被限边重编码、视频被抽成
/// 按时间排好的帧。
@Suite
struct AgentPluginAIMediaTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-ai-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// 写一段两秒、每秒十帧的纯色 H.264 视频。
    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer)
            #expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test("附件只认 user 消息的 imagePaths / videoPaths，去空去重")
    func validatorCollectsAttachments() {
        let raw: [String: Any] = [
            "messages": [[
                "role": "user", "content": "审一下",
                "imagePaths": ["/a.png", " /a.png ", "", 42, "/b.png"],
                "videoPaths": ["/c.mp4"],
            ]],
        ]
        guard case .success(let request) = AgentPluginAIRequestValidator.request(from: raw) else {
            Issue.record("合法附件不该被拒")
            return
        }
        #expect(request.messages[0].imagePaths == ["/a.png", "/b.png"])
        #expect(request.messages[0].videoPaths == ["/c.mp4"])
        #expect(request.messages[0].hasMedia)
    }

    @Test("不带附件的请求形状不变")
    func validatorKeepsPlainRequestsUnchanged() {
        guard case .success(let request) = AgentPluginAIRequestValidator.request(from: [
            "messages": [["role": "user", "content": "你好"]],
        ]) else {
            Issue.record("普通请求不该被拒")
            return
        }
        #expect(!request.messages[0].hasMedia)
    }

    @Test("附件数量超限、挂在非 user 消息上都当场拒")
    func validatorRejectsAbuse() {
        let images = (0...AgentPluginAIMedia.maximumImages).map { "/\($0).png" }
        #expect(AgentPluginAIRequestValidator.request(from: [
            "messages": [["role": "user", "content": "x", "imagePaths": images]],
        ]) == .failure(.tooManyImages(AgentPluginAIMedia.maximumImages + 1)))
        let videos = (0...AgentPluginAIMedia.maximumVideos).map { "/\($0).mp4" }
        #expect(AgentPluginAIRequestValidator.request(from: [
            "messages": [["role": "user", "content": "x", "videoPaths": videos]],
        ]) == .failure(.tooManyVideos(AgentPluginAIMedia.maximumVideos + 1)))
        #expect(AgentPluginAIRequestValidator.request(from: [
            "system": "s",
            "messages": [["role": "assistant", "content": "x", "imagePaths": ["/a.png"]]],
        ]) == .failure(.mediaOnNonUserMessage))
    }

    @Test("路径钳制：只认插件生成目录里的普通文件")
    func clampRejectsEverythingOutsideTheMediaRoot() throws {
        let base = try temporaryRoot()
        let root = base.appendingPathComponent("generated-images", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("a.png")
        try writePNG(to: inside, width: 8, height: 8)
        let outside = base.appendingPathComponent("secret.png")
        try writePNG(to: outside, width: 8, height: 8)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(try AgentPluginAIMedia.clampedFileURL(path: inside.path, mediaRoot: root) == inside)
        #expect(throws: AgentPluginAIError.mediaOutsidePluginData(outside.path)) {
            try AgentPluginAIMedia.clampedFileURL(path: outside.path, mediaRoot: root)
        }
        let traversal = root.path + "/../secret.png"
        #expect(throws: AgentPluginAIError.mediaOutsidePluginData(traversal)) {
            try AgentPluginAIMedia.clampedFileURL(path: traversal, mediaRoot: root)
        }
        #expect(throws: AgentPluginAIError.mediaOutsidePluginData(link.path)) {
            try AgentPluginAIMedia.clampedFileURL(path: link.path, mediaRoot: root)
        }
        #expect(throws: AgentPluginAIError.mediaOutsidePluginData("a.png")) {
            try AgentPluginAIMedia.clampedFileURL(path: "a.png", mediaRoot: root)
        }
        #expect(throws: AgentPluginAIError.mediaOutsidePluginData(root.path)) {
            try AgentPluginAIMedia.clampedFileURL(path: root.path, mediaRoot: root)
        }
    }

    @Test("大图限边后重编码成 JPEG")
    func imagesAreDownscaledToJPEG() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("big.png")
        try writePNG(to: url, width: 3_000, height: 2_000)
        let attachment = try AgentPluginAIMedia.imageAttachment(at: url)
        #expect(attachment.mimeType == "image/jpeg")
        let data = try #require(attachment.inlineImageData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= AgentPluginAIMedia.maximumImagePixels)
    }

    @Test("不是图片的文件报 unreadableMedia，而不是发一个空附件")
    func garbageImageIsRejected() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: url)
        #expect(throws: AgentPluginAIError.unreadableMedia("fake.png")) {
            try AgentPluginAIMedia.imageAttachment(at: url)
        }
    }

    @Test("视频按时间均匀抽帧，时间点落在每段中点")
    func videoFramesAreEvenlySpaced() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("clip.mp4")
        try await writeVideo(to: url)
        let frames = try await AgentPluginAIMedia.videoFrames(at: url, count: 4)
        #expect(frames.count == 4)
        #expect(frames.map(\.seconds) == [0.25, 0.75, 1.25, 1.75])
        #expect(frames.allSatisfy { $0.attachment.mimeType == "image/jpeg" && $0.attachment.inlineImageData != nil })
    }

    @Test("解不出画面的视频报错")
    func garbageVideoIsRejected() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("fake.mp4")
        try Data("not a video".utf8).write(to: url)
        await #expect(throws: AgentPluginAIError.unreadableMedia("fake.mp4")) {
            _ = try await AgentPluginAIMedia.videoFrames(at: url)
        }
    }

    @Test("桥版本与能力清单分别宣告 ai.images 与 ai.videos")
    func bridgeAdvertisesMedia() {
        #expect(AgentPluginPageBridge.capabilities.contains("ai.images"))
        #expect(AgentPluginPageBridge.capabilities.contains("ai.videos"))
        // 2.6.0 起才有媒体；之后加别的能力只会再往上升
        #expect(AgentPluginPageBridge.version != "2.5.0")
    }
}
