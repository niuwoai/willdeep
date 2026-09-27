//
//  AgentPluginMCPGatewayTests.swift
//  XeditTests
//
//  插件 MCP 网关的请求解析、准入、路由与 JSON-RPC 分派。宿主和转发器都是
//  注入的假实现：不拉起任何插件进程，不连任何网络；插件数据目录指向每个
//  用例自己的临时目录，不碰 ~/Library/Application Support/WillDeep。
//

import Foundation
import Testing
@testable import WillDeep

// MARK: - 测试替身

final class GatewayFakeHost: AgentPluginMCPGatewayHost, @unchecked Sendable {
    private let lock = NSLock()
    private var _servers: [AgentPluginMCPGatewayServer]
    private var _ensureCalls: [String] = []
    private var _relayCalls: [(method: String, params: Data)] = []
    var ensureError: Error?
    var relayResult: Result<String, Error> = .success(#"{"tools":[]}"#)

    init(servers: [AgentPluginMCPGatewayServer] = [GatewayFakeHost.videoStudio]) {
        _servers = servers
    }

    static let videoStudio = AgentPluginMCPGatewayServer(
        pluginID: "willdeep-video-studio",
        serverName: "video-studio",
        pluginVersion: "0.30.0-rc1"
    )

    var servers: [AgentPluginMCPGatewayServer] {
        get { lock.withLock { _servers } }
        set { lock.withLock { _servers = newValue } }
    }
    var ensureCalls: [String] { lock.withLock { _ensureCalls } }
    var relayCalls: [(method: String, params: Data)] { lock.withLock { _relayCalls } }

    func activeServers() -> [AgentPluginMCPGatewayServer] { servers }

    func ensureStarted(_ server: AgentPluginMCPGatewayServer) async throws {
        lock.withLock { _ensureCalls.append("\(server.pluginID)/\(server.serverName)") }
        if let ensureError { throw ensureError }
    }

    func relay(_ server: AgentPluginMCPGatewayServer, method: String, paramsJSON: Data) async throws -> String {
        lock.withLock { _relayCalls.append((method, paramsJSON)) }
        return try relayResult.get()
    }
}

final class GatewayFakeForwarder: AgentPluginMCPGatewayForwarder, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<AgentPluginMCPGatewayForwardResult, Error>]
    private var _calls: [(url: URL, token: String, body: Data)] = []
    /// 每次调用前执行，用来模拟「插件在两次尝试之间重启、改写了 mcp-http.json」。
    var beforeEachCall: (@Sendable (Int) -> Void)?

    init(_ queued: [Result<AgentPluginMCPGatewayForwardResult, Error>] = []) {
        self.queued = queued
    }

    var calls: [(url: URL, token: String, body: Data)] { lock.withLock { _calls } }

    func forward(body: Data, to endpoint: AgentPluginMCPGatewayEndpoint) async throws -> AgentPluginMCPGatewayForwardResult {
        let index = lock.withLock { () -> Int in
            _calls.append((endpoint.url, endpoint.token, body))
            return _calls.count - 1
        }
        beforeEachCall?(index)
        let next: Result<AgentPluginMCPGatewayForwardResult, Error> = lock.withLock {
            queued.isEmpty ? .failure(AgentPluginMCPGatewayForwardError.failed("no queued response")) : queued.removeFirst()
        }
        return try next.get()
    }
}

/// 每个用例一个临时目录，用完即删。
struct GatewayTempDirectory {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-mcp-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var pluginDataRoot: URL { root.appendingPathComponent("plugin-data", isDirectory: true) }

    var paths: AgentPluginMCPGatewayPaths {
        AgentPluginMCPGatewayPaths(
            discoveryFileURL: root.appendingPathComponent("mcp-gateway.json"),
            pluginDataRoot: pluginDataRoot
        )
    }

    /// `extra` 是插件 0.32.0-rc2 起附带的 `host` / `pid` / `parentPID` 等字段。
    func writeEndpoint(pluginID: String, url: String, token: String, extra: [String: Any] = [:]) throws {
        let directory = pluginDataRoot.appendingPathComponent(pluginID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = extra.merging(["url": url, "token": token]) { _, fixed in fixed }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent("mcp-http.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum GatewayTestSupport {
    static let token = String(repeating: "ab", count: 32)
    static let path = "/plugins/willdeep-video-studio/video-studio/mcp"

    static func request(
        method: String = "POST",
        path: String = GatewayTestSupport.path,
        headers: [String: String] = [:],
        body: String = ""
    ) -> AgentPluginMCPGatewayHTTPRequest {
        var merged = [
            "host": "127.0.0.1:47831",
            "authorization": "Bearer \(token)"
        ]
        for (key, value) in headers { merged[key.lowercased()] = value }
        return AgentPluginMCPGatewayHTTPRequest(method: method, target: path, headers: merged, body: Data(body.utf8))
    }

    static func withoutHeader(_ name: String, _ request: AgentPluginMCPGatewayHTTPRequest) -> AgentPluginMCPGatewayHTTPRequest {
        var headers = request.headers
        headers.removeValue(forKey: name)
        return AgentPluginMCPGatewayHTTPRequest(method: request.method, target: request.target, headers: headers, body: request.body)
    }

    static func router(
        host: GatewayFakeHost = GatewayFakeHost(),
        forwarder: GatewayFakeForwarder = GatewayFakeForwarder(),
        temp: GatewayTempDirectory,
        gatewayProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> AgentPluginMCPGatewayRouter {
        var router = AgentPluginMCPGatewayRouter(
            token: token,
            host: host,
            forwarder: forwarder,
            endpoints: AgentPluginMCPGatewayEndpointReader(
                pluginDataRoot: temp.pluginDataRoot,
                gatewayProcessID: gatewayProcessID
            )
        )
        router.makeSessionID = { "session-fixed" }
        return router
    }

    static func json(_ response: AgentPluginMCPGatewayHTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    }
}

// MARK: - HTTP 解析

@Suite("插件 MCP 网关：HTTP 请求解析")
struct AgentPluginMCPGatewayHTTPParserTests {
    private func parse(_ raw: String) -> AgentPluginMCPGatewayHTTPParser.Outcome {
        AgentPluginMCPGatewayHTTPParser.parse(Data(raw.utf8))
    }

    @Test("完整的 POST：header 名转小写、query 不进 path、请求体按 Content-Length 截取")
    func parsesCompletePost() throws {
        let raw = "POST /plugins/p/s/mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        guard case .request(let request) = parse(raw) else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/plugins/p/s/mcp")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.headers["host"] == "127.0.0.1:1")
        #expect(request.body == Data("{}".utf8))
    }

    @Test("header 没收完、请求体没收完时都要继续读")
    func waitsForMoreBytes() {
        #expect(parse("POST / HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"") == .incomplete)
    }

    @Test("POST 不带 Content-Length、或用分块编码，回 411")
    func requiresContentLength() {
        #expect(parse("POST / HTTP/1.1\r\nHost: x\r\n\r\n") == .reject(status: 411))
        #expect(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n") == .reject(status: 411))
    }

    @Test("GET 不带 Content-Length 也能解析（留给路由回 405）")
    func getWithoutBodyParses() {
        guard case .request(let request) = parse("GET /x HTTP/1.1\r\nHost: x\r\n\r\n") else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.body.isEmpty)
    }

    @Test("请求体超过 8 MB 在读体之前就回 413")
    func rejectsOversizedBody() {
        let length = AgentPluginMCPGatewayHTTPParser.maximumBodyBytes + 1
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n") == .reject(status: 413))
    }

    @Test("请求行不合格、两个不一致的 Content-Length、非数字长度都回 400")
    func rejectsMalformedRequests() {
        #expect(parse("POST\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST relative HTTP/1.1\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/2\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nno-colon-here\r\n\r\n") == .reject(status: 400))
    }

    @Test("header 迟迟不结束且超过上限，回 431 而不是无限攒着")
    func rejectsEndlessHeaders() {
        let raw = "POST / HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: AgentPluginMCPGatewayHTTPParser.maximumHeaderBytes + 1)
        #expect(parse(raw) == .reject(status: 431))
    }

    @Test("响应序列化带 Content-Length 和 Connection: close")
    func serializesResponse() {
        let response = AgentPluginMCPGatewayHTTPResponse.json(status: 200, body: Data("{}".utf8))
        let text = String(data: response.serialized(), encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}

// MARK: - 准入与路由

@Suite("插件 MCP 网关：鉴权、Host、Origin 与路由")
struct AgentPluginMCPGatewayAdmissionTests {
    private let token = GatewayTestSupport.token

    @Test("没带或带错 Bearer token 回 401")
    func rejectsMissingOrWrongToken() {
        let missing = GatewayTestSupport.withoutHeader("authorization", GatewayTestSupport.request())
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: missing, token: token)?.status == 401)
        let wrong = GatewayTestSupport.request(headers: ["Authorization": "Bearer \(String(repeating: "cd", count: 32))"])
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: wrong, token: token)?.status == 401)
        let basic = GatewayTestSupport.request(headers: ["Authorization": "Basic \(token)"])
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: basic, token: token)?.status == 401)
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: missing, token: token)?.header("WWW-Authenticate") == "Bearer")
    }

    @Test("token 正确、Host 是本机时放行；Bearer 大小写不敏感")
    func admitsValidRequests() {
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: GatewayTestSupport.request(), token: token) == nil)
        let lowerScheme = GatewayTestSupport.request(headers: ["Authorization": "bearer \(token)", "Host": "localhost:47831"])
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: lowerScheme, token: token) == nil)
        let bareHost = GatewayTestSupport.request(headers: ["Host": "127.0.0.1"])
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: bareHost, token: token) == nil)
    }

    @Test("Host 不是 127.0.0.1 / localhost 回 403（防 DNS rebinding），先于鉴权")
    func rejectsForeignHost() {
        for host in ["evil.example:47831", "127.0.0.2:47831", "[::1]:47831", "localhost.evil.example", "127.0.0.1:abc"] {
            let request = GatewayTestSupport.request(headers: ["Host": host])
            #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: request, token: token)?.status == 403, "\(host)")
        }
        let noHost = GatewayTestSupport.withoutHeader("host", GatewayTestSupport.request())
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: noHost, token: token)?.status == 403)
        let wrongTokenForeignHost = GatewayTestSupport.request(headers: ["Host": "evil.example", "Authorization": "Bearer x"])
        #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: wrongTokenForeignHost, token: token)?.status == 403)
    }

    @Test("带非本机 Origin 回 403；本机 Origin 放行")
    func checksOrigin() {
        for origin in ["https://evil.example", "null", "file://", "http://127.0.0.2:3000"] {
            let request = GatewayTestSupport.request(headers: ["Origin": origin])
            #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: request, token: token)?.status == 403, "\(origin)")
        }
        for origin in ["http://localhost:3000", "http://127.0.0.1:5173", "https://localhost"] {
            let request = GatewayTestSupport.request(headers: ["Origin": origin])
            #expect(AgentPluginMCPGatewayRouter.admissionFailure(for: request, token: token) == nil, "\(origin)")
        }
    }

    @Test("常量时间比较的结果与普通相等一致")
    func constantTimeEquality() {
        #expect(AgentPluginMCPGatewayRouter.constantTimeEquals("abc", "abc"))
        #expect(!AgentPluginMCPGatewayRouter.constantTimeEquals("abc", "abd"))
        #expect(!AgentPluginMCPGatewayRouter.constantTimeEquals("abc", "abcd"))
        #expect(!AgentPluginMCPGatewayRouter.constantTimeEquals("", "a"))
    }

    @Test("路由只认 /plugins/<pluginID>/<server>/mcp，段内可百分号编码，不许路径穿越")
    func parsesRoutes() {
        #expect(AgentPluginMCPGatewayRouter.route(path: GatewayTestSupport.path)?.pluginID == "willdeep-video-studio")
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/p/my%20server/mcp")?.serverName == "my server")
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/p/s") == nil)
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/p/s/mcp/extra") == nil)
        #expect(AgentPluginMCPGatewayRouter.route(path: "/mcp") == nil)
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/../s/mcp") == nil)
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/%2E%2E/s/mcp") == nil)
        #expect(AgentPluginMCPGatewayRouter.route(path: "/plugins/p/a%2Fb/mcp") == nil)
    }

    @Test("未知、未启用的插件或服务回 404；GET / DELETE 回 405 并带 Allow")
    func routesToKnownServersOnly() async {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let router = GatewayTestSupport.router(host: host, temp: temp)

        let unknownPlugin = await router.handle(GatewayTestSupport.request(path: "/plugins/other/video-studio/mcp", body: "{}"))
        #expect(unknownPlugin.response.status == 404)
        let unknownServer = await router.handle(GatewayTestSupport.request(path: "/plugins/willdeep-video-studio/nope/mcp", body: "{}"))
        #expect(unknownServer.response.status == 404)
        let badPath = await router.handle(GatewayTestSupport.request(path: "/", body: "{}"))
        #expect(badPath.response.status == 404)

        host.servers = []
        let disabled = await router.handle(GatewayTestSupport.request(body: "{}"))
        #expect(disabled.response.status == 404)

        host.servers = [GatewayFakeHost.videoStudio]
        for method in ["GET", "DELETE"] {
            let outcome = await router.handle(GatewayTestSupport.request(method: method))
            #expect(outcome.response.status == 405)
            #expect(outcome.response.header("Allow") == "POST")
        }
        #expect(host.ensureCalls.isEmpty)
    }

    @Test("鉴权失败不泄露插件是否存在：未知插件也先回 401")
    func authenticatesBeforeRouting() async {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let router = GatewayTestSupport.router(temp: temp)
        let request = GatewayTestSupport.request(
            path: "/plugins/other/x/mcp",
            headers: ["Authorization": "Bearer wrong"],
            body: "{}"
        )
        #expect(await router.handle(request).response.status == 401)
    }
}

// MARK: - JSON-RPC 分派

@Suite("插件 MCP 网关：JSON-RPC 分派、转发与中转")
struct AgentPluginMCPGatewayDispatchTests {
    private static let callBody = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drama.list","arguments":{}}}"#

    @Test("批量数组和非对象回 -32600，坏 JSON 回 -32700，都不拉起插件")
    func rejectsNonObjects() async {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let router = GatewayTestSupport.router(host: host, temp: temp)

        let batch = await router.handle(GatewayTestSupport.request(body: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#))
        #expect(batch.response.status == 400)
        #expect((GatewayTestSupport.json(batch.response)?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(GatewayTestSupport.json(batch.response)?["id"] is NSNull)

        let scalar = await router.handle(GatewayTestSupport.request(body: "42"))
        #expect((GatewayTestSupport.json(scalar.response)?["error"] as? [String: Any])?["code"] as? Int == -32600)

        let broken = await router.handle(GatewayTestSupport.request(body: "{not json"))
        #expect((GatewayTestSupport.json(broken.response)?["error"] as? [String: Any])?["code"] as? Int == -32700)

        let noMethod = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","id":3}"#))
        #expect((GatewayTestSupport.json(noMethod.response)?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(host.ensureCalls.isEmpty)
    }

    @Test("initialize 由网关自己应答：回请求的协议版本、tools 能力、插件名与版本和 Mcp-Session-Id")
    func answersInitialize() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder()
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)
        let body = #"{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{"sampling":{}},"clientInfo":{"name":"claude-code","version":"2"}}}"#

        let outcome = await router.handle(GatewayTestSupport.request(body: body))
        #expect(outcome.response.status == 200)
        #expect(outcome.response.header("Mcp-Session-Id") == "session-fixed")
        #expect(outcome.response.header("Content-Type") == "application/json")
        let json = try #require(GatewayTestSupport.json(outcome.response))
        #expect(json["jsonrpc"] as? String == "2.0")
        #expect(json["id"] as? String == "init-1")
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?.keys.sorted() == ["tools"])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "willdeep-video-studio/video-studio")
        #expect(serverInfo["version"] as? String == "0.30.0-rc1")
        // 不转给插件：客户端的能力声明碰不到插件。
        #expect(host.ensureCalls.isEmpty)
        #expect(forwarder.calls.isEmpty)
        #expect(host.relayCalls.isEmpty)
    }

    @Test("initialize 没带 protocolVersion 时回 2025-06-18")
    func initializeDefaultsProtocolVersion() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let router = GatewayTestSupport.router(temp: temp)
        let outcome = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        let result = try #require(GatewayTestSupport.json(outcome.response)?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    @Test("通知（含 notifications/initialized）回 202、空体，不转发；客户端发来的响应也回 202")
    func acceptsNotifications() async {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder()
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let initialized = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        #expect(initialized.response.status == 202)
        #expect(initialized.response.body.isEmpty)
        let cancelled = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        #expect(cancelled.response.status == 202)
        let clientResponse = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","id":"s1","result":{}}"#))
        #expect(clientResponse.response.status == 202)
        #expect(host.ensureCalls.isEmpty)
        #expect(forwarder.calls.isEmpty)
    }

    @Test("ping 由网关直接回 {}")
    func answersPing() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let router = GatewayTestSupport.router(host: host, temp: temp)
        let outcome = await router.handle(GatewayTestSupport.request(body: #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#))
        let json = try #require(GatewayTestSupport.json(outcome.response))
        #expect(json["id"] as? Int == 5)
        #expect((json["result"] as? [String: Any])?.isEmpty == true)
        #expect(host.ensureCalls.isEmpty)
    }

    @Test("插件公布了 HTTP 入口：先确保已启动，再把原始请求体带插件自己的 token 原样转发，响应原样回")
    func forwardsToPluginEndpoint() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50123/mcp", token: "plugin-token")
        let host = GatewayFakeHost()
        let pluginResponse = Data(#"{"jsonrpc":"2.0","id":7,"result":{"content":[]}}"#.utf8)
        let forwarder = GatewayFakeForwarder([.success(.init(status: 200, contentType: "application/json", body: pluginResponse))])
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .forwarded)
        #expect(outcome.response.status == 200)
        #expect(outcome.response.body == pluginResponse)
        #expect(host.ensureCalls == ["willdeep-video-studio/video-studio"])
        let call = try #require(forwarder.calls.first)
        #expect(call.url.absoluteString == "http://127.0.0.1:50123/mcp")
        #expect(call.token == "plugin-token")
        #expect(call.body == Data(Self.callBody.utf8))
        #expect(host.relayCalls.isEmpty)
    }

    @Test("没有 mcp-http.json：经宿主 stdio 客户端中转，结果包成 JSON-RPC 响应并保留 id")
    func relaysWithoutEndpoint() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        host.relayResult = .success(#"{"content":[{"type":"text","text":"ok"}]}"#)
        let forwarder = GatewayFakeForwarder()
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let body = #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"drama.list","arguments":{"limit":2}}}"#
        let outcome = await router.handle(GatewayTestSupport.request(body: body))
        #expect(outcome.disposition == .relayed)
        #expect(forwarder.calls.isEmpty)
        let json = try #require(GatewayTestSupport.json(outcome.response))
        #expect(json["id"] as? String == "abc")
        #expect(json["jsonrpc"] as? String == "2.0")
        let content = try #require((json["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "ok")
        let relay = try #require(host.relayCalls.first)
        #expect(relay.method == "tools/call")
        let params = try #require(try JSONSerialization.jsonObject(with: relay.params) as? [String: Any])
        #expect(params["name"] as? String == "drama.list")
        #expect((params["arguments"] as? [String: Any])?["limit"] as? Int == 2)
    }

    @Test("连接被拒：重读一次 mcp-http.json 用新地址重试，成功就不走中转")
    func retriesAfterRereadingEndpoint() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50001/mcp", token: "old")
        let host = GatewayFakeHost()
        let ok = Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)
        let forwarder = GatewayFakeForwarder([
            .failure(AgentPluginMCPGatewayForwardError.connectionRefused),
            .success(.init(status: 200, contentType: "application/json", body: ok))
        ])
        // 第一次尝试时插件已经重启并改写了连接文件。
        forwarder.beforeEachCall = { index in
            if index == 0 {
                try? temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50002/mcp", token: "new")
            }
        }
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .forwarded)
        #expect(outcome.response.body == ok)
        #expect(forwarder.calls.map(\.url.port) == [50001, 50002])
        #expect(forwarder.calls.map(\.token) == ["old", "new"])
        #expect(host.relayCalls.isEmpty)
    }

    @Test("重读后仍连不上：退回 stdio 中转")
    func fallsBackToRelayWhenStillRefused() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50001/mcp", token: "t")
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder([
            .failure(AgentPluginMCPGatewayForwardError.connectionRefused),
            .failure(AgentPluginMCPGatewayForwardError.connectionRefused)
        ])
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .relayed)
        #expect(forwarder.calls.count == 2)
        #expect(host.relayCalls.count == 1)
        #expect(GatewayTestSupport.json(outcome.response)?["result"] != nil)
    }

    @Test("插件入口回 401（token 已换）按没送到处理，重读后再试")
    func treatsPluginUnauthorizedAsNotDelivered() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50001/mcp", token: "t")
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder([
            .success(.init(status: 401, contentType: "application/json", body: Data(#"{"error":"Unauthorized."}"#.utf8))),
            .success(.init(status: 401, contentType: "application/json", body: Data(#"{"error":"Unauthorized."}"#.utf8)))
        ])
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)
        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .relayed)
        #expect(outcome.response.status == 200)
        #expect(host.relayCalls.count == 1)
    }

    @Test("转发中途失败（可能已经在执行）不重发、不中转，回 -32603")
    func doesNotReplayAfterAmbiguousFailure() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50001/mcp", token: "t")
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder([.failure(AgentPluginMCPGatewayForwardError.failed("timed out"))])
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(forwarder.calls.count == 1)
        #expect(host.relayCalls.isEmpty)
        let error = try #require(GatewayTestSupport.json(outcome.response)?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32603)
        #expect((error["message"] as? String)?.contains("timed out") == true)
        #expect(GatewayTestSupport.json(outcome.response)?["id"] as? Int == 7)
    }

    @Test("中转出错包成 JSON-RPC 错误对象：-32603 带原因")
    func wrapsRelayErrors() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        host.relayResult = .failure(AgentPluginMCPGatewayHostError(message: "Unknown tool: nope"))
        let router = GatewayTestSupport.router(host: host, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.response.status == 200)
        let json = try #require(GatewayTestSupport.json(outcome.response))
        #expect(json["id"] as? Int == 7)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32603)
        #expect(error["message"] as? String == "Unknown tool: nope")
    }

    @Test("插件拉不起来时回 -32603，不再去转发或中转")
    func reportsStartFailure() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: "willdeep-video-studio", url: "http://127.0.0.1:50001/mcp", token: "t")
        let host = GatewayFakeHost()
        host.ensureError = AgentPluginMCPGatewayHostError(message: "spawn failed")
        let forwarder = GatewayFakeForwarder()
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        let error = try #require(GatewayTestSupport.json(outcome.response)?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32603)
        #expect((error["message"] as? String)?.contains("spawn failed") == true)
        #expect(forwarder.calls.isEmpty)
        #expect(host.relayCalls.isEmpty)
    }

    @Test("mcp-http.json 只认 http://127.0.0.1:<端口>/…，指向别处一律当作没公布")
    func acceptsOnlyLoopbackEndpoints() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let reader = AgentPluginMCPGatewayEndpointReader(pluginDataRoot: temp.pluginDataRoot)
        #expect(reader.endpoint(pluginID: "p") == nil)

        try temp.writeEndpoint(pluginID: "p", url: "http://127.0.0.1:50001/mcp", token: "t")
        #expect(reader.endpoint(pluginID: "p")?.url.absoluteString == "http://127.0.0.1:50001/mcp")

        for url in ["http://example.com:50001/mcp", "https://127.0.0.1:50001/mcp", "http://localhost:50001/mcp",
                    "http://127.0.0.1/mcp", "http://user:pw@127.0.0.1:50001/mcp", "ftp://127.0.0.1:21/"] {
            try temp.writeEndpoint(pluginID: "p", url: url, token: "t")
            #expect(reader.endpoint(pluginID: "p") == nil, "\(url)")
        }
        try temp.writeEndpoint(pluginID: "p", url: "http://127.0.0.1:50001/mcp", token: "")
        #expect(reader.endpoint(pluginID: "p") == nil)
        #expect(reader.endpoint(pluginID: "../p") == nil)
    }
}

// MARK: - 连接文件归属（契约修订 1）

/// 2026-09-27：WillDeep macOS 与 willdeep-rs 拉起的两个插件进程写同一份
/// mcp-http.json，macOS 网关照着转发进了 willdeep-rs 拉起的那个，`video.generate`
/// 报「Video API key is not configured.」。插件 0.32.0-rc2 起在文件里写
/// `parentPID`（拉起它的宿主进程）；≤ 0.32.0-rc1 的插件被 willdeep-rs 拉起时仍写
/// macOS 这份，只能靠网关按 `parentPID` 认出来。
@Suite("插件 MCP 网关：连接文件的拉起者（parentPID）")
struct AgentPluginMCPGatewayEndpointOwnershipTests {
    private static let pluginID = "willdeep-video-studio"
    private static let gatewayPID: Int32 = 4242
    private static let otherHostPID: Int32 = 5151
    private static let callBody = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"video.generate","arguments":{}}}"#

    private func reader(_ temp: GatewayTempDirectory, gatewayProcessID: Int32 = Self.gatewayPID) -> AgentPluginMCPGatewayEndpointReader {
        AgentPluginMCPGatewayEndpointReader(pluginDataRoot: temp.pluginDataRoot, gatewayProcessID: gatewayProcessID)
    }

    private func writeEndpoint(
        _ temp: GatewayTempDirectory,
        port: Int = 50_001,
        token: String = "plugin-token",
        host: String = "willdeep-macos",
        parentPID: Any
    ) throws {
        try temp.writeEndpoint(
            pluginID: Self.pluginID,
            url: "http://127.0.0.1:\(port)/mcp",
            token: token,
            extra: ["host": host, "pid": 60_001, "parentPID": parentPID]
        )
    }

    @Test("parentPID 是网关所在进程：照常读出 url 和 token，host / pid 等附加字段不影响")
    func acceptsOwnPlugin() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try writeEndpoint(temp, parentPID: Self.gatewayPID)
        let endpoint = try #require(reader(temp).endpoint(pluginID: Self.pluginID))
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:50001/mcp")
        #expect(endpoint.token == "plugin-token")
    }

    @Test("parentPID 是别的进程（别的宿主拉起的插件写的）：当作没公布")
    func ignoresOtherHostsPlugin() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try writeEndpoint(temp, host: "willdeep-rs", parentPID: Self.otherHostPID)
        #expect(reader(temp).endpoint(pluginID: Self.pluginID) == nil)
        // host 字段不作数：自称 willdeep-macos、拉起者却不是本进程，同样不认。
        try writeEndpoint(temp, host: "willdeep-macos", parentPID: Self.otherHostPID)
        #expect(reader(temp).endpoint(pluginID: Self.pluginID) == nil)
    }

    @Test("不带 parentPID 的文件（插件 ≤ 0.32.0-rc1）照旧接受")
    func acceptsFilesWithoutParentPID() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try temp.writeEndpoint(pluginID: Self.pluginID, url: "http://127.0.0.1:50001/mcp", token: "t")
        #expect(reader(temp).endpoint(pluginID: Self.pluginID)?.token == "t")
        try temp.writeEndpoint(pluginID: Self.pluginID, url: "http://127.0.0.1:50001/mcp", token: "t",
                               extra: ["host": "willdeep-macos", "pid": 60_001])
        #expect(reader(temp).endpoint(pluginID: Self.pluginID)?.token == "t")
    }

    @Test("parentPID 不是能核对的整数：字符串、布尔、小数、null、数组、超出 pid 范围都不转发")
    func rejectsUnverifiableParentPID() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        // 2^32 + 4242：按位截断会恰好撞上 4242。
        let unverifiable: [Any] = ["4242", 4242.5, NSNull(), [4242], Int64(4_294_971_538), -1]
        for value in unverifiable {
            try writeEndpoint(temp, parentPID: value)
            #expect(reader(temp).endpoint(pluginID: Self.pluginID) == nil, "\(value)")
        }
        // JSON 的 true 读回来是 NSNumber，不能被当成 pid 1。
        try writeEndpoint(temp, parentPID: true)
        #expect(reader(temp, gatewayProcessID: 1).endpoint(pluginID: Self.pluginID) == nil)
    }

    @Test("默认按当前进程核对 parentPID")
    func defaultsToCurrentProcess() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let current = ProcessInfo.processInfo.processIdentifier
        let reader = AgentPluginMCPGatewayEndpointReader(pluginDataRoot: temp.pluginDataRoot)
        #expect(reader.gatewayProcessID == current)
        try writeEndpoint(temp, parentPID: current)
        #expect(reader.endpoint(pluginID: Self.pluginID) != nil)
        try writeEndpoint(temp, parentPID: current &+ 1)
        #expect(reader.endpoint(pluginID: Self.pluginID) == nil)
    }

    @Test("复现 2026-09-27：连接文件是 willdeep-rs 拉起的插件写的，不转过去，经 stdio 中转回自己的插件")
    func relaysInsteadOfForwardingToOtherHostsPlugin() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try writeEndpoint(temp, host: "willdeep-rs", parentPID: Self.otherHostPID)
        let host = GatewayFakeHost()
        host.relayResult = .success(#"{"content":[{"type":"text","text":"submitted"}]}"#)
        let forwarder = GatewayFakeForwarder()
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp, gatewayProcessID: Self.gatewayPID)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .relayed)
        #expect(forwarder.calls.isEmpty)
        #expect(host.ensureCalls == ["willdeep-video-studio/video-studio"])
        #expect(host.relayCalls.map(\.method) == ["tools/call"])
        #expect(GatewayTestSupport.json(outcome.response)?["id"] as? Int == 9)
    }

    @Test("连接文件是自己拉起的插件写的：照常转发，带插件自己的 token")
    func forwardsToOwnPlugin() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try writeEndpoint(temp, parentPID: Self.gatewayPID)
        let host = GatewayFakeHost()
        let ok = Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8)
        let forwarder = GatewayFakeForwarder([.success(.init(status: 200, contentType: "application/json", body: ok))])
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp, gatewayProcessID: Self.gatewayPID)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .forwarded)
        #expect(outcome.response.body == ok)
        #expect(forwarder.calls.map(\.token) == ["plugin-token"])
        #expect(host.relayCalls.isEmpty)
    }

    @Test("重读时文件已被别的宿主拉起的插件改写：不转过去，退回 stdio 中转")
    func rereadRejectsOtherHostsRewrite() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        try writeEndpoint(temp, port: 50_001, token: "own", parentPID: Self.gatewayPID)
        let host = GatewayFakeHost()
        let forwarder = GatewayFakeForwarder([.failure(AgentPluginMCPGatewayForwardError.connectionRefused)])
        // 自己的插件刚退出，另一个宿主拉起的插件抢着写了同一份文件。
        forwarder.beforeEachCall = { index in
            if index == 0 {
                try? writeEndpoint(temp, port: 50_002, token: "other", host: "willdeep-rs", parentPID: Self.otherHostPID)
            }
        }
        let router = GatewayTestSupport.router(host: host, forwarder: forwarder, temp: temp, gatewayProcessID: Self.gatewayPID)

        let outcome = await router.handle(GatewayTestSupport.request(body: Self.callBody))
        #expect(outcome.disposition == .relayed)
        #expect(forwarder.calls.map(\.token) == ["own"])
        #expect(host.relayCalls.count == 1)
    }
}
