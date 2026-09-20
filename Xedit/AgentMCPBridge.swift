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

    /// 停用或卸载插件后回收它的 stdio 子进程。
    ///
    /// 停用插件时 `AgentMCPServerDirectory.list()` 立刻不再返回它的服务器，
    /// 但连接池里已经起好的进程没人管：池子的存活周期是整个 App，而它只在
    /// 请求出错时自己 `invalidate()`。于是停用一个插件之后，它的 MCP 子进程
    /// 还在后台跑着，直到退出 App。
    ///
    /// 按 id 前缀清：插件服务器的 id 形如 `plugin:<插件ID>:<服务名>`，一个
    /// 插件可以声明多个服务器，所以匹配的是前缀而不是某一个 id。
    static func invalidatePluginConnections(pluginID: String) {
        guard let prefix = pluginConnectionIDPrefix(pluginID: pluginID) else { return }
        stdioConnectionPool.invalidateAll(idPrefix: prefix)
    }

    /// 回收时用来匹配连接的 id 前缀。
    ///
    /// 单独拿出来是为了让它和 `AgentMCPServerDirectory.loadPluginServers()` 造
    /// 出的 id 形状咬在同一处，并且可以被测试直接钉住：这俩一旦对不上，回收
    /// 会静默地什么都不匹配——子进程照样留着，而没有任何报错。
    nonisolated static func pluginConnectionIDPrefix(pluginID: String) -> String? {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "plugin:\(trimmed):"
    }

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
        // 模型自己问过一次，就把插件 MCP 的工具目录一并更新——下一回合起这些
        // 工具就是一等的，不用再走三段式。
        if server.source == .plugin,
           let pluginID = AgentPluginMCPToolCatalog.pluginID(fromServerID: server.id) {
            AgentPluginMCPToolCatalog.record(
                serverID: server.id,
                pluginID: pluginID,
                serverName: server.name,
                listToolsPayload: result
            )
        }
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
        // 页面消费者是 JSON.parse：完整或报错，不要半份。
        return try await runRequest(
            server: server,
            method: "tools/call",
            params: ["name": toolName, "arguments": arguments],
            rendering: .pageFacing
        )
    }

    /// 测试入口：对一个手工构造的服务配置跑一次请求，走与正式调用相同的连接池
    /// 与等待循环。正式代码路径都先经过服务目录解析，测试造不出已安装的插件。
    static func requestForTesting(
        server: AgentMCPServerConfig,
        method: String,
        params: [String: Any]
    ) async throws -> String {
        try await runRequest(server: server, method: method, params: params, rendering: .pageFacing)
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
        params: [String: Any],
        rendering: ResultRendering = .modelFacing
    ) async throws -> String {
        switch server.transport {
        case .stdio:
            let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
            return try await stdioConnectionPool.request(
                server: server, method: method, paramsData: paramsData, rendering: rendering
            )
        case .streamableHTTP:
            return try await runStreamableHTTPRequest(
                server: server, method: method, params: params, rendering: rendering
            )
        }
    }

    private nonisolated final class MCPStdioConnectionPool: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [String: MCPStdioConnection] = [:]

        func request(server: AgentMCPServerConfig, method: String, paramsData: Data,
                     rendering: AgentMCPBridge.ResultRendering = .modelFacing) async throws -> String {
            let key = connectionKey(for: server)
            let connection = connection(for: key, server: server)

            do {
                return try await connection.request(
                    method: method, paramsData: paramsData, rendering: rendering
                )
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

        /// 关掉 id 以某前缀开头的全部连接。
        ///
        /// key 的第一段就是 `server.id`（见下面 connectionKey），所以前缀匹配
        /// 直接落在 key 上。先从字典里摘掉再 invalidate：invalidate 是把重置
        /// 派到连接自己的队列上异步做的，留在字典里会被下一次请求捞出来复用
        /// 一个正在关的连接。
        func invalidateAll(idPrefix: String) {
            lock.lock()
            let doomed = connections.filter { $0.key.hasPrefix(idPrefix) }
            for key in doomed.keys { connections.removeValue(forKey: key) }
            lock.unlock()
            for connection in doomed.values { connection.invalidate() }
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

        func request(method: String, paramsData: Data,
                     rendering: AgentMCPBridge.ResultRendering = .modelFacing) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let result = try self.requestSync(
                            method: method, paramsData: paramsData, rendering: rendering
                        )
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

        private func requestSync(method: String, paramsData: Data,
                                 rendering: AgentMCPBridge.ResultRendering) throws -> String {
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
                process: process,
                onServerRequest: serverRequestHandler(stdin: stdinPipe)
            )
            if let result = response["result"] {
                return try AgentMCPBridge.render(result, as: rendering)
            }
            return try AgentMCPBridge.render(response, as: rendering)
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
            inbox.setServerRequestHandler(serverRequestHandler(stdin: stdinPipe))
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
                "params": AgentMCPBridge.initializeParams(for: server)
            ], to: stdinPipe)
            let initializeResponse = try AgentMCPBridge.waitForResponse(
                id: initializeID,
                inbox: inbox,
                timeout: server.startupTimeout,
                stderr: stderrCollector,
                process: process,
                onServerRequest: serverRequestHandler(stdin: stdinPipe)
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

        /// 服务端反向请求的处理器：交给 `AgentMCPHostRequests`，响应写回这个
        /// 进程的 stdin。写失败（服务端刚好退出）只能放弃——等待循环随后会因为
        /// 进程退出而超时报错，不会悄悄当成成功。
        private func serverRequestHandler(stdin: Pipe) -> ([String: Any]) -> Void {
            let server = self.server
            return { message in
                let response = AgentMCPHostRequests.respondSync(to: message, server: server)
                try? AgentMCPBridge.send(response, to: stdin)
            }
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
        params: [String: Any],
        rendering: ResultRendering = .modelFacing
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
            return try render(result, as: rendering)
        }
        return try render(response.object, as: rendering)
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

    /// `server` 为 nil 或非插件服务时，形状与此前完全一致；插件的 stdio 服务
    /// 额外宣告可以反向请求哪些宿主能力（见 `AgentMCPHostRequests`）。
    nonisolated static func initializeParams(for server: AgentMCPServerConfig? = nil) -> [String: Any] {
        var extensions: [String: Any] = [
            "io.modelcontextprotocol/ui": [
                "mimeTypes": ["text/html;profile=mcp-app"]
            ]
        ]
        if let server, let hostRequests = AgentMCPHostRequests.advertisedCapability(for: server) {
            extensions[AgentMCPHostRequests.capabilityKey] = hostRequests
        }
        return [
            "protocolVersion": "2025-06-18",
            "capabilities": ["extensions": extensions],
            "clientInfo": ["name": AgentNetworkSupport.clientNameHeaderValue, "version": "1"]
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

    /// `onServerRequest`：服务端在这次请求进行中反向发来的请求。处理完之后
    /// 超时从头计：它衡量的是「服务端多久没动静」，宿主替它出图的那几十秒
    /// 不该算进服务端自己的超时里——否则 10 秒超时的插件出一张图就必然被杀。
    nonisolated private static func waitForResponse(
        id: Int,
        inbox: MCPLineInbox,
        timeout: TimeInterval,
        stderr: MCPDataCollector,
        process: Process,
        onServerRequest: (([String: Any]) -> Void)? = nil
    ) throws -> [String: Any] {
        inbox.beginWaitingForResponse()
        defer { inbox.endWaitingForResponse() }
        var deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = inbox.nextLine(until: deadline) else { break }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else {
                continue
            }
            if AgentMCPHostRequests.isServerRequest(dict) {
                // stdio 连接总会传处理器（它负责把响应写回 stdin）；没有处理器的
                // 调用方拿不到服务端的 stdin，只能跳过这一行。
                if let onServerRequest {
                    onServerRequest(dict)
                    deadline = Date().addingTimeInterval(timeout)
                }
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

    /// 谁在读这份结果。
    ///
    /// 两个消费者的要求正好相反。模型那头要省上下文，读得懂 `[truncated]`，
    /// 半份 JSON 对它只是信息少了一点。插件页面那头是 `JSON.parse`，半份
    /// JSON 直接抛 `Unterminated string`——切口落在字符串里的时候尤其像
    /// 「服务挂了」，而实际上服务好好的，是宿主把它的回答剪断了。
    ///
    /// 这个区分本来不存在：`prettyJSON` 是给模型写的，后来被顺手用在了
    /// 页面这条路上。短剧工坊一集剧本加候选图的数据轻松过 48000 字符，
    /// 于是「生成首尾帧」必然报解析错误。
    nonisolated enum ResultRendering {
        /// 缩进 + 排序 + 48000 字符截断。
        case modelFacing
        /// 紧凑、完整。宁可报错也不交出半份 JSON。
        case pageFacing
    }

    /// 页面那条路的硬上限。超过就抛错，**不截断**：一个明确的失败可以查，
    /// 一份看着像 JSON 的半截数据只会让人去查错的地方。
    nonisolated static let pageFacingResultLimit = 32 * 1024 * 1024

    nonisolated static func compactJSON(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("MCP result is not representable as JSON")
        }
        guard data.count <= pageFacingResultLimit else {
            throw AgentToolError.commandFailed(
                -1,
                "MCP result is \(data.count) bytes, over the \(pageFacingResultLimit) byte page limit"
            )
        }
        return text
    }

    nonisolated static func render(_ value: Any, as rendering: ResultRendering) throws -> String {
        switch rendering {
        case .modelFacing: return prettyJSON(value)
        case .pageFacing: return try compactJSON(value)
        }
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
        private var serverRequestHandler: (([String: Any]) -> Void)?
        private var waitingForResponse = false

        init(serverName: String, serverID: String) {
            self.serverName = serverName
            self.serverID = serverID
        }

        func setServerRequestHandler(_ handler: @escaping ([String: Any]) -> Void) {
            condition.lock()
            serverRequestHandler = handler
            condition.unlock()
        }

        func beginWaitingForResponse() {
            condition.lock()
            waitingForResponse = true
            condition.unlock()
        }

        func endWaitingForResponse() {
            condition.lock()
            waitingForResponse = false
            condition.unlock()
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            var serverRequests: [[String: Any]] = []
            var handler: (([String: Any]) -> Void)?
            condition.lock()
            buffer.append(data)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let data = line.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data),
                       let dictionary = object as? [String: Any],
                       AgentMCPHostRequests.isServerRequest(dictionary) {
                        if waitingForResponse {
                            lines.append(line)
                        } else {
                            serverRequests.append(dictionary)
                        }
                    } else {
                        lines.append(line)
                        publishResourceNotificationIfNeeded(line)
                    }
                }
            }
            handler = serverRequestHandler
            condition.signal()
            condition.unlock()
            serverRequests.forEach { handler?($0) }
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
