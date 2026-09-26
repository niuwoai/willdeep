//
//  AgentPluginMCPGatewayDiscoveryTests.swift
//  XeditTests
//
//  插件 MCP 网关的发现文件（内容、权限、端口与 token 沿用）和真实监听。
//  发现文件和插件数据目录都指向每个用例自己的临时目录，不碰
//  ~/Library/Application Support/WillDeep；宿主和转发器是假的，不拉起进程。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("插件 MCP 网关：发现文件与监听", .serialized)
struct AgentPluginMCPGatewayDiscoveryTests {
    private func makeGateway(
        temp: GatewayTempDirectory,
        host: GatewayFakeHost = GatewayFakeHost(),
        randomPorts: [UInt16] = []
    ) -> AgentPluginMCPGateway {
        AgentPluginMCPGateway(
            paths: temp.paths,
            host: host,
            forwarder: GatewayFakeForwarder(),
            randomPortCandidates: { randomPorts }
        )
    }

    private func readDiscovery(_ temp: GatewayTempDirectory) throws -> AgentPluginMCPGatewayDiscovery {
        let data = try Data(contentsOf: temp.paths.discoveryFileURL)
        return try JSONDecoder().decode(AgentPluginMCPGatewayDiscovery.self, from: data)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("token 是 64 位小写十六进制，每次不同")
    func generatesTokens() throws {
        let first = try #require(AgentPluginMCPGatewayDiscoveryStore.makeToken())
        let second = try #require(AgentPluginMCPGatewayDiscoveryStore.makeToken())
        #expect(first.count == 64)
        #expect(AgentPluginMCPGatewayDiscoveryStore.isValidToken(first))
        #expect(first == first.lowercased())
        #expect(first != second)
        #expect(!AgentPluginMCPGatewayDiscoveryStore.isValidToken("short"))
        #expect(!AgentPluginMCPGatewayDiscoveryStore.isValidToken(String(repeating: "g", count: 64)))
    }

    @Test("发现文件按契约写：version / host / url / token / servers，权限 0600")
    func writesDiscoveryFile() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let token = GatewayTestSupport.token
        let discovery = AgentPluginMCPGatewayDiscoveryStore.makeDiscovery(
            port: 47831,
            token: token,
            servers: [
                AgentPluginMCPGatewayServer(pluginID: "zeta", serverName: "z", pluginVersion: "1"),
                GatewayFakeHost.videoStudio
            ]
        )
        try AgentPluginMCPGatewayDiscoveryStore.write(discovery, to: temp.paths.discoveryFileURL)

        #expect(try permissions(temp.paths.discoveryFileURL) == 0o600)
        let text = try String(contentsOf: temp.paths.discoveryFileURL, encoding: .utf8)
        #expect(text.contains(#""url" : "http://127.0.0.1:47831""#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["host"] as? String == "willdeep-macos")
        #expect(object["url"] as? String == "http://127.0.0.1:47831")
        #expect(object["token"] as? String == token)
        let servers = try #require(object["servers"] as? [[String: Any]])
        #expect(servers.count == 2)
        #expect(servers.first?["pluginID"] as? String == "willdeep-video-studio")
        #expect(servers.first?["server"] as? String == "video-studio")
        #expect(servers.first?["url"] as? String
            == "http://127.0.0.1:47831/plugins/willdeep-video-studio/video-studio/mcp")

        // 覆盖写也保持 0600、不留临时文件。
        try AgentPluginMCPGatewayDiscoveryStore.write(discovery, to: temp.paths.discoveryFileURL)
        #expect(try permissions(temp.paths.discoveryFileURL) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.root.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)

        let loaded = try #require(AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: temp.paths.discoveryFileURL))
        #expect(loaded.port == 47831)
        #expect(loaded.token == token)
    }

    @Test("发现文件不合格（坏 JSON、token 不对、主机不是 127.0.0.1）时不沿用")
    func ignoresInvalidDiscovery() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let url = temp.paths.discoveryFileURL
        #expect(AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: url) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: url) == nil)

        let badToken = AgentPluginMCPGatewayDiscovery(version: 1, host: "willdeep-macos", url: "http://127.0.0.1:47831", token: "x", servers: [])
        try AgentPluginMCPGatewayDiscoveryStore.write(badToken, to: url)
        #expect(AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: url) == nil)

        let badHost = AgentPluginMCPGatewayDiscovery(version: 1, host: "willdeep-macos", url: "http://0.0.0.0:47831", token: GatewayTestSupport.token, servers: [])
        try AgentPluginMCPGatewayDiscoveryStore.write(badHost, to: url)
        #expect(AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: url) == nil)
    }

    @Test("Claude Code 连接命令带网关地址和 Bearer 头")
    func buildsClaudeCodeCommand() {
        let command = AgentPluginMCPGatewayDiscoveryStore.claudeCodeCommand(
            name: "video studio",
            url: "http://127.0.0.1:47831/plugins/p/s/mcp",
            token: "abc"
        )
        #expect(command == #"claude mcp add --transport http video-studio http://127.0.0.1:47831/plugins/p/s/mcp --header "Authorization: Bearer abc""#)
    }

    @Test("启动后写发现文件；停掉再起沿用原端口和原 token")
    func reusesPortAndToken() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let first = makeGateway(temp: temp)
        let port = try #require(first.startAndWait())
        let written = try readDiscovery(temp)
        #expect(written.url == "http://127.0.0.1:\(port)")
        #expect(AgentPluginMCPGatewayDiscoveryStore.isValidToken(written.token))
        #expect(written.servers.map(\.pluginID) == ["willdeep-video-studio"])
        #expect(try permissions(temp.paths.discoveryFileURL) == 0o600)
        // 重复启动不换端口。
        #expect(first.startAndWait() == port)
        first.stop()

        let second = makeGateway(temp: temp)
        defer { second.stop() }
        #expect(second.startAndWait() == port)
        let rewritten = try readDiscovery(temp)
        #expect(rewritten.token == written.token)
        #expect(rewritten.url == written.url)
    }

    @Test("原端口被占时换新端口并重写文件，token 不变")
    func movesToNewPortWhenOccupied() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let holder = makeGateway(temp: temp)
        defer { holder.stop() }
        let heldPort = try #require(holder.startAndWait())
        let token = try readDiscovery(temp).token

        let second = makeGateway(temp: temp)
        defer { second.stop() }
        let newPort = try #require(second.startAndWait())
        #expect(newPort != heldPort)
        let rewritten = try readDiscovery(temp)
        #expect(rewritten.url == "http://127.0.0.1:\(newPort)")
        #expect(rewritten.token == token)
    }

    @Test("插件启停后重写 servers；网关没在运行时不写文件")
    func rewritesServersOnChange() throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let host = GatewayFakeHost()
        let idle = makeGateway(temp: temp, host: host)
        idle.pluginServersDidChange()
        idle.stop()  // 同一条串行队列：返回时上面那次重写已经执行完（且应当什么都没做）
        #expect(idle.baseURL == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.paths.discoveryFileURL.path))

        let gateway = makeGateway(temp: temp, host: host)
        defer { gateway.stop() }
        _ = try #require(gateway.startAndWait())
        host.servers = []
        gateway.pluginServersDidChange()
        // startAndWait 在同一条串行队列上执行，等它返回即等到了重写完成。
        _ = gateway.startAndWait()
        #expect(try readDiscovery(temp).servers.isEmpty)
    }

    @Test("真实 HTTP：initialize 经监听端口应答，错 token 回 401，Host 不对回 403")
    func servesOverLoopback() async throws {
        let temp = GatewayTempDirectory()
        defer { temp.remove() }
        let gateway = makeGateway(temp: temp)
        defer { gateway.stop() }
        let port = try #require(gateway.startAndWait())
        let token = try readDiscovery(temp).token
        let url = try #require(URL(string: "http://127.0.0.1:\(port)\(GatewayTestSupport.path)"))
        let session = URLSession(configuration: .ephemeral)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Mcp-Session-Id")?.isEmpty == false)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serverInfo = (json["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "willdeep-video-studio/video-studio")

        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, unauthorized) = try await session.data(for: request)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)

        // URLSession 不让改 Host，这两条用原始字节发。
        let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let foreign = try rawExchange(
            port: port,
            "POST \(GatewayTestSupport.path) HTTP/1.1\r\nHost: evil.example\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
        #expect(foreign.hasPrefix("HTTP/1.1 403 "))
        let notification = try rawExchange(
            port: port,
            "POST \(GatewayTestSupport.path) HTTP/1.1\r\nHost: localhost:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        )
        #expect(notification.hasPrefix("HTTP/1.1 202 "))
        let chunked = try rawExchange(
            port: port,
            "POST \(GatewayTestSupport.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        )
        #expect(chunked.hasPrefix("HTTP/1.1 411 "))
    }

    /// 用 BSD 套接字发一段原始请求，读到对端关闭为止。
    private func rawExchange(port: UInt16, _ raw: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(raw.utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { throw POSIXError(.EIO) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(data: received, encoding: .utf8) ?? ""
    }
}
