//
//  AgentMCPBridge.swift
//  VeilWriter
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
        let lowercased = key.lowercased()
        if lowercased.contains("token")
            || lowercased.contains("secret")
            || lowercased.contains("password")
            || lowercased == "authorization"
            || lowercased == "cookie"
            || lowercased.contains("key") {
            return "[redacted]"
        }
        return value
    }
}

struct AgentMCPSettings: Codable, Equatable {
    var disabledServerIDs: [String]
    var userServers: [AgentMCPServerConfig]

    static let `default` = AgentMCPSettings(disabledServerIDs: [], userServers: [])

    var normalized: AgentMCPSettings {
        var copy = self
        copy.disabledServerIDs = Array(Set(copy.disabledServerIDs.filter { !$0.isEmpty })).sorted()
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
    private static let settingsKey = "im.some.veilwriter.agentMCPSettings.v1"

    static func load() -> AgentMCPSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentMCPSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func save(_ settings: AgentMCPSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
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

    static func upsertUserServer(_ server: AgentMCPServerConfig) {
        var settings = load()
        var normalized = server.normalized
        normalized.source = .user
        normalized.id = "user:\(normalized.name)"
        settings.userServers.removeAll { $0.id == normalized.id || $0.name == normalized.name }
        settings.userServers.append(normalized)
        settings.userServers.sort { $0.name < $1.name }
        save(settings)
    }

    static func deleteUserServer(id: String) {
        var settings = load()
        settings.userServers.removeAll { $0.id == id }
        settings.disabledServerIDs.removeAll { $0 == id }
        save(settings)
    }

    static func clearAuthorizationHeader(id: String) {
        var settings = load()
        guard let index = settings.userServers.firstIndex(where: { $0.id == id }) else { return }
        settings.userServers[index].headers.removeValue(forKey: "Authorization")
        settings.userServers[index].headers.removeValue(forKey: "authorization")
        save(settings)
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
            environment[key] = value
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
            headers: server.headers,
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
            headers: server.headers,
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
            headers: server.headers,
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
            "clientInfo": ["name": "VeilWriter", "version": "1"]
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
