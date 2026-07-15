//
//  AgentToolAuthorizationSupport.swift
//  WillDeep
//
//  Support helpers for tool authorization:
//   - sandbox audit JSONL logging;
//   - command-family signatures used by Always Allow;
//   - tool-level signatures and MCP read-only heuristics.
//

import Foundation

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

    private static func summary(toolName: String, arguments: [String: AgentJSONValue]) -> String {
        if toolName == "run_command", let command = arguments["command"]?.stringValue() {
            return command
        }
        if toolName == "web_fetch", let url = arguments["url"]?.stringValue() {
            return url
        }
        if toolName == "call_mcp_tool" {
            let server = arguments["server"]?.stringValue() ?? "?"
            let tool = arguments["tool"]?.stringValue() ?? "?"
            return "\(server).\(tool)"
        }
        if toolName == "lark_cli" {
            return AgentLarkCLI.commandPreview(arguments: arguments["arguments"]?.stringArrayValue() ?? [])
        }
        return toolName
    }

    private static func auditURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("AgentAudit", isDirectory: true)
            .appendingPathComponent("sandbox.jsonl")
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
            } else if entry.approvedBy == "user" {
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

    /// Trim once and check non-empty, used by MCP signature derivation.
    nonisolated fileprivate static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func sshRemoteCommand(from command: String) -> String? {
        guard let tokens = shellTokens(from: command) else { return nil }
        return sshRemoteCommand(from: tokens)
    }

    nonisolated static func sshRemoteCommand(from tokens: [String]) -> String? {
        guard tokens.first?.lowercased() == "ssh",
              let hostIndex = sshHostIndex(tokens),
              hostIndex + 1 < tokens.count else {
            return nil
        }
        return cleaned(tokens.dropFirst(hostIndex + 1).joined(separator: " "))
    }

    nonisolated static func sshHostIndex(_ tokens: [String]) -> Int? {
        var index = 1
        let optionsWithArgument: Set<String> = [
            "-b", "-c", "-D", "-E", "-e", "-F", "-i", "-J", "-L", "-l", "-m",
            "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
        ]
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                continue
            }
            if optionsWithArgument.contains(token) {
                index += 2
                continue
            }
            if token.hasPrefix("-o") && token.count > 2 {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return index
        }
        return nil
    }

    nonisolated static func shellTokens(from command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            if "|&;".contains(character) {
                if character == "&", current.last == ">" {
                    current.append(character)
                    continue
                }
                return nil
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
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
        guard let signature = signature(toolName: toolName, arguments: arguments) else {
            return nil
        }

        switch toolName {
        case "run_command", "terminal_send_command":
            guard let command = arguments["command"]?.stringValue(),
                  commandLooksReusable(command) else {
                return nil
            }
            if toolName == "terminal_send_command",
               AgentTerminalTools.hasZModemPathSelection(arguments) {
                // File and destination selections are deliberately exact and
                // almost always one-off, even when the visible command is the
                // reusable-looking `rz` or `sz`.
                return nil
            }
        case "lark_cli":
            let cliArguments = AgentLarkCLI.normalizedArguments(
                arguments["arguments"]?.stringArrayValue() ?? []
            )
            guard cliArguments.count <= 4,
                  cliArguments.allSatisfy({ $0.count <= 80 }) else {
                return nil
            }
        default:
            break
        }

        return signature
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
                  ["ctrl_c", "enter", "escape"].contains(control) else {
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
        case "cursor_agent":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
            return "cursor_agent:\(mode)"
        case "cline_cli":
            let mode = arguments["permission_mode"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "act"
            return "cline_cli:\(mode == "default" ? "act" : mode)"
        case "web_fetch":
            guard let raw = arguments["url"]?.stringValue(),
                  let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
                  !host.isEmpty else {
                return nil
            }
            return "web_fetch:\(host.lowercased())"
        default:
            return nil
        }
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
    /// (`ctrl_c` / `enter` / `escape`); the judge sees the intent and can
    /// YES the harmless interrupt/cancel keys while staying cautious about
    /// `enter` submitting a queued line.
    static func terminalControlJudgePseudoCommand(control: String) -> String {
        "terminal-send-control key=\(control)"
    }
}
