//
//  AgentMCPBridge.swift
//  WillDeep
//
//  MCP server discovery plus stdio and streamable HTTP JSON-RPC transports.
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
/// - `fullyTrusted` — user explicitly marked "this is my own MCP";
///   every call_mcp_tool to it auto-runs, including writes.
/// - `standard` — the default; read-style calls auto-run (name
///   heuristic / LLM judge), writes gate on the user.
/// - `untrusted` — everything gates, Always-Allow pins are ignored.
enum AgentMCPServerTrustLevel: String, Codable {
    case fullyTrusted
    case standard
    case untrusted
}

struct AgentMCPSettings: Codable, Equatable {
    var disabledServerIDs: [String]
    var userServers: [AgentMCPServerConfig]
    /// rc3: server IDs the user has marked as "untrusted". A server in
    /// this set is *still* enabled — list_mcp_tools / call_mcp_tool will
    /// still reach it — but the auto-approve path treats it like any
    /// fresh write-tier tool: `Always Allow` pins are ignored, every
    /// call_mcp_tool to this server falls back to the per-call Allow/
    /// Deny gate. Use it for servers you imported but don't fully trust
    /// (third-party packages, experimental personal MCPs). Default is
    /// empty — all servers trusted unless explicitly demoted.
    var untrustedServerIDs: [String]
    /// 1.58: server IDs the user promoted to "fully trusted" (their own
    /// MCPs). Every call auto-runs, writes included. Mutually exclusive
    /// with `untrustedServerIDs` — `normalized` resolves a conflict in
    /// favour of untrusted (the safer reading).
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
        // decodeIfPresent so settings.json written before rc3 (no key)
        // decodes cleanly into the default empty set — every existing
        // server stays trusted.
        self.untrustedServerIDs = try container.decodeIfPresent([String].self, forKey: .untrustedServerIDs) ?? []
        self.trustedServerIDs = try container.decodeIfPresent([String].self, forKey: .trustedServerIDs) ?? []
    }

    var normalized: AgentMCPSettings {
        var copy = self
        copy.disabledServerIDs = Array(Set(copy.disabledServerIDs.filter { !$0.isEmpty })).sorted()
        copy.untrustedServerIDs = Array(Set(copy.untrustedServerIDs.filter { !$0.isEmpty })).sorted()
        // A server can't be both fully trusted and untrusted; if some
        // stale write left it in both sets, untrusted wins.
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

enum AgentMCPSettingsStore {
    private static let settingsKey = "com.willdeep.agentMCPSettings.v1"

    /// Test-only override, mirroring AgentSettingsStore: redirect every
    /// read / write into a sandbox suite so unit tests can't mutate the
    /// developer's real MCP trust state.
    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?

    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    private static var defaults: UserDefaults {
        testDefaultsOverride ?? .standard
    }

    static func load() -> AgentMCPSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentMCPSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func save(_ settings: AgentMCPSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    static func setServerEnabled(id: String, enabled: Bool) {
        var settings = load()
        var disabled = Set(settings.disabledServerIDs)
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        settings.disabledServerIDs = Array(disabled)
        save(settings)
    }

    /// rc3: flip a server between trusted (default) and untrusted.
    /// Untrusted means the server still runs but its tools no longer
    /// participate in Always-Allow auto-approval — every call gates.
    static func setServerTrusted(id: String, trusted: Bool) {
        setServerTrustLevel(id: id, level: trusted ? .standard : .untrusted)
    }

    /// 1.58: set the full three-tier trust posture for a server. The
    /// two id sets are kept mutually exclusive here AND re-resolved in
    /// `normalized` (untrusted wins) in case of stale persisted data.
    static func setServerTrustLevel(id: String, level: AgentMCPServerTrustLevel) {
        var settings = load()
        var untrusted = Set(settings.untrustedServerIDs)
        var trusted = Set(settings.trustedServerIDs)
        untrusted.remove(id)
        trusted.remove(id)
        switch level {
        case .fullyTrusted: trusted.insert(id)
        case .standard: break
        case .untrusted: untrusted.insert(id)
        }
        settings.untrustedServerIDs = Array(untrusted)
        settings.trustedServerIDs = Array(trusted)
        save(settings)
    }

    static func trustLevel(id: String) -> AgentMCPServerTrustLevel {
        let settings = load()
        if settings.untrustedServerIDs.contains(id) { return .untrusted }
        if settings.trustedServerIDs.contains(id) { return .fullyTrusted }
        return .standard
    }

    /// Name-keyed trust level for the auto-approve path (the MCP wire
    /// shape carries server *names*). When several configured servers
    /// share a name, the safest reading wins: any untrusted match →
    /// untrusted; otherwise fullyTrusted only if a match says so.
    static func trustLevel(name: String) -> AgentMCPServerTrustLevel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .standard }
        let lowered = trimmed.lowercased()
        let settings = load()
        let untrustedIDs = Set(settings.untrustedServerIDs)
        let trustedIDs = Set(settings.trustedServerIDs)
        var sawFullyTrusted = false
        for server in AgentMCPServerDirectory.list(includeDisabled: true)
        where server.name.lowercased() == lowered {
            if untrustedIDs.contains(server.id) { return .untrusted }
            if trustedIDs.contains(server.id) { sawFullyTrusted = true }
        }
        return sawFullyTrusted ? .fullyTrusted : .standard
    }

    /// rc3: check whether a given server id is trusted. Cheap; used by
    /// the auto-approve path inside `autoApprovalSource` to short-circuit
    /// Always-Allow when the user has demoted the server.
    static func isServerTrusted(id: String) -> Bool {
        let settings = load()
        return !settings.untrustedServerIDs.contains(id)
    }

    /// rc3: name-keyed version — the MCP wire shape always carries the
    /// server *name* (not id) into call_mcp_tool, so the auto-approve
    /// path needs to map name → server config → id before consulting
    /// trust state. This helper does the lookup with a case-insensitive
    /// name compare matching the rest of the MCP layer.
    static func isServerTrusted(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
        // Walk the full directory (user + cursor + codex) so trust
        // state works regardless of which source the server came from.
        let all = AgentMCPServerDirectory.list(includeDisabled: true)
        let untrustedIDs = Set(load().untrustedServerIDs)
        for server in all where server.name.lowercased() == lowered {
            if untrustedIDs.contains(server.id) { return false }
        }
        return true
    }

    static func upsertUserServer(_ server: AgentMCPServerConfig) {
        var settings = load()
        var normalized = server.normalized
        normalized.source = .user
        normalized.id = "user:\(normalized.name)"
        let previousServer = settings.userServers.first {
            $0.id == normalized.id || $0.name == normalized.name
        }
        normalized.headers = secureKeyValueMap(
            normalized.headers,
            serverID: normalized.id,
            kind: "headers"
        )
        normalized.env = secureKeyValueMap(
            normalized.env,
            serverID: normalized.id,
            kind: "env"
        )
        if let previousServer {
            let retainedAccounts = credentialAccounts(in: normalized.headers)
                .union(credentialAccounts(in: normalized.env))
            deleteCredentialReferences(in: previousServer.headers, retaining: retainedAccounts)
            deleteCredentialReferences(in: previousServer.env, retaining: retainedAccounts)
        }
        settings.userServers.removeAll { $0.id == normalized.id || $0.name == normalized.name }
        settings.userServers.append(normalized)
        settings.userServers.sort { $0.name < $1.name }
        save(settings)
    }

    static func deleteUserServer(id: String) {
        var settings = load()
        if let server = settings.userServers.first(where: { $0.id == id }) {
            deleteCredentialReferences(in: server.headers)
            deleteCredentialReferences(in: server.env)
        }
        settings.userServers.removeAll { $0.id == id }
        settings.disabledServerIDs.removeAll { $0 == id }
        save(settings)
    }

    static func clearAuthorizationHeader(id: String) {
        var settings = load()
        guard let index = settings.userServers.firstIndex(where: { $0.id == id }) else { return }
        let keys = settings.userServers[index].headers.keys.filter { $0.lowercased() == "authorization" }
        for key in keys {
            if let value = settings.userServers[index].headers[key] {
                deleteCredentialReferences(in: [key: value])
            }
            let account = AgentCredentialStore.mcpAccount(serverID: id, kind: "headers", key: key)
            AgentCredentialStore.delete(account: account)
            settings.userServers[index].headers.removeValue(forKey: key)
        }
        save(settings)
    }

    private static func secureKeyValueMap(
        _ values: [String: String],
        serverID: String,
        kind: String
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentMCPServerConfig.isSensitiveCredentialKey(key),
                  !trimmed.isEmpty,
                  !AgentCredentialStore.isReference(trimmed) else {
                return (key, value)
            }
            let account = AgentCredentialStore.mcpAccount(serverID: serverID, kind: kind, key: key)
            AgentCredentialStore.save(trimmed, account: account)
            return (key, AgentCredentialStore.reference(account: account))
        })
    }

    private static func deleteCredentialReferences(
        in values: [String: String],
        retaining retainedAccounts: Set<String> = []
    ) {
        for account in credentialAccounts(in: values) where !retainedAccounts.contains(account) {
            AgentCredentialStore.delete(account: account)
        }
    }

    private static func credentialAccounts(in values: [String: String]) -> Set<String> {
        var accounts: Set<String> = []
        for value in values.values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(AgentCredentialStore.referencePrefix) else { continue }
            accounts.insert(String(trimmed.dropFirst(AgentCredentialStore.referencePrefix.count)))
        }
        return accounts
    }
}

enum AgentMCPServerDirectory {
    static var cursorConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/mcp.json")
    }

    static var codexConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    static func list(includeDisabled: Bool = false) -> [AgentMCPServerConfig] {
        let settings = AgentMCPSettingsStore.load()
        var servers: [AgentMCPServerConfig] = []
        servers.append(contentsOf: settings.userServers)
        servers.append(contentsOf: loadCursorServers())
        servers.append(contentsOf: loadCodexServers())

        var seenNames: Set<String> = []
        var deduped: [AgentMCPServerConfig] = []
        for var server in servers {
            server = server.normalized
            guard !server.name.isEmpty else { continue }
            let key = server.name.lowercased()
            guard !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            server.isEnabled = !settings.disabledServerIDs.contains(server.id)
            guard includeDisabled || server.isEnabled else { continue }
            deduped.append(server)
        }
        return deduped.sorted { lhs, rhs in
            if lhs.source == rhs.source { return lhs.name < rhs.name }
            return sourceRank(lhs.source) < sourceRank(rhs.source)
        }
    }

    static func server(named name: String) throws -> AgentMCPServerConfig {
        guard let server = list().first(where: { $0.name == name }) else {
            throw AgentToolError.notFound("MCP server \(name)")
        }
        return server
    }

    static func loadCursorServers(from data: Data? = nil) -> [AgentMCPServerConfig] {
        let sourceData: Data
        if let data {
            sourceData = data
        } else {
            guard let loaded = try? Data(contentsOf: cursorConfigURL) else { return [] }
            sourceData = loaded
        }
        guard let root = try? JSONSerialization.jsonObject(with: sourceData, options: []),
              let rootDict = root as? [String: Any],
              let mcpServers = rootDict["mcpServers"] as? [String: Any] else {
            return []
        }

        return mcpServers.compactMap { name, rawServer in
            guard let dict = rawServer as? [String: Any] else { return nil }
            return parseJSONServer(name: name, source: .cursor, dict: dict)
        }.sorted { $0.name < $1.name }
    }

    static func loadCodexServers(from text: String? = nil) -> [AgentMCPServerConfig] {
        let configText: String
        if let text {
            configText = text
        } else {
            guard let data = try? Data(contentsOf: codexConfigURL),
                  let loaded = String(data: data, encoding: .utf8) else {
                return []
            }
            configText = loaded
        }
        return parseTOMLServers(from: configText)
    }

    private static func parseJSONServer(
        name: String,
        source: AgentMCPServerSource,
        dict: [String: Any]
    ) -> AgentMCPServerConfig? {
        let type = (dict["type"] as? String)?.lowercased()
        let headers = dict["headers"] as? [String: String] ?? [:]
        let env = dict["env"] as? [String: String] ?? [:]
        let timeout = dict["startup_timeout_sec"] as? Double ?? dict["timeout"] as? Double ?? 30
        if type == AgentMCPTransport.streamableHTTP.rawValue || dict["url"] is String {
            guard let url = dict["url"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AgentMCPServerConfig(
                name: name,
                source: source,
                transport: .streamableHTTP,
                url: url,
                headers: headers,
                startupTimeout: timeout
            )
        }

        guard let command = dict["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return AgentMCPServerConfig(
            name: name,
            source: source,
            transport: .stdio,
            command: command,
            args: dict["args"] as? [String] ?? [],
            env: env,
            startupTimeout: timeout
        )
    }

    private static func parseTOMLServers(from text: String) -> [AgentMCPServerConfig] {
        var serversByName: [String: AgentMCPServerConfig] = [:]
        var currentName: String?
        var currentIsEnv = false
        var currentIsHeaders = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let body = String(line.dropFirst().dropLast())
                if let section = parseMCPSection(body) {
                    currentName = section.name
                    currentIsEnv = section.kind == "env"
                    currentIsHeaders = section.kind == "headers"
                    if serversByName[section.name] == nil {
                        serversByName[section.name] = AgentMCPServerConfig(
                            name: section.name,
                            source: .codex,
                            transport: .stdio
                        )
                    }
                } else {
                    currentName = nil
                    currentIsEnv = false
                    currentIsHeaders = false
                }
                continue
            }

            guard let currentName,
                  let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if currentIsEnv {
                serversByName[currentName]?.env[key] = parseString(value) ?? ""
                continue
            }
            if currentIsHeaders {
                serversByName[currentName]?.headers[key] = parseString(value) ?? ""
                continue
            }

            switch key {
            case "command":
                serversByName[currentName]?.command = parseString(value) ?? ""
            case "args":
                serversByName[currentName]?.args = parseStringArray(value)
            case "type":
                if parseString(value)?.lowercased() == AgentMCPTransport.streamableHTTP.rawValue {
                    serversByName[currentName]?.transport = .streamableHTTP
                }
            case "url":
                serversByName[currentName]?.url = parseString(value) ?? ""
                serversByName[currentName]?.transport = .streamableHTTP
            case "startup_timeout_sec":
                if let timeout = Double(value) {
                    serversByName[currentName]?.startupTimeout = min(max(timeout, 1), 180)
                }
            default:
                continue
            }
        }

        return serversByName.values
            .map(\.normalized)
            .filter { server in
                switch server.transport {
                case .stdio:
                    return !server.command.isEmpty
                case .streamableHTTP:
                    return !server.url.isEmpty
                }
            }
            .sorted { $0.name < $1.name }
    }

    private static func parseMCPSection(_ body: String) -> (name: String, kind: String?)? {
        let prefix = "mcp_servers."
        guard body.hasPrefix(prefix) else { return nil }
        var remainder = String(body.dropFirst(prefix.count))
        var kind: String?
        for suffix in [".env", ".headers"] where remainder.hasSuffix(suffix) {
            remainder.removeLast(suffix.count)
            kind = String(suffix.dropFirst())
        }
        if remainder.hasPrefix("\""), remainder.hasSuffix("\""), remainder.count >= 2 {
            remainder.removeFirst()
            remainder.removeLast()
        }
        return remainder.isEmpty ? nil : (remainder, kind)
    }

    private static func parseString(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func parseStringArray(_ raw: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inString = false
        var isEscaped = false

        for character in raw {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                if inString {
                    values.append(current)
                    current = ""
                }
                inString.toggle()
                continue
            }
            if inString {
                current.append(character)
            }
        }
        return values
    }

    private static func sourceRank(_ source: AgentMCPServerSource) -> Int {
        switch source {
        case .user:
            return 0
        case .cursor:
            return 1
        case .codex:
            return 2
        }
    }
}

enum AgentMCPBridge {
    static func listServers() throws -> AgentToolResult {
        let servers = AgentMCPServerDirectory.list()
        guard !servers.isEmpty else {
            return AgentToolResult(summary: "0 MCP servers", payload: "No MCP servers found.")
        }

        let lines = servers.map { server in
            switch server.transport {
            case .stdio:
                let envSummary = server.redactedEnv.isEmpty
                    ? "env=[]"
                    : "env=\(server.redactedEnv)"
                return "- \(server.name): source=\(server.source.displayName), type=stdio, command=\(server.command), args=\(server.args), timeout=\(Int(server.startupTimeout))s, \(envSummary)"
            case .streamableHTTP:
                let headerSummary = server.redactedHeaders.isEmpty
                    ? "headers=[]"
                    : "headers=\(server.redactedHeaders)"
                return "- \(server.name): source=\(server.source.displayName), type=streamable-http, url=\(server.url), timeout=\(Int(server.startupTimeout))s, \(headerSummary)"
            }
        }
        return AgentToolResult(summary: "\(servers.count) MCP servers", payload: lines.joined(separator: "\n"))
    }

    static func listTools(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let server = try AgentMCPServerDirectory.server(named: requiredString("server", in: arguments))
        let result = try await runRequest(server: server, method: "tools/list", params: [:])
        return AgentToolResult(summary: "tools from \(server.name)", payload: result)
    }

    static func callTool(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let server = try AgentMCPServerDirectory.server(named: requiredString("server", in: arguments))
        let toolName = try requiredString("tool", in: arguments)
        let rawArguments = arguments["arguments_json"]?.stringValue() ?? "{}"
        let toolArguments = try parseJSONObject(rawArguments)
        let result = try await runRequest(
            server: server,
            method: "tools/call",
            params: [
                "name": toolName,
                "arguments": toolArguments
            ]
        )
        return AgentToolResult(summary: "\(server.name).\(toolName)", payload: result)
    }

    static func parseToolCount(from listToolsPayload: String) -> Int? {
        guard let data = listToolsPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let tools = dict["tools"] as? [Any] else {
            return nil
        }
        return tools.count
    }

    private static func requiredString(_ name: String, in arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private static func parseJSONObject(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8) else {
            throw AgentToolError.invalidArgument("arguments_json is not UTF-8")
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw AgentToolError.invalidArgument("arguments_json must be a JSON object")
        }
        return dict
    }

    private static func runRequest(
        server: AgentMCPServerConfig,
        method: String,
        params: [String: Any]
    ) async throws -> String {
        switch server.transport {
        case .stdio:
            let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
            return try await Task.detached(priority: .userInitiated) {
                try runStdioRequestSync(server: server, method: method, paramsData: paramsData)
            }.value
        case .streamableHTTP:
            return try await runStreamableHTTPRequest(server: server, method: method, params: params)
        }
    }

    nonisolated private static func runStdioRequestSync(
        server: AgentMCPServerConfig,
        method: String,
        paramsData: Data
    ) throws -> String {
        let params = try JSONSerialization.jsonObject(with: paramsData, options: [.fragmentsAllowed])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.command)
        process.arguments = server.args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in server.env {
            environment[key] = AgentCredentialStore.resolve(value)
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let inbox = MCPLineInbox()
        let stderrCollector = MCPDataCollector(limit: 32_000)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            inbox.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentToolError.commandFailed(-1, error.localizedDescription)
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": initializeParams()
        ], to: stdinPipe)
        _ = try waitForResponse(id: 1, inbox: inbox, timeout: server.startupTimeout, stderr: stderrCollector, process: process)

        try send([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ], to: stdinPipe)

        try send([
            "jsonrpc": "2.0",
            "id": 2,
            "method": method,
            "params": params
        ], to: stdinPipe)
        let response = try waitForResponse(id: 2, inbox: inbox, timeout: server.startupTimeout, stderr: stderrCollector, process: process)
        if let result = response["result"] {
            return prettyJSON(result)
        }
        return prettyJSON(response)
    }

    private static func runStreamableHTTPRequest(
        server: AgentMCPServerConfig,
        method: String,
        params: [String: Any]
    ) async throws -> String {
        guard let url = URL(string: server.url) else {
            throw AgentToolError.invalidArgument("Invalid MCP server URL: \(server.url)")
        }

        let session = URLSession(configuration: .ephemeral)
        var sessionID: String?
        let initialize = try await sendHTTPRequest(
            url: url,
            headers: resolvedHeaders(server.headers),
            sessionID: nil,
            timeout: server.startupTimeout,
            object: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": initializeParams()
            ],
            session: session
        )
        sessionID = initialize.sessionID

        _ = try await sendHTTPRequest(
            url: url,
            headers: resolvedHeaders(server.headers),
            sessionID: sessionID,
            timeout: server.startupTimeout,
            object: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ],
            session: session
        )

        let response = try await sendHTTPRequest(
            url: url,
            headers: resolvedHeaders(server.headers),
            sessionID: sessionID,
            timeout: server.startupTimeout,
            object: [
                "jsonrpc": "2.0",
                "id": 2,
                "method": method,
                "params": params
            ],
            session: session
        )
        if let result = response.object["result"] {
            return prettyJSON(result)
        }
        return prettyJSON(response.object)
    }

    private static func sendHTTPRequest(
        url: URL,
        headers: [String: String],
        sessionID: String?,
        timeout: TimeInterval,
        object: [String: Any],
        session: URLSession
    ) async throws -> (object: [String: Any], sessionID: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.commandFailed(-1, "MCP server did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AgentToolError.commandFailed(Int32(http.statusCode), text)
        }
        let nextSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID

        if data.isEmpty {
            return ([:], nextSessionID)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            return (try parseSSEJSONRPCResponse(data), nextSessionID)
        }

        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw AgentToolError.invalidArgument("MCP HTTP response is not a JSON object.")
        }
        if let error = object["error"] {
            throw AgentToolError.commandFailed(-1, prettyJSON(error))
        }
        return (object, nextSessionID)
    }

    private static func resolvedHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key, AgentCredentialStore.resolve(value))
        })
    }

    nonisolated private static func parseSSEJSONRPCResponse(_ data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("MCP SSE response is not UTF-8.")
        }

        var dataLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        for line in dataLines.reversed() {
            guard let payload = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else {
                continue
            }
            if let error = dict["error"] {
                throw AgentToolError.commandFailed(-1, prettyJSON(error))
            }
            if dict["result"] != nil || dict["id"] != nil {
                return dict
            }
        }
        throw AgentToolError.invalidArgument("MCP SSE response did not contain a JSON-RPC result.")
    }

    nonisolated private static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": ["name": "WillDeep", "version": "1"]
        ]
    }

    nonisolated private static func send(_ object: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.write(Data([0x0A]))
    }

    nonisolated private static func waitForResponse(
        id: Int,
        inbox: MCPLineInbox,
        timeout: TimeInterval,
        stderr: MCPDataCollector,
        process: Process
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = inbox.nextLine(until: deadline) else { break }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else {
                continue
            }
            guard let responseID = dict["id"] as? NSNumber, responseID.intValue == id else {
                continue
            }
            if let error = dict["error"] {
                throw AgentToolError.commandFailed(-1, prettyJSON(error))
            }
            return dict
        }

        if process.isRunning {
            process.terminate()
        }
        let stderrText = stderr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderrText.isEmpty {
            throw AgentToolError.commandTimeout
        }
        throw AgentToolError.commandFailed(-1, stderrText)
    }

    nonisolated static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        if text.count > 48_000 {
            let index = text.index(text.startIndex, offsetBy: 48_000)
            return "\(text[..<index])\n\n[truncated]"
        }
        return text
    }

    private nonisolated final class MCPLineInbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer = Data()
        private var lines: [String] = []

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            condition.lock()
            buffer.append(data)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(line)
                }
            }
            condition.signal()
            condition.unlock()
        }

        func nextLine(until deadline: Date) -> String? {
            condition.lock()
            defer { condition.unlock() }

            while lines.isEmpty {
                guard condition.wait(until: deadline) else { return nil }
            }
            return lines.removeFirst()
        }
    }

    private nonisolated final class MCPDataCollector: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
        }

        var stringValue: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
