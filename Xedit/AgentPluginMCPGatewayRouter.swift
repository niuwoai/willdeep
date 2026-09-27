//
//  AgentPluginMCPGatewayRouter.swift
//  WillDeep
//
//  插件 MCP 网关的请求处理：准入（Host / Origin / Bearer）、路由、JSON-RPC
//  分派，以及「转发到插件自己的 HTTP 入口」与「经宿主 stdio 客户端中转」
//  之间的选择。不碰套接字，也不直接碰进程和网络——这些经注入的
//  `AgentPluginMCPGatewayHost` / `AgentPluginMCPGatewayForwarder` 完成，
//  所以单测不会拉起任何插件进程。
//
//  契约见 docs/decisions/0001-plugin-mcp-gateway.md。
//

import Foundation
import os

/// 网关对外暴露的一个插件 MCP 服务。
nonisolated struct AgentPluginMCPGatewayServer: Equatable, Sendable {
    let pluginID: String
    let serverName: String
    let pluginVersion: String
}

/// 宿主侧出错时带回给客户端的说明。宿主那头的错误类型大多是主 actor 上的
/// `LocalizedError`，离开主 actor 再取描述不可靠，所以在宿主那头就转成文字。
nonisolated struct AgentPluginMCPGatewayHostError: Error, Equatable, Sendable {
    let message: String
}

/// 网关要用到的宿主能力。
nonisolated protocol AgentPluginMCPGatewayHost: Sendable {
    /// 已启用插件里、当前已启用的 MCP 服务。
    func activeServers() -> [AgentPluginMCPGatewayServer]
    /// 经宿主平时用的 MCP 客户端连接发一次 `tools/list`：插件没在运行就按
    /// 平常的方式拉起它，结果顺手刷新聊天用的插件工具目录。
    func ensureStarted(_ server: AgentPluginMCPGatewayServer) async throws
    /// 经宿主的 MCP 客户端中转一条请求，返回紧凑、完整的 `result` JSON 文本。
    func relay(_ server: AgentPluginMCPGatewayServer, method: String, paramsJSON: Data) async throws -> String
}

/// 插件自己在数据目录里公布的 HTTP 入口（`mcp-http.json`）。
nonisolated struct AgentPluginMCPGatewayEndpoint: Equatable, Sendable {
    let url: URL
    let token: String
}

nonisolated struct AgentPluginMCPGatewayForwardResult: Equatable, Sendable {
    let status: Int
    let contentType: String?
    let body: Data
}

nonisolated enum AgentPluginMCPGatewayForwardError: Error, Equatable, Sendable {
    /// 连接被拒：请求根本没送到插件手里，换条路再发一遍是安全的。
    case connectionRefused
    /// 其他失败（超时、中途断开……）：插件可能已经在执行了，不能重发。
    case failed(String)
}

nonisolated protocol AgentPluginMCPGatewayForwarder: Sendable {
    func forward(body: Data, to endpoint: AgentPluginMCPGatewayEndpoint) async throws -> AgentPluginMCPGatewayForwardResult
}

/// 读插件数据目录下的 `mcp-http.json`。
nonisolated struct AgentPluginMCPGatewayEndpointReader: Sendable {
    static let fileName = "mcp-http.json"
    static let parentPIDKey = "parentPID"
    private static let maximumFileBytes = 64 * 1024
    /// 文件是插件写的，记日志时字段截断，免得一份怪文件把日志撑满。
    private static let loggedFieldLimit = 32

    /// `plugin-data` 目录；每个插件的数据目录是它下面的 `<pluginID>/`。
    let pluginDataRoot: URL
    /// 网关所在进程，也就是拉起插件的进程：`AgentMCPBridge` 直接 spawn 插件
    /// `mcp.json` 里的命令（短剧工坊是 `/usr/bin/ruby`），中间没有 shell。
    var gatewayProcessID: Int32 = ProcessInfo.processInfo.processIdentifier

    func endpoint(pluginID: String) -> AgentPluginMCPGatewayEndpoint? {
        guard AgentPluginMCPGatewayRouter.isValidPluginID(pluginID) else { return nil }
        let fileURL = pluginDataRoot
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = object["url"] as? String,
              let token = object["token"] as? String,
              !token.isEmpty,
              let url = Self.loopbackURL(rawURL) else {
            return nil
        }
        // 契约修订 1：文件写明了拉起者、却不是本进程，就是别的宿主（如 willdeep-rs）
        // 拉起的插件写的。转过去会落进一个没有本宿主注入的设置、反向请求也发回
        // 别的宿主的进程（2026-09-27「Video API key is not configured.」），所以当作
        // 没公布，走 stdio 中转回到自己拉起的插件。不带这个字段的旧文件照旧接受。
        if let rawParentPID = object[Self.parentPIDKey],
           !Self.parentPID(rawParentPID, matches: gatewayProcessID) {
            let parentPID = String(String(describing: rawParentPID).prefix(Self.loggedFieldLimit))
            let host = String((object["host"] as? String ?? "-").prefix(Self.loggedFieldLimit))
            AgentPluginMCPGateway.log.info(
                "plugin endpoint ignored: plugin=\(pluginID, privacy: .public) parentPID=\(parentPID, privacy: .public) gatewayPID=\(gatewayProcessID, privacy: .public) host=\(host, privacy: .public)"
            )
            return nil
        }
        return AgentPluginMCPGatewayEndpoint(url: url, token: token)
    }

    /// `parentPID` 必须是等于 `processID` 的整数；布尔、小数、字符串、null 都不算，
    /// 认不出拉起者的文件同样不转发。
    static func parentPID(_ raw: Any, matches processID: Int32) -> Bool {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int32(exactly: number.doubleValue) else {
            return false
        }
        return value == processID
    }

    /// 契约：只认 `http://127.0.0.1:<端口>/…`。这份文件是插件写的，宿主不能
    /// 被它指到别的主机上去，把插件的 token 和客户端的请求体一起送出去。
    static func loopbackURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.user == nil, components.password == nil,
              components.path.hasPrefix("/"),
              let url = components.url else {
            return nil
        }
        return url
    }
}

nonisolated struct AgentPluginMCPGatewayRouter: Sendable {
    /// 客户端没带 `protocolVersion` 时回这个版本。
    static let defaultProtocolVersion = "2025-06-18"

    nonisolated enum JSONRPCErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let invalidParams = -32602
        static let internalError = -32603
    }

    let token: String
    let host: any AgentPluginMCPGatewayHost
    let forwarder: any AgentPluginMCPGatewayForwarder
    let endpoints: AgentPluginMCPGatewayEndpointReader
    var makeSessionID: @Sendable () -> String = { UUID().uuidString.lowercased() }

    /// 这次请求走了哪条路，给日志用。
    nonisolated enum Disposition: String, Sendable {
        case rejected
        case gateway
        case forwarded
        case relayed
    }

    nonisolated struct Outcome: Sendable {
        let response: AgentPluginMCPGatewayHTTPResponse
        let disposition: Disposition
        let pluginID: String?
        let serverName: String?
        let rpcMethod: String?
    }

    func handle(_ request: AgentPluginMCPGatewayHTTPRequest) async -> Outcome {
        if let rejection = Self.admissionFailure(for: request, token: token) {
            return Outcome(response: rejection, disposition: .rejected, pluginID: nil, serverName: nil, rpcMethod: nil)
        }
        guard let route = Self.route(path: request.path),
              let server = host.activeServers().first(where: {
                  $0.pluginID == route.pluginID && $0.serverName == route.serverName
              }) else {
            return Outcome(
                response: .plainError(status: 404, message: "Unknown or disabled plugin MCP server."),
                disposition: .rejected, pluginID: nil, serverName: nil, rpcMethod: nil
            )
        }
        guard request.method == "POST" else {
            return Outcome(
                response: .plainError(
                    status: 405,
                    message: "Use POST for MCP JSON-RPC.",
                    extraHeaders: [.init(name: "Allow", value: "POST")]
                ),
                disposition: .rejected, pluginID: server.pluginID, serverName: server.serverName, rpcMethod: nil
            )
        }
        return await handleJSONRPC(body: request.body, server: server)
    }

    // MARK: - 准入

    /// Host → Origin → Bearer 依次检查；全过返回 nil。
    static func admissionFailure(
        for request: AgentPluginMCPGatewayHTTPRequest,
        token: String
    ) -> AgentPluginMCPGatewayHTTPResponse? {
        // 防 DNS rebinding：浏览器被骗来访问时，Host 是攻击者的域名。
        guard let hostHeader = request.header("host"), isAllowedHostHeader(hostHeader) else {
            return .plainError(status: 403, message: "Host not allowed.")
        }
        if let origin = request.header("origin"), !isLocalOrigin(origin) {
            return .plainError(status: 403, message: "Origin not allowed.")
        }
        guard let presented = bearerToken(from: request.header("authorization")),
              constantTimeEquals(presented, token) else {
            return .plainError(
                status: 401,
                message: "Unauthorized.",
                extraHeaders: [.init(name: "WWW-Authenticate", value: "Bearer")]
            )
        }
        return nil
    }

    static func isAllowedHostHeader(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let hostPart: Substring
        if let colon = trimmed.lastIndex(of: ":") {
            let port = trimmed[trimmed.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            hostPart = trimmed[..<colon]
        } else {
            hostPart = Substring(trimmed)
        }
        let host = hostPart.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    static func isLocalOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
    }

    static func bearerToken(from header: String?) -> String? {
        guard let header = header?.trimmingCharacters(in: .whitespaces) else { return nil }
        let scheme = "bearer "
        guard header.count > scheme.count, header.lowercased().hasPrefix(scheme) else { return nil }
        let value = header.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// 常量时间比较：耗时只取决于长度，不取决于从第几个字节开始不同。
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0 && left.count == right.count
    }

    // MARK: - 路由

    /// `/plugins/<pluginID>/<server>/mcp`，段内允许百分号编码。
    static func route(path: String) -> (pluginID: String, serverName: String)? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 5,
              segments[0].isEmpty,
              segments[1] == "plugins",
              segments[4] == "mcp",
              let pluginID = segments[2].removingPercentEncoding,
              let serverName = segments[3].removingPercentEncoding,
              isValidPluginID(pluginID),
              !serverName.isEmpty,
              !serverName.contains("/") else {
            return nil
        }
        return (pluginID, serverName)
    }

    /// 与插件生成媒体目录同一条规则：插件 ID 会拼进数据目录路径。
    static func isValidPluginID(_ pluginID: String) -> Bool {
        pluginID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    // MARK: - JSON-RPC

    private func handleJSONRPC(body: Data, server: AgentPluginMCPGatewayServer) async -> Outcome {
        func outcome(_ response: AgentPluginMCPGatewayHTTPResponse, _ disposition: Disposition, _ method: String?) -> Outcome {
            Outcome(response: response, disposition: disposition,
                    pluginID: server.pluginID, serverName: server.serverName, rpcMethod: method)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return outcome(Self.rpcError(id: nil, code: JSONRPCErrorCode.parseError,
                                         message: "Parse error.", status: 400), .rejected, nil)
        }
        // 契约：只收单条 JSON-RPC 对象，批量数组也回 -32600。
        guard let message = parsed as? [String: Any] else {
            return outcome(Self.rpcError(id: nil, code: JSONRPCErrorCode.invalidRequest,
                                         message: "Expected a single JSON-RPC object.", status: 400), .rejected, nil)
        }
        let hasID = message.keys.contains("id")
        let id = message["id"]
        if hasID, !Self.isValidID(id) {
            return outcome(Self.rpcError(id: nil, code: JSONRPCErrorCode.invalidRequest,
                                         message: "Invalid JSON-RPC id.", status: 400), .rejected, nil)
        }
        guard let method = message["method"] as? String else {
            // 客户端回给服务端请求的响应：网关不发服务端请求，收下即可。
            if hasID, message["result"] != nil || message["error"] != nil {
                return outcome(.empty(status: 202), .gateway, nil)
            }
            return outcome(Self.rpcError(id: hasID ? id : nil, code: JSONRPCErrorCode.invalidRequest,
                                         message: "Missing JSON-RPC method.", status: 400), .rejected, nil)
        }
        // 通知（含 notifications/initialized）：202、空体、不转发。
        guard hasID else { return outcome(.empty(status: 202), .gateway, method) }

        switch method {
        case "initialize":
            return outcome(initializeResponse(id: id, params: message["params"], server: server), .gateway, method)
        case "ping":
            return outcome(Self.rpcResult(id: id, resultJSON: Data("{}".utf8)), .gateway, method)
        default:
            let (response, disposition) = await dispatch(body: body, id: id, method: method,
                                                         params: message["params"], server: server)
            return outcome(response, disposition, method)
        }
    }

    /// 网关自己应答 initialize，不转给插件：第三方客户端的能力声明不能覆盖
    /// 宿主在 stdio 那头宣告的反向请求能力。
    private func initializeResponse(
        id: Any?,
        params: Any?,
        server: AgentPluginMCPGatewayServer
    ) -> AgentPluginMCPGatewayHTTPResponse {
        let requested = (params as? [String: Any])?["protocolVersion"] as? String
        let protocolVersion = requested?.isEmpty == false ? requested! : Self.defaultProtocolVersion
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": [
                "name": "\(server.pluginID)/\(server.serverName)",
                "version": server.pluginVersion
            ]
        ]
        let resultJSON = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Self.rpcResult(
            id: id,
            resultJSON: resultJSON,
            extraHeaders: [.init(name: "Mcp-Session-Id", value: makeSessionID())]
        )
    }

    private func dispatch(
        body: Data,
        id: Any?,
        method: String,
        params: Any?,
        server: AgentPluginMCPGatewayServer
    ) async -> (AgentPluginMCPGatewayHTTPResponse, Disposition) {
        // 1. 确保插件已启动（没在运行就按平常的方式拉起）。
        do {
            try await host.ensureStarted(server)
        } catch {
            return (Self.rpcError(id: id, code: JSONRPCErrorCode.internalError,
                                  message: "Plugin MCP server is not available: \(Self.describe(error))"), .relayed)
        }

        // 2. 插件公布了自己的 HTTP 入口就优先转发：宿主对单个 stdio 请求有启动
        //    超时并串行执行，出图、审核这类一两分钟的调用走中转会被超时结束。
        if let endpoint = endpoints.endpoint(pluginID: server.pluginID) {
            switch await forwardOnce(body: body, id: id, to: endpoint) {
            case .delivered(let response):
                return (response, .forwarded)
            case .notDelivered:
                // 插件可能刚被重启，端口和 token 都换了：重读一次再试。
                if let retried = endpoints.endpoint(pluginID: server.pluginID),
                   case .delivered(let response) = await forwardOnce(body: body, id: id, to: retried) {
                    return (response, .forwarded)
                }
            }
        }

        // 3. 没有 HTTP 入口，或两次都没送到：经宿主的 stdio 客户端中转。
        guard params == nil || params is [String: Any] else {
            return (Self.rpcError(id: id, code: JSONRPCErrorCode.invalidParams,
                                  message: "JSON-RPC params must be an object."), .relayed)
        }
        let paramsObject = params as? [String: Any] ?? [:]
        guard let paramsJSON = try? JSONSerialization.data(withJSONObject: paramsObject, options: []) else {
            return (Self.rpcError(id: id, code: JSONRPCErrorCode.invalidParams,
                                  message: "JSON-RPC params are not representable as JSON."), .relayed)
        }
        do {
            let resultText = try await host.relay(server, method: method, paramsJSON: paramsJSON)
            let resultData = Data(resultText.utf8)
            guard (try? JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed])) != nil else {
                return (Self.rpcError(id: id, code: JSONRPCErrorCode.internalError,
                                      message: "Plugin MCP server returned a result that is not JSON."), .relayed)
            }
            return (Self.rpcResult(id: id, resultJSON: resultData), .relayed)
        } catch {
            return (Self.rpcError(id: id, code: JSONRPCErrorCode.internalError,
                                  message: Self.describe(error)), .relayed)
        }
    }

    private nonisolated enum ForwardAttempt {
        case delivered(AgentPluginMCPGatewayHTTPResponse)
        /// 请求没送到插件手里（连接被拒，或插件在入队前就拒了这个 token / 路径）。
        case notDelivered
    }

    private func forwardOnce(
        body: Data,
        id: Any?,
        to endpoint: AgentPluginMCPGatewayEndpoint
    ) async -> ForwardAttempt {
        let result: AgentPluginMCPGatewayForwardResult
        do {
            result = try await forwarder.forward(body: body, to: endpoint)
        } catch AgentPluginMCPGatewayForwardError.connectionRefused {
            return .notDelivered
        } catch {
            return .delivered(Self.rpcError(id: id, code: JSONRPCErrorCode.internalError,
                                            message: "Plugin HTTP endpoint failed: \(Self.describe(error))"))
        }
        // 插件自己的入口在入队执行之前就回 401（token 已换）/ 404（路径不对），
        // 这两种请求同样没被执行，按「没送到」处理，不把插件的 401 当成网关的。
        if result.status == 401 || result.status == 404 {
            return .notDelivered
        }
        guard (200...299).contains(result.status) else {
            let detail = String(data: result.body.prefix(2_000), encoding: .utf8) ?? ""
            return .delivered(Self.rpcError(
                id: id, code: JSONRPCErrorCode.internalError,
                message: "Plugin HTTP endpoint returned HTTP \(result.status): \(detail)"
            ))
        }
        let contentType = result.contentType?.isEmpty == false ? result.contentType! : "application/json"
        return .delivered(.json(status: result.status, body: result.body, contentType: contentType))
    }

    // MARK: - JSON-RPC 编码

    static func isValidID(_ id: Any?) -> Bool {
        id is NSNull || id is String || id is NSNumber
    }

    static func rpcResult(
        id: Any?,
        resultJSON: Data,
        extraHeaders: [AgentPluginMCPGatewayHTTPResponse.Header] = []
    ) -> AgentPluginMCPGatewayHTTPResponse {
        // 结果原样嵌进去，不经一次反序列化再序列化，避免数字、键序被改写。
        var body = Data("{\"id\":".utf8)
        body.append(encodedID(id))
        body.append(Data(",\"jsonrpc\":\"2.0\",\"result\":".utf8))
        body.append(resultJSON)
        body.append(Data("}".utf8))
        return .json(status: 200, body: body, extraHeaders: extraHeaders)
    }

    static func rpcError(id: Any?, code: Int, message: String, status: Int = 200) -> AgentPluginMCPGatewayHTTPResponse {
        let error: [String: Any] = ["code": code, "message": message]
        let errorJSON = (try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys])) ?? Data("{}".utf8)
        var body = Data("{\"error\":".utf8)
        body.append(errorJSON)
        body.append(Data(",\"id\":".utf8))
        body.append(encodedID(id))
        body.append(Data(",\"jsonrpc\":\"2.0\"}".utf8))
        return .json(status: status, body: body)
    }

    private static func encodedID(_ id: Any?) -> Data {
        guard let id, !(id is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]) else {
            return Data("null".utf8)
        }
        return data
    }

    static func describe(_ error: Error) -> String {
        if let hostError = error as? AgentPluginMCPGatewayHostError { return hostError.message }
        if case AgentPluginMCPGatewayForwardError.failed(let message) = error { return message }
        return String(describing: error)
    }
}
