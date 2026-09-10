import Foundation

/// What a plugin page actually did, on disk, one directory per plugin.
///
/// Until now: nothing. A plugin asking the model went straight to
/// `AgentClient.streamChat` and left no timing, no tokens, no cost. A plugin
/// running a command went through the same denylist, the same confirmation
/// and the same seatbelt as the agent's own commands — and then wrote no
/// line to `sandbox.jsonl`, because every one of that file's writers sits on
/// the main agent path. The same `npm install` was audited when the agent ran
/// it and invisible when a page did.
///
/// Two consequences made this worth fixing. A customer reporting that a
/// plugin is slow would send a diagnostics bundle with nothing in it. And an
/// approval remembered with "don't ask again" bought a plugin unaudited
/// execution from then on.
///
/// Kept apart from the agent's own logs rather than folded into them:
/// a plugin's work has no session and no project to hang off, so the fields
/// that make `worker-timing.jsonl` cuttable by conversation simply do not
/// exist here. Forcing it into that shape would mean a column of nulls and a
/// filter that silently matches nothing.
///
/// ```
/// AgentAudit/plugins/<plugin-id>/ai.jsonl
/// AgentAudit/plugins/<plugin-id>/commands.jsonl
/// ```
///
/// `ai.jsonl` records no prompt or response text — identifiers, counts and
/// timings only, the same rule `worker-timing.jsonl` follows, so it stays
/// safe to hand to someone. `commands.jsonl` records the command itself,
/// because the command *is* the audit; it goes through the same scrub as
/// `sandbox.jsonl`.
nonisolated enum AgentPluginAuditLog {
    static let aiFileName = "ai.jsonl"
    static let commandsFileName = "commands.jsonl"
    static let hostCallsFileName = "host-calls.jsonl"
    static let rotatedSuffix = ".1.jsonl"
    static let rotationThresholdBytes: UInt64 = 8 * 1024 * 1024
    /// 命令原文的截断长度。审计要的是「跑了什么」，不是把一整段 heredoc
    /// 抄进日志。
    static let maximumCommandCharacters = 2_000

    struct AICall: Codable, Equatable, Sendable {
        var kind = "plugin_ai"
        let recordedAt: Date
        let pluginID: String
        let providerID: String
        let model: String
        /// 请求发出到收到结果的墙钟。
        let seconds: Double
        let messageCount: Int
        /// 只记字符数，不记内容。
        let promptCharacters: Int
        let skillCount: Int
        /// 页面声明的产出形状，只记名字。
        let declaredTools: [String]
        /// 模型实际填了哪几个。空数组说明它用正文回答。
        let toolCalls: [String]
        let responseCharacters: Int
        /// `succeeded` / `failed` / `cancelled`
        let outcome: String
        /// 失败时的错误描述，已截断。宿主自己抛的那几种错，不含用户内容。
        let errorDescription: String?
    }

    struct CommandRun: Codable, Equatable, Sendable {
        var kind = "plugin_command"
        let recordedAt: Date
        let pluginID: String
        /// 已脱敏、已截断。
        let command: String
        let sandboxMode: String
        /// 这次是怎么放行的：`alwaysSafe` 静态判定只读、`remembered` 用户
        /// 之前勾了不再询问、`confirmed` 这次弹框批准。这一列存在的理由：
        /// 「以后不再询问」之后的每一次执行，都要能被数出来。
        let approval: String
        let seconds: Double
        let outcome: String
        let errorDescription: String?
    }

    /// 页面调宿主命令（`executeCommand`）。
    ///
    /// 只记尺寸和结果，不记参数与返回的内容——那里面是剧本正文和整份短剧
    /// 数据。而这条路最常见的故障恰好是尺寸问题：页面 `JSON.parse` 抛
    /// 「Unterminated string」，说明拿到的不是完整 JSON，那时要问的是
    /// 「回了多少字节」，不是「回了什么」。
    struct HostCall: Codable, Equatable, Sendable {
        var kind = "plugin_host_call"
        let recordedAt: Date
        let pluginID: String
        let commandID: String
        let argumentCount: Int
        let argumentBytes: Int
        /// 回给页面的 JSON 字节数。命令没有返回值时为 0。
        let resultBytes: Int
        let seconds: Double
        let outcome: String
        let errorDescription: String?
    }

    static func recordHostCall(_ entry: HostCall, root: URL = AgentSandboxAuditLog.directory) {
        append(entry, to: directory(forPluginID: entry.pluginID, root: root).appendingPathComponent(hostCallsFileName))
    }

    /// 插件 ID 直接当目录名不安全：它来自插件清单，可能带斜杠或 `..`。
    /// 非白名单字符一律换成下划线，空的退回 `unknown`。
    static func directoryName(forPluginID pluginID: String) -> String {
        let mapped = pluginID.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character
                : "_"
        }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return name.isEmpty ? "unknown" : String(name.prefix(120))
    }

    static func directory(forPluginID pluginID: String, root: URL = AgentSandboxAuditLog.directory) -> URL {
        root.appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(directoryName(forPluginID: pluginID), isDirectory: true)
    }

    static func recordAICall(_ entry: AICall, root: URL = AgentSandboxAuditLog.directory) {
        append(entry, to: directory(forPluginID: entry.pluginID, root: root).appendingPathComponent(aiFileName))
    }

    static func recordCommandRun(_ entry: CommandRun, root: URL = AgentSandboxAuditLog.directory) {
        append(entry, to: directory(forPluginID: entry.pluginID, root: root).appendingPathComponent(commandsFileName))
    }

    /// 每次执行都要留痕，所以写失败不能把调用方带崩，也不该阻塞它。
    private static func append<T: Encodable>(_ entry: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        Task.detached(priority: .utility) { await AgentPluginAuditWriter.shared.append(line, to: url) }
    }
}

/// 串行化落盘。两个插件页面可以同时在跑，写同一个文件的两条 JSON 交错在
/// 一行里，整个文件就从那一行起解不出来了。
actor AgentPluginAuditWriter {
    static let shared = AgentPluginAuditWriter()

    func append(_ line: String, to url: URL) {
        guard let bytes = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(url)
        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: [.atomic])
        }
    }

    /// 一次轮转就够，不需要后台清理进程——和 worker-timing 同一套。
    private func rotateIfNeeded(_ url: URL) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size >= AgentPluginAuditLog.rotationThresholdBytes else { return }
        let base = url.deletingPathExtension().lastPathComponent
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(base + AgentPluginAuditLog.rotatedSuffix)
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: url, to: rotated)
    }
}
