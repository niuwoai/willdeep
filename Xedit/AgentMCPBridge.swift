//
//  AgentMCPBridge.swift
//  WillDeep
//
//  MCP JSON-RPC bridge for listing and calling tools over stdio or
//  streamable HTTP transports. Server models, settings, and discovery
//  live in AgentMCPModels.swift and AgentMCPServerDirectory.swift.
//

import Foundation

extension Notification.Name {
    static let agentMCPResourcesDidChange = Notification.Name("AgentMCPResourcesDidChange")
}

nonisolated enum AgentMCPResourceNotificationKey {
    static let server = "server"
    static let serverID = "serverID"
    static let uri = "uri"
}

enum AgentMCPBridge {
    private static let stdioConnectionPool = MCPStdioConnectionPool()

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

    /// Read an MCP resource for a plugin sidebar or MCP App page. Keeping
    /// resource traffic in the existing bridge means stdio connection reuse,
    /// credential resolution and transport timeouts remain identical to tool
    /// discovery/calls.
    static func readResource(serverName: String, uri: String) async throws -> String {
        let server = try AgentMCPServerDirectory.server(named: serverName)
        return try await runRequest(
            server: server,
            method: "resources/read",
            params: ["uri": uri]
        )
    }

    static func readPluginResource(
        pluginID: AgentPluginID,
        serverName: String,
        uri: String
    ) async throws -> String {
        let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
        return try await runRequest(
            server: server,
            method: "resources/read",
            params: ["uri": uri]
        )
    }

    static func listResources(serverName: String) async throws -> String {
        let server = try AgentMCPServerDirectory.server(named: serverName)
        return try await runRequest(server: server, method: "resources/list", params: [:])
    }

    static func subscribeResource(serverName: String, uri: String) async throws {
        let server = try AgentMCPServerDirectory.server(named: serverName)
        guard server.transport == .stdio else { return }
        _ = try await runRequest(
            server: server,
            method: "resources/subscribe",
            params: ["uri": uri]
        )
    }

    static func subscribePluginResource(
        pluginID: AgentPluginID,
        serverName: String,
        uri: String
    ) async throws {
        let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
        guard server.transport == .stdio else { return }
        _ = try await runRequest(
            server: server,
            method: "resources/subscribe",
            params: ["uri": uri]
        )
    }

    /// Direct command entry used only after the plugin page host has shown a
    /// user confirmation. It deliberately accepts a resolved server/tool pair
    /// rather than arbitrary JSON-RPC methods.
    static func callPluginTool(
        pluginID: AgentPluginID,
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> String {
        let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
        return try await runRequest(
            server: server,
            method: "tools/call",
            params: ["name": toolName, "arguments": arguments]
        )
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
            return try await stdioConnectionPool.request(server: server, method: method, paramsData: paramsData)
        case .streamableHTTP:
            return try await runStreamableHTTPRequest(server: server, method: method, params: params)
        }
    }

    private nonisolated final class MCPStdioConnectionPool: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [String: MCPStdioConnection] = [:]

        func request(server: AgentMCPServerConfig, method: String, paramsData: Data) async throws -> String {
            let key = connectionKey(for: server)
            let connection = connection(for: key, server: server)

            do {
                return try await connection.request(method: method, paramsData: paramsData)
            } catch {
                remove(connection: connection, for: key)
                connection.invalidate()
                throw error
            }
        }

        private func connection(for key: String, server: AgentMCPServerConfig) -> MCPStdioConnection {
            lock.lock()
            defer { lock.unlock() }
            if let existing = connections[key] {
                return existing
            }
            let created = MCPStdioConnection(server: server)
            connections[key] = created
            return created
        }

        private func remove(connection: MCPStdioConnection, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if connections[key] === connection {
                connections.removeValue(forKey: key)
            }
        }

        private func connectionKey(for server: AgentMCPServerConfig) -> String {
            let envSignature = server.env
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\u{1f}")
            return [
                server.id,
                server.command,
                server.args.joined(separator: "\u{1e}"),
                envSignature
            ].joined(separator: "\u{1d}")
        }
    }

    private nonisolated final class MCPStdioConnection: @unchecked Sendable {
        private let server: AgentMCPServerConfig
        private let queue: DispatchQueue
        private var process: Process?
        private var stdinPipe: Pipe?
        private var stdoutPipe: Pipe?
        private var stderrPipe: Pipe?
        private var inbox: MCPLineInbox?
        private var stderrCollector: MCPDataCollector?
        private var nextRequestID = 1
        private var supportsResourceSubscriptions = false

        init(server: AgentMCPServerConfig) {
            self.server = server
            self.queue = DispatchQueue(label: "com.willdeep.mcp.stdio.\(server.id)")
        }

        func request(method: String, paramsData: Data) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let result = try self.requestSync(method: method, paramsData: paramsData)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func invalidate() {
            queue.async {
                self.resetProcess()
            }
        }

        private func requestSync(method: String, paramsData: Data) throws -> String {
            try ensureStarted()
            if method == "resources/subscribe", !supportsResourceSubscriptions {
                return "{}"
            }
            guard let process, let stdinPipe, let inbox, let stderrCollector else {
                throw AgentToolError.commandFailed(-1, "MCP stdio server is not running.")
            }

            let params = try JSONSerialization.jsonObject(with: paramsData, options: [.fragmentsAllowed])
            let id = nextID()
            try AgentMCPBridge.send([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ], to: stdinPipe)
            let response = try AgentMCPBridge.waitForResponse(
                id: id,
                inbox: inbox,
                timeout: server.startupTimeout,
                stderr: stderrCollector,
                process: process
            )
            if let result = response["result"] {
                return AgentMCPBridge.prettyJSON(result)
            }
            return AgentMCPBridge.prettyJSON(response)
        }

        private func ensureStarted() throws {
            if let process, process.isRunning {
                return
            }
            resetProcess()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: server.command)
            process.arguments = server.args

            var environment = AgentToolRunner.shellEnvironment()
            for (key, value) in server.env {
                environment[key] = AgentCredentialStore.resolve(value)
            }
            process.environment = environment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let inbox = MCPLineInbox(serverName: server.name, serverID: server.id)
            let stderrCollector = MCPDataCollector(limit: 32_000)
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

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

            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.inbox = inbox
            self.stderrCollector = stderrCollector

            let initializeID = nextID()
            try AgentMCPBridge.send([
                "jsonrpc": "2.0",
                "id": initializeID,
                "method": "initialize",
                "params": AgentMCPBridge.initializeParams()
            ], to: stdinPipe)
            let initializeResponse = try AgentMCPBridge.waitForResponse(
                id: initializeID,
                inbox: inbox,
                timeout: server.startupTimeout,
                stderr: stderrCollector,
                process: process
            )
            if let result = initializeResponse["result"] as? [String: Any],
               let capabilities = result["capabilities"] as? [String: Any],
               let resources = capabilities["resources"] as? [String: Any] {
                supportsResourceSubscriptions = resources["subscribe"] as? Bool == true
            }

            try AgentMCPBridge.send([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ], to: stdinPipe)
        }

        private func nextID() -> Int {
            defer { nextRequestID += 1 }
            return nextRequestID
        }

        private func resetProcess() {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            if process?.isRunning == true {
                process?.terminate()
            }
            try? stdinPipe?.fileHandleForWriting.close()
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            inbox = nil
            stderrCollector = nil
            supportsResourceSubscriptions = false
        }
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
            "protocolVersion": "2025-06-18",
            "capabilities": [
                "extensions": [
                    "io.modelcontextprotocol/ui": [
                        "mimeTypes": ["text/html;profile=mcp-app"]
                    ]
                ]
            ],
            "clientInfo": ["name": "WillDeep", "version": "1"]
        ]
    }

    nonisolated private static func send(_ object: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        // Legacy `write(_:)` raises an uncatchable ObjC exception when the
        // server died between the isRunning check and this write (broken
        // pipe), crashing the whole app. `write(contentsOf:)` throws a
        // Swift error we can surface as a tool failure instead.
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
            try pipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        } catch {
            throw AgentToolError.commandFailed(-1, "MCP server stdin write failed (server likely exited): \(error.localizedDescription)")
        }
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
        private let serverName: String
        private let serverID: String
        private let condition = NSCondition()
        private var buffer = Data()
        private var lines: [String] = []

        init(serverName: String, serverID: String) {
            self.serverName = serverName
            self.serverID = serverID
        }

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
                    publishResourceNotificationIfNeeded(line)
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

        private func publishResourceNotificationIfNeeded(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let method = dictionary["method"] as? String,
                  method == "notifications/resources/updated"
                    || method == "notifications/resources/list_changed" else { return }
            let parameters = dictionary["params"] as? [String: Any]
            var userInfo: [String: String] = [
                AgentMCPResourceNotificationKey.server: serverName,
                AgentMCPResourceNotificationKey.serverID: serverID,
            ]
            if let uri = parameters?["uri"] as? String, !uri.isEmpty {
                userInfo[AgentMCPResourceNotificationKey.uri] = uri
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .agentMCPResourcesDidChange,
                    object: nil,
                    userInfo: userInfo
                )
            }
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
