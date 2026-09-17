//
//  AgentMonitorTool.swift
//  WillDeep
//
//  `monitor` 工具的运行时一半：盯着一条命令的 stdout，每批新行作为一条宿主事件
//  推给模型。合同见 `docs/BACKGROUND_TASK_CONTRACT.md`「第三批 · C·一」，渲染在
//  `AgentMonitorNotice`。
//
//  - 审批：`monitor` 在主循环的唯一入口被改写成 `run_command`（带宿主私有的
//    `_monitor` 参数）再去做风险分级、自动批准、审批卡、裁判与沙箱判定，所以同一
//    条命令拿到的判定与 `run_in_background: true` 的 `run_command` 逐项相同，不开
//    新口子。模型自己塞进 `run_command` 的 `_monitor` 在同一处被剥掉。
//  - 进程：复用 `AgentJobRegistry.start`——同一套沙箱、环境、进程树清理、超时与
//    `background-jobs/<mon_id>/output.log` 落盘；`list_jobs` 可见、`kill_job` 可停、
//    `get_job_output(mon_id)` 可读，退出 App 与回合作业一起被清理。
//  - 合批 / 防刷屏 / 唤醒节流长在监视器自己身上（`AgentMonitorSession`）：宿主
//    事件不走外部唤醒额度，这几道闸没有别处可放。
//

import Foundation

enum AgentMonitorTool {
    static let name = "monitor"
    /// 宿主私有参数：只由主循环的改写写入，模型提供的一律剥掉。
    static let hostArgumentKey = "_monitor"

    nonisolated static let description = "Watch a shell command and receive its new stdout lines as <monitor-event> notices while it runs; a <monitor-ended> notice follows when it exits, times out, floods or is stopped with kill_job. Use monitor when you need to react to in-progress output; when you only care about the final result, use run_command with run_in_background instead. Every line costs model attention: filter inside the command first (for example `tail -f build.log | grep --line-buffered -E 'Error|FAILED|Traceback|done'`) down to lines worth reacting to, and cover failure shapes such as Error, FAILED and Traceback, not only the success marker. Lines arriving within 200ms are batched (at most 50 per event); more than 30 events in 60 seconds stops the monitor as flooded. stderr is only written to the log; merge it with 2>&1 when it matters. Uses the same approval path as run_command."

    static var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: name,
            description: description,
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Shell command line whose stdout lines become events.", required: true),
                AgentToolParameter(name: "label", type: .string, description: "Short user-facing label shown in every event; never include secrets.", required: true),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Stop the command after this many seconds (1-1800). Defaults to 300.", required: false)
            ]
        )
    }

    /// 审批与执行看到的形态。`monitor` → 带 `_monitor` 的后台 `run_command`；
    /// `run_command` → 剥掉模型伪造的 `_monitor`；其余原样返回。
    static func authorizationForm(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> (toolName: String, arguments: [String: AgentJSONValue]) {
        switch toolName {
        case "run_command":
            var stripped = arguments
            stripped.removeValue(forKey: hostArgumentKey)
            return ("run_command", stripped)
        case name:
            let command = arguments["command"]?.stringValue() ?? ""
            let label = arguments["label"]?.stringValue() ?? ""
            let timeout = min(
                max(arguments["timeout_seconds"]?.intValue() ?? AgentMonitorLimits.defaultTimeoutSeconds, 1),
                AgentMonitorLimits.maximumTimeoutSeconds
            )
            return ("run_command", [
                "command": .string(command),
                "label": .string(label),
                "run_in_background": .bool(true),
                hostArgumentKey: .object([
                    "label": .string(label),
                    "timeout_seconds": .number(Double(timeout))
                ])
            ])
        default:
            return (toolName, arguments)
        }
    }

    static func isMonitorInvocation(_ arguments: [String: AgentJSONValue]) -> Bool {
        arguments[hostArgumentKey] != nil
    }

    /// `run_command` 发现 `_monitor` 时转到这里。
    static func start(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        // 子 Agent 的上下文拿不到这个工具；伪造参数也只会在这里被拒。
        guard context.canSpawnSubagents else {
            throw AgentToolError.invalidArgument("monitor is only available in the main WillDeep conversation")
        }
        guard context.remoteBackend == nil else {
            throw AgentToolError.invalidArgument("monitor is only available for local workspaces; use run_command with run_in_background on remote runtimes")
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard case .object(let host)? = arguments[hostArgumentKey] else {
            throw AgentToolError.invalidArgument("monitor must be invoked as the monitor tool")
        }
        let command = (arguments["command"]?.stringValue() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (host["label"]?.stringValue() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !label.isEmpty else {
            throw AgentToolError.invalidArgument("monitor needs a non-empty command and label")
        }
        let timeout = min(
            max(host["timeout_seconds"]?.intValue() ?? AgentMonitorLimits.defaultTimeoutSeconds, 1),
            AgentMonitorLimits.maximumTimeoutSeconds
        )
        let root = context.rootDirectory?.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let job = try await MainActor.run {
            try registry.start(
                command: command,
                workingDirectory: root,
                additionalWorkspaceRoots: Array(context.workspaceRoots.dropFirst()),
                runtimeID: runtimeID,
                turnID: context.turnID,
                timeoutSeconds: Double(timeout),
                sandboxMode: context.sandboxMode,
                environment: context.localCommandEnvironment,
                displayCommand: AgentSecretStore.redact(command, secretValues: context.secretRedactionValues),
                secretRedactionValues: context.secretRedactionValues,
                lifetime: .turn,
                label: label,
                monitorLabel: label
            )
        }
        return AgentToolResult(
            summary: "\(job.displayHandle) started",
            payload: "Monitor started: \(job.displayHandle). New stdout lines arrive as <monitor-event> notices and a <monitor-ended> notice follows; keep working instead of polling. Stop it with kill_job."
        )
    }
}

/// 一个运行中的监视器：切行、合批、防刷屏、唤醒节流，并按序交出发布物。
/// 所有状态只在私有串行队列上读写；发布物经 `deliver` 按产生顺序送出。
nonisolated final class AgentMonitorSession: @unchecked Sendable {
    struct Publication: Equatable, Sendable {
        let runtimeID: UUID
        let handle: String
        let label: String
        let payload: String
        let dedupeKey: String
        /// 假 = 只入队、不唤醒空闲会话（30 秒节流内的事件；被 Stop 收掉的结束通知）。
        let wakes: Bool
        let isEnded: Bool
        /// 结束通知：除 `exited` 且退出码 0 之外都算需要关注。
        let isUrgent: Bool
        let contract: String
    }

    let handle: String
    let label: String
    let runtimeID: UUID
    private let queue = DispatchQueue(label: "com.willdeep.agent-monitor", qos: .userInitiated)
    private let uptime: @Sendable () -> TimeInterval
    private let deliver: @Sendable (Publication) -> Void
    private let requestStop: @Sendable () -> Void

    // Queue-confined.
    private var splitter = AgentMonitorLineSplitter()
    private var batch = AgentMonitorBatch()
    private var flood = AgentMonitorFloodGuard()
    private var wake = AgentMonitorWakeThrottle()
    private var seq: UInt64 = 0
    private var windowGeneration = 0
    private var stopped = false
    private var flooded = false
    private var ended = false

    init(
        handle: String,
        label: String,
        runtimeID: UUID,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deliver: @escaping @Sendable (Publication) -> Void,
        requestStop: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        self.label = label
        self.runtimeID = runtimeID
        self.uptime = uptime
        self.deliver = deliver
        self.requestStop = requestStop
    }

    /// stdout 字节。stderr 不进来——它只写日志。
    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !stopped else { return }
            for line in splitter.push(data) where !accept(line) { return }
        }
    }

    /// 进程已经结束（或从未启动）。先把残行与当前一批按规则发完，再发结束通知。
    func finish(
        reason: AgentMonitorNotice.EndReason,
        exitCode: Int32?,
        durationSeconds: UInt64?,
        outputPath: String?,
        wakes: Bool = true
    ) {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            if !stopped {
                if let rest = splitter.finish() { _ = accept(rest) }
                if !stopped { _ = flush() }
            }
            stopped = true
            let finalReason = flooded ? .flooded : reason
            let notice = AgentMonitorNotice.Ended(
                id: handle,
                label: label,
                reason: finalReason,
                exitCode: finalReason == .exited ? exitCode : nil,
                durationSeconds: durationSeconds,
                events: seq,
                outputPath: outputPath
            )
            deliver(Publication(
                runtimeID: runtimeID, handle: handle, label: label,
                payload: AgentMonitorNotice.render(notice),
                dedupeKey: "monitor:\(handle):ended",
                wakes: wakes, isEnded: true,
                isUrgent: !(finalReason == .exited && exitCode == 0),
                contract: AgentMonitorNotice.endedContractV1
            ))
        }
    }

    /// Blocks until every queued ingest/finish has run. Tests only.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// 返回 false 表示触发了防刷屏，调用方停止读取。
    private func accept(_ line: String) -> Bool {
        let wasEmpty = batch.isEmpty
        if batch.push(line, now: uptime()) { return flush() }
        if wasEmpty, !batch.isEmpty { scheduleWindow() }
        return true
    }

    private func scheduleWindow() {
        windowGeneration += 1
        let generation = windowGeneration
        queue.asyncAfter(deadline: .now() + AgentMonitorLimits.batchWindow) { [self] in
            guard !stopped, generation == windowGeneration, !batch.isEmpty else { return }
            _ = flush()
        }
    }

    private func flush() -> Bool {
        guard !batch.isEmpty else { return true }
        windowGeneration += 1
        let now = uptime()
        guard flood.admit(now) else {
            // 触发防刷屏的这一批不投递；`events` 记已投递数。
            _ = batch.take()
            stopped = true
            flooded = true
            requestStop()
            return false
        }
        seq += 1
        let event = AgentMonitorNotice.Event(id: handle, label: label, seq: seq, lines: batch.take())
        deliver(Publication(
            runtimeID: runtimeID, handle: handle, label: label,
            payload: AgentMonitorNotice.render(event),
            dedupeKey: "monitor:\(handle):\(seq)",
            wakes: wake.admit(now), isEnded: false, isUrgent: false,
            contract: AgentMonitorNotice.eventContractV1
        ))
        return true
    }
}
