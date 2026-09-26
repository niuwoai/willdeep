//
//  AgentPluginMCPGatewayDiscovery.swift
//  WillDeep
//
//  插件 MCP 网关的发现文件 `mcp-gateway.json`：外部 MCP 客户端从这里读网关
//  地址和 token。端口和 token 首次随机生成后就写在这份文件里，下次启动先读
//  回来沿用，外部客户端的配置因此长期有效。宿主退出时不删这份文件。
//
//  契约见 docs/decisions/0001-plugin-mcp-gateway.md。
//

import Foundation
import Security

nonisolated struct AgentPluginMCPGatewayDiscovery: Codable, Equatable, Sendable {
    nonisolated struct Server: Codable, Equatable, Sendable {
        let pluginID: String
        let server: String
        let url: String
    }

    static let currentVersion = 1
    static let hostID = "willdeep-macos"

    let version: Int
    let host: String
    let url: String
    let token: String
    let servers: [Server]
}

/// 网关用到的磁盘位置。测试注入临时目录，不碰真实的
/// `~/Library/Application Support/WillDeep`。
nonisolated struct AgentPluginMCPGatewayPaths: Sendable {
    static let discoveryFileName = "mcp-gateway.json"

    let discoveryFileURL: URL
    /// `plugin-data` 目录。
    let pluginDataRoot: URL

    static var live: Self {
        let pluginDataRoot = AgentPluginGeneratedMediaResolver.pluginDataRoot
        return Self(
            discoveryFileURL: pluginDataRoot
                .deletingLastPathComponent()
                .appendingPathComponent(discoveryFileName, isDirectory: false),
            pluginDataRoot: pluginDataRoot
        )
    }
}

nonisolated enum AgentPluginMCPGatewayDiscoveryStore {
    /// 32 字节随机数的十六进制。
    static let tokenHexLength = 64

    /// 读回上次保存的端口和 token；文件不存在或内容不合格都返回 nil。
    static func loadPortAndToken(from url: URL) -> (port: UInt16, token: String)? {
        guard let data = try? Data(contentsOf: url),
              let discovery = try? JSONDecoder().decode(AgentPluginMCPGatewayDiscovery.self, from: data),
              isValidToken(discovery.token),
              let components = URLComponents(string: discovery.url),
              components.host == "127.0.0.1",
              let port = components.port,
              let port16 = UInt16(exactly: port), port16 > 0 else {
            return nil
        }
        return (port16, discovery.token)
    }

    static func isValidToken(_ token: String) -> Bool {
        token.count == tokenHexLength && token.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// 用 `SecRandomCopyBytes` 生成 32 字节随机数，转成 64 位小写十六进制。
    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: tokenHexLength / 2)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func baseURL(port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    static func serverURL(baseURL: String, pluginID: String, serverName: String) -> String {
        "\(baseURL)/plugins/\(encodePathSegment(pluginID))/\(encodePathSegment(serverName))/mcp"
    }

    static func makeDiscovery(
        port: UInt16,
        token: String,
        servers: [AgentPluginMCPGatewayServer]
    ) -> AgentPluginMCPGatewayDiscovery {
        let base = baseURL(port: port)
        let entries = servers
            .sorted { ($0.pluginID, $0.serverName) < ($1.pluginID, $1.serverName) }
            .map {
                AgentPluginMCPGatewayDiscovery.Server(
                    pluginID: $0.pluginID,
                    server: $0.serverName,
                    url: serverURL(baseURL: base, pluginID: $0.pluginID, serverName: $0.serverName)
                )
            }
        return AgentPluginMCPGatewayDiscovery(
            version: AgentPluginMCPGatewayDiscovery.currentVersion,
            host: AgentPluginMCPGatewayDiscovery.hostID,
            url: base,
            token: token,
            servers: entries
        )
    }

    /// 原子写入，权限 0600：先在同目录建一个 0600 的临时文件写好，再 rename
    /// 覆盖。任何时刻读到的要么是旧文件、要么是完整的新文件，也从不存在一个
    /// 其他用户可读的中间态。
    static func write(_ discovery: AgentPluginMCPGatewayDiscovery, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(discovery)
        data.append(0x0A)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // 覆盖的是用户手工放宽过权限的旧文件时，rename 带过来的是临时文件的
        // 0600，这里再收紧一次只是保险。
        _ = chmod(url.path, 0o600)
    }

    /// 设置页「复制 Claude Code 连接命令」用的命令行。命令里带 token，只在
    /// 用户点按钮时生成并放进剪贴板，不落日志。
    static func claudeCodeCommand(name: String, url: String, token: String) -> String {
        let safeName = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return "claude mcp add --transport http \(String(safeName)) \(url) --header \"Authorization: Bearer \(token)\""
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
