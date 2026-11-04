import Foundation
import Testing
import Darwin
#if canImport(WillDeep)
@testable import WillDeep
#else
@testable import MagpieIntegrationCore
#endif

@Suite("Magpie 只读连接契约")
struct AgentMagpieIntegrationTests {
    typealias Integration = AgentMagpieIntegration

    private func connected(_ extra: String = "", model: String = "mock/model-a", url: String = "http://127.0.0.1:3425/v1") -> Data {
        Data("{\"schema_version\":1,\"client_id\":\"willdeep\",\"enabled\":true,\"base_url\":\"\(url)\",\"client_marker\":\"magpie-willdeep\",\"model\":\"\(model)\"\(extra)}".utf8)
    }

    @Test("读取 canonical 原始 fixture", .enabled(if: ProcessInfo.processInfo.environment["WILLDEEP_MAGPIE_FIXTURES"] != nil))
    func sharedFixtures() throws {
        struct Manifest: Decodable {
            struct Case: Decodable { let id: String; let client_id: String; let contents: String?; let expected: String }
            let desktop_provider_uuid: String
            let cases: [Case]
        }
        let path = try #require(ProcessInfo.processInfo.environment["WILLDEEP_MAGPIE_FIXTURES"])
        let fixture = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(fixture.desktop_provider_uuid == Integration.providerEntryID.uuidString)
        for item in fixture.cases {
            // Do not deserialize/re-encode contents: duplicate keys must survive.
            let state = Integration.parse(item.contents.map { Data($0.utf8) }, clientID: item.client_id)
            let result: String
            switch state { case .connected: result = "connected"; case .disconnected: result = "disconnected"; case .invalid: result = "invalid" }
            #expect(result == item.expected, "fixture: \(item.id)")
        }
    }

    @Test("所有断开形态均不应用 model")
    func disconnectedShapes() {
        for raw in ["{}", #"{"enabled":false}"#, #"{"model":"native/model"}"#] {
            #expect(Integration.parse(Data(raw.utf8)) == .disconnected)
        }
        #expect(Integration.parse(nil) == .disconnected)
    }

    @Test("合法连接保留完整模型和未知元数据")
    func connectedMetadata() throws {
        guard case .connected(let connection) = Integration.parse(connected(model: "vendor/model-a")) else { Issue.record("应连接"); return }
        #expect(connection.model == "vendor/model-a")
        #expect(connection.contextWindow == nil)
        #expect(connection.maximumOutputTokens == nil)
        guard case .connected(let bounded) = Integration.parse(connected(",\"context_window\":4000,\"max_output_tokens\":4000")) else { Issue.record("边界应合法"); return }
        #expect(bounded.contextWindow == 4000)
        #expect(bounded.maximumOutputTokens == 4000)
    }

    @Test("非法字段不因 disabled 被忽略", arguments: [
        #"{"enabled":false,"unknown":null}"#, #"{"enabled":false,"schema_version":2}"#,
        #"{"enabled":false,"client_id":"willdeep-cli"}"#, #"{"enabled":false,"model":0}"#,
        #"{"enabled":false,"enabled":true}"#, #"{"enabled":false,"enabled":false}"#,
        #"{"enabled":false,"context_window":4000.0}"#, #"{"enabled":false,"max_output_tokens":1e2}"#,
        #"{"enabled":false,"client_marker":"not-public"}"#, #"{"enabled":false,"model":"\u0085"}"#,
        #"{"model":"mock/line\nmodel"}"#, #"{"model":"   "}"#, #"{"enabled":null}"#,
        #"{"enabled":{},"model":"a"}"#, #"{"model":[]}"#, #"[]"#
    ])
    func rejectsInvalid(raw: String) {
        guard case .invalid(let failure) = Integration.parse(Data(raw.utf8)) else { Issue.record("应拒绝"); return }
        #expect(!failure.retryable)
    }

    @Test("字段错误优先于尾部截断")
    func immediateFailures() {
        for raw in [#"{"unknown":"#, #"{"schema_version":2,"model":"#, #"{"enabled":[],"model":"#] {
            guard case .invalid(let error) = Integration.parse(Data(raw.utf8)) else { Issue.record("应拒绝"); continue }
            #expect(!error.retryable)
        }
        guard case .invalid(let error) = Integration.parse(Data("{\"enabled\":".utf8)) else { Issue.record("应识别截断"); return }
        #expect(error.retryable)
    }

    @Test("模型使用 UTF-8 字节上限并拒绝 C0/C1")
    func modelBounds() {
        #expect(throws: Never.self) { try Integration.validateModel(String(repeating: "界", count: 341)) }
        #expect(throws: Integration.Failure.self) { try Integration.validateModel(String(repeating: "界", count: 342)) }
        #expect(throws: Integration.Failure.self) { try Integration.validateModel("a\u{009F}b") }
        #expect(throws: Integration.Failure.self) { try Integration.validateModel("a\u{0000}b") }
        #expect(throws: Integration.Failure.self) { try Integration.validateModel("a\u{007F}b") }
    }

    @Test("元数据必须为范围内的整数 token")
    func metadataBounds() {
        for suffix in [",\"context_window\":3999", ",\"context_window\":1048577", ",\"max_output_tokens\":0",
                       ",\"max_output_tokens\":1048577", ",\"context_window\":8192,\"max_output_tokens\":8193",
                       ",\"context_window\":4000.0", ",\"context_window\":4e3", ",\"max_output_tokens\":true"] {
            guard case .invalid = Integration.parse(connected(suffix)) else { Issue.record("应拒绝元数据"); continue }
        }
        #expect(Integration.parse(Data(repeating: 32, count: Integration.maximumFileBytes + 1)) == .invalid(.init(code: .size)))
    }

    @Test("严格回环 URL 语法", arguments: [
        "http://127.1/v1", "http://127.000.0.1/v1", "http://127.0.0.256/v1", "http://2130706433/v1",
        "HTTP://127.0.0.1/v1", "http://LOCALHOST/v1", "http://localhost./v1", "http://localhost:0/v1",
        "http://localhost:65536/v1", "http://localhost:/v1", "http://localhost:+1/v1", "http://localhost/v1/",
        "http://localhost/v1?", "http://localhost/v1#", "http://u@localhost/v1", "https://example.com/v1",
        "http://[::ffff:127.0.0.1]/v1", "http://127.0.0.1/%76%31", "http://127.0.0.1/v1\n"
    ])
    func invalidURLs(url: String) {
        #expect(throws: Integration.Failure.self) { try Integration.validatedBaseURL(url) }
    }

    @Test("localhost 固定回环并保留端口")
    func pinsLocalhost() throws {
        #expect(try Integration.validatedBaseURL("http://localhost:4567/v1") == "http://127.0.0.1:4567/v1")
        #expect(try Integration.validatedBaseURL("https://[::1]:65535/v1") == "https://[::1]:65535/v1")
        #expect(try Integration.validatedBaseURL("http://127.255.255.255/v1") == "http://127.255.255.255/v1")
    }

    @Test("文件安全边界和仅写私有支持标记")
    func fileBoundaries() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(await Integration.read(home: home) == .disconnected)
        try await Integration.writeSupportMarker(home: home, version: "test-version")
        let directory = connectionDirectory(home)
        let connection = directory.appendingPathComponent("connection.json")
        #expect(!FileManager.default.fileExists(atPath: connection.path))
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("client.json"))) as? [String: Any]
        #expect(marker?["client_id"] as? String == "willdeep")
        #expect(marker?["version"] as? String == "test-version")
        try connected().write(to: connection)
        guard case .connected = await Integration.read(home: home) else { Issue.record("应读取普通文件"); return }
        try FileManager.default.removeItem(at: connection)
        try FileManager.default.createSymbolicLink(at: connection, withDestinationURL: directory.appendingPathComponent("client.json"))
        #expect(await Integration.read(home: home) == .invalid(.init(code: .file)))
        try FileManager.default.removeItem(at: connection)
        try FileManager.default.createDirectory(at: connection, withIntermediateDirectories: false)
        #expect(await Integration.read(home: home) == .invalid(.init(code: .file)))
        try FileManager.default.removeItem(at: connection)
        #expect(mkfifo(connection.path, 0o600) == 0)
        #expect(await Integration.read(home: home) == .invalid(.init(code: .file)))
        try FileManager.default.removeItem(at: connection)
        try Data(repeating: 32, count: Integration.maximumFileBytes + 1).write(to: connection)
        #expect(await Integration.read(home: home) == .invalid(.init(code: .size)))
    }

    @Test("符号链接目录被拒绝")
    func symlinkDirectory() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".willdeep"), withDestinationURL: elsewhere)
        #expect(await Integration.read(home: home) == .invalid(.init(code: .file)))
    }

    @Test("截断后异步重试一次可读取原子替换结果")
    func retriesTruncatedWrite() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = connectionDirectory(home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("connection.json")
        try Data("{\"enabled\":".utf8).write(to: file)
        let data = connected(model: "mock/after-retry")
        let replacement = Task.detached {
            try await Task.sleep(nanoseconds: 30_000_000)
            try data.write(to: file, options: .atomic)
        }
        let state = await Integration.read(home: home)
        try await replacement.value
        guard case .connected(let result) = state else { Issue.record("重试应成功"); return }
        #expect(result.model == "mock/after-retry")
        try Data("{\"enabled\":".utf8).write(to: file)
        guard case .invalid(let failure) = await Integration.read(home: home) else { Issue.record("二次截断必须失败"); return }
        #expect(failure.code == .truncated)
        try Data("{}".utf8).write(to: file, options: .atomic)
        #expect(await Integration.read(home: home) == .disconnected)
    }

    @Test("无代理且不继承 Cookie/凭据存储")
    func transportIsolation() {
        let session = AgentMagpieTransport.session()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            #expect(configuration.connectionProxyDictionary?[key] as? Int == 0)
        }
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test("真实回环 HTTP 请求不跟随重定向")
    func blocksRedirects() async throws {
        let upstream = try MagpieFakeUpstream(responses: ["HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/redirect-target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"])
        defer { upstream.stop() }
        let session = AgentMagpieTransport.session(requestTimeout: 2, resourceTimeout: 3)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: upstream.baseURL + "/models")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(upstream.requests.count == 1)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("magpie-tests-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func connectionDirectory(_ home: URL) -> URL {
        Integration.directoryComponents.reduce(home) { $0.appendingPathComponent($1) }
    }
}
