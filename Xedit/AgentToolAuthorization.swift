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

/// Risk and intent checks for the one host-native file tool that may cross
/// the workspace boundary. External access is granted to one exact file for
/// one call; it never turns into a directory-wide or persistent allow rule.
nonisolated enum AgentExternalFileWritePolicy {
    private static let autoApprovedContentLimit = 1 * 1024 * 1024
    private static let explicitIntentContentLimit = 4 * 1024 * 1024

    private static let lowRiskTextExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html",
        "java", "js", "json", "jsx", "kt", "kts", "md", "markdown",
        "mjs", "rb", "rs", "scss", "sql", "swift", "toml", "ts",
        "tsx", "txt", "xml", "yaml", "yml"
    ]

    private static let writeIntentMarkers = [
        "写", "保存", "生成", "创建", "修改", "更新", "覆盖", "替换",
        "write", "save", "create", "generate", "edit", "update",
        "overwrite", "replace"
    ]

    private static let overwriteIntentMarkers = [
        "修改", "更新", "覆盖", "替换", "重写",
        "edit", "update", "overwrite", "replace", "rewrite"
    ]

    private static let deniedWriteIntentMarkers = [
        "不要写", "别写", "禁止写", "不要保存", "不要创建", "不要修改",
        "不要更新", "不要覆盖", "不要替换", "不可写", "只读",
        "do not write", "don't write", "dont write", "never write",
        "do not save", "don't save", "do not create", "do not edit",
        "do not update", "do not overwrite", "read only", "read-only"
    ]

    struct Target: Equatable {
        let url: URL
        let existedBeforeWrite: Bool
        let overwriteRequested: Bool
        let isSensitive: Bool
        let isLowRiskText: Bool
        let parentExists: Bool
    }

    static func target(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?
    ) -> Target? {
        guard let rawPath = arguments["path"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty,
            let resolved = resolveAbsolutePath(rawPath) else {
            return nil
        }

        let root = rootDirectory?.standardizedFileURL
        guard root.map({ !isInside(resolved, root: $0) }) ?? true else {
            return nil
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
        guard !existed || !isDirectory.boolValue else { return nil }

        let canonicalURL: URL
        if existed {
            canonicalURL = resolved.resolvingSymlinksInPath().standardizedFileURL
        } else {
            canonicalURL = resolved.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .appendingPathComponent(resolved.lastPathComponent)
                .standardizedFileURL
        }
        guard root.map({ !isInside(canonicalURL, root: $0) }) ?? true else {
            return nil
        }

        let parent = canonicalURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = fileManager.fileExists(
            atPath: parent.path,
            isDirectory: &parentIsDirectory
        ) && parentIsDirectory.boolValue
        let path = canonicalURL.path.lowercased()
        let fileName = canonicalURL.lastPathComponent.lowercased()
        let pathExtension = canonicalURL.pathExtension.lowercased()

        return Target(
            url: canonicalURL,
            existedBeforeWrite: existed,
            overwriteRequested: arguments["overwrite"]?.boolValue() ?? false,
            isSensitive: isSensitivePath(path, fileName: fileName),
            isLowRiskText: lowRiskTextExtensions.contains(pathExtension),
            parentExists: parentExists
        )
    }

    static func canAutoApproveNewDocument(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?
    ) -> Bool {
        guard let target = target(arguments: arguments, rootDirectory: rootDirectory),
              !target.existedBeforeWrite,
              !target.isSensitive,
              target.isLowRiskText,
              target.parentExists,
              let content = arguments["content"]?.stringValue(),
              content.utf8.count <= autoApprovedContentLimit else {
            return false
        }
        return true
    }

    static func currentUserExplicitlyAuthorizes(
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?,
        latestUserMessage: String
    ) -> Bool {
        guard let target = target(arguments: arguments, rootDirectory: rootDirectory),
              !target.isSensitive,
              target.parentExists,
              let content = arguments["content"]?.stringValue(),
              content.utf8.count <= explicitIntentContentLimit else {
            return false
        }
        if target.existedBeforeWrite && !target.overwriteRequested {
            return false
        }

        let normalizedMessage = latestUserMessage
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard !deniedWriteIntentMarkers.contains(where: normalizedMessage.contains) else {
            return false
        }
        guard writeIntentMarkers.contains(where: normalizedMessage.contains) else {
            return false
        }
        if target.existedBeforeWrite,
           !overwriteIntentMarkers.contains(where: normalizedMessage.contains) {
            return false
        }

        let absolutePath = target.url.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        var acceptedSpellings = [absolutePath]
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        if absolutePath == home {
            acceptedSpellings.append("~")
        } else if absolutePath.hasPrefix(home + "/") {
            acceptedSpellings.append("~" + String(absolutePath.dropFirst(home.count)))
        }
        return acceptedSpellings.contains(where: normalizedMessage.contains)
    }

    static func resolveAbsolutePath(_ rawPath: String) -> URL? {
        let expanded: String
        if rawPath == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if rawPath.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(rawPath.dropFirst(2)))
                .path
        } else {
            expanded = rawPath
        }
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSensitivePath(_ path: String, fileName: String) -> Bool {
        let protectedPrefixes = [
            "/system/", "/library/", "/applications/", "/usr/", "/bin/",
            "/sbin/", "/etc/", "/private/etc/", "/private/var/db/"
        ]
        if protectedPrefixes.contains(where: path.hasPrefix) { return true }

        let protectedFragments = [
            "/.ssh/", "/.gnupg/", "/.aws/", "/.config/gh/",
            "/library/keychains/", "/library/launchagents/",
            "/library/launchdaemons/", "/.git/hooks/"
        ]
        if protectedFragments.contains(where: path.contains) { return true }

        let protectedNames: Set<String> = [
            ".bash_profile", ".bashrc", ".env", ".profile", ".zprofile",
            ".zshenv", ".zshrc", "authorized_keys", "hosts", "sudoers"
        ]
        return protectedNames.contains(fileName)
    }
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
        ".env", "id_rsa", "id_ed25519"
    ]

    /// Credential nouns are intentionally boundary-matched. Product and
    /// namespace names such as `tokenhub` are ordinary identifiers; treating
    /// every substring containing "token" as a secret upgrades harmless
    /// commands to danger-tier confirmation.
    nonisolated private static let sensitiveCredentialMarkers: [String] = [
        "token", "tokens", "secret", "secrets", "credential", "credentials"
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
        case "write_file":
            guard let target = AgentExternalFileWritePolicy.target(
                arguments: arguments,
                rootDirectory: rootDirectory
            ) else {
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: false,
                    reason: "External file target must be an absolute or home-relative path outside the workspace, with an existing parent directory.",
                    prefixRule: nil
                )
            }
            if target.isSensitive {
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: true,
                    reason: "Writing this sensitive, system, credential, shell-profile, or persistence path requires typed confirmation.",
                    prefixRule: nil
                )
            }
            let reason = target.existedBeforeWrite
                ? "Replacing an existing file outside the workspace requires an exact user instruction or explicit approval."
                : "Creating a bounded text file outside the workspace is reviewed by target risk instead of workspace membership alone."
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: reason,
                prefixRule: nil
            )
        case "web_fetch":
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "Network access to an arbitrary URL requires approval.",
                prefixRule: nil
            )
        case "lark_cli":
            let arguments = arguments["arguments"]?.stringArrayValue() ?? []
            switch AgentLarkCLI.risk(arguments: arguments) {
            case .read:
                return AgentSandboxDecision(
                    mode: .readOnly,
                    requiresUserApproval: false,
                    requiresTypedConfirmation: false,
                    reason: "lark-cli local status, schema, help, or dry-run operation.",
                    prefixRule: nil
                )
            case .danger:
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: true,
                    reason: "lark-cli operation may delete data, change permissions, or expose credentials.",
                    prefixRule: ["lark-cli"]
                )
            case .write, .userInput:
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: false,
                    reason: "lark-cli write operation acts on Feishu/Lark data outside the workspace.",
                    prefixRule: ["lark-cli"]
                )
            }
        case "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli":
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "External agent CLIs need their own authenticated home/config and enforce their own permission mode.",
                prefixRule: nil
            )
        case "delete_user_skill":
            return AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Deleting a user skill is destructive.",
                prefixRule: nil
            )
        case "terminal_send_command":
            guard let command = arguments["command"]?.stringValue() else {
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: true,
                    reason: "Missing terminal command argument.",
                    prefixRule: nil
                )
            }
            // The visible terminal is not a sandbox boundary. Reuse the full
            // command preflight so sensitive paths, credentials, destructive
            // operations and external targets cannot be hidden behind an
            // otherwise read-only executable such as `cat`.
            return commandDecision(command: command, rootDirectory: rootDirectory)
        case "rename_session":
            return AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: false,
                requiresTypedConfirmation: false,
                reason: "Renaming the current session is a bounded, reversible local metadata change.",
                prefixRule: nil
            )
        case "change_workspace", "call_mcp_tool", "kill_job", "activate_expert", "add_memory", "create_user_skill", "create_user_skills", "update_user_skill", "suggest_mcp_server", "configure_mcp_server",
             "terminal_send_control", "terminal_create_shortcut", "terminal_edit_shortcut":
            return AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "This tool can modify application state or run external code.",
                prefixRule: nil
            )
        case "computer_use_request_permissions", "computer_use_launch_app", "computer_use_activate_app", "computer_use_click", "computer_use_secondary_action", "computer_use_scroll", "computer_use_drag", "computer_use_type_text", "computer_use_press_key", "computer_use_set_value", "computer_use_focus", "computer_use_hover", "computer_use_select_text", "computer_use_restart_helper":
            let explicitConfirmation = AgentComputerUsePolicy.requiresExplicitConfirmation(
                toolName: toolName,
                arguments: arguments
            )
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: explicitConfirmation,
                reason: explicitConfirmation
                    ? "Computer Use requires fresh per-action confirmation for malformed or ambiguous actions, non-navigation keys, sensitive/control-character input, and private-takeover boundaries; an operational lease cannot bypass it."
                    : "This Computer Use action may run automatically only inside the current runtime-, turn-, and target-bound controlling lease; the first control action and Strict mode still require user approval.",
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
        if commandRequiresSensitiveDesktopConfirmation(trimmed) {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Screen capture, clipboard access, or GUI scripting can observe private pixels or mutate external desktop state and requires typed confirmation.",
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
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

        guard let chain = AgentShellCommandParser.parse(policyCommand),
              !chain.segments.isEmpty else {
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

        if chain.requiresBackgroundJudgment {
            needsWorkspaceWrite = true
            reasons.append("Background shell execution requires approval.")
        }

        for (segmentIndex, segment) in chain.segments.enumerated() {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text),
                  let invocation = shellInvocation(from: rawTokens) else {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Unable to parse command segment \(segmentIndex + 1) safely.")
                continue
            }
            let tokens = invocation.commandTokens
            let head = invocation.head
            let assignmentValues = invocation.environmentAssignments.map(environmentAssignmentValue)
            let localPathTokens = localPathCheckTokens(for: tokens, head: head)

            // Non-escalated commands intentionally receive an isolated HOME.
            // Running a command that spells `~/...` or `$HOME/...` there would
            // silently target the sandbox home instead of the user's real
            // home. Escalate before launch so the exact user-requested path is
            // preserved rather than relying on a failing seatbelt retry.
            if assignmentValues.contains(where: referencesSandboxRemappedHome)
                || localPathTokens.contains(where: referencesSandboxRemappedHome) {
                needsEscalation = true
                reasons.append("Home-relative paths require access to the user's real home outside the workspace sandbox.")
            }

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
                needsEscalation = true
                reasons.append("Environment assignment references a path outside the workspace and must preserve the real target before launch.")
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
                        if !segment.runsInPipeline {
                            workingDirectory = resolved
                        }
                    } else if rootDirectory == nil, isSafeRelativeDirectoryHop(next) {
                        if !segment.runsInPipeline {
                            workingDirectory = resolveRelativeDirectoryHop(next, workingDirectory: workingDirectory)
                        }
                    } else {
                        needsEscalation = true
                        reasons.append("Changing directory outside the workspace requires direct preflight escalation.")
                    }
                } else {
                    if !segment.runsInPipeline {
                        workingDirectory = rootDirectory?.standardizedFileURL ?? workingDirectory
                    }
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
                switch SafeCommand.classify(command: segment.text) {
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

            if localPathTokens.contains(where: { token in
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) else {
                    return false
                }
                return !isInsideWorkspace(resolved, rootDirectory: rootDirectory)
            }) {
                needsEscalation = true
                reasons.append("Command references a path outside the workspace and must be reviewed before running without the workspace sandbox.")
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
              let chain = AgentShellCommandParser.parse(policyCommand),
              !chain.segments.isEmpty else {
            return false
        }

        let root = rootDirectory.standardizedFileURL
        var workingDirectory: URL? = root

        for segment in chain.segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text),
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
                    if !segment.runsInPipeline {
                        workingDirectory = resolved
                    }
                } else {
                    if !segment.runsInPipeline {
                        workingDirectory = root
                    }
                }
                continue
            }

            if AgentPackageCommandPolicy.isDependencyInstallCommand(tokens: tokens) {
                continue
            }
            if AgentPackageCommandPolicy.isPackageManager(head) {
                guard SafeCommand.classify(command: segment.text) == .alwaysSafe else {
                    return false
                }
                continue
            }

            for token in Array(localPathCheckTokens(for: tokens, head: head)) + assignmentValues {
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

    /// Returns whether a shell command reaches beyond the local workspace via
    /// network or credential-bearing tools. Workspace Access deliberately
    /// keeps these calls behind confirmation even when the underlying command
    /// is read-only (for example, a plain `curl` GET).
    nonisolated static func commandUsesExternalAccess(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if commandRequiresSensitiveDesktopConfirmation(trimmed) {
            return true
        }

        let policyCommand = commandByReplacingSafeShellExpansions(
            commandWithHeredocBodiesRemoved(trimmed)
        )
        guard !containsUnsafeShellExpansion(policyCommand),
              let chain = AgentShellCommandParser.parse(policyCommand),
              !chain.segments.isEmpty else {
            return true
        }

        for segment in chain.segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text),
                  let invocation = shellInvocation(from: rawTokens) else {
                return true
            }
            let tokens = invocation.commandTokens
            if networkHeads.contains(invocation.head)
                || credentialHeads.contains(invocation.head)
                || AgentPackageCommandPolicy.isDependencyInstallCommand(tokens: tokens) {
                return true
            }
        }
        return false
    }

    /// Commands that can bypass Computer Use's private-takeover boundary by
    /// reading screen pixels, reading/writing the system clipboard, or
    /// driving macOS UI scripting. Detection covers direct executables and
    /// inline-language wrappers (`ruby -e`, `swift -e`, `sh -c`, etc.).
    nonisolated static func commandRequiresSensitiveDesktopConfirmation(
        _ command: String
    ) -> Bool {
        let lowered = command.lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let directPatterns = [
            #"(?<![a-z0-9_])screencapture(?![a-z0-9_])"#,
            #"(?<![a-z0-9_])pbpaste(?![a-z0-9_])"#,
            #"(?<![a-z0-9_])pbcopy(?![a-z0-9_])"#,
            #"cgwindowlistcreateimage"#,
        ]
        if directPatterns.contains(where: {
            lowered.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }

        let usesAppleScript = lowered.range(
            of: #"(?<![a-z0-9_])osascript(?![a-z0-9_])|nsapplescript"#,
            options: .regularExpression
        ) != nil
        guard usesAppleScript else { return false }

        let guiOrClipboardTerms = [
            "clipboard", "system events", "keystroke", "key code",
            "ui element", "menu item", "frontmost", "click ",
            "click\"", "click'",
        ]
        return guiOrClipboardTerms.contains(where: lowered.contains)
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
            let sandboxTemporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-agent-sandbox-tmp", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: sandboxTemporaryDirectory,
                withIntermediateDirectories: true
            )
            let sandboxHome = sandboxTemporaryDirectory
                .appendingPathComponent("willdeep-agent-sandbox-home", isDirectory: true)
            try? FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
            environment["HOME"] = sandboxHome.path
            // Node/Playwright inherit the GUI process' TMPDIR by default. On
            // macOS that path can be a parent of Foundation's actual
            // temporaryDirectory, while the seatbelt profile only allows the
            // latter. Keep every common temp variable on one host-created,
            // explicitly allowed directory so transform caches and browser
            // profiles do not fail with a misleading EPERM.
            environment["TMPDIR"] = sandboxTemporaryDirectory.path
            environment["TMP"] = sandboxTemporaryDirectory.path
            environment["TEMP"] = sandboxTemporaryDirectory.path
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
        // Pure read-only allowlist commands (git log/status/diff, rg, …) gain
        // nothing from seatbelt — reads were already unrestricted, and the
        // profile still trips over /dev/null, xcrun caches, and similar
        // utility paths. Skip sandbox-exec for those; keep scrubbed env.
        // Network/credential heads stay under seatbelt even in .readOnly.
        if shouldRunWithoutSeatbelt(command: command, mode: mode)
            || !FileManager.default.isExecutableFile(atPath: sandboxExecPath) {
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

    /// Launch a known executable with a typed argv vector. External coding
    /// agents use this path so prompts and paths are never reparsed by a shell.
    /// The process still inherits the same seatbelt profile as run_command.
    nonisolated static func processLaunch(
        executableURL: URL,
        arguments: [String],
        mode: AgentSandboxMode,
        rootDirectory: URL?
    ) -> AgentSandboxLaunch {
        if mode == .escalated
            || !FileManager.default.isExecutableFile(atPath: sandboxExecPath) {
            return AgentSandboxLaunch(
                executableURL: executableURL,
                arguments: arguments
            )
        }
        return AgentSandboxLaunch(
            executableURL: URL(fileURLWithPath: sandboxExecPath),
            arguments: [
                "-p",
                seatbeltProfile(mode: mode, rootDirectory: rootDirectory),
                executableURL.path,
            ] + arguments
        )
    }

    /// Whether `shellLaunch` should skip `sandbox-exec` for this command.
    nonisolated static func shouldRunWithoutSeatbelt(
        command: String,
        mode: AgentSandboxMode
    ) -> Bool {
        switch mode {
        case .escalated:
            return true
        case .workspaceWrite, .workspaceWriteNetwork:
            return false
        case .readOnly:
            break
        }

        guard SafeCommand.classify(command: command) == .alwaysSafe else { return false }
        guard let chain = AgentShellCommandParser.parse(command),
              !chain.segments.isEmpty,
              !chain.requiresBackgroundJudgment else {
            return false
        }

        for segment in chain.segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text),
                  let invocation = shellInvocation(from: rawTokens) else {
                return false
            }
            let head = invocation.head
            // curl/ssh/… may be classified alwaysSafe for "read-shaped"
            // network ops, but they still need the seatbelt network deny
            // (or a prior escalation) — never skip the profile for them.
            if networkHeads.contains(head) || credentialHeads.contains(head) {
                return false
            }
        }
        return true
    }

    /// Heuristic for "seatbelt / sandbox-exec blocked this command".
    /// Used to offer a one-shot escalation approval instead of treating the
    /// denial as a normal tool failure the model has to guess around.
    nonisolated static func looksLikeSandboxDenial(
        error: Error,
        sandboxMode: AgentSandboxMode
    ) -> Bool {
        guard sandboxMode != .escalated else { return false }
        if let toolError = error as? AgentToolError {
            switch toolError {
            case .commandFailed(let code, let output):
                return looksLikeSandboxDenial(exitStatus: code, output: output, sandboxMode: sandboxMode)
            case .commandTimeout, .missingArgument, .invalidArgument, .noWorkspace,
                    .pathOutsideWorkspace, .notFound, .notRegular, .binaryFile,
                    .fileTooLarge, .unknownTool, .invalidRegex, .httpFailed:
                return false
            }
        }
        return looksLikeSandboxDenial(
            exitStatus: -1,
            output: error.localizedDescription,
            sandboxMode: sandboxMode
        )
    }

    nonisolated static func looksLikeSandboxDenial(
        exitStatus: Int32,
        output: String,
        sandboxMode: AgentSandboxMode
    ) -> Bool {
        guard sandboxMode != .escalated else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let strongMarkers = [
            "sandbox-exec:",
            "deny file-write",
            "deny network",
            "operation not permitted",
        ]
        if strongMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }

        // "permission denied" shows up in many real app failures. Only treat
        // it as a sandbox signal when the failure looks primary / short, or
        // the phrase sits near the end of stderr (typical seatbelt shape).
        guard lowered.contains("permission denied") else { return false }
        if trimmed.count <= 800 { return true }
        let tail = String(lowered.suffix(400))
        return tail.contains("permission denied")
            || exitStatus == 1
            || exitStatus == -1
    }

    /// Model-facing note appended to a failed `run_command` result when the
    /// command actually executed under seatbelt. Without it the model only
    /// sees a bare "operation not permitted" and — nudged by the "keep
    /// trying" guidance in the system prompt — tends to retry the identical
    /// command, which the sandbox denies again. Returns nil when the command
    /// did not run sandboxed (alwaysSafe skip, escalated, no sandbox-exec).
    nonisolated static func sandboxedFailureNote(
        toolName: String,
        command: String?,
        effectiveMode: AgentSandboxMode
    ) -> String? {
        guard toolName == "run_command",
              let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.isExecutableFile(atPath: sandboxExecPath),
              !shouldRunWithoutSeatbelt(command: command, mode: effectiveMode) else {
            return nil
        }
        let restrictions: String
        switch effectiveMode {
        case .escalated:
            return nil
        case .readOnly:
            restrictions = "reads allowed everywhere; writes denied except the temp dir; network denied"
        case .workspaceWrite:
            restrictions = "writes allowed only inside the workspace and temp dir; network denied"
        case .workspaceWriteNetwork:
            restrictions = "writes allowed only inside the workspace and temp dir; network allowed"
        }
        return "[sandbox] This command ran inside WillDeep's macOS sandbox (\(effectiveMode.rawValue): \(restrictions)). If the failure above looks like 'permission denied' / 'operation not permitted', do NOT retry the identical command — the sandbox will deny it again. Instead: use read_file/edit_file/create_file for file work, keep paths inside the workspace, or briefly tell the user why the command must run outside the sandbox so they can approve escalation."
    }

    /// Argument flag stamped onto a tool call while waiting for the user to
    /// approve re-running outside the sandbox after a denial.
    nonisolated static let sandboxEscalationRequestArgumentKey = "_sandbox_escalation_request"
    nonisolated static let sandboxDenialDetailArgumentKey = "_sandbox_denial_detail"

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
        // git 等工具几乎所有子命令都会以写模式打开 /dev/null（重定向 hook/pager/gpg
        // 探测输出），交互探测会打开 /dev/tty；(deny default) 下不放行会导致命令恒 EPERM。
        var writeAllows: [String] = [
            "(literal \"/dev/null\")",
            "(literal \"/dev/tty\")",
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
        AgentShellCommandParser.containsExecutableSubstitution(command)
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
        guard let unquoted = AgentShellCommandParser.unquotedText(command),
              unquoted.contains(where: { redirectionCharacters.contains($0) }) else {
            return false
        }
        return !onlyContainsHarmlessRedirections(unquoted)
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
            // A public-looking GET can redirect or be route-overridden to a
            // private endpoint. Keep risk metadata conservative and send it
            // through Smart review rather than treating network text as a
            // purely local read.
            return .needsJudgment
        case "ssh":
            return classifySSHRemoteCommand(tokens)
        default:
            return .needsJudgment
        }
    }

    nonisolated private static func classifySSHRemoteCommand(_ tokens: [String]) -> CommandSafety {
        guard let remoteCommand = AgentCommandAuthorization.sshRemoteCommand(from: tokens) else {
            return .needsJudgment
        }
        return SafeCommand.classify(command: remoteCommand)
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

    nonisolated private static func resolvePath(_ raw: String, workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard looksLikePath(cleaned) else { return nil }
        if let expandedHomePath = expandedSandboxRemappedHomePath(cleaned) {
            return URL(fileURLWithPath: expandedHomePath).standardizedFileURL
        }
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

    nonisolated private static func localPathCheckTokens(for tokens: [String], head: String) -> ArraySlice<String> {
        guard head == "ssh",
              let hostIndex = AgentCommandAuthorization.sshHostIndex(tokens),
              hostIndex + 1 < tokens.count else {
            return tokens.dropFirst()
        }
        return tokens.dropFirst().prefix(hostIndex)
    }

    nonisolated private static func looksLikePath(_ token: String) -> Bool {
        token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token == ".."
            || expandedSandboxRemappedHomePath(token) != nil
    }

    nonisolated private static func referencesSandboxRemappedHome(_ raw: String) -> Bool {
        expandedSandboxRemappedHomePath(raw) != nil
    }

    /// Expands only the shell forms whose meaning changes when the sandbox
    /// replaces HOME. Leading redirection syntax is ignored so both
    /// `> ~/bin/file` and `>~/bin/file` are recognized.
    nonisolated private static func expandedSandboxRemappedHomePath(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        while let first = cleaned.first,
              first == ">" || first == "<" || first.isNumber {
            cleaned.removeFirst()
        }

        let suffix: Substring
        if cleaned == "~" || cleaned == "$HOME" || cleaned == "${HOME}" {
            suffix = ""
        } else if cleaned.hasPrefix("~/") {
            suffix = cleaned.dropFirst(2)
        } else if cleaned.hasPrefix("$HOME/") {
            suffix = cleaned.dropFirst("$HOME/".count)
        } else if cleaned.hasPrefix("${HOME}/") {
            suffix = cleaned.dropFirst("${HOME}/".count)
        } else {
            return nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard !suffix.isEmpty else { return home.path }
        return home.appendingPathComponent(String(suffix)).standardizedFileURL.path
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
        if sensitivePathFragments.contains(where: { lower.contains($0) }) {
            return true
        }
        if sensitiveOptionNameLooksSensitive(lower) {
            return true
        }
        return sensitiveCredentialMarkers.contains { marker in
            containsIdentifierBoundedMarker(marker, in: lower)
        }
    }

    nonisolated private static func sensitiveOptionNameLooksSensitive(_ lower: String) -> Bool {
        guard lower.hasPrefix("-") else { return false }
        let optionName = lower.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lower
        return sensitiveCredentialMarkers.contains { marker in
            optionName.hasSuffix(marker)
                || containsIdentifierBoundedMarker(marker, in: optionName)
        }
    }

    nonisolated private static func containsIdentifierBoundedMarker(
        _ marker: String,
        in value: String
    ) -> Bool {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(of: marker, range: searchStart..<value.endIndex) {
            let isLeadingBoundary = range.lowerBound == value.startIndex
                || !isASCIIAlphaNumeric(value[value.index(before: range.lowerBound)])
            let isTrailingBoundary = range.upperBound == value.endIndex
                || !isASCIIAlphaNumeric(value[range.upperBound])
            if isLeadingBoundary && isTrailingBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    nonisolated private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
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
