//
//  AgentMonitorNotice.swift
//  WillDeep
//
//  `monitor` 工具的事件与结束通知 v1，以及只依赖时间与文本的几道闸（行切分、
//  合批、防刷屏、唤醒节流）。canonical 合同在 `docs/BACKGROUND_TASK_CONTRACT.md`
//  「第三批 · C·一」，金样在 `docs/contracts/monitor-event.v1.txt`。
//
//  willdeep-rs 的 `monitor_notice.rs` / `tools/monitor.rs` /
//  `execution/line_stream.rs` 是另一半，两端逐字一致。脱敏与标签中和复用
//  `AgentBackgroundNotice`，「字符」一律按 Unicode 标量数（Rust `chars()`）。
//

import Foundation

nonisolated enum AgentMonitorNotice {
    /// 内核事件带上的合同标记；`AgentRuntimeKernel.modelNotice` 据此不再整段
    /// 转义框架（仅限宿主发布、工具来源的事件）。
    static let contractMetadataKey = "notice_contract"
    static let eventContractV1 = "monitor-event.v1"
    static let endedContractV1 = "monitor-ended.v1"
    static let contracts: Set<String> = [eventContractV1, endedContractV1]

    enum EndReason: String, Equatable, Sendable {
        case exited
        case timedOut = "timed_out"
        case killed
        case flooded
        case launchFailed = "launch_failed"
    }

    struct Event: Equatable, Sendable {
        var id: String
        var label: String
        var seq: UInt64
        var lines: [String]
    }

    struct Ended: Equatable, Sendable {
        var id: String
        var label: String
        var reason: EndReason
        var exitCode: Int32?
        var durationSeconds: UInt64?
        /// 交给模型的事件条数。
        var events: UInt64
        var outputPath: String?
    }

    static func render(_ event: Event) -> String {
        "<monitor-event>\n"
            + "id: \(AgentBackgroundNotice.clean(event.id))\n"
            + "label: \(AgentBackgroundNotice.label(event.label))\n"
            + "seq: \(event.seq)\n"
            + "lines: \(event.lines.count)\n"
            + "```text\n\(AgentBackgroundNotice.clean(event.lines.joined(separator: "\n")))\n```\n"
            + "</monitor-event>"
    }

    static func render(_ ended: Ended) -> String {
        "<monitor-ended>\n"
            + "id: \(AgentBackgroundNotice.clean(ended.id))\n"
            + "label: \(AgentBackgroundNotice.label(ended.label))\n"
            + "reason: \(ended.reason.rawValue)\n"
            + "exit_code: \(ended.exitCode.map(String.init) ?? "unknown")\n"
            + "duration: \(ended.durationSeconds.map(AgentBackgroundNotice.formatDuration) ?? "unknown")\n"
            + "events: \(ended.events)\n"
            + "output_path: \(AgentBackgroundNotice.path(ended.outputPath))\n"
            + "</monitor-ended>"
    }
}

// MARK: - Limits (合同「实现细则」)

nonisolated enum AgentMonitorLimits {
    static let defaultTimeoutSeconds = 300
    static let maximumTimeoutSeconds = 1_800
    /// 每行最多这么多字符，超出保留前 1999 个再加 `…`。
    static let maximumLineCharacters = 2_000
    static let batchWindow: TimeInterval = 0.2
    static let maximumBatchLines = 50
    /// 内核正文上限 24000；被它从尾部截掉会连框架一起截坏，合批时提前收口。
    static let maximumBatchCharacters = 20_000
    static let floodWindow: TimeInterval = 60
    static let floodMaximumEvents = 30
    static let wakeInterval: TimeInterval = 30
}

/// 任意 60 秒内最多放行 30 个事件。时间是单调秒数（`systemUptime`）。
nonisolated struct AgentMonitorFloodGuard: Equatable, Sendable {
    private var admitted: [TimeInterval] = []

    mutating func admit(_ now: TimeInterval) -> Bool {
        admitted.removeAll { now - $0 >= AgentMonitorLimits.floodWindow }
        guard admitted.count < AgentMonitorLimits.floodMaximumEvents else { return false }
        admitted.append(now)
        return true
    }
}

/// 每个监视器每 30 秒最多唤醒一次。
nonisolated struct AgentMonitorWakeThrottle: Equatable, Sendable {
    private var last: TimeInterval?

    mutating func admit(_ now: TimeInterval) -> Bool {
        if let last, now - last < AgentMonitorLimits.wakeInterval { return false }
        last = now
        return true
    }
}

/// 一批待发的行。第一行到达时开 200ms 窗口；满 50 行或正文逼近事件上限立刻收口。
nonisolated struct AgentMonitorBatch: Equatable, Sendable {
    private(set) var lines: [String] = []
    private(set) var characters = 0
    private(set) var deadline: TimeInterval?

    var isEmpty: Bool { lines.isEmpty }

    /// 收下一行，返回这一批是否已经满了。只含空白的行不算事件。
    mutating func push(_ line: String, now: TimeInterval) -> Bool {
        guard line.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return false }
        if lines.isEmpty { deadline = now + AgentMonitorLimits.batchWindow }
        characters += line.unicodeScalars.count + 1
        lines.append(line)
        return lines.count >= AgentMonitorLimits.maximumBatchLines
            || characters >= AgentMonitorLimits.maximumBatchCharacters
    }

    mutating func take() -> [String] {
        let taken = lines
        lines = []
        characters = 0
        deadline = nil
        return taken
    }
}

/// 把字节块切成行：去掉行尾 `\r`，非 UTF-8 有损解码，超长行截断并以 `…` 结尾。
/// 没有换行的超长行缓冲到上限后丢弃后续字节，直到换行。
nonisolated struct AgentMonitorLineSplitter: Sendable {
    private var pending: [UInt8] = []
    private var overflowed = false
    let maximumCharacters: Int

    init(maximumCharacters: Int = AgentMonitorLimits.maximumLineCharacters) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    /// 一个字符最多 4 字节；多留一个字符的余量，才知道「确实超了」。
    private var byteBudget: Int { (maximumCharacters + 1) * 4 }

    mutating func push(_ chunk: Data) -> [String] {
        var lines: [String] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            append(chunk[start..<newline])
            lines.append(takeLine())
            start = chunk.index(after: newline)
        }
        append(chunk[start...])
        return lines
    }

    /// 流结束时剩下的半行。
    mutating func finish() -> String? {
        guard !pending.isEmpty || overflowed else { return nil }
        return takeLine()
    }

    private mutating func append(_ bytes: Data.SubSequence) {
        let room = max(0, byteBudget - pending.count)
        if bytes.count > room { overflowed = true }
        pending.append(contentsOf: bytes.prefix(room))
    }

    private mutating func takeLine() -> String {
        var bytes = pending
        pending = []
        let wasOverflowed = overflowed
        overflowed = false
        if bytes.last == 0x0D { bytes.removeLast() }
        return Self.truncate(String(decoding: bytes, as: UTF8.self),
                             maximumCharacters: maximumCharacters, forceMarker: wasOverflowed)
    }

    /// 截到 `maximumCharacters` 个字符：超了就保留前 `maximumCharacters - 1` 个再加 `…`。
    static func truncate(_ line: String, maximumCharacters: Int, forceMarker: Bool = false) -> String {
        let scalars = line.unicodeScalars
        guard scalars.count > maximumCharacters || forceMarker else { return line }
        let kept = scalars.prefix(min(max(0, maximumCharacters - 1), scalars.count))
        return String(String.UnicodeScalarView(kept)) + "…"
    }
}
