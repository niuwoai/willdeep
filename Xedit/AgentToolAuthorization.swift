//
//  AgentToolAuthorization.swift
//  WillDeep
//
//  Always-allow signature derivation for tool calls. Three pieces:
//   - `AgentAlwaysAllowedCommand`: the persisted "remember this command"
//     record (id + signature + createdAt) wired into AppState.
//   - `AgentCommandAuthorization`: derives a normalized signature like
//     "git status" / "yarn run build" / "ls" from a raw `run_command`
//     string, so the auto-allow comparison is structural rather than a
//     textual match. Holds its own private `shellTokens` (the conservative
//     no-pipeline tokenizer); the broader read-only-shell classifier in
//     AgentToolRegistry has a different, more permissive copy.
//   - `AgentToolAuthorization`: tool-level entry point that picks the
//     right signature scheme by tool name. `run_command` falls back to
//     AgentCommandAuthorization; `call_mcp_tool` returns
//     `mcp:<server>:<tool>` so pinning an MCP tool auto-approves every
//     future call to that exact server.tool pair regardless of
//     arguments. Returns nil for tools we don't know how to scope
//     (file_write, file_patch, …) — those still gate per-call.
//

import Foundation

struct AgentAlwaysAllowedCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let commandSignature: String
    let createdAt: Date

    init(id: UUID = UUID(), commandSignature: String, createdAt: Date = Date()) {
        self.id = id
        self.commandSignature = commandSignature
        self.createdAt = createdAt
    }
}

enum AgentSandboxMode: String, Codable, Equatable {
    case readOnly
    case workspaceWrite
    case escalated
}

struct AgentSandboxDecision: Equatable {
    let mode: AgentSandboxMode
    let requiresUserApproval: Bool
    let requiresTypedConfirmation: Bool
    let reason: String
    let prefixRule: [String]?

    var risk: AgentToolRisk {
        if requiresTypedConfirmation { return .danger }
        if requiresUserApproval { return .write }
        return .read
    }
}

struct AgentSandboxLaunch: Equatable {
    let executableURL: URL
    let arguments: [String]
}

/// Codex-style local execution policy for agent tools.
///
/// The app cannot create the exact same Linux/macOS seatbelt sandbox that
/// Codex CLI uses in every environment, so this policy provides the same
/// product contract at the tool boundary:
///  - read-only commands run in a scrubbed environment;
///  - workspace writes require explicit approval;
///  - network/credential/system/destructive commands require escalation;
///  - remembered approvals are scoped to narrow command prefixes.
enum AgentSandboxPolicy {
    nonisolated private static let shellControlOperators: Set<Character> = ["|", "&", ";", "\n"]
    nonisolated private static let redirectionCharacters: Set<Character> = [">", "<"]

    nonisolated private static let workspaceWriteHeads: Set<String> = [
        "apply_patch", "git", "make", "xcodebuild", "swift", "go",
        "cargo", "npm", "pnpm", "yarn", "ruby", "node", "python", "python3"
    ]

    nonisolated private static let networkHeads: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "gh", "brew"
    ]

    nonisolated private static let credentialHeads: Set<String> = [
        "security", "op", "pass", "gpg", "ssh-add"
    ]

    nonisolated private static let destructiveHeads: Set<String> = [
        "rm", "rmdir", "mv", "chmod", "chown", "chgrp", "sudo", "doas", "su",
        "kill", "killall", "pkill", "diskutil", "fdisk", "mkfs", "shutdown",
        "reboot", "halt", "poweroff", "launchctl", "dd"
    ]

    nonisolated private static let sensitivePathFragments: [String] = [
        "/.ssh", "/.gnupg", "/.aws", "/.config/gh", "/library/keychains",
        ".env", "id_rsa", "id_ed25519", "credentials", "token", "secret"
    ]

    nonisolated private static let sandboxExecPath = "/usr/bin/sandbox-exec"

    nonisolated static func decision(
        toolName: String,
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?
    ) -> AgentSandboxDecision {
        switch toolName {
        case "run_command":
            guard let command = arguments["command"]?.stringValue() else {
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: true,
                    reason: "Missing command argument.",
                    prefixRule: nil
                )
            }
            return commandDecision(command: command, rootDirectory: rootDirectory)
        case "web_fetch":
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "Network access to an arbitrary URL requires approval.",
                prefixRule: nil
            )
        case "call_mcp_tool", "claude_code", "codex_cli", "cursor_agent", "cline_cli", "kill_job":
            return AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "This tool can modify state or run external code.",
                prefixRule: nil
            )
        default:
            return AgentSandboxDecision(
                mode: .readOnly,
                requiresUserApproval: false,
                requiresTypedConfirmation: false,
                reason: "Read-only workspace tool.",
                prefixRule: nil
            )
        }
    }

    nonisolated static func commandDecision(command: String, rootDirectory: URL?) -> AgentSandboxDecision {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Empty command is refused.",
                prefixRule: nil
            )
        }

        let policyCommand = commandWithHeredocBodiesRemoved(trimmed)
        if containsUnsafeShellExpansion(policyCommand) {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Shell expansion can escape the sandbox.",
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }
        let hasRedirection = containsRedirection(policyCommand)

        guard let segments = splitCommandSegments(policyCommand), !segments.isEmpty else {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Complex shell syntax requires explicit escalation.",
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }

        var needsWorkspaceWrite = false
        var needsEscalation = false
        var needsConfirmation = false
        var reasons: [String] = []
        var workingDirectory = rootDirectory?.standardizedFileURL

        for segment in segments {
            guard let tokens = AgentCommandAuthorization.shellTokens(from: segment),
                  let head = tokens.first?.lowercased() else {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Unable to parse command segment safely.")
                continue
            }

            if forcefulGitMutation(tokens) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Forceful git history or workspace mutation requires typed confirmation.")
            }

            if hasRedirection {
                needsWorkspaceWrite = true
                reasons.append("Shell redirection may write outside normal tool output.")
            }

            if head == "cd" {
                if let next = tokens.dropFirst().first {
                    if let resolved = resolvePath(next, workingDirectory: workingDirectory, rootDirectory: rootDirectory),
                       isInsideWorkspace(resolved, rootDirectory: rootDirectory) {
                        workingDirectory = resolved
                    } else if rootDirectory == nil, isSafeRelativeDirectoryHop(next) {
                        workingDirectory = resolveRelativeDirectoryHop(next, workingDirectory: workingDirectory)
                    } else {
                        needsWorkspaceWrite = true
                        reasons.append("Changing directory outside the workspace requires approval.")
                    }
                } else {
                    workingDirectory = rootDirectory?.standardizedFileURL ?? workingDirectory
                }
                continue
            }

            if destructiveHeads.contains(head) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Destructive or privilege-changing command `\(head)` requires typed confirmation.")
            } else if networkHeads.contains(head) || credentialHeads.contains(head) {
                needsEscalation = true
                reasons.append("Command `\(head)` may use network, credentials, or macOS keychain access.")
            } else {
                switch SafeCommand.classify(command: segment) {
                case .alwaysSafe:
                    break
                case .alwaysDangerous:
                    if hasRedirection {
                        needsWorkspaceWrite = true
                        reasons.append("Command `\(head)` uses shell redirection and requires approval.")
                    } else {
                        needsEscalation = true
                        needsConfirmation = true
                        reasons.append("Command `\(head)` matches a destructive shell pattern.")
                    }
                case .needsJudgment:
                    needsWorkspaceWrite = true
                    if workspaceWriteHeads.contains(head) {
                        reasons.append("Command `\(head)` may write inside the workspace.")
                    } else {
                        reasons.append("Command `\(head)` is not known to be read-only.")
                    }
                }
            }

            if tokens.dropFirst().contains(where: referencesSensitivePath) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Command references a sensitive path or credential-like value.")
            }

            if tokens.dropFirst().contains(where: { token in
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) else {
                    return false
                }
                return !isInsideWorkspace(resolved, rootDirectory: rootDirectory)
            }) {
                needsWorkspaceWrite = true
                reasons.append("Command references a path outside the workspace.")
            }
        }

        if needsEscalation {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: needsConfirmation,
                reason: reasons.uniqued().joined(separator: " "),
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }

        if needsWorkspaceWrite {
            return AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: reasons.uniqued().joined(separator: " "),
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }

        return AgentSandboxDecision(
            mode: .readOnly,
            requiresUserApproval: false,
            requiresTypedConfirmation: false,
            reason: "Command is read-only and stays inside the workspace.",
            prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
        )
    }

    nonisolated static func sandboxedEnvironment(
        mode: AgentSandboxMode,
        rootDirectory: URL?,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for key in environment.keys where keyLooksSensitive(key) {
            environment.removeValue(forKey: key)
        }
        environment["WILLDEEP_AGENT_SANDBOX"] = mode.rawValue
        environment["WILLDEEP_WORKSPACE_ROOT"] = rootDirectory?.standardizedFileURL.path ?? ""

        if mode != .escalated {
            let sandboxHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-agent-sandbox-home", isDirectory: true)
            try? FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
            environment["HOME"] = sandboxHome.path
            environment["SSH_AUTH_SOCK"] = nil
            environment["GITHUB_TOKEN"] = nil
            environment["GH_TOKEN"] = nil
        }
        return environment
    }

    nonisolated static func shellLaunch(
        command: String,
        mode: AgentSandboxMode,
        rootDirectory: URL?
    ) -> AgentSandboxLaunch {
        guard mode != .escalated,
              FileManager.default.isExecutableFile(atPath: sandboxExecPath) else {
            return AgentSandboxLaunch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command]
            )
        }
        return AgentSandboxLaunch(
            executableURL: URL(fileURLWithPath: sandboxExecPath),
            arguments: ["-p", seatbeltProfile(mode: mode, rootDirectory: rootDirectory), "/bin/sh", "-c", command]
        )
    }

    nonisolated static func scrub(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{8,}"#,
            #"gh[pousr]_[A-Za-z0-9_]{20,}"#,
            #"sk-[A-Za-z0-9_-]{20,}"#,
            #"xox[baprs]-[A-Za-z0-9-]{20,}"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
            }
        }
        return result
    }

    nonisolated private static func seatbeltProfile(mode: AgentSandboxMode, rootDirectory: URL?) -> String {
        var writeAllows: [String] = [
            "(subpath \(profileString(FileManager.default.temporaryDirectory.standardizedFileURL.path)))"
        ]
        if mode == .workspaceWrite, let root = rootDirectory?.standardizedFileURL.path {
            writeAllows.append("(subpath \(profileString(root)))")
        }
        let writeRule = "(allow file-write* \(writeAllows.joined(separator: " ")))"
        return """
        (version 1)
        (deny default)
        (allow process*)
        (allow signal (target self))
        (allow sysctl-read)
        (allow file-read*)
        \(writeRule)
        (allow ipc*)
        (allow mach-lookup)
        (deny network*)
        """
    }

    nonisolated private static func profileString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private static func containsUnsafeShellExpansion(_ command: String) -> Bool {
        command.contains("$(") || command.contains("`") || command.contains("<(")
    }

    nonisolated private static func commandWithHeredocBodiesRemoved(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        var keptLines: [String] = []
        var pendingDelimiter: String?

        for line in command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let delimiter = pendingDelimiter {
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == delimiter {
                    pendingDelimiter = nil
                }
                continue
            }
            keptLines.append(line)
            if let delimiter = heredocDelimiter(in: line) {
                pendingDelimiter = delimiter
            }
        }

        return keptLines.joined(separator: "\n")
    }

    nonisolated private static func heredocDelimiter(in line: String) -> String? {
        guard let marker = line.range(of: "<<") else { return nil }
        var tail = String(line[marker.upperBound...])
        if tail.first == "-" {
            tail.removeFirst()
        }
        tail = tail.trimmingCharacters(in: .whitespaces)
        guard let first = tail.first else { return nil }
        if first == "'" || first == "\"" {
            let quote = first
            let body = tail.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            let delimiter = String(body[..<end])
            return delimiter.isEmpty ? nil : delimiter
        }
        let stopCharacters = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|&;<>"))
        let delimiter = tail.unicodeScalars.prefix { !stopCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(delimiter))
        return value.isEmpty ? nil : value
    }

    nonisolated private static func containsRedirection(_ command: String) -> Bool {
        guard command.contains(where: { redirectionCharacters.contains($0) }) else { return false }
        return !onlyContainsHarmlessRedirections(command)
    }

    nonisolated private static func onlyContainsHarmlessRedirections(_ command: String) -> Bool {
        var stripped = command
        for token in ["2>&1", "2>/dev/null", "1>/dev/null", ">/dev/null"] {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        return !stripped.contains(where: { redirectionCharacters.contains($0) })
    }

    nonisolated private static func forcefulGitMutation(_ tokens: [String]) -> Bool {
        guard tokens.first?.lowercased() == "git" else { return false }
        let lowered = tokens.map { $0.lowercased() }
        guard let subcommandIndex = gitSubcommandIndex(tokens: lowered) else {
            return false
        }
        let subcommand = lowered[subcommandIndex]
        let args = Array(lowered.dropFirst(subcommandIndex + 1))
        if subcommand == "push" {
            return args.contains("--force") || args.contains("--force-with-lease") || args.contains("-f")
        }
        if subcommand == "reset" {
            return args.contains("--hard")
        }
        if subcommand == "clean" {
            return args.contains("-f") || args.contains("-fd") || args.contains("-xdf")
        }
        return false
    }

    nonisolated private static func gitSubcommandIndex(tokens: [String]) -> Int? {
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "-c" || token == "--git-dir" || token == "--work-tree" {
                index += 2
                continue
            }
            if token.hasPrefix("--git-dir=") || token.hasPrefix("--work-tree=") || token.hasPrefix("-c=") {
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

    nonisolated private static func splitCommandSegments(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var activeQuote: Character?
        var escaped = false
        var index = command.startIndex

        while index < command.endIndex {
            let ch = command[index]
            if escaped {
                current.append(ch)
                escaped = false
                index = command.index(after: index)
                continue
            }
            if ch == "\\" {
                escaped = true
                current.append(ch)
                index = command.index(after: index)
                continue
            }
            if let quote = activeQuote {
                if ch == quote { activeQuote = nil }
                current.append(ch)
                index = command.index(after: index)
                continue
            }
            if ch == "\"" || ch == "'" {
                activeQuote = ch
                current.append(ch)
                index = command.index(after: index)
                continue
            }
            if ch == "&", current.last == ">" {
                current.append(ch)
                index = command.index(after: index)
                continue
            }
            if shellControlOperators.contains(ch) {
                if ch == "&" {
                    let next = command.index(after: index)
                    guard next < command.endIndex, command[next] == "&" else { return nil }
                    index = command.index(after: next)
                } else if ch == "|" {
                    let next = command.index(after: index)
                    if next < command.endIndex, command[next] == "|" {
                        index = command.index(after: next)
                    } else {
                        index = command.index(after: index)
                    }
                } else {
                    index = command.index(after: index)
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { segments.append(trimmed) }
                current = ""
                continue
            }
            current.append(ch)
            index = command.index(after: index)
        }

        if activeQuote != nil || escaped { return nil }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }

    nonisolated private static func resolvePath(_ raw: String, workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard looksLikePath(cleaned) else { return nil }
        if cleaned.hasPrefix("/") {
            return URL(fileURLWithPath: cleaned).standardizedFileURL
        }
        let base = workingDirectory ?? rootDirectory?.standardizedFileURL
        return base?.appendingPathComponent(cleaned).standardizedFileURL
    }

    nonisolated private static func isInsideWorkspace(_ url: URL, rootDirectory: URL?) -> Bool {
        guard let root = rootDirectory?.standardizedFileURL.path else { return false }
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    nonisolated private static func looksLikePath(_ token: String) -> Bool {
        token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token == ".."
    }

    nonisolated private static func isSafeRelativeDirectoryHop(_ raw: String) -> Bool {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !cleaned.isEmpty,
              !cleaned.hasPrefix("/"),
              !cleaned.hasPrefix("~"),
              !cleaned.contains("*"),
              !cleaned.contains("?") else {
            return false
        }
        return cleaned
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != ".." }
    }

    nonisolated private static func resolveRelativeDirectoryHop(_ raw: String, workingDirectory: URL?) -> URL {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let base = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(cleaned, isDirectory: true).standardizedFileURL
    }

    nonisolated private static func referencesSensitivePath(_ token: String) -> Bool {
        let lower = token.lowercased()
        return sensitivePathFragments.contains { lower.contains($0) }
    }

    nonisolated private static func keyLooksSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("token") || lower.contains("secret") || lower.contains("password")
            || lower.contains("api_key") || lower.contains("apikey") || lower.contains("credential")
    }
}

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
            try? handle.seekToEnd()
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

private extension Array where Element: Hashable {
    nonisolated func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Tool-level always-allow signature. Decides per tool name how to
/// scope the "remember this" rule:
///  - `run_command` → command-family signature ("git push") via
///    AgentCommandAuthorization.
///  - `call_mcp_tool` → "mcp:<server>:<tool>", so the same server.tool
///    pair auto-approves regardless of `arguments_json`. Arguments are
///    intentionally not part of the signature — the user pinning a
///    specific MCP tool means "I trust this tool, run it again", not
///    "exactly this query string".
///  - everything else → nil (the Always Allow button hides; the user
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
            // Scope always-allow by permission mode: pinning "plan"
            // (read-only) must not silently authorize "acceptEdits".
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
            // Scope by host: pinning means "I trust this domain", not
            // "exactly this URL". Path/query stay out of the signature.
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
    /// NOT marked untrusted — a hostile server could name a destructive
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
    /// uses — see AgentInjectionDefense).
    static func mcpJudgePseudoCommand(server: String, tool: String, argumentsJSON: String) -> String {
        "mcp-tool-call server=\(server) tool=\(tool) arguments=\(argumentsJSON)"
    }
}
