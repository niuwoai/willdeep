//
//  SomeIMImageGenerationRequestTests.swift
//  WillDeepTests
//
//  `/images/generations` 的请求体：nano-banana 系要额外带 `aspect_ratio`，
//  gpt-image 系保持原样。见 `SomeIMImageGenerationRequest` 顶部的说明。
//

import Foundation
import Testing
@testable import WillDeep

struct SomeIMImageGenerationRequestTests {
    @Test("size 按约分结果换成比例", arguments: [
        ("1024x1024", "1:1"),
        ("1536x1024", "3:2"),
        ("1024x1536", "2:3"),
        ("1080x1920", "9:16"),
        ("1080x1440", "3:4"),
        ("1920x1080", "16:9"),
        ("1024X1536", "2:3"),
        (" 1024 x 1536 ", "2:3"),
    ])
    func aspectRatioFromSize(size: String, expected: String) {
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: size) == expected)
    }

    @Test("约分后不在表里的尺寸贴到最近的一档，而不是送一个上游不认的值")
    func aspectRatioSnapsToNearestSupported() {
        // 7:4 = 1.75，最近的是 16:9（1.78）。
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: "1792x1024") == "16:9")
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: "1024x1792") == "9:16")
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: "2560x1080") == "21:9")
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: "1000x1001") == "1:1")
    }

    @Test("解析不了的 size 不给比例", arguments: ["", "auto", "1024", "0x1024", "-1x10", "axb", "1024x1024x2"])
    func aspectRatioRejectsUnparsableSize(size: String) {
        #expect(SomeIMImageGenerationRequest.aspectRatio(forSize: size) == nil)
    }

    /// 插件白名单里的每一档都必须**精确**对上一个比例，不能靠贴近。往
    /// `allowedSizes` 里加了新尺寸却忘了它在 nano-banana 上出不来，这里会红。
    @Test("插件白名单里的每个尺寸都精确对应一个支持的比例")
    func everyPluginSizeMapsExactly() throws {
        for size in AgentPluginImageRequest.allowedSizes {
            let parts = size.split(separator: "x").compactMap { Int($0) }
            try #require(parts.count == 2, "\(size)")
            let label = try #require(SomeIMImageGenerationRequest.aspectRatio(forSize: size), "\(size)")
            let entry = try #require(
                SomeIMImageGenerationRequest.supportedAspectRatios.first { $0.label == label }
            )
            #expect(parts[0] * entry.height == parts[1] * entry.width, "\(size) → \(label) 不是精确比例")
        }
    }

    @Test("gpt-image / dall-e 家族的判定")
    func openAIImageFamily() {
        for model in ["gpt-image-2", "gpt-image-1", "GPT-Image-1.5", "gpt4-image", "dall-e-3", " gpt-image-2 "] {
            #expect(SomeIMImageGenerationRequest.isOpenAIImageFamily(model), "\(model)")
        }
        for model in ["nano-banana-2", "nano-banana-pro", "gemini-2.5-flash-image", "seedream-4", ""] {
            #expect(!SomeIMImageGenerationRequest.isOpenAIImageFamily(model), "\(model)")
        }
    }

    @Test("nano-banana-2 竖图：size 照送，并带上 aspect_ratio 2:3")
    func nanoBananaBodyCarriesAspectRatio() {
        let body = SomeIMImageGenerationRequest.body(
            model: "nano-banana-2",
            prompt: "竖屏首帧",
            size: "1024x1536"
        )
        #expect(Set(body.keys) == ["model", "prompt", "size", "aspect_ratio"])
        #expect(body["model"] as? String == "nano-banana-2")
        #expect(body["size"] as? String == "1024x1536")
        #expect(body["aspect_ratio"] as? String == "2:3")
    }

    @Test("gpt-image-2 的 body 与改动前逐键一致，不带 aspect_ratio")
    func gptImageBodyUnchanged() {
        let body = SomeIMImageGenerationRequest.body(
            model: "gpt-image-2",
            prompt: "竖屏首帧",
            size: "1024x1536"
        )
        #expect(Set(body.keys) == ["model", "prompt", "size"])
        #expect(body["size"] as? String == "1024x1536")
    }

    @Test("解析不了的 size 不带 aspect_ratio，交给上游默认")
    func unparsableSizeOmitsAspectRatio() {
        let body = SomeIMImageGenerationRequest.body(model: "nano-banana-2", prompt: "p", size: "auto")
        #expect(body["aspect_ratio"] == nil)
        #expect(body["size"] as? String == "auto")
    }

    @Test("参照图四个键照旧都带上")
    func referenceImageKeys() {
        let urls = ["https://img.example/a.png", "https://img.example/b.png"]
        let body = SomeIMImageGenerationRequest.body(
            model: "nano-banana-2",
            prompt: "p",
            size: "1080x1920",
            referenceImageURLs: urls
        )
        #expect(body["aspect_ratio"] as? String == "9:16")
        #expect(body["image_url"] as? String == urls[0])
        #expect(body["reference_image_url"] as? String == urls[0])
        #expect(body["image_urls"] as? [String] == urls)
        #expect(body["reference_image_urls"] as? [String] == urls)
    }

    /// 出口测试：纯函数对了、`generateImage` 没接上时上面几项照样全绿。这里走
    /// 真实的 `SomeIMClient.generateImage`，在网络层截下实际发出去的 body。
    @Test("generateImage 实际发出的 body：nano-banana-2 带比例，gpt-image-2 不带", arguments: [
        ("nano-banana-2", "2:3" as String?),
        ("gpt-image-2", nil),
    ])
    func generateImageSendsBuiltBody(model: String, expectedRatio: String?) async throws {
        let stub = ImageRequestStubSession()
        defer { stub.tearDown() }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-image-request-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let image = try await SomeIMClient.generateImage(
            prompt: "竖屏首帧",
            size: "1024x1536",
            model: model,
            outputDirectory: outputDirectory,
            settings: SomeIMIntegrationSettings(enabled: true, baseURL: "https://fixture.invalid/v1"),
            apiKey: "test-placeholder",
            session: stub.session
        )

        let recorded = try #require(stub.recordedBodies.first)
        #expect(stub.recordedPaths == ["/v1/images/generations"])
        let body = try #require(try JSONSerialization.jsonObject(with: recorded) as? [String: Any])
        #expect(body["model"] as? String == model)
        #expect(body["size"] as? String == "1024x1536")
        #expect(body["aspect_ratio"] as? String == expectedRatio)
        #expect(image.model == model)
        #expect(FileManager.default.fileExists(atPath: image.fileURL.path))
    }
}

/// 按 token 路由的桩：套件里的用例并发跑，共用一个静态 handler 会串台
/// （`AgentToolResultImageEncodingTests` 里 `StubURLProtocol` 的注释记过这事）。
private final class ImageRequestStubSession: @unchecked Sendable {
    let session: URLSession
    private let token = UUID().uuidString

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestStubURLProtocol.self]
        configuration.httpAdditionalHeaders = [ImageRequestStubURLProtocol.tokenHeader: token]
        session = URLSession(configuration: configuration)
        ImageRequestStubURLProtocol.register(token)
    }

    var recordedBodies: [Data] { ImageRequestStubURLProtocol.recorded(for: token).map(\.body) }
    var recordedPaths: [String] { ImageRequestStubURLProtocol.recorded(for: token).map(\.path) }

    func tearDown() {
        ImageRequestStubURLProtocol.unregister(token)
        session.invalidateAndCancel()
    }
}

private final class ImageRequestStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let tokenHeader = "X-WillDeep-Image-Stub-Token"
    /// 1x1 透明 PNG。
    private static let pixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private static let lock = NSLock()
    private static var records: [String: [(path: String, body: Data)]] = [:]

    static func register(_ token: String) { lock.withLock { records[token] = [] } }
    static func unregister(_ token: String) { lock.withLock { records[token] = nil } }
    static func recorded(for token: String) -> [(path: String, body: Data)] {
        lock.withLock { records[token] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.tokenHeader),
              let url = request.url,
              Self.lock.withLock({ Self.records[token] != nil }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Self.bodyData(from: request)
        Self.lock.withLock { Self.records[token]?.append((path: url.path, body: body)) }
        let payload = Data(#"{"data":[{"b64_json":"\#(Self.pixelPNGBase64)"}]}"#.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 交给 URLProtocol 时常把 `httpBody` 换成流，两种都要认。
    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
