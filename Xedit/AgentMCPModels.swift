//
//  AgentMCPModels.swift
//  WillDeep
//
//  MCP transport, source, server configuration, trust, and settings
//  models shared by Settings, approval policy, and the JSON-RPC bridge.
//

import Foundation

enum AgentMCPTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case stdio
    case streamableHTTP = "streamable-http"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stdio:
            return "stdio"
        case .streamableHTTP:
            return "streamable-http"
        }
    }
}

enum AgentMCPServerSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case cursor
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user:
            return "User"
        case .cursor:
            return "Cursor"
        case .codex:
            return "Codex"
        }
    }
}

struct AgentMCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var source: AgentMCPServerSource
    var transport: AgentMCPTransport
    var command: String
    var args: [String]
    var env: [String: String]
    var url: String
    var headers: [String: String]
    var startupTimeout: TimeInterval
    var isEnabled: Bool

    init(
        id: String? = nil,
        name: String,
        source: AgentMCPServerSource,
        transport: AgentMCPTransport,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        url: String = "",
        headers: [String: String] = [:],
        startupTimeout: TimeInterval = 30,
        isEnabled: Bool = true
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.transport = transport
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.args = args
        self.env = env
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = headers
        self.startupTimeout = min(max(startupTimeout, 1), 180)
        self.isEnabled = isEnabled
        self.id = id ?? "\(source.rawValue):\(self.name)"
    }

    var normalized: AgentMCPServerConfig {
        var copy = self
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.command = copy.command.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.url = copy.url.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.startupTimeout = min(max(copy.startupTimeout, 1), 180)
        copy.id = copy.id.isEmpty ? "\(copy.source.rawValue):\(copy.name)" : copy.id
        return copy
    }

    var summary: String {
        switch transport {
        case .stdio:
            let argText = args.isEmpty ? "" : " \(args.joined(separator: " "))"
            return "\(command)\(argText)"
        case .streamableHTTP:
            return url
        }
    }

    var redactedHeaders: [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key, Self.redactedValue(for: key, value: value))
        })
    }

    var redactedEnv: [String: String] {
        Dictionary(uniqueKeysWithValues: env.map { key, value in
            (key, Self.redactedValue(for: key, value: value))
        })
    }

    static func redactedValue(for key: String, value: String) -> String {
        if AgentCredentialStore.isReference(value) {
            return "[redacted]"
        }
        if isSensitiveCredentialKey(key) {
            return value.isEmpty ? "" : "[redacted]"
        }
        return value
    }

    static func isSensitiveCredentialKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("token")
            || lowercased.contains("secret")
            || lowercased.contains("password")
            || lowercased == "authorization"
            || lowercased == "cookie"
            || lowercased.contains("key")
    }
}

/// Per-server trust posture, three tiers:
/// - `fullyTrusted`: user explicitly marked "this is my own MCP";
///   every call_mcp_tool to it auto-runs, including writes.
/// - `standard`: the default; read-style calls auto-run (name
///   heuristic / LLM judge), writes gate on the user.
/// - `untrusted`: everything gates, Always-Allow pins are ignored.
enum AgentMCPServerTrustLevel: String, Codable {
    case fullyTrusted
    case standard
    case untrusted
}

struct AgentMCPSettings: Codable, Equatable {
    var disabledServerIDs: [String]
    var userServers: [AgentMCPServerConfig]
    /// Server IDs the user marked as untrusted. The server is still
    /// enabled, but Always-Allow auto-approval is ignored for its tools.
    var untrustedServerIDs: [String]
    /// Server IDs the user promoted to fully trusted. Mutually exclusive
    /// with `untrustedServerIDs`; normalized settings let untrusted win.
    var trustedServerIDs: [String]

    static let `default` = AgentMCPSettings(
        disabledServerIDs: [],
        userServers: [],
        untrustedServerIDs: [],
        trustedServerIDs: []
    )

    enum CodingKeys: String, CodingKey {
        case disabledServerIDs
        case userServers
        case untrustedServerIDs
        case trustedServerIDs
    }

    init(
        disabledServerIDs: [String],
        userServers: [AgentMCPServerConfig],
        untrustedServerIDs: [String] = [],
        trustedServerIDs: [String] = []
    ) {
        self.disabledServerIDs = disabledServerIDs
        self.userServers = userServers
        self.untrustedServerIDs = untrustedServerIDs
        self.trustedServerIDs = trustedServerIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.disabledServerIDs = try container.decodeIfPresent([String].self, forKey: .disabledServerIDs) ?? []
        self.userServers = try container.decodeIfPresent([AgentMCPServerConfig].self, forKey: .userServers) ?? []
        self.untrustedServerIDs = try container.decodeIfPresent([String].self, forKey: .untrustedServerIDs) ?? []
        self.trustedServerIDs = try container.decodeIfPresent([String].self, forKey: .trustedServerIDs) ?? []
    }

    var normalized: AgentMCPSettings {
        var copy = self
        copy.disabledServerIDs = Array(Set(copy.disabledServerIDs.filter { !$0.isEmpty })).sorted()
        copy.untrustedServerIDs = Array(Set(copy.untrustedServerIDs.filter { !$0.isEmpty })).sorted()
        let untrusted = Set(copy.untrustedServerIDs)
        copy.trustedServerIDs = Array(Set(copy.trustedServerIDs.filter { !$0.isEmpty && !untrusted.contains($0) })).sorted()
        copy.userServers = copy.userServers.map {
            var server = $0.normalized
            server.source = .user
            server.id = server.id.hasPrefix("user:") ? server.id : "user:\(server.name)"
            return server
        }
        return copy
    }
}

struct AgentMCPServerPreset: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var server: AgentMCPServerConfig

    static let playwright = AgentMCPServerPreset(
        id: "playwright",
        title: "Playwright MCP",
        detail: "npx -y @playwright/mcp@latest",
        server: AgentMCPServerConfig.playwrightMCP()
    )

    static let playwrightChinaMirror = AgentMCPServerPreset(
        id: "playwright-china-mirror",
        title: "Playwright MCP (China mirror)",
        detail: "npx -y @playwright/mcp@latest + npmmirror",
        server: AgentMCPServerConfig.playwrightMCP(
            env: ["npm_config_registry": "https://registry.npmmirror.com"]
        )
    )

    static let recommended: [AgentMCPServerPreset] = [
        .playwright,
        .playwrightChinaMirror
    ]
}

extension AgentMCPServerConfig {
    static func playwrightMCP(env: [String: String] = [:]) -> AgentMCPServerConfig {
        AgentMCPServerConfig(
            name: "playwright",
            source: .user,
            transport: .stdio,
            command: "/usr/bin/env",
            args: ["npx", "-y", "@playwright/mcp@latest"],
            env: env,
            startupTimeout: 90
        )
    }
}
