//
//  AgentToolAuthorization.swift
//  WillDeep
//
//  Sandbox policy and the persisted "Always Allow" record. Signature
//  derivation, MCP read-only heuristics, and sandbox audit logging live
//  in AgentToolAuthorizationSupport.swift so this file can focus on the
//  execution-boundary decision tree.
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
    case workspaceWriteNetwork
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

    /// Heads whose SafeCommand `.alwaysSafe` verdict still WRITES inside the
    /// workspace — build artifacts, package-script output, dir/file creation —
    /// so a SafeCommand-certified call must run under a workspace-write
    /// seatbelt, not the read-only one (which would block the very write the
    /// command exists to make). Deliberately EXCLUDES `git`: SafeCommand only
    /// certifies read-only git subcommands (diff/log/status/show/…) as
    /// alwaysSafe, and those genuinely don't write, so they must stay
    /// `.readOnly`. Pre-1.78.0-rc15 the bump keyed off the whole
    /// `workspaceWriteHeads` set, which wrongly promoted `git diff` to
    /// workspace-write. Keep mkdir/touch/mktemp in sync with
    /// SafeCommand.safeWorkspaceCreateTokens.
    nonisolated private static let lowRiskWriteHeads: Set<String> = [
        "apply_patch", "make", "xcodebuild", "swift", "go", "cargo",
        "npm", "pnpm", "yarn", "ruby", "node", "python", "python3", "rake",
        "mkdir", "touch", "mktemp"
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
        case "call_mcp_tool", "claude_code", "codex_cli", "cursor_agent", "cline_cli", "kill_job",
             "add_memory", "create_user_skill", "suggest_mcp_server":
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

        let policyCommand = commandByReplacingSafeShellExpansions(
            commandWithHeredocBodiesRemoved(trimmed)
        )
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
        var needsWorkspaceNetwork = false
        var needsEscalation = false
        var needsConfirmation = false
        var reasons: [String] = []
        var workingDirectory = rootDirectory?.standardizedFileURL

        for segment in segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment),
                  let invocation = shellInvocation(from: rawTokens) else {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Unable to parse command segment safely.")
                continue
            }
            let tokens = invocation.commandTokens
            let head = invocation.head
            let assignmentValues = invocation.environmentAssignments.map(environmentAssignmentValue)

            if invocation.environmentAssignments.contains(where: environmentAssignmentKeyLooksSensitive) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Environment assignment uses a credential-like variable name.")
            }

            if assignmentValues.contains(where: referencesSensitivePath) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Environment assignment references a sensitive path or credential-like value.")
            }

            if assignmentValues.contains(where: { token in
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) else {
                    return false
                }
                return !isInsideWorkspace(resolved, rootDirectory: rootDirectory)
            }) {
                needsWorkspaceWrite = true
                reasons.append("Environment assignment references a path outside the workspace.")
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
            } else if networkHeads.contains(head) {
                switch classifyNetworkReadOnly(head: head, tokens: tokens) {
                case .alwaysSafe:
                    break
                case .alwaysDangerous:
                    needsEscalation = true
                    needsConfirmation = true
                    reasons.append("Command `\(head)` runs a dangerous remote or network operation.")
                case .needsJudgment:
                    needsEscalation = true
                    reasons.append("Command `\(head)` may use network, credentials, or macOS keychain access.")
                }
            } else if credentialHeads.contains(head) {
                needsEscalation = true
                reasons.append("Command `\(head)` may use network, credentials, or macOS keychain access.")
            } else {
                if AgentPackageCommandPolicy.isDependencyInstallCommand(tokens: tokens) {
                    needsWorkspaceWrite = true
                    needsWorkspaceNetwork = true
                    reasons.append("Package dependency installation may write inside the workspace and needs registry network access.")
                    continue
                }
                switch SafeCommand.classify(command: segment) {
                case .alwaysSafe:
                    // A SafeCommand-certified call is auto-approvable, but some
                    // of those still write (go build, npm run build, mkdir).
                    // Bump only those to workspace-write; read-only certs like
                    // `git diff` stay read-only. See `lowRiskWriteHeads`.
                    if lowRiskWriteHeads.contains(head) {
                        needsWorkspaceWrite = true
                        reasons.append("Command `\(head)` is a low-risk workspace build or development operation.")
                    }
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
                mode: needsWorkspaceNetwork ? .workspaceWriteNetwork : .workspaceWrite,
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

    nonisolated static func canAutoApproveWorkspaceWriteCommand(command: String, rootDirectory: URL?) -> Bool {
        guard let rootDirectory else { return false }

        let decision = commandDecision(command: command, rootDirectory: rootDirectory)
        guard (decision.mode == .workspaceWrite || decision.mode == .workspaceWriteNetwork),
              decision.requiresUserApproval,
              !decision.requiresTypedConfirmation else {
            return false
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let policyCommand = commandByReplacingSafeShellExpansions(
            commandWithHeredocBodiesRemoved(trimmed)
        )
        guard !containsUnsafeShellExpansion(policyCommand),
              let segments = splitCommandSegments(policyCommand),
              !segments.isEmpty else {
            return false
        }

        let root = rootDirectory.standardizedFileURL
        var workingDirectory: URL? = root

        for segment in segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment),
                  let invocation = shellInvocation(from: rawTokens) else {
                return false
            }
            let tokens = invocation.commandTokens
            let head = invocation.head
            let assignmentValues = invocation.environmentAssignments.map(environmentAssignmentValue)

            if invocation.environmentAssignments.contains(where: environmentAssignmentKeyLooksSensitive) {
                return false
            }

            if forcefulGitMutation(tokens) ||
                destructiveHeads.contains(head) ||
                credentialHeads.contains(head) {
                return false
            }

            if networkHeads.contains(head) {
                switch classifyNetworkReadOnly(head: head, tokens: tokens) {
                case .alwaysSafe:
                    break
                case .alwaysDangerous, .needsJudgment:
                    return false
                }
            }

            if head == "cd" {
                if let next = tokens.dropFirst().first {
                    guard let resolved = resolvePath(next, workingDirectory: workingDirectory, rootDirectory: root),
                          isInsideWorkspace(resolved, rootDirectory: root) else {
                        return false
                    }
                    workingDirectory = resolved
                } else {
                    workingDirectory = root
                }
                continue
            }

            if AgentPackageCommandPolicy.isDependencyInstallCommand(tokens: tokens) {
                continue
            }
            if AgentPackageCommandPolicy.isPackageManager(head) {
                guard SafeCommand.classify(command: segment) == .alwaysSafe else {
                    return false
                }
                continue
            }

            for token in Array(tokens.dropFirst()) + assignmentValues {
                if referencesSensitivePath(token) {
                    return false
                }
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: root) else {
                    continue
                }
                if !isInsideWorkspace(resolved, rootDirectory: root) {
                    return false
                }
            }
        }

        return true
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
        if (mode == .workspaceWrite || mode == .workspaceWriteNetwork),
           let root = rootDirectory?.standardizedFileURL.path {
            writeAllows.append("(subpath \(profileString(root)))")
        }
        let writeRule = "(allow file-write* \(writeAllows.joined(separator: " ")))"
        let networkRule = mode == .workspaceWriteNetwork ? "(allow network*)" : "(deny network*)"
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
        \(networkRule)
        """
    }

    nonisolated private static func profileString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private struct ShellInvocation {
        let environmentAssignments: [String]
        let commandTokens: [String]
        let head: String
    }

    nonisolated private static func shellInvocation(from tokens: [String]) -> ShellInvocation? {
        var index = 0
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        guard index < tokens.count else { return nil }
        return ShellInvocation(
            environmentAssignments: Array(tokens.prefix(index)),
            commandTokens: Array(tokens.suffix(from: index)),
            head: tokens[index].lowercased()
        )
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

    nonisolated private static func environmentAssignmentValue(_ assignment: String) -> String {
        guard let equalsIndex = assignment.firstIndex(of: "=") else { return "" }
        return String(assignment[assignment.index(after: equalsIndex)...])
    }

    nonisolated private static func environmentAssignmentKeyLooksSensitive(_ assignment: String) -> Bool {
        guard let equalsIndex = assignment.firstIndex(of: "=") else { return false }
        return keyLooksSensitive(String(assignment[..<equalsIndex]))
    }

    nonisolated private static func commandByReplacingSafeShellExpansions(_ command: String) -> String {
        command.replacingOccurrences(of: "$(pwd)", with: ".")
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

    nonisolated private static func classifyNetworkReadOnly(head: String, tokens: [String]) -> CommandSafety {
        switch head {
        case "curl":
            return isReadOnlyCurl(tokens) ? .alwaysSafe : .needsJudgment
        case "ssh":
            return classifySSHRemoteCommand(tokens)
        default:
            return .needsJudgment
        }
    }

    nonisolated private static func isReadOnlyCurl(_ tokens: [String]) -> Bool {
        guard tokens.first?.lowercased() == "curl" else { return false }
        var requestMethod = "GET"
        var sawPublicURL = false
        var index = 1
        let safeNoArgumentLongFlags: Set<String> = [
            "--fail", "--fail-with-body", "--silent", "--show-error", "--verbose",
            "--location", "--location-trusted", "--head", "--include",
            "--compressed", "--http1.1", "--http2", "--http3", "--ipv4", "--ipv6",
            "--insecure", "--no-progress-meter"
        ]
        let safeArgumentLongFlags: Set<String> = [
            "--connect-timeout", "--max-time", "--retry", "--retry-delay",
            "--retry-max-time", "--user-agent", "--referer", "--url",
            "--cacert", "--capath", "--resolve", "--connect-to"
        ]
        let unsafeLongFlagPrefixes = [
            "--data", "--form", "--upload-file", "--output", "--remote-name",
            "--dump-header", "--cookie-jar", "--config", "--netrc", "--user",
            "--proxy-user", "--oauth2-bearer", "--aws-sigv4", "--request-target"
        ]

        while index < tokens.count {
            let token = tokens[index]
            let lower = token.lowercased()
            if lower == "--" {
                index += 1
                continue
            }
            if lower == "-x" || lower == "--request" {
                guard index + 1 < tokens.count else { return false }
                requestMethod = tokens[index + 1].uppercased()
                index += 2
                continue
            }
            if lower.hasPrefix("-x") && lower.count > 2 {
                requestMethod = String(token.dropFirst(2)).uppercased()
                index += 1
                continue
            }
            if lower.hasPrefix("--request=") {
                requestMethod = String(token.dropFirst("--request=".count)).uppercased()
                index += 1
                continue
            }
            if unsafeLongFlagPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0 + "=") }) {
                return false
            }
            if safeNoArgumentLongFlags.contains(lower) {
                if lower == "--head" { requestMethod = "HEAD" }
                index += 1
                continue
            }
            if safeArgumentLongFlags.contains(lower) {
                guard index + 1 < tokens.count else { return false }
                if lower == "--url" {
                    sawPublicURL = sawPublicURL || AgentWebTools.validatedPublicURL(tokens[index + 1]) != nil
                }
                index += 2
                continue
            }
            if let flagName = lower.split(separator: "=", maxSplits: 1).first,
               safeArgumentLongFlags.contains(String(flagName)) {
                if flagName == "--url" {
                    let rawURL = String(lower.dropFirst("--url=".count))
                    sawPublicURL = sawPublicURL || AgentWebTools.validatedPublicURL(rawURL) != nil
                }
                index += 1
                continue
            }
            if lower.hasPrefix("-") {
                if lower.contains("o") || lower.contains("O") ||
                    lower.contains("d") || lower.contains("F") ||
                    lower.contains("T") || lower.contains("u") {
                    return false
                }
                let safeShortFlags = Set("slivkf")
                guard lower.dropFirst().allSatisfy({ safeShortFlags.contains($0) }) else {
                    return false
                }
                if lower.contains("I") { requestMethod = "HEAD" }
                index += 1
                continue
            }
            sawPublicURL = sawPublicURL || AgentWebTools.validatedPublicURL(token) != nil
            index += 1
        }

        return sawPublicURL && (requestMethod == "GET" || requestMethod == "HEAD")
    }

    nonisolated private static func classifySSHRemoteCommand(_ tokens: [String]) -> CommandSafety {
        guard tokens.first?.lowercased() == "ssh" else { return .needsJudgment }
        guard let hostIndex = sshHostIndex(tokens) else { return .needsJudgment }
        let remoteCommandTokens = tokens.dropFirst(hostIndex + 1)
        guard !remoteCommandTokens.isEmpty else { return .needsJudgment }
        return SafeCommand.classify(command: remoteCommandTokens.joined(separator: " "))
    }

    nonisolated private static func sshHostIndex(_ tokens: [String]) -> Int? {
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

private extension Array where Element: Hashable {
    nonisolated func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
