//
//  AgentToolAuthorizationSupport.swift
//  WillDeep
//
//  Support helpers for tool authorization:
//   - sandbox audit JSONL logging;
//   - command-family signatures used by Always Allow;
//   - tool-level signatures and MCP read-only heuristics.
//

import CryptoKit
import Foundation
import WillDeepCore

enum AgentSandboxAuditLog {
    struct Entry: Codable, Equatable {
        let timestamp: Date
        let toolName: String
        let mode: AgentSandboxMode
        let approvedBy: String
        let summary: String
        let reason: String
        let outcome: String
    }

    private static let maxLineBytes = 8 * 1024

    static func append(
        toolName: String,
        arguments: [String: AgentJSONValue],
        decision: AgentSandboxDecision,
        approvalSource: AgentToolApprovalSource?,
        outcome: String
    ) {
        let entry = Entry(
            timestamp: Date(),
            toolName: toolName,
            mode: decision.mode,
            approvedBy: approvalSource?.rawValue ?? (decision.requiresUserApproval ? "userRequired" : "autoReadOnly"),
            summary: AgentSandboxPolicy.scrub(summary(toolName: toolName, arguments: arguments)),
            reason: AgentSandboxPolicy.scrub(decision.reason),
            outcome: outcome
        )
        guard let data = try? JSONEncoder.agentSandboxEncoder.encode(entry) else { return }
        var line = String(data: data, encoding: .utf8) ?? "{}"
        if line.utf8.count > maxLineBytes {
            line = String(line.prefix(maxLineBytes)) + "\"...[truncated]\"}"
        }
        line += "\n"
        guard let url = auditURL(),
              let bytes = line.data(using: .utf8) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: [.atomic])
        }
    }

    /// Browser rows used to record only the tool name, so an audit could not
    /// tell which site was opened or which script ran. Typed text is never
    /// logged (it may be a resolved secret) — only its length.
    static func browserSummary(toolName: String, arguments: [String: AgentJSONValue]) -> String {
        var parts = [toolName]
        if let url = arguments["url"]?.stringValue() {
            parts.append("url=\(url)")
        }
        if let selector = arguments["selector"]?.stringValue() {
            parts.append("selector=\(selector.prefix(120))")
        }
        if let ref = arguments["ref"]?.stringValue() {
            parts.append("ref=\(ref)")
        }
        if let text = arguments["text"]?.stringValue() {
            parts.append("text_chars=\(text.count)")
        }
        if let method = arguments["method"]?.stringValue() {
            parts.append("method=\(method)")
        }
        if let key = arguments["key"]?.stringValue() {
            parts.append("key=\(key)")
        }
        if let direction = arguments["direction"]?.stringValue() {
            parts.append("direction=\(direction)")
        }
        if let paths = arguments["paths"]?.stringArrayValue(), !paths.isEmpty {
            parts.append("paths=\(paths.joined(separator: ","))")
        }
        if let javascript = arguments["javascript"]?.stringValue() {
            let digest = SHA256.hash(data: Data(javascript.utf8))
                .prefix(6).map { String(format: "%02x", $0) }.joined()
            let head = javascript.replacingOccurrences(of: "\n", with: " ").prefix(160)
            parts.append("js_chars=\(javascript.count) js_sha256=\(digest) js=\(head)")
        }
        return parts.joined(separator: " ")
    }

    private static func summary(toolName: String, arguments: [String: AgentJSONValue]) -> String {
        if toolName == "run_command", let command = arguments["command"]?.stringValue() {
            return command
        }
        if toolName == "terminal_send_command",
           let command = arguments["command"]?.stringValue() {
            return command
        }
        if toolName == "web_fetch", let url = arguments["url"]?.stringValue() {
            return url
        }
        if toolName == "write_file", let path = arguments["path"]?.stringValue() {
            let overwrite = arguments["overwrite"]?.boolValue() ?? false
            return "path=\(path) overwrite=\(overwrite)"
        }
        if toolName == "call_mcp_tool" {
            let server = arguments["server"]?.stringValue() ?? "?"
            let tool = arguments["tool"]?.stringValue() ?? "?"
            return "\(server).\(tool)"
        }
        if toolName == "lark_cli" {
            return AgentLarkCLI.commandPreview(arguments: arguments["arguments"]?.stringArrayValue() ?? [])
        }
        if toolName.hasPrefix("embedded_browser_") || toolName.hasPrefix("chrome_") {
            return browserSummary(toolName: toolName, arguments: arguments)
        }
        if toolName.hasPrefix("computer_use_") {
            let targetPID = arguments["pid"]?.intValue().map(String.init)
            let target = arguments["target_label"]?.stringValue()
                ?? arguments["app"]?.stringValue()
                ?? targetPID
                ?? "?"
            let purpose = arguments["purpose"]?.stringValue() ?? "-"
            let consequence = arguments["consequence"]?.stringValue() ?? "-"
            return "\(toolName) target=\(target) purpose=\(purpose) consequence=\(consequence)"
        }
        return toolName
    }

    /// The directory holding every audit log — `sandbox.jsonl`,
    /// `judge.jsonl` and the Worker timing log are siblings. Exposed so the
    /// diagnostics export reads one definition of where they live instead of
    /// rebuilding the path and drifting from it.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("AgentAudit", isDirectory: true)
    }

    private static func auditURL() -> URL? {
        directory.appendingPathComponent("sandbox.jsonl")
    }

    // MARK: - Reading prior decisions (judge few-shot history)

    /// Split recent audit entries into command samples the operator
    /// APPROVED by hand versus ones they REJECTED, newest first. Only
    /// command-shaped tools contribute (a `terminal_snapshot` line is
    /// noise to the judge). Bounded work: only the last `tailBytes` of the
    /// file are read and parsed, so this stays cheap even as the log grows.
    static func judgeHistorySamples(
        approvedLimit: Int = 40,
        rejectedLimit: Int = 20,
        tailBytes: Int = 128 * 1024
    ) -> (approved: [String], rejected: [String]) {
        let entries = recentEntries(tailBytes: tailBytes)
        var approved: [String] = []
        var rejected: [String] = []
        // recentEntries is oldest→newest (file order); walk backwards so the
        // freshest decisions win the capped slots.
        for entry in entries.reversed() {
            guard entry.toolName == "run_command"
                || entry.toolName == "terminal_send_command"
                || entry.toolName == "call_mcp_tool" else { continue }
            let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, summary != entry.toolName else { continue }
            if entry.outcome == "denied" {
                if rejected.count < rejectedLimit { rejected.append(summary) }
            } else if entry.approvedBy == "user" || entry.approvedBy == "escalated" {
                // Escalated is still a hand approval: it means the operator
                // explicitly allowed an unsandboxed/external command. Omitting
                // it taught the judge from easy local approvals while ignoring
                // the network/remote decisions where learning mattered most.
                if approved.count < approvedLimit { approved.append(summary) }
            }
            if approved.count >= approvedLimit && rejected.count >= rejectedLimit { break }
        }
        return (approved, rejected)
    }

    private static func recentEntries(tailBytes: Int) -> [Entry] {
        guard let url = auditURL(),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // Drop the leading partial line when we seeked into the middle.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Judge outcome log

    struct JudgeEntry: Codable, Equatable {
        let timestamp: Date
        let toolName: String
        let command: String
        let model: String
        let verdict: String
        let detail: String
    }

    /// Record one auto-approve judge round trip to `judge.jsonl` (sibling of
    /// sandbox.jsonl). This is the observability that used to be missing:
    /// every allow / deny / unavailable outcome lands on disk with its
    /// reason, so "why did it still ask me?" becomes answerable instead of a
    /// silent `return false`.
    static func recordJudge(
        toolName: String,
        command: String,
        model: String,
        verdict: String,
        detail: String
    ) {
        let entry = JudgeEntry(
            timestamp: Date(),
            toolName: toolName,
            command: AgentSandboxPolicy.scrub(String(command.prefix(400))),
            model: model,
            verdict: verdict,
            detail: String(detail.prefix(200))
        )
        guard let data = try? JSONEncoder.agentSandboxEncoder.encode(entry) else { return }
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line += "\n"
        guard let url = judgeURL(), let bytes = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: [.atomic])
        }
    }

    private static func judgeURL() -> URL? {
        auditURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("judge.jsonl")
    }
}

private extension JSONEncoder {
    static var agentSandboxEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum AgentCommandAuthorization {
    nonisolated static func signature(for command: String) -> String? {
        guard let rawTokens = shellTokens(from: command) else { return nil }
        let tokens = commandTokensSkippingEnvironmentAssignments(rawTokens)
        guard let executable = tokens.first?.lowercased(), !executable.isEmpty else {
            return nil
        }

        if executable == "ssh", let remoteCommand = sshRemoteCommand(from: tokens),
           let remoteSignature = signature(for: remoteCommand) {
            return "ssh \(remoteSignature)"
        }

        if executable == "git", tokens.count >= 2 {
            return "\(executable) \(tokens[1].lowercased())"
        }

        if ["npm", "pnpm"].contains(executable), tokens.count >= 3, tokens[1].lowercased() == "run" {
            return "\(executable) run \(tokens[2].lowercased())"
        }

        if executable == "yarn", tokens.count >= 3, tokens[1].lowercased() == "run" {
            return "\(executable) run \(tokens[2].lowercased())"
        }

        if tokenUsesSubcommand(executable), tokens.count >= 2 {
            return "\(executable) \(tokens[1].lowercased())"
        }

        return tokenAllowsBareSignature(executable) ? executable : nil
    }

    nonisolated static func reusableCategorySignature(for command: String) -> String? {
        let segments = shellSegments(from: command)
        guard !segments.isEmpty else { return nil }

        let tokenizedSegments = segments.compactMap { segment -> [String]? in
            guard let rawTokens = shellTokens(from: segment) else { return nil }
            return commandTokensSkippingEnvironmentAssignments(rawTokens)
        }
        guard tokenizedSegments.count == segments.count,
              !tokenizedSegments.contains(where: \.isEmpty) else {
            return nil
        }

        if tokenizedSegments.allSatisfy(isKubernetesOrHarmlessCompanionSegment),
           tokenizedSegments.contains(where: isKubernetesSegment),
           SafeCommand.classify(command: command) == .alwaysSafe {
            return "shell_category:kubernetes_read"
        }

        if tokenizedSegments.count == 1,
           let host = curlGetHost(tokenizedSegments[0]),
           !containsShellRedirectionOrPipe(command) {
            return "shell_category:http_get:\(host)"
        }

        if tokenizedSegments.allSatisfy(isReadOnlyInspectionSegment),
           !containsShellRedirectionOrPipe(command) {
            return "shell_category:read_only_inspection"
        }

        return nil
    }

    nonisolated static func displayName(for command: String) -> String {
        signature(for: command) ?? command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func prefixRule(for command: String) -> [String]? {
        guard let rawTokens = shellTokens(from: command) else { return nil }
        let tokens = commandTokensSkippingEnvironmentAssignments(rawTokens)
        guard !tokens.isEmpty else { return nil }
        let executable = tokens[0].lowercased()
        if executable == "ssh", let remoteCommand = sshRemoteCommand(from: tokens),
           let remoteRule = prefixRule(for: remoteCommand) {
            return ["ssh"] + remoteRule
        }
        if executable == "git", tokens.count >= 2 {
            return [executable, tokens[1].lowercased()]
        }
        if ["npm", "pnpm", "yarn"].contains(executable), tokens.count >= 3, tokens[1].lowercased() == "run" {
            return [executable, "run", tokens[2].lowercased()]
        }
        if tokenUsesSubcommand(executable), tokens.count >= 2 {
            return [executable, tokens[1].lowercased()]
        }
        return tokenAllowsBareSignature(executable) ? [executable] : nil
    }

    nonisolated private static func commandTokensSkippingEnvironmentAssignments(_ tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        return Array(tokens.suffix(from: index))
    }

    nonisolated private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex else {
            return false
        }
        let name = token[..<equalsIndex]
        guard let first = name.first,
              first == "_" || first.isLetter else {
            return false
        }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    nonisolated private static func tokenUsesSubcommand(_ token: String) -> Bool {
        [
            "cargo", "go", "swift", "xcodebuild", "make",
            "ruby", "python", "python3", "node",
            "npm", "pnpm", "yarn", "gh"
        ].contains(token)
    }

    nonisolated private static func tokenAllowsBareSignature(_ token: String) -> Bool {
        ["ls", "pwd"].contains(token)
    }

    nonisolated private static func shellSegments(from command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .split { $0 == "\n" || $0 == ";" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func executableName(from tokens: [String]) -> String? {
        guard let head = tokens.first else { return nil }
        return URL(fileURLWithPath: head).lastPathComponent.lowercased()
    }

    nonisolated private static func isKubernetesSegment(_ tokens: [String]) -> Bool {
        guard let executable = executableName(from: tokens) else { return false }
        // `k` is an arbitrary local executable/alias and `oc` has additional
        // mutation verbs. Only the classifier-covered kubectl binary earns a
        // reusable read-only category.
        return executable == "kubectl"
    }

    nonisolated private static func isKubernetesOrHarmlessCompanionSegment(_ tokens: [String]) -> Bool {
        if isKubernetesSegment(tokens) { return true }
        guard let executable = executableName(from: tokens) else { return false }
        return ["echo", "printf"].contains(executable)
    }

    nonisolated private static func isReadOnlyInspectionSegment(_ tokens: [String]) -> Bool {
        guard let executable = executableName(from: tokens) else { return false }
        return [
            "cat", "command", "echo", "head", "less", "ls", "more", "nl",
            "printf", "ps", "pwd", "tail", "type", "wc", "whereis", "which"
        ].contains(executable)
    }

    nonisolated private static func curlGetHost(_ tokens: [String]) -> String? {
        guard executableName(from: tokens) == "curl" else { return nil }
        var explicitMethod: String?
        var publicHosts: [String] = []
        var index = 1
        let safeNoArgumentLongFlags: Set<String> = [
            "--fail", "--fail-with-body", "--silent", "--show-error",
            "--verbose", "--head", "--include", "--compressed",
            "--http1.1", "--http2", "--http3", "--ipv4", "--ipv6",
            "--insecure", "--no-progress-meter"
        ]
        let safeArgumentLongFlags: Set<String> = [
            "--connect-timeout", "--max-time", "--retry", "--retry-delay",
            "--retry-max-time"
        ]
        while index < tokens.count {
            let token = tokens[index]
            let lower = token.lowercased()
            if token == "-X" || lower == "--request" {
                if index + 1 < tokens.count {
                    explicitMethod = tokens[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    return nil
                }
                index += 2
                continue
            }
            if token.hasPrefix("-X"), token.count > 2 {
                explicitMethod = String(token.dropFirst(2))
            } else if lower.hasPrefix("--request=") {
                explicitMethod = String(token.dropFirst("--request=".count))
            } else if token == "-I" || lower == "--head" {
                explicitMethod = "HEAD"
            } else if safeNoArgumentLongFlags.contains(lower) {
                // no-op
            } else if safeArgumentLongFlags.contains(lower) {
                guard index + 1 < tokens.count else { return nil }
                index += 2
                continue
            } else if safeArgumentLongFlags.contains(where: { lower.hasPrefix($0 + "=") }) {
                // accepted bounded transport tuning
            } else if lower == "--url" {
                guard index + 1 < tokens.count,
                      let host = AgentWebTools.validatedPublicURL(tokens[index + 1])?.host?.lowercased() else {
                    return nil
                }
                publicHosts.append(host)
                index += 2
                continue
            } else if lower.hasPrefix("--url=") {
                let rawURL = String(token.dropFirst("--url=".count))
                guard let host = AgentWebTools.validatedPublicURL(rawURL)?.host?.lowercased() else {
                    return nil
                }
                publicHosts.append(host)
            } else if token.hasPrefix("-") {
                let safeShortFlags = Set("fsSIivk46")
                guard token.dropFirst().allSatisfy(safeShortFlags.contains) else {
                    return nil
                }
            } else {
                guard let host = AgentWebTools.validatedPublicURL(token)?.host?.lowercased() else {
                    return nil
                }
                publicHosts.append(host)
            }
            index += 1
        }
        let method = explicitMethod?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard method == nil || method == "GET" || method == "HEAD" else { return nil }
        let uniqueHosts = Set(publicHosts)
        guard uniqueHosts.count == 1 else { return nil }
        return uniqueHosts.first
    }

    nonisolated private static func containsShellRedirectionOrPipe(_ command: String) -> Bool {
        command.contains("|") || command.contains(">") || command.contains("<")
    }

    /// Trim once and check non-empty, used by MCP signature derivation.
    // `cleaned` 是本类型自己的实现细节，包里也有一份同样的私有副本。
    // 刻意不从包里 public 出来：包的公开面越小，改包内实现越不触发 App 重编。
    nonisolated fileprivate static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // 这几个纯字符串处理函数已移入 WillDeepCore（包内与 SafeCommand 同模块，
    // 避免包反向依赖 App）。这里保留同名转调，既有调用点一个都不用改。
    nonisolated static func sshRemoteCommand(from command: String) -> String? {
        AgentShellCommandParser.sshRemoteCommand(from: command)
    }

    nonisolated static func sshRemoteCommand(from tokens: [String]) -> String? {
        AgentShellCommandParser.sshRemoteCommand(from: tokens)
    }

    nonisolated static func sshHostIndex(_ tokens: [String]) -> Int? {
        AgentShellCommandParser.sshHostIndex(tokens)
    }

    nonisolated static func shellTokens(from command: String) -> [String]? {
        AgentShellCommandParser.shellTokens(from: command)
    }
}

/// Tool-level always-allow signature. Decides per tool name how to
/// scope the "remember this" rule:
///  - `run_command` -> command-family signature ("git push") via
///    AgentCommandAuthorization.
///  - `call_mcp_tool` -> "mcp:<server>:<tool>", so the same server.tool
///    pair auto-approves regardless of `arguments_json`. Arguments are
///    intentionally not part of the signature: the user pinning a
///    specific MCP tool means "I trust this tool, run it again", not
///    "exactly this query string".
///  - `terminal_send_command` -> exact visible-terminal command line,
///    because typing into the user's watched terminal is side-effectful
///    and should not be broadened to a whole command family.
///  - `terminal_send_control` -> exact whitelisted control key, e.g.
///    `terminal_control:ctrl_c`; Ctrl-C approval must not imply Enter.
///  - everything else -> nil (the Always Allow button hides; the user
///    still has to click Allow per call). file_write / file_patch /
///    file_remove are deliberately not pinnable because their blast
///    radius depends entirely on the path argument.
enum AgentToolAuthorization {
    /// Cache key for safety-judge YES verdicts: tool name + exact normalized
    /// command + the compact redacted task context used for that review. A
    /// hidden, short-lived machine verdict must never broaden one
    /// `git push`/`gh pr` decision to different arguments merely because the
    /// executable and subcommand match. Durable family rules remain a
    /// separate, explicit user choice.
    nonisolated static func judgeVerdictCacheKey(
        toolName: String,
        command: String,
        taskContext: String = "",
        environmentTrustFingerprint: String = "",
        judgeKind: AgentSafetyJudgeKind = .developerOperations
    ) -> String {
        let exactCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactTaskContext = taskContext.trimmingCharacters(in: .whitespacesAndNewlines)
        // 声明指纹进键：同一条命令在"有声明"与"无声明"两种语境下是两个键。
        // 撤销声明后旧的 YES 不会被复用，跨会话共享的缓存也不会把 A 会话
        // 声明下的判决泄给没有声明的 B 会话。
        // 裁判种类进键：两种裁判问的是方向相反的问题，一个 YES 绝不能
        // 顶另一个的 YES 用。
        return "\(judgeKind)|\(toolName)|\(exactCommand)|\(exactTaskContext)|\(environmentTrustFingerprint)"
    }

    static func interactiveSurfaceSignature(toolName: String) -> String? {
        if toolName.hasPrefix("computer_use_") {
            // Native desktop control never uses the generic conversation
            // allow-list. Ordinary actions are approved only by the live
            // runtime/target-bound Computer Use lease; consequential actions
            // remain per-action confirmations.
            return nil
        }
        // Arbitrary page JavaScript and raw CDP commands can read cookies and
        // tokens on logged-in pages, so they never ride on a family grant:
        // each call is approved on its own.
        if browserToolsRequiringPerCallApproval.contains(toolName) {
            return nil
        }
        if toolName.hasPrefix("chrome_") {
            return "browser:chrome"
        }
        if toolName.hasPrefix("embedded_browser_") {
            return "browser:embedded"
        }
        return nil
    }

    nonisolated static let browserToolsRequiringPerCallApproval: Set<String> = [
        "embedded_browser_eval",
        "chrome_debugger_command",
        // Sends local files to a website: each upload is its own decision.
        "embedded_browser_upload_file",
    ]

    /// Durable ("always allow") rule for a browser tool. Earlier builds saved
    /// the whole family (`browser:embedded` / `browser:chrome`), so one
    /// approved navigation silently authorized eval, click and type on every
    /// site forever. Rules are now one tool wide, and navigation rules are
    /// also bound to the destination host. Legacy family rules no longer
    /// match anything.
    static func browserPersistentSignature(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> String? {
        guard let family = interactiveSurfaceSignature(toolName: toolName) else { return nil }
        guard toolName.hasSuffix("_navigate") else {
            return "\(family):\(toolName)"
        }
        guard let host = browserNavigationHost(arguments["url"]?.stringValue() ?? "") else {
            return nil
        }
        return "\(family):\(toolName):\(host)"
    }

    static func browserNavigationHost(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: candidate)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Signature offered by the approval card as a durable rule.
    ///
    /// `signature` remains the matching contract for rules the user already
    /// saved. This narrower entry point only controls whether a *new* rule is
    /// worth suggesting. Keeping those concerns separate lets us stop
    /// advertising one-off, deeply wrapped commands without silently
    /// invalidating existing preferences.
    static func suggestedPersistentSignature(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> String? {
        // Native desktop control is intentionally never durable. A remembered
        // `computer_use:*` rule would outlive the current target/turn and let
        // an approval for a harmless scroll authorize a later send, delete,
        // purchase, permission change, or entirely different app.
        if toolName.hasPrefix("computer_use_") {
            return nil
        }
        if ["run_command", "terminal_send_command"].contains(toolName),
           let command = arguments["command"]?.stringValue(),
           AgentSandboxPolicy.commandRequiresSensitiveDesktopConfirmation(command) {
            return nil
        }
        let baseSignature = signature(toolName: toolName, arguments: arguments)

        switch toolName {
        case "run_command", "terminal_send_command":
            guard let command = arguments["command"]?.stringValue(),
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if toolName == "terminal_send_command",
               AgentTerminalTools.hasZModemPathSelection(arguments) {
                // File and destination selections are deliberately exact and
                // almost always one-off, even when the visible command is the
                // reusable-looking `rz` or `sz`.
                return nil
            }
            if let category = AgentCommandAuthorization.reusableCategorySignature(for: command) {
                return category
            }
            guard let signature = baseSignature else { return nil }
            guard commandLooksReusable(command) else { return nil }
            return signature
        case "lark_cli":
            guard let signature = baseSignature else { return nil }
            let cliArguments = AgentLarkCLI.normalizedArguments(
                arguments["arguments"]?.stringArrayValue() ?? []
            )
            guard cliArguments.count <= 4,
                  cliArguments.allSatisfy({ $0.count <= 80 }) else {
                return nil
            }
            return signature
        default:
            return baseSignature
        }
    }

    /// Cheap, deterministic first-pass for the approval UI. The safety judge
    /// answers whether a command is safe to execute *now*; this answers the
    /// different question of whether its authorization shape is likely to be
    /// useful again. Avoiding another LLM round trip here keeps every approval
    /// card responsive and prevents spending tokens just to decide whether to
    /// render an optional button.
    private static func commandLooksReusable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 180,
              let tokens = AgentCommandAuthorization.shellTokens(from: trimmed),
              !tokens.isEmpty,
              tokens.count <= 5,
              tokens.allSatisfy({ $0.count <= 80 }) else {
            return false
        }

        let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent.lowercased()
        if executable == "ssh" {
            // A local command wrapping a second remote command has two scopes
            // and usually contains host-specific, one-off arguments.
            return false
        }

        let inlineProgramFlags: Set<String> = ["-c", "-lc", "-e"]
        if ["sh", "bash", "zsh", "fish", "ruby", "python", "python3", "node"].contains(executable),
           tokens.dropFirst().contains(where: { inlineProgramFlags.contains($0.lowercased()) }) {
            return false
        }

        return true
    }

    static func signature(toolName: String, arguments: [String: AgentJSONValue]) -> String? {
        if toolName.hasPrefix("chrome_") || toolName.hasPrefix("embedded_browser_") {
            return browserPersistentSignature(toolName: toolName, arguments: arguments)
        }
        if let signature = interactiveSurfaceSignature(toolName: toolName) {
            return signature
        }
        switch toolName {
        case "run_command":
            guard let command = arguments["command"]?.stringValue() else { return nil }
            return AgentCommandAuthorization.signature(for: command)
        case "terminal_send_command":
            guard let command = AgentCommandAuthorization.cleaned(arguments["command"]?.stringValue() ?? "") else {
                return nil
            }
            var signature = "terminal_command:\(command)"
            if let uploadPaths = arguments["zmodem_upload_paths"]?.stringArrayValue(),
               !uploadPaths.isEmpty {
                signature += "|zmodem_upload:" + uploadPaths.joined(separator: "\u{1F}")
            }
            if let downloadDirectory = AgentCommandAuthorization.cleaned(
                arguments["zmodem_download_directory"]?.stringValue() ?? ""
            ) {
                signature += "|zmodem_download:\(downloadDirectory)"
            }
            return signature
        case "terminal_send_control":
            guard let control = AgentCommandAuthorization.cleaned(arguments["control"]?.stringValue() ?? "")?.lowercased(),
                  ["ctrl_c", "ctrl_d", "ctrl_right_bracket", "enter", "escape"].contains(control) else {
                return nil
            }
            return "terminal_control:\(control)"
        case "call_mcp_tool":
            guard let rawServer = arguments["server"]?.stringValue(),
                  let rawTool = arguments["tool"]?.stringValue(),
                  let server = AgentCommandAuthorization.cleaned(rawServer),
                  let tool = AgentCommandAuthorization.cleaned(rawTool) else {
                return nil
            }
            return "mcp:\(server.lowercased()):\(tool)"
        case "lark_cli":
            let cliArguments = AgentLarkCLI.normalizedArguments(arguments["arguments"]?.stringArrayValue() ?? [])
            guard let first = cliArguments.first else { return nil }
            var parts = [first]
            if let second = cliArguments.dropFirst().first {
                parts.append(second)
            }
            let scope = parts.map { $0.lowercased() }.joined(separator: ":")
            return scope.isEmpty ? nil : "lark_cli:\(scope)"
        case "claude_code":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "acceptEdits"
            return "claude_code:\(mode)"
        case "codex_cli":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "workspaceWrite"
            return "codex_cli:\(mode)"
        case "hermes_cli":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "workspaceWrite"
            return "hermes_cli:\(mode)"
        case "cursor_agent":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
            return "cursor_agent:\(mode)"
        case "cline_cli":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "act"
            return "cline_cli:\(mode == "default" ? "act" : mode)"
        case "opencode_cli":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
            return "opencode_cli:\(mode)"
        default:
            return nil
        }
    }

    static func matchingSignatures(toolName: String, arguments: [String: AgentJSONValue]) -> [String] {
        var result: [String] = []
        if ["run_command", "terminal_send_command"].contains(toolName),
           let command = arguments["command"]?.stringValue(),
           let category = AgentCommandAuthorization.reusableCategorySignature(for: command) {
            result.append(category)
        }
        if let signature = signature(toolName: toolName, arguments: arguments) {
            result.append(signature)
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0).inserted }
    }

    static func signature(for call: AgentToolCall) -> String? {
        signature(toolName: call.toolName, arguments: call.arguments)
    }

    // MARK: - MCP read-only heuristics

    /// Tool-name prefixes that, by near-universal MCP convention, name
    /// read/query operations. Only consulted for servers the user has
    /// NOT marked untrusted: a hostile server could name a destructive
    /// tool `get_pwned`, which is exactly what the per-server trust
    /// flag is for.
    private static let mcpReadOnlyToolNamePrefixes = [
        "get_", "list_", "read_", "search_", "query_", "fetch_",
        "describe_", "show_", "find_", "count_", "preview_", "lookup_",
        "check_", "view_", "inspect_", "browse_",
    ]

    private static let mcpReadOnlyToolNames: Set<String> = [
        "ping", "status", "info", "version", "health", "whoami", "help",
    ]

    static func mcpToolNameLooksReadOnly(_ tool: String) -> Bool {
        let normalized = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if mcpReadOnlyToolNames.contains(normalized) { return true }
        return mcpReadOnlyToolNamePrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Render an MCP call as a pseudo command line for the LLM safety
    /// judge (same fenced-data / verdict-tag pipeline the shell judge
    /// uses; see AgentInjectionDefense).
    static func mcpJudgePseudoCommand(server: String, tool: String, argumentsJSON: String) -> String {
        "mcp-tool-call server=\(server) tool=\(tool) arguments=\(argumentsJSON)"
    }

    /// Render a `terminal_send_control` call as a pseudo command line for
    /// the LLM safety judge. The control key is one of the whitelisted set
    /// (`ctrl_c` / `ctrl_d` / `ctrl_right_bracket` / `enter` / `escape`);
    /// the judge sees the intent and can
    /// YES the harmless interrupt/cancel keys while staying cautious about
    /// `enter` submitting a queued line.
    static func terminalControlJudgePseudoCommand(control: String) -> String {
        "terminal-send-control key=\(control)"
    }
}
