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
    /// MCP 服务器发了 `notifications/tools/list_changed`；userInfo 同 `AgentMCPResourceNotificationKey`。
    static let agentMCPToolsDidChange = Notification.Name("AgentMCPToolsDidChange")
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
        return try await callToolForModel(
            server: server,
            toolName: toolName,
            arguments: toolArguments,
            summary: "\(server.name).\(toolName)",
            style: .indented
        )
    }

    /// 插件 MCP 工具的一等入口（`mcp__<服务器>__<工具>`），给模型用。
    ///
    /// 与 `callPluginTool` 分开：那条给插件页面 / MCP App，要的是原始 MCP
    /// result（`executeCommand` 的既有契约），这条给模型，二进制块要剥掉。
    static func callPluginToolForModel(
        pluginID: AgentPluginID,
        serverName: String,
        toolName: String,
        arguments: [String: Any]
    ) async throws -> AgentToolResult {
        let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
        return try await callToolForModel(
            server: server,
            toolName: toolName,
            arguments: arguments,
            summary: "\(serverName)/\(toolName)",
            style: .compact
        )
    }

    /// 模型那条路的 `tools/call`：取完整结果，图片挂成附件，音频与资源二进制
    /// 落盘，文本里只留说明。
    private static func callToolForModel(
        server: AgentMCPServerConfig,
        toolName: String,
        arguments: [String: Any],
        summary: String,
        style: AgentMCPToolResultContent.PayloadStyle,
        storage: AgentMCPToolResultContent.Storage = .standard
    ) async throws -> AgentToolResult {
        let result = try await runRequest(
            server: server,
            method: "tools/call",
            params: [
                "name": toolName,
                "arguments": arguments
            ],
            rendering: .complete
        )
        let toolResult = await AgentMCPToolResultContent.toolResult(
            summary: summary,
            resultJSON: result,
            style: style,
            storage: storage
        )
        return try AgentMCPToolResultContent.enforcePayloadLimit(toolResult, style: style)
    }

    /// 测试入口：对手工构造的服务配置走一遍模型那条路的 `tools/call`。
    static func callToolForModelTesting(
        server: AgentMCPServerConfig,
        toolName: String,
        arguments: [String: Any],
        style: AgentMCPToolResultContent.PayloadStyle,
        storage: AgentMCPToolResultContent.Storage
    ) async throws -> AgentToolResult {
        try await callToolForModel(
            server: server,
            toolName: toolName,
            arguments: arguments,
            summary: "\(server.name).\(toolName)",
            style: style,
            storage: storage
        )
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
    ///
    /// Returns the raw MCP result, binary blocks included: pages and MCP Apps
    /// render them themselves. The model-facing counterpart is
    /// `callPluginToolForModel`.
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

    /// 插件 MCP 网关（`AgentPluginMCPGateway`）：确保插件的 MCP 进程已起。
    ///
    /// 插件没在运行时，经与页面、模型同一个连接池发一次 `tools/list`：按平常的
    /// 方式拉起（进程、反向请求能力、环境变量完全一致），结果顺手刷新聊天用的
    /// 插件工具目录。错误在主 actor 上转成文字再交出去，网关那头不在主 actor 上。
    static func ensurePluginServerStartedForGateway(pluginID: AgentPluginID, serverName: String) async throws {
        do {
            let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
            guard let result = try await ensureStartedForGateway(server: server) else { return }
            AgentPluginMCPToolCatalog.record(
                serverID: server.id,
                pluginID: pluginID,
                serverName: server.name,
                listToolsPayload: result
            )
        } catch {
            throw AgentPluginMCPGatewayHostError(message: gatewayErrorMessage(error))
        }
    }

    /// 返回这次探测拿到的 `tools/list` 结果；连接已经活着、没有探测时返回 nil。
    ///
    /// 进程活着、握手做过，就算「已启动」，不再发探测：网关每条请求都要先过这一步，
    /// 探测会排在这条连接的串行队列后面，还受插件应答超时约束。插件正忙的时候
    /// （一条经 stdio 的工具调用在等宿主出图），探测要么干等一两分钟，要么超时把
    /// 正在干活的进程结束掉——2026-09-27 短剧工坊批量出图时插件就这样被反复重启。
    private static func ensureStartedForGateway(server: AgentMCPServerConfig) async throws -> String? {
        if server.transport == .stdio, stdioConnectionPool.hasLiveConnection(for: server) {
            return nil
        }
        return try await runRequest(server: server, method: "tools/list", params: [:], rendering: .pageFacing)
    }

    /// 插件工具目录预热（`AgentPluginMCPToolWarmup`，1.410.0-rc1）：问一次 `tools/list` 写进目录。
    ///
    /// `skipIfLive`：stdio 连接已经活着时不问——插件可能正忙着一条长调用（等宿主出图），
    /// 探测会排在后面干等，还受应答超时约束（见 `ensureStartedForGateway` 的注释）。
    /// 插件自己发了 `tools/list_changed` 时传 false：那一刻它显然没在忙。
    /// 返回是否真的问了。
    @discardableResult
    static func refreshPluginToolCatalog(
        server: AgentMCPServerConfig,
        pluginID: AgentPluginID,
        packageDigest: String?,
        skipIfLive: Bool
    ) async throws -> Bool {
        if skipIfLive, server.transport == .stdio, stdioConnectionPool.hasLiveConnection(for: server) {
            return false
        }
        let result = try await runRequest(server: server, method: "tools/list", params: [:], rendering: .pageFacing)
        AgentPluginMCPToolCatalog.record(
            serverID: server.id,
            pluginID: pluginID,
            serverName: server.name,
            listToolsPayload: result,
            packageDigest: packageDigest
        )
        return true
    }

    /// 插件 MCP 网关：插件没有公布自己的 HTTP 入口时，经宿主的 MCP 客户端中转
    /// 一条请求。返回紧凑、完整的 `result` JSON（与页面同一种渲染）。
    static func relayPluginRequestForGateway(
        pluginID: AgentPluginID,
        serverName: String,
        method: String,
        paramsJSON: Data
    ) async throws -> String {
        do {
            let server = try AgentMCPServerDirectory.pluginServer(pluginID: pluginID, named: serverName)
            let params = try JSONSerialization.jsonObject(with: paramsJSON) as? [String: Any] ?? [:]
            return try await runRequest(server: server, method: method, params: params, rendering: .pageFacing)
        } catch {
            throw AgentPluginMCPGatewayHostError(message: gatewayErrorMessage(error))
        }
    }

    /// `commandTimeout` 的通用文案是写给模型的（「改用后台运行」），外部客户端
    /// 看了只会困惑，这里换成说清是插件没按时应答。
    private static func gatewayErrorMessage(_ error: Error) -> String {
        if case AgentToolError.commandTimeout = error {
            return "Plugin MCP server did not answer before the host's stdio timeout."
        }
        return error.localizedDescription
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

    /// 测试入口：网关「确保已启动」的判断，返回这次是否真的发了 `tools/list`。
    static func ensureStartedForGatewayForTesting(server: AgentMCPServerConfig) async throws -> Bool {
        try await ensureStartedForGateway(server: server) != nil
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
        if AgentPluginRuntimeWorkflow.routes(server: server, method: method, params: params),
           let name = params["name"] as? String {
            return try await AgentPluginRuntimeWorkflow.call(tool: name, arguments: params["arguments"] as? [String: Any] ?? [:])
        }
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
            } catch let answered as MCPErrorResponse {
                // 服务端好好地回了一个 JSON-RPC 错误：连接没坏，不重启进程。
                // 重启会连带打断它手上别的活，比如正在等宿主出图的那一张。
                throw answered.error
            } catch {
                remove(connection: connection, for: key)
                connection.invalidate()
                throw error
            }
        }

        /// 这个服务已有一条握手完成、进程还活着的连接。不排连接队列，任何线程都能问。
        func hasLiveConnection(for server: AgentMCPServerConfig) -> Bool {
            lock.lock()
            let existing = connections[connectionKey(for: server)]
            lock.unlock()
            return existing?.isLive == true
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

    /// 服务端回了一个 JSON-RPC 错误：请求失败了，连接本身没坏。只在连接池里认，
    /// 交给调用方之前换回 `error`。
    private nonisolated struct MCPErrorResponse: Error {
        let error: AgentToolError
    }

    private nonisolated final class MCPStdioConnection: @unchecked Sendable {
        private let server: AgentMCPServerConfig
        private let queue: DispatchQueue
        // 以下状态只在 `queue` 上读写。
        private var process: Process?
        private var stdin: MCPStdinWriter?
        private var stdoutPipe: Pipe?
        private var stderrPipe: Pipe?
        private var inbox: MCPLineInbox?
        private var stderrCollector: MCPDataCollector?
        private var nextRequestID = 1
        private var supportsResourceSubscriptions = false

        /// 握手完成的进程，给 `isLive` 用。它要在队列之外读（队列可能正被一条
        /// 等宿主出图的请求占着一两分钟），所以单独上锁，不和上面那组放一起。
        private let liveLock = NSLock()
        private var liveProcess: Process?

        init(server: AgentMCPServerConfig) {
            self.server = server
            self.queue = DispatchQueue(label: "com.willdeep.mcp.stdio.\(server.id)")
        }

        /// 进程已起、握手已完成、还在运行。
        var isLive: Bool {
            liveLock.lock()
            defer { liveLock.unlock() }
            return liveProcess?.isRunning == true
        }

        private func setLiveProcess(_ process: Process?) {
            liveLock.lock()
            liveProcess = process
            liveLock.unlock()
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
            guard let process, let stdin, let inbox, let stderrCollector else {
                throw AgentToolError.commandFailed(-1, "MCP stdio server is not running.")
            }

            let params = try JSONSerialization.jsonObject(with: paramsData, options: [.fragmentsAllowed])
            let id = nextID()
            try stdin.send([
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params
            ])
            let response = try AgentMCPBridge.waitForResponse(
                id: id,
                inbox: inbox,
                timeout: server.startupTimeout,
                stderr: stderrCollector,
                process: process
            )
            if let error = response["error"] {
                throw MCPErrorResponse(error: .commandFailed(-1, AgentMCPBridge.prettyJSON(error)))
            }
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
            let stdin = MCPStdinWriter(pipe: stdinPipe)
            let inbox = MCPLineInbox(
                serverName: server.name,
                serverID: server.id,
                onServerRequest: Self.serverRequestHandler(server: server, stdin: stdin)
            )
            let stderrCollector = MCPDataCollector(limit: 32_000)
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // 读到 EOF 就摘掉 handler：插件死了又没人再调它时，不摘会每根管道
            // 钉死一个核空转（实测 3 个死插件把 App 顶到 230% CPU）。
            AgentPipeEOFReader.attach(to: stdoutPipe.fileHandleForReading) { data in
                inbox.append(data)
            }
            AgentPipeEOFReader.attach(to: stderrPipe.fileHandleForReading) { data in
                stderrCollector.append(data)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                throw AgentToolError.commandFailed(-1, error.localizedDescription)
            }

            self.process = process
            self.stdin = stdin
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.inbox = inbox
            self.stderrCollector = stderrCollector

            let initializeID = nextID()
            try stdin.send([
                "jsonrpc": "2.0",
                "id": initializeID,
                "method": "initialize",
                "params": AgentMCPBridge.initializeParams(for: server)
            ])
            let initializeResponse = try AgentMCPBridge.waitForResponse(
                id: initializeID,
                inbox: inbox,
                timeout: server.startupTimeout,
                stderr: stderrCollector,
                process: process
            )
            // 握手失败不走 MCPErrorResponse：进程起了却没握上手，下一次请求
            // 必须重来，所以要让连接池把它当坏连接丢掉。
            if let error = initializeResponse["error"] {
                throw AgentToolError.commandFailed(-1, AgentMCPBridge.prettyJSON(error))
            }
            if let result = initializeResponse["result"] as? [String: Any],
               let capabilities = result["capabilities"] as? [String: Any],
               let resources = capabilities["resources"] as? [String: Any] {
                supportsResourceSubscriptions = resources["subscribe"] as? Bool == true
            }

            try stdin.send([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ])
            setLiveProcess(process)
        }

        private func nextID() -> Int {
            defer { nextRequestID += 1 }
            return nextRequestID
        }

        /// 服务端反向请求的处理器：交给 `AgentMCPHostRequests`，响应写回这个
        /// 进程的 stdin。写失败（服务端刚好退出）只能放弃——等它应答的请求
        /// 随后会因为进程退出而超时报错，不会悄悄当成成功。
        private static func serverRequestHandler(
            server: AgentMCPServerConfig,
            stdin: MCPStdinWriter
        ) -> MCPLineInbox.ServerRequestHandler {
            { message in
                let response = await AgentMCPHostRequests.respond(
                    to: message,
                    server: server,
                    within: AgentMCPHostRequests.handlingLimit(for: message)
                )
                try? stdin.send(response)
            }
        }

        private func resetProcess() {
            setLiveProcess(nil)
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            if process?.isRunning == true {
                process?.terminate()
            }
            stdin?.close()
            process = nil
            stdin = nil
            stdoutPipe = nil
            stderrPipe = nil
            inbox = nil
            stderrCollector = nil
            supportsResourceSubscriptions = false
        }
    }

    /// 往服务端 stdin 写一行 JSON。
    ///
    /// 宿主自己的请求在连接队列上写，反向请求的应答在处理它的任务里写，两边
    /// 会同时写同一根管道。超过 PIPE_BUF（512 字节）的写入不保证原子，不加锁
    /// 两行会交错成一行坏 JSON，所以一行（连同换行符）在锁里一次写完。
    private nonisolated final class MCPStdinWriter: @unchecked Sendable {
        private let pipe: Pipe
        private let lock = NSLock()

        init(pipe: Pipe) {
            self.pipe = pipe
        }

        func send(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [])
            line.append(0x0A)
            lock.lock()
            defer { lock.unlock() }
            // Legacy `write(_:)` raises an uncatchable ObjC exception when the
            // server died between the isRunning check and this write (broken
            // pipe), crashing the whole app. `write(contentsOf:)` throws a
            // Swift error we can surface as a tool failure instead.
            do {
                try pipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                throw AgentToolError.commandFailed(-1, "MCP server stdin write failed (server likely exited): \(error.localizedDescription)")
            }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            try? pipe.fileHandleForWriting.close()
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

    /// 等 `id` 的应答，原样交回（含 `error`，由调用方决定怎么算）。
    ///
    /// 超时衡量的是「服务端多久没动静」，由 `MCPLineInbox.nextLine` 计：宿主替它
    /// 办反向请求（出图）的那几十秒不算进去，否则 10 秒超时的插件出一张图就必然
    /// 被杀。反向请求不经过这里，读 stdout 的时候就交出去处理了。
    nonisolated private static func waitForResponse(
        id: Int,
        inbox: MCPLineInbox,
        timeout: TimeInterval,
        stderr: MCPDataCollector,
        process: Process
    ) throws -> [String: Any] {
        let started = Date()
        while let line = inbox.nextLine(silenceTimeout: timeout, since: started) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else {
                continue
            }
            guard let responseID = dict["id"] as? NSNumber, responseID.intValue == id else {
                continue
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
        /// 紧凑、完整、不设页面上限：模型那条路的 `tools/call` 要先经
        /// `AgentMCPToolResultContent` 把图片、音频等二进制块剥出来再给模型。
        /// 先截断再剥就晚了——48000 字符里一张图都放不下，切口还会落在
        /// base64 中间，JSON 解不开，二进制块只能原样留在文本里。
        case complete
    }

    /// 页面那条路的硬上限。超过就抛错，**不截断**：一个明确的失败可以查，
    /// 一份看着像 JSON 的半截数据只会让人去查错的地方。
    nonisolated static let pageFacingResultLimit = 32 * 1024 * 1024

    /// `limit` 为 nil 时不设上限。
    nonisolated static func compactJSON(_ value: Any, limit: Int? = pageFacingResultLimit) throws -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.invalidArgument("MCP result is not representable as JSON")
        }
        if let limit, data.count > limit {
            throw AgentToolError.commandFailed(
                -1,
                "MCP result is \(data.count) bytes, over the \(limit) byte page limit"
            )
        }
        return text
    }

    nonisolated static func render(_ value: Any, as rendering: ResultRendering) throws -> String {
        switch rendering {
        case .modelFacing: return prettyJSON(value)
        case .pageFacing: return try compactJSON(value)
        case .complete:
            // 协议里 result 总是对象；万一不是，按模型那份的老办法转成文本，
            // 解析器认不出就原样交出去。
            guard JSONSerialization.isValidJSONObject(value) else { return prettyJSON(value) }
            return try compactJSON(value, limit: nil)
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

    /// 服务端 stdout 的收件箱：应答与通知按行排队给等待方，反向请求当场交给
    /// 处理器、另起任务去办。
    ///
    /// `append` 跑在读 stdout 的线程上，这条线程一停，后面的应答就都读不进来了。
    /// 所以反向请求绝不能在这里等它办完：出一张图一两分钟，这期间服务端对别的
    /// 请求（网关探活的 `tools/list`、页面的读取）的应答全被堵在管道里，宿主等
    /// 不到就判它超时、把它结束，正在出的图也跟着断了（2026-09-27 短剧工坊）。
    private nonisolated final class MCPLineInbox: @unchecked Sendable {
        typealias ServerRequestHandler = @Sendable ([String: Any]) async -> Void

        private let serverName: String
        private let serverID: String
        private let onServerRequest: ServerRequestHandler
        private let condition = NSCondition()
        private var framer = AgentMCPLineFramer()
        private var lines: [String] = []
        /// 宿主正在替服务端办、还没答复的反向请求数。
        private var pendingHostRequests = 0
        /// 最近一次答完反向请求的时刻。
        private var lastHostRequestFinishedAt = Date.distantPast

        init(serverName: String, serverID: String, onServerRequest: @escaping ServerRequestHandler) {
            self.serverName = serverName
            self.serverID = serverID
            self.onServerRequest = onServerRequest
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            var serverRequests: [MCPJSONMessage] = []
            condition.lock()
            for lineData in framer.append(data) {
                if let line = String(data: lineData, encoding: .utf8),
                   !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let data = line.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data),
                       let dictionary = object as? [String: Any],
                       AgentMCPHostRequests.isServerRequest(dictionary) {
                        serverRequests.append(MCPJSONMessage(value: dictionary))
                    } else {
                        lines.append(line)
                        publishResourceNotificationIfNeeded(line)
                    }
                }
            }
            // 在同一把锁里记账：等待方醒来时要么看到新行，要么看到有反向请求
            // 在办，不会在两者之间误判超时。
            pendingHostRequests += serverRequests.count
            condition.broadcast()
            condition.unlock()

            let handler = onServerRequest
            for request in serverRequests {
                Task.detached(priority: .userInitiated) {
                    await handler(request.value)
                    self.finishHostRequest()
                }
            }
        }

        private func finishHostRequest() {
            condition.lock()
            pendingHostRequests -= 1
            lastHostRequestFinishedAt = Date()
            condition.broadcast()
            condition.unlock()
        }

        /// 等下一行，服务端沉默超过 `timeout` 就返回 nil。
        ///
        /// 沉默从 `since` 起算。有反向请求在办时不计时——服务端可能正等着宿主的
        /// 答复，没法应答别的；最后一个答完之后从那一刻重新计。反向请求自己有
        /// 处理上限（`AgentMCPHostRequests.maximumHandlingSeconds`），这里不会
        /// 无限等下去。
        func nextLine(silenceTimeout timeout: TimeInterval, since start: Date) -> String? {
            condition.lock()
            defer { condition.unlock() }

            while lines.isEmpty {
                if pendingHostRequests > 0 {
                    condition.wait()
                    continue
                }
                let deadline = max(start, lastHostRequestFinishedAt).addingTimeInterval(timeout)
                guard Date() < deadline else { return nil }
                condition.wait(until: deadline)
            }
            return lines.removeFirst()
        }

        private func publishResourceNotificationIfNeeded(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let method = dictionary["method"] as? String else { return }
            // 工具清单变了（1.410.0-rc1）：交给预热重新拉一次，聊天用的插件工具目录跟着更新。
            if method == "notifications/tools/list_changed" {
                let userInfo = [
                    AgentMCPResourceNotificationKey.server: serverName,
                    AgentMCPResourceNotificationKey.serverID: serverID,
                ]
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .agentMCPToolsDidChange, object: nil, userInfo: userInfo)
                }
                return
            }
            guard method == "notifications/resources/updated"
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

    /// JSON 对象本身不是 Sendable；反向请求从读 stdout 的线程交给处理任务时只交接
    /// 一次，之后没有并发读写。
    private nonisolated struct MCPJSONMessage: @unchecked Sendable {
        let value: [String: Any]
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
