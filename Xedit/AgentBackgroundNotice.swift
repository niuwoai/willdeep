//
//  AgentBackgroundNotice.swift
//  WillDeep
//
//  后台任务完成通知 v1 的渲染器。canonical 合同在
//  `docs/BACKGROUND_TASK_CONTRACT.md`，金样在
//  `docs/contracts/background-task-notification.v1.txt`。
//
//  willdeep-rs 的 `background_notice.rs` 渲染同一份金样，两端必须逐字一致：
//  同一个模型换个前端，不该重新学一遍怎么读通知。字段顺序、取值拼写、尾巴
//  长度、脱敏规则都是合同的一部分，改这里要同时改 rs 端和金样。
//
//  「字符」一律按 Unicode 标量数（Rust `chars()` 的口径），不按 Swift 的
//  字素簇 `String.count`；比较、前缀判断也走标量/字节，避开 Swift 的
//  规范等价比较。
//

import Foundation

nonisolated enum AgentBackgroundNotice {
    /// 失败类通知带多少行尾巴。
    static let failureTailLines = 40
    /// 失败类通知尾巴的字符上限。
    static let failureTailCharacters = 4_000
    /// 成功通知带多少行尾巴：一句「PASS」够模型确认，省掉一次 `get_job_output`。
    static let successTailLines = 10
    static let successTailCharacters = 1_000
    /// `label` 只取第一行，并截到这么多字符。
    static let labelCharacters = 200

    private static let sensitiveKeyMarkers = [
        "key", "token", "secret", "password", "passwd", "pwd",
        "credential", "auth", "session", "cookie", "signature",
    ]
    private static let bareSecretPrefixes = ["sk-", "ghp_", "xoxb-"]
    private static let bareSecretMinimumBytes = 16
    private static let redactedMarker = "[REDACTED]"
    private static let ellipsis = "…"

    enum Kind: String {
        case shell
        case subagent
        case executor

        var tag: String {
            switch self {
            case .subagent: return "subagent-report"
            case .shell, .executor: return "background-task-notification"
            }
        }
    }

    enum Status: String {
        case completed
        case failed
        case killed
        case timedOut = "timed_out"
        case launchFailed = "launch_failed"
        /// 进程没了且没留下退出码。**不是失败**：失败是有退出码的。
        case vanished
        /// 子 Agent 专用：交了部分结果 / 被卡住需要父 Agent 介入。
        case partial
        case blocked
    }

    struct Notice {
        var id: String
        var kind: Kind
        var label: String
        var status: Status
        var exitCode: Int32?
        var durationSeconds: UInt64?
        /// 完整日志所在路径；不落盘时为 nil。
        var outputPath: String?
        /// stderr 单独落盘时的路径；Mac 合并日志，恒为 nil。
        var stderrPath: String?
        /// 因单日志上限没能落盘的字节数，通常为 0。
        var omittedBytes: UInt64
        var output: String
        /// 仅 executor：可复用会话，渲染为紧跟 `omitted_bytes:` 的
        /// `session: <executor> <session_id>` 一行。其他宿主不输出这一行。
        var executorSession: String? = nil
    }

    static func render(_ notice: Notice) -> String {
        let tag = notice.kind.tag
        // 子 Agent 的报告本身就是结论，成功也给长尾巴。
        let (lines, characters) = notice.status == .completed && notice.kind != .subagent
            ? (successTailLines, successTailCharacters)
            : (failureTailLines, failureTailCharacters)
        var rendered = "<\(tag)>\n"
        rendered += "id: \(clean(notice.id))\n"
        rendered += "kind: \(notice.kind.rawValue)\n"
        rendered += "label: \(label(notice.label))\n"
        rendered += "status: \(notice.status.rawValue)\n"
        rendered += "exit_code: \(notice.exitCode.map(String.init) ?? "unknown")\n"
        rendered += "duration: \(notice.durationSeconds.map(formatDuration) ?? "unknown")\n"
        rendered += "output_path: \(path(notice.outputPath))\n"
        rendered += "stderr_path: \(path(notice.stderrPath))\n"
        rendered += "omitted_bytes: \(notice.omittedBytes)\n"
        if notice.kind == .executor, let session = notice.executorSession {
            rendered += "session: \(clean(session))\n"
        }
        let tail = tail(notice.output, lines: lines, characters: characters)
        if tail.isEmpty {
            rendered += "output_tail: (empty)\n"
        } else {
            rendered += "output_tail (last \(lines) lines, secrets redacted):\n```text\n\(tail)\n```\n"
        }
        rendered += "</\(tag)>"
        return rendered
    }

    /// `65` → `1m5s`，`3725` → `1h2m5s`，`0` → `0s`。
    static func formatDuration(_ seconds: UInt64) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let remainder = seconds % 60
        if hours == 0 && minutes == 0 { return "\(remainder)s" }
        if hours == 0 { return "\(minutes)m\(remainder)s" }
        return "\(hours)h\(minutes)m\(remainder)s"
    }

    // MARK: - Fields

    /// Shared with `AgentMonitorNotice`: same first-line, 200-character rule.
    static func label(_ value: String) -> String {
        let first = rustLines(Array(value.unicodeScalars)).first ?? []
        let cleaned = Array(clean(string(trimWhitespace(first))).unicodeScalars)
        guard cleaned.count > labelCharacters else { return string(cleaned) }
        return string(Array(cleaned.prefix(labelCharacters))) + ellipsis
    }

    static func path(_ value: String?) -> String {
        value.map(clean) ?? "none"
    }

    /// 最后 `lines` 行，再截到最后 `characters` 个字符；截过就以 `…` 开头。
    static func tail(_ output: String, lines: Int, characters: Int) -> String {
        var trimmed = Array(output.unicodeScalars)
        while let last = trimmed.last, last == "\n" || last == "\r" { trimmed.removeLast() }
        guard !trimWhitespace(trimmed).isEmpty else { return "" }
        let all = rustLines(trimmed)
        let keptLines = all.suffix(lines).map(string)
        let kept = Array(clean(keptLines.joined(separator: "\n")).unicodeScalars)
        guard kept.count > characters else { return string(kept) }
        return ellipsis + string(Array(kept.suffix(characters)))
    }

    // MARK: - Cleaning

    /// 脱敏并中和标签：不可信文本里的 `</background-task-notification>` 不能
    /// 把框架提前关掉。
    static func clean(_ value: String) -> String {
        let redacted = Array(redactLines(value).unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < redacted.count {
            let scalar = redacted[index]
            let next = index + 1 < redacted.count ? redacted[index + 1] : nil
            if scalar == "<", let next, (next.isASCII && next.properties.isAlphabetic) || next == "/" {
                output.append(contentsOf: "&lt;".unicodeScalars)
            } else {
                output.append(scalar)
            }
            index += 1
        }
        return String(output)
    }

    /// 逐行脱敏。按空白切词再拼回会吃掉缩进和对齐；只有真的命中了凭据的
    /// 那一行才换成脱敏版本，其余行保持原样。
    static func redactLines(_ value: String) -> String {
        split(Array(value.unicodeScalars), separator: "\n").map { line -> String in
            let tokens = splitWhitespace(line)
            let redacted = redactCredentials(tokens)
            // rs 侧比较 `redacted.split(' ')` 与 `line.split_whitespace()`：
            // 空词序列拼回是 ""，再按空格切出一个空串，与空序列不等。
            let unchanged = !tokens.isEmpty && redacted.map(Array.init) == tokens.map { Array($0.unicodeScalars) }
            return unchanged ? string(line) : redacted.map { String($0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// `willdeep-core::judge::redact_credentials` 的逐词移植：`KEY=value`、
    /// `--password value`、`Bearer <token>`、裸 `sk-…` 类令牌。
    private static func redactCredentials(_ tokens: [String]) -> [String.UnicodeScalarView] {
        var output: [String.UnicodeScalarView] = []
        var redactNextValue = false
        for token in tokens {
            let scalars = token.unicodeScalars
            let startsWithDash = scalars.first == "-"
            if redactNextValue && !startsWithDash {
                output.append(redactedMarker.unicodeScalars)
                redactNextValue = false
                continue
            }
            redactNextValue = false

            if let equals = scalars.firstIndex(of: "=") {
                let key = String(scalars[scalars.startIndex..<equals])
                let value = scalars[scalars.index(after: equals)...]
                if !value.isEmpty && keyLooksSensitive(key) {
                    output.append((key + "=" + redactedMarker).unicodeScalars)
                    continue
                }
            }
            let flag = String(String.UnicodeScalarView(Array(scalars.drop(while: { $0 == "-" }))))
            if startsWithDash && keyLooksSensitive(flag) {
                output.append(scalars)
                redactNextValue = true
                continue
            }
            if looksLikeBareSecret(token) {
                output.append(redactedMarker.unicodeScalars)
                continue
            }
            if asciiEqualsIgnoringCase(token, "bearer") || asciiEqualsIgnoringCase(token, "basic") {
                output.append(scalars)
                redactNextValue = true
                continue
            }
            output.append(scalars)
        }
        return output
    }

    private static func keyLooksSensitive(_ key: String) -> Bool {
        let lowered = key.utf8.map(asciiLowercased)
        return sensitiveKeyMarkers.contains { containsBytes(lowered, Array($0.utf8)) }
    }

    private static func looksLikeBareSecret(_ token: String) -> Bool {
        var scalars = Array(token.unicodeScalars)
        let trimmable: Set<Unicode.Scalar> = ["\"", "'", ",", ";"]
        while let first = scalars.first, trimmable.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, trimmable.contains(last) { scalars.removeLast() }
        let bytes = Array(string(scalars).utf8)
        return bareSecretPrefixes.contains { prefix in
            let prefixBytes = Array(prefix.utf8)
            return bytes.starts(with: prefixBytes) && bytes.count - prefixBytes.count >= bareSecretMinimumBytes
        }
    }

    // MARK: - Scalar helpers (Rust `str` semantics)

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func split(_ scalars: [Unicode.Scalar], separator: Unicode.Scalar) -> [[Unicode.Scalar]] {
        scalars.split(separator: separator, omittingEmptySubsequences: false).map(Array.init)
    }

    /// Rust `str::lines`：按 `\n` 切，每段去掉一个结尾 `\r`，末尾空段不算。
    private static func rustLines(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        guard !scalars.isEmpty else { return [] }
        var pieces = split(scalars, separator: "\n")
        if scalars.last == "\n" { pieces.removeLast() }
        return pieces.map { piece in
            piece.last == "\r" ? Array(piece.dropLast()) : piece
        }
    }

    /// Rust `str::split_whitespace`（Unicode White_Space）。
    private static func splitWhitespace(_ scalars: [Unicode.Scalar]) -> [String] {
        scalars.split(whereSeparator: { $0.properties.isWhitespace }).map { string(Array($0)) }
    }

    private static func trimWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var slice = scalars[...]
        while let first = slice.first, first.properties.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.properties.isWhitespace { slice = slice.dropLast() }
        return Array(slice)
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func asciiEqualsIgnoringCase(_ value: String, _ other: String) -> Bool {
        value.utf8.map(asciiLowercased) == other.utf8.map(asciiLowercased)
    }

    private static func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}
