//
//  AgentMCPHostRequests.swift
//  WillDeep
//
//  插件 MCP 进程反向请求宿主能力。
//
//  起因：短剧工坊要让主 Agent 在聊天里跑完整条生产流水线，而出图原本只有插件
//  页面能做——页面调 `window.willdeep.ai.generateImage`，宿主拿自己的 some.im
//  凭据去请求。Agent 调的是插件的 MCP 服务，那是一个没有页面的独立进程，
//  调不到页面桥，只能各自再配一份 key。
//
//  做法沿用 MCP 协议本来就有的「服务端向客户端发请求」（`sampling/createMessage`
//  就是这个形状）：插件在处理 `tools/call` 期间，往 stdout 写一条带 `id` 的
//  JSON-RPC 请求，宿主在等待工具结果的循环里认出它、处理、把响应写回 stdin，
//  然后接着等原来那个工具结果。
//
//  边界：
//  - 只对**插件来源**的 stdio 服务开放；用户手工配置的 MCP 服务一律回
//    method not found——它们没有经过插件清单的权限声明与安装批准。
//  - 权限、路径钳制、输出目录与页面桥完全相同（`AgentPluginImageGeneration`），
//    凭据永远不出宿主。
//  - 插件的请求 id 请用字符串：宿主自己的请求 id 是整数，两边混用同一种会撞号。
//

import Foundation

nonisolated enum AgentMCPHostRequests {
    /// 在 initialize 的 `capabilities.extensions` 里宣告，插件据此判断宿主支不支持。
    static let capabilityKey = "io.willdeep/host-requests"
    static let imageGenerateMethod = "willdeep/images/generate"
    /// 问一次模型（1.380.0-rc1）。形状、校验、权限（`ai.chat`）、附图附视频的路径钳制
    /// 与页面桥 `window.willdeep.ai.complete` 完全相同，只是不流式：MCP 这条路
    /// 没有页面可推增量。起因是内容审核——Agent 替用户出完图、出完片之后要让插件
    /// 配置的多模态审核模型看一眼，插件进程自己没有任何模型凭据。
    static let aiCompleteMethod = "willdeep/ai/complete"
    static let supportedMethods = [imageGenerateMethod, aiCompleteMethod]

    /// 单次反向请求的处理上限。出一张图通常几十秒，带参考图要先上传；
    /// 十分钟之外只可能是上游挂住了，不能让 MCP 连接的串行队列永远卡着。
    static let maximumHandlingSeconds: TimeInterval = 600

    /// JSON-RPC 错误码。-32601 / -32602 是协议保留值，-32000 起是实现自定义。
    enum ErrorCode {
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let failed = -32000
        static let timedOut = -32001
    }

    typealias ImageGenerator = @Sendable (AgentPluginID, AgentPluginImageRequest) async throws -> AgentPluginImageResult

    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var imageGeneratorOverride: ImageGenerator?

    /// 测试入口：替换真实出图，避免单测打外网、花钱。传 nil 恢复。
    static func setImageGeneratorForTesting(_ generator: ImageGenerator?) {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        imageGeneratorOverride = generator
    }

    private static func imageGenerator() -> ImageGenerator {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        if let imageGeneratorOverride { return imageGeneratorOverride }
        return { pluginID, request in
            try await AgentPluginImageGeneration.run(pluginID: pluginID, request: request)
        }
    }

    typealias AICompleter = @Sendable (AgentPluginID, AgentPluginAIRequest) async throws -> AgentPluginAIResult

    nonisolated(unsafe) private static var aiCompleterOverride: AICompleter?

    /// 测试入口：替换真实模型调用。传 nil 恢复。
    static func setAICompleterForTesting(_ completer: AICompleter?) {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        aiCompleterOverride = completer
    }

    private static func aiCompleter() -> AICompleter {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        if let aiCompleterOverride { return aiCompleterOverride }
        return { pluginID, request in
            // 模型路由（provider 库、默认 flash 档）挂在 AppState 上。MCP 调用不带
            // 窗口归属，取当前窗口；各窗口读的是同一份 provider 设置。
            try await Task { @MainActor in
                let registry = EditorAppStateRegistry.shared
                guard let appState = registry.current ?? registry.appStatesForTerminationCheck.first else {
                    throw AgentPluginAIError.unavailable
                }
                return try await appState.runPluginAICompletion(pluginID: pluginID, request: request)
            }.value
        }
    }

    /// 要在 initialize 里宣告的能力；非插件服务返回 nil。
    static func advertisedCapability(for server: AgentMCPServerConfig) -> [String: Any]? {
        guard pluginID(for: server) != nil else { return nil }
        return ["methods": supportedMethods]
    }

    /// 插件服务的 id 形如 `plugin:<插件ID>:<服务名>`（`AgentMCPServerDirectory.loadPluginServers`）。
    static func pluginID(for server: AgentMCPServerConfig) -> AgentPluginID? {
        let prefix = "plugin:"
        guard server.source == .plugin, server.transport == .stdio, server.id.hasPrefix(prefix) else {
            return nil
        }
        let remainder = server.id.dropFirst(prefix.count)
        guard let separator = remainder.lastIndex(of: ":") else { return nil }
        let pluginID = String(remainder[..<separator])
        return pluginID.isEmpty ? nil : pluginID
    }

    /// 这一行是不是服务端发给宿主的请求：有 method 也有 id。只有 method 没有 id
    /// 的是通知，按原样忽略；有 id 没有 method 的是对宿主请求的响应。
    static func isServerRequest(_ message: [String: Any]) -> Bool {
        message["method"] is String && message["id"] != nil && !(message["id"] is NSNull)
    }

    /// 同步版本，给 MCP 连接的串行队列用。那条队列本来就在阻塞等工具结果，
    /// 在这里等反向请求处理完，顺序才对得上。
    static func respondSync(to message: [String: Any], server: AgentMCPServerConfig) -> [String: Any] {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let request = SendableMessage(value: message)
        // 继承调用线程的优先级：等待方阻塞在信号量上，干活的 Task 优先级更低就是优先级反转。
        Task.detached(priority: Task.currentPriority) {
            box.set(await respond(to: request.value, server: server))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + maximumHandlingSeconds) == .success, let response = box.get() else {
            return errorResponse(
                id: message["id"],
                code: ErrorCode.timedOut,
                message: "Host request \(message["method"] as? String ?? "") did not finish within \(Int(maximumHandlingSeconds)) seconds."
            )
        }
        return response
    }

    static func respond(to message: [String: Any], server: AgentMCPServerConfig) async -> [String: Any] {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        guard let pluginID = pluginID(for: server) else {
            return errorResponse(
                id: id, code: ErrorCode.methodNotFound,
                message: "Host requests are only available to plugin MCP servers."
            )
        }
        switch method {
        case imageGenerateMethod:
            let params = message["params"] as? [String: Any] ?? [:]
            let request: AgentPluginImageRequest
            switch AgentPluginImageRequestValidator.request(from: params) {
            case .failure(let error):
                return errorResponse(id: id, code: ErrorCode.invalidParams, message: error.localizedDescription)
            case .success(let validated):
                request = validated
            }
            do {
                let image = try await imageGenerator()(pluginID, request)
                return [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "result": [
                        "mediaURL": image.mediaURL,
                        "filePath": image.filePath,
                        "model": image.model,
                        "providerID": image.providerID,
                    ],
                ]
            } catch {
                return errorResponse(id: id, code: ErrorCode.failed, message: error.localizedDescription)
            }
        case aiCompleteMethod:
            let params = message["params"] as? [String: Any] ?? [:]
            let request: AgentPluginAIRequest
            switch AgentPluginAIRequestValidator.request(from: params) {
            case .failure(let error):
                return errorResponse(id: id, code: ErrorCode.invalidParams, message: error.localizedDescription)
            case .success(let validated):
                request = validated
            }
            do {
                let result = try await aiCompleter()(pluginID, request)
                return [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "result": [
                        "text": result.text,
                        "model": result.model,
                        "providerID": result.providerID,
                        "toolCalls": result.toolCalls.map(\.jsonObject),
                    ],
                ]
            } catch {
                return errorResponse(id: id, code: ErrorCode.failed, message: error.localizedDescription)
            }
        default:
            return errorResponse(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Any]?
        func set(_ next: [String: Any]) { lock.lock(); value = next; lock.unlock() }
        func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// JSON 对象本身不是 Sendable；这里只在一次交接里读，不会并发写。
    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }
}
