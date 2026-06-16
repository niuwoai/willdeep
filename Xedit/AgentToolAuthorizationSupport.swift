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
        guard let tokens = shellTokens(from: command) else { return nil }
        guard let executable = tokens.first?.lowercased(), !executable.isEmpty else {
            return nil
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
        guard let tokens = shellTokens(from: command), !tokens.isEmpty else { return nil }
        let executable = tokens[0].lowercased()
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
///  - everything else -> nil (the Always Allow button hides; the user
///    still has to click Allow per call). file_write / file_patch /
///    file_remove are deliberately not pinnable because their blast
///    radius depends entirely on the path argument.
enum AgentToolAuthorization {
    static func signature(toolName: String, arguments: [String: AgentJSONValue]) -> String? {
        switch toolName {
        case "run_command":
            guard let command = arguments["command"]?.stringValue() else { return nil }
            return AgentCommandAuthorization.signature(for: command)
        case "call_mcp_tool":
            guard let rawServer = arguments["server"]?.stringValue(),
                  let rawTool = arguments["tool"]?.stringValue(),
                  let server = AgentCommandAuthorization.cleaned(rawServer),
                  let tool = AgentCommandAuthorization.cleaned(rawTool) else {
                return nil
            }
            return "mcp:\(server.lowercased()):\(tool)"
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
}
