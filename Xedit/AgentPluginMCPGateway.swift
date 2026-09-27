//
//  AgentPluginMCPGateway.swift
//  WillDeep
//
//  插件 MCP 网关：宿主自己开一个只绑 127.0.0.1 的 Streamable HTTP 入口，
//  外部 MCP 客户端（Claude Code、Codex……）连它就能调插件的 MCP 工具，
//  不必先在 WillDeep 里点开插件页面。
//
//  按需激活：网关收到第一条要插件处理的请求时，才经宿主平时用的那条 MCP
//  客户端连接发一次 `tools/list`——插件没在运行就按平常的方式被拉起，进程、
//  反向请求能力、环境变量都与页面打开时完全一致。之后插件公布了自己的 HTTP
//  入口（plugin-data/<插件 ID>/mcp-http.json）就把原始请求体转发过去；没公布
//  就经 stdio 客户端中转。
//
//  契约见 docs/decisions/0001-plugin-mcp-gateway.md。
//

import Foundation
import Network
import os

nonisolated final class AgentPluginMCPGateway: @unchecked Sendable {
    static let shared = AgentPluginMCPGateway()

    /// 结构化日志：状态码、路径、插件、服务、方法与耗时；从不记 token。
    static let log = Logger(subsystem: "com.willdeep.agent", category: "plugin-mcp-gateway")

    /// 同时处理的连接上限。网关只服务本机客户端，超过这个数只可能是失控的
    /// 脚本，直接断开比排队更安全。
    static let maximumConcurrentConnections = 64
    /// 首次没有保存端口时随机挑的范围：避开 macOS 的临时端口段（49152 起）。
    static let randomPortRange: ClosedRange<UInt16> = 41_000...48_999
    static let randomPortAttempts = 6
    private static let bindTimeout: TimeInterval = 3

    private let paths: AgentPluginMCPGatewayPaths
    private let host: any AgentPluginMCPGatewayHost
    private let forwarder: any AgentPluginMCPGatewayForwarder
    private let randomPortCandidates: @Sendable () -> [UInt16]

    /// 启动、停止、重写发现文件都在这条串行队列上做。
    private let stateQueue = DispatchQueue(label: "com.willdeep.plugin-mcp-gateway.state")
    /// NWListener / NWConnection 的回调队列。
    private let networkQueue = DispatchQueue(label: "com.willdeep.plugin-mcp-gateway.network")

    private let lock = NSLock()
    private var listener: NWListener?
    private var runningPort: UInt16?
    private var runningToken: String?
    private var activeConnections = 0

    init(
        paths: AgentPluginMCPGatewayPaths = .live,
        host: any AgentPluginMCPGatewayHost = AgentPluginMCPGatewayLiveHost(),
        forwarder: any AgentPluginMCPGatewayForwarder = AgentPluginMCPGatewayURLSessionForwarder(),
        randomPortCandidates: (@Sendable () -> [UInt16])? = nil
    ) {
        self.paths = paths
        self.host = host
        self.forwarder = forwarder
        self.randomPortCandidates = randomPortCandidates ?? {
            (0..<AgentPluginMCPGateway.randomPortAttempts).map { _ in
                UInt16.random(in: AgentPluginMCPGateway.randomPortRange)
            }
        }
    }

    // MARK: - 生命周期

    /// App 启动时调用；重复调用无副作用。
    func start() {
        stateQueue.async { _ = self.startOnStateQueue() }
    }

    /// 同步启动并返回监听端口，失败返回 nil。测试和需要立刻知道结果的调用方用。
    @discardableResult
    func startAndWait() -> UInt16? {
        stateQueue.sync { startOnStateQueue() }
    }

    func stop() {
        stateQueue.sync {
            lock.lock()
            let current = listener
            listener = nil
            runningPort = nil
            runningToken = nil
            lock.unlock()
            guard let current else { return }
            // cancel() 是异步的：不等 listener 走到 .cancelled，端口可能还占着，紧接着
            // 的 start() 绑原端口会失败、改绑别的端口，发现文件里的地址就变了，
            // 「停掉再起沿用原端口」的承诺落空（单测曾因此偶发失败）。回调在
            // networkQueue 上，这里在 stateQueue 上等，不会互锁。
            let cancelled = DispatchSemaphore(value: 0)
            current.stateUpdateHandler = { state in
                if case .cancelled = state { cancelled.signal() }
            }
            current.cancel()
            if cancelled.wait(timeout: .now() + Self.bindTimeout) == .timedOut {
                AgentPluginMCPGateway.log.error("gateway stop: listener did not reach cancelled within \(Self.bindTimeout, privacy: .public)s")
            }
        }
    }

    /// 插件启用、停用、安装、卸载，或插件 MCP 服务开关变动后调用：重写发现
    /// 文件里的 `servers`。网关没在运行时什么都不做。
    func pluginServersDidChange() {
        stateQueue.async {
            guard let port = self.currentPort, let token = self.currentToken else { return }
            self.writeDiscovery(port: port, token: token)
        }
    }

    /// 网关地址（`http://127.0.0.1:<端口>`），没在运行时为 nil。
    var baseURL: String? {
        currentPort.map(AgentPluginMCPGatewayDiscoveryStore.baseURL(port:))
    }

    /// 设置页「复制 Claude Code 连接命令」。命令里带 token，只在用户点按钮时生成。
    func claudeCodeCommand(pluginID: String, serverName: String) -> String? {
        guard let port = currentPort, let token = currentToken else { return nil }
        let url = AgentPluginMCPGatewayDiscoveryStore.serverURL(
            baseURL: AgentPluginMCPGatewayDiscoveryStore.baseURL(port: port),
            pluginID: pluginID,
            serverName: serverName
        )
        return AgentPluginMCPGatewayDiscoveryStore.claudeCodeCommand(name: serverName, url: url, token: token)
    }

    private var currentPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return runningPort
    }

    private var currentToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return runningToken
    }

    private func startOnStateQueue() -> UInt16? {
        if let port = currentPort { return port }

        let saved = AgentPluginMCPGatewayDiscoveryStore.loadPortAndToken(from: paths.discoveryFileURL)
        guard let token = saved?.token ?? AgentPluginMCPGatewayDiscoveryStore.makeToken() else {
            AgentPluginMCPGateway.log.error("gateway start failed: could not generate a token")
            return nil
        }

        // 先试上次的端口（外部客户端的配置因此长期有效），被占了再随机换。
        var candidates: [UInt16] = []
        if let savedPort = saved?.port { candidates.append(savedPort) }
        for candidate in randomPortCandidates() where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        candidates.append(0)

        let router = AgentPluginMCPGatewayRouter(
            token: token,
            host: host,
            forwarder: forwarder,
            endpoints: AgentPluginMCPGatewayEndpointReader(pluginDataRoot: paths.pluginDataRoot)
        )
        for candidate in candidates {
            guard let (boundListener, port) = bind(port: candidate, router: router) else {
                AgentPluginMCPGateway.log.info("gateway port unavailable: port=\(candidate, privacy: .public)")
                continue
            }
            lock.lock()
            listener = boundListener
            runningPort = port
            runningToken = token
            lock.unlock()
            writeDiscovery(port: port, token: token)
            AgentPluginMCPGateway.log.info(
                "gateway started: port=\(port, privacy: .public) reusedPort=\(saved?.port == port, privacy: .public) reusedToken=\(saved != nil, privacy: .public)"
            )
            return port
        }
        AgentPluginMCPGateway.log.error("gateway start failed: no port could be bound, tried=\(candidates.count, privacy: .public)")
        return nil
    }

    private func bind(port: UInt16, router: AgentPluginMCPGatewayRouter) -> (NWListener, UInt16)? {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        // 只影响 TIME_WAIT 的重绑；两个进程同时监听同一端口仍然会失败（实测）。
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        guard let listener = try? NWListener(using: parameters) else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let readiness = AgentPluginMCPGatewayReadiness()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readiness.resolve(true)
                semaphore.signal()
            case .failed(let error):
                if readiness.resolve(false) {
                    semaphore.signal()
                } else {
                    AgentPluginMCPGateway.log.error("gateway listener failed: \(String(describing: error), privacy: .public)")
                }
            case .waiting:
                if readiness.resolve(false) { semaphore.signal() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, router: router)
        }
        listener.start(queue: networkQueue)

        let finished = semaphore.wait(timeout: .now() + Self.bindTimeout) == .success
        guard finished, readiness.isReady, let boundPort = listener.port?.rawValue, boundPort > 0 else {
            listener.cancel()
            return nil
        }
        return (listener, boundPort)
    }

    private func writeDiscovery(port: UInt16, token: String) {
        let discovery = AgentPluginMCPGatewayDiscoveryStore.makeDiscovery(
            port: port,
            token: token,
            servers: host.activeServers()
        )
        do {
            try AgentPluginMCPGatewayDiscoveryStore.write(discovery, to: paths.discoveryFileURL)
        } catch {
            AgentPluginMCPGateway.log.error(
                "gateway discovery write failed: path=\(self.paths.discoveryFileURL.path, privacy: .public) reason=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection, router: AgentPluginMCPGatewayRouter) {
        lock.lock()
        let admitted = activeConnections < Self.maximumConcurrentConnections
        if admitted { activeConnections += 1 }
        lock.unlock()
        guard admitted else {
            AgentPluginMCPGateway.log.error("gateway connection refused: too many concurrent connections")
            connection.cancel()
            return
        }
        let session = AgentPluginMCPGatewayConnection(
            connection: connection,
            router: router,
            queue: networkQueue
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.activeConnections -= 1
            self.lock.unlock()
        }
        session.start()
    }
}

/// bind 时 ready / failed 只认第一次。
private nonisolated final class AgentPluginMCPGatewayReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private(set) var isReady = false

    /// 第一次调用返回 true。
    @discardableResult
    func resolve(_ ready: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return false }
        resolved = true
        isReady = ready
        return true
    }
}

/// 一条 TCP 连接：读一条请求、回一条响应、关闭。所有状态只在 `queue` 上改。
private nonisolated final class AgentPluginMCPGatewayConnection: @unchecked Sendable {
    /// 从连上到请求收齐的上限。之后的处理（出图、审核）可以长达 15 分钟，不计在内。
    static let requestReadTimeout: TimeInterval = 30
    private static let receiveChunkBytes = 64 * 1024

    private let connection: NWConnection
    private let router: AgentPluginMCPGatewayRouter
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var isClosed = false
    private var requestReceived = false
    private var readTimer: DispatchWorkItem?

    init(
        connection: NWConnection,
        router: AgentPluginMCPGatewayRouter,
        queue: DispatchQueue,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        let timer = DispatchWorkItem { [self] in
            guard !requestReceived, !isClosed else { return }
            respond(.plainError(status: 408, message: "Request timed out."), started: Date(), outcome: nil)
        }
        readTimer = timer
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout, execute: timer)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) { [self] data, _, isComplete, error in
            guard !isClosed, !requestReceived else { return }
            if let data, !data.isEmpty { buffer.append(data) }
            switch AgentPluginMCPGatewayHTTPParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    close()
                } else {
                    receive()
                }
            case .reject(let status):
                requestReceived = true
                readTimer?.cancel()
                respond(
                    .plainError(status: status, message: AgentPluginMCPGatewayHTTPResponse.reasonPhrase(for: status)),
                    started: Date(),
                    outcome: nil
                )
            case .request(let request):
                requestReceived = true
                readTimer?.cancel()
                buffer = Data()
                handle(request)
            }
        }
    }

    private func handle(_ request: AgentPluginMCPGatewayHTTPRequest) {
        let started = Date()
        let router = router
        Task.detached(priority: .userInitiated) { [self] in
            let outcome = await router.handle(request)
            queue.async {
                self.respond(outcome.response, started: started, outcome: outcome)
            }
        }
    }

    private func respond(
        _ response: AgentPluginMCPGatewayHTTPResponse,
        started: Date,
        outcome: AgentPluginMCPGatewayRouter.Outcome?
    ) {
        guard !isClosed else { return }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AgentPluginMCPGateway.log.info(
            "gateway request: status=\(response.status, privacy: .public) route=\(outcome?.disposition.rawValue ?? "rejected", privacy: .public) plugin=\(outcome?.pluginID ?? "-", privacy: .public) server=\(outcome?.serverName ?? "-", privacy: .public) rpc=\(outcome?.rpcMethod ?? "-", privacy: .public) ms=\(elapsed, privacy: .public)"
        )
        connection.send(
            content: response.serialized(),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [self] _ in
                close()
            }
        )
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        readTimer?.cancel()
        readTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }
}

// MARK: - 正式实现

/// 经宿主平时用的 MCP 客户端（`AgentMCPBridge`）访问插件。
nonisolated struct AgentPluginMCPGatewayLiveHost: AgentPluginMCPGatewayHost {
    func activeServers() -> [AgentPluginMCPGatewayServer] {
        var versions: [String: String] = [:]
        for package in AgentPluginRuntimeSnapshotStore.activePackages() where versions[package.pluginID] == nil {
            versions[package.pluginID] = package.version
        }
        // list() 只返回已启用的服务器；插件停用后它的服务器直接不在册。
        return AgentMCPServerDirectory.list().compactMap { server in
            guard server.source == .plugin,
                  let pluginID = AgentPluginMCPToolCatalog.pluginID(fromServerID: server.id) else {
                return nil
            }
            return AgentPluginMCPGatewayServer(
                pluginID: pluginID,
                serverName: server.name,
                pluginVersion: versions[pluginID] ?? "0.0.0"
            )
        }
    }

    func ensureStarted(_ server: AgentPluginMCPGatewayServer) async throws {
        try await AgentMCPBridge.ensurePluginServerStartedForGateway(
            pluginID: server.pluginID,
            serverName: server.serverName
        )
    }

    func relay(_ server: AgentPluginMCPGatewayServer, method: String, paramsJSON: Data) async throws -> String {
        try await AgentMCPBridge.relayPluginRequestForGateway(
            pluginID: server.pluginID,
            serverName: server.serverName,
            method: method,
            paramsJSON: paramsJSON
        )
    }
}

/// 把原始请求体 POST 到插件自己的 HTTP 入口。
nonisolated struct AgentPluginMCPGatewayURLSessionForwarder: AgentPluginMCPGatewayForwarder {
    /// 契约：转发超时 15 分钟。出图、审核一次一两分钟，插件又是单线程排队。
    static let timeout: TimeInterval = 15 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // 目标永远是 127.0.0.1，不能让系统代理截走插件的 token。
        configuration.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: false]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func forward(
        body: Data,
        to endpoint: AgentPluginMCPGatewayEndpoint
    ) async throws -> AgentPluginMCPGatewayForwardResult {
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgentPluginMCPGatewayForwardError.failed("Plugin endpoint did not return an HTTP response.")
            }
            return AgentPluginMCPGatewayForwardResult(
                status: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: data
            )
        } catch let error as AgentPluginMCPGatewayForwardError {
            throw error
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw AgentPluginMCPGatewayForwardError.connectionRefused
        } catch {
            throw AgentPluginMCPGatewayForwardError.failed(error.localizedDescription)
        }
    }
}
