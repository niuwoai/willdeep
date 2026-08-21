//
//  AgentMCPServerDirectory.swift
//  WillDeep
//
//  MCP settings persistence, credential redaction/storage, and server
//  discovery from user, Cursor, and Codex configuration files.
//

import Foundation

nonisolated enum AgentMCPSettingsStore {
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

    static func setServerTrusted(id: String, trusted: Bool) {
        setServerTrustLevel(id: id, level: trusted ? .standard : .untrusted)
    }

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
    /// shape carries server names). When several configured servers
    /// share a name, the safest reading wins: any untrusted match means
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

    static func isServerTrusted(id: String) -> Bool {
        let settings = load()
        return !settings.untrustedServerIDs.contains(id)
    }

    static func isServerTrusted(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lowered = trimmed.lowercased()
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

nonisolated enum AgentMCPServerDirectory {
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
        servers.append(contentsOf: loadPluginServers())

        var seenNames: Set<String> = []
        var deduped: [AgentMCPServerConfig] = []
        for var server in servers {
            server = server.normalized
            guard !server.name.isEmpty else { continue }
            let key = server.source == .plugin
                ? server.id.lowercased()
                : server.name.lowercased()
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

    /// Cursor and Codex configuration files may live on slow or busy disks.
    /// Parse them away from the main actor when presenting Settings.
    static func listAsync(includeDisabled: Bool = false) async -> [AgentMCPServerConfig] {
        await Task.detached(priority: .userInitiated) {
            list(includeDisabled: includeDisabled)
        }.value
    }

    static func server(named name: String) throws -> AgentMCPServerConfig {
        guard let server = list().first(where: { $0.name == name }) else {
            throw AgentToolError.notFound("MCP server \(name)")
        }
        return server
    }

    static func pluginServer(pluginID: AgentPluginID, named name: String) throws -> AgentMCPServerConfig {
        let serverID = "plugin:\(pluginID):\(name)"
        guard let server = list().first(where: { $0.id == serverID }) else {
            throw AgentToolError.notFound("MCP server \(name) for plugin \(pluginID)")
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

    static func parseJSONServer(
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

    static func loadPluginServers() -> [AgentMCPServerConfig] {
        AgentPluginRuntimeSnapshotStore.activePackages().flatMap { package -> [AgentMCPServerConfig] in
            guard let definitions = pluginMCPDefinitions(for: package) else { return [] }
            let declaredNames = package.manifest.map { Set($0.dependencies.mcpServers) }
                ?? Set(definitions.keys)
            guard !declaredNames.isEmpty else { return [] }
            let permissions = Set(requiredPluginPermissions(for: package))
            return definitions.compactMap { name, raw -> AgentMCPServerConfig? in
                guard declaredNames.contains(name), let dictionary = raw as? [String: Any],
                      var server = parseJSONServer(name: name, source: .plugin, dict: dictionary) else {
                    return nil
                }
                switch server.transport {
                case .stdio where !permissions.contains(.processExecute): return nil
                case .streamableHTTP where !permissions.contains(.networkAccess): return nil
                default: break
                }
                let pluginRoot = package.packageURL.path
                server.command = resolvePluginRoot(server.command, pluginRoot: pluginRoot)
                server.args = server.args.map { resolvePluginRoot($0, pluginRoot: pluginRoot) }
                guard let env = resolvePluginConfigurationMap(
                    server.env,
                    package: package,
                    pluginRoot: pluginRoot
                ), let headers = resolvePluginConfigurationMap(
                    server.headers,
                    package: package,
                    pluginRoot: pluginRoot
                ) else { return nil }
                server.env = env
                server.headers = headers
                server.id = "plugin:\(package.pluginID):\(name)"
                return server
            }
        }
    }

    /// Codex-only packages have no WillDeep permission declaration. Preserve
    /// compatibility by deriving the minimum transport permissions shown in
    /// the installation proposal. Packages with a WillDeep manifest remain
    /// strictly declaration-driven, including when their mcp.json contains
    /// additional undeclared transports.
    static func requiredPluginPermissions(for package: AgentPluginPackage) -> [AgentPluginPermission] {
        if let manifest = package.manifest {
            return manifest.permissions
        }
        guard let definitions = pluginMCPDefinitions(for: package) else { return [] }
        var permissions: Set<AgentPluginPermission> = []
        for (name, raw) in definitions {
            guard let dictionary = raw as? [String: Any],
                  let server = parseJSONServer(name: name, source: .plugin, dict: dictionary) else {
                continue
            }
            switch server.transport {
            case .stdio:
                permissions.insert(.processExecute)
            case .streamableHTTP:
                permissions.insert(.networkAccess)
            }
        }
        return permissions.sorted { $0.rawValue < $1.rawValue }
    }

    private static func pluginMCPDefinitions(for package: AgentPluginPackage) -> [String: Any]? {
        let configURL = package.packageURL.appendingPathComponent("mcp.json")
        guard let data = try? Data(contentsOf: configURL),
              data.count <= AgentPluginPackageLoader.maximumManifestBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["mcpServers"] as? [String: Any]
    }

    private static func resolvePluginRoot(_ value: String, pluginRoot: String) -> String {
        value.replacingOccurrences(of: "${pluginRoot}", with: pluginRoot)
    }

    private static func resolvePluginConfigurationMap(
        _ values: [String: String],
        package: AgentPluginPackage,
        pluginRoot: String
    ) -> [String: String]? {
        var result: [String: String] = [:]
        let settings = package.manifest?.contributes.settings ?? []
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentMCPServerConfig.isSensitiveCredentialKey(key),
               !AgentCredentialStore.isReference(trimmed),
               !trimmed.contains("${setting:") {
                // Plugin packages may reference credentials, but may never
                // smuggle a plaintext token or password through mcp.json.
                return nil
            }
            var resolved = resolvePluginRoot(value, pluginRoot: pluginRoot)
            for setting in settings {
                let placeholder = "${setting:\(setting.id)}"
                guard resolved.contains(placeholder) else { continue }
                let replacement: String
                if setting.type == .secret {
                    let account = AgentPluginSettingsStore.credentialAccount(
                        pluginID: package.pluginID,
                        settingID: setting.id
                    )
                    replacement = AgentCredentialStore.reference(account: account)
                } else {
                    replacement = AgentPluginSettingsStore.value(
                        pluginID: package.pluginID,
                        setting: setting
                    )
                }
                resolved = resolved.replacingOccurrences(of: placeholder, with: replacement)
            }
            guard !resolved.contains("${setting:") else { return nil }
            result[key] = resolved
        }
        return result
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
        case .plugin:
            return 3
        }
    }
}
