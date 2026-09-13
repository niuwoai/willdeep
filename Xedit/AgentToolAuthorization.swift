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
    case readOnlyNetwork
    case workspaceWrite
    case workspaceWriteNetwork
    /// 和 `workspaceWriteNetwork` 同样的 seatbelt profile（写只限 workspace +
    /// temp，网络放行），**唯一的差别是保留真实 `HOME` 与 `SSH_AUTH_SOCK`**。
    ///
    /// 存在的理由：部署、`git push`、`scp`/`rsync` 这类活儿需要的不是"更大的
    /// 写权限"，而是**用户的钥匙**。之前它们只有两个选择——要么落在
    /// `workspaceWriteNetwork`（有网但 HOME 被指到临时目录，`~/.ssh/config`、
    /// 私钥、known_hosts 一个都读不到，必然失败），要么整体跳到 `escalated`
    /// （连 workspace 写入限制一起放掉，杀鸡用牛刀）。这一档把"解开凭证"和
    /// "解开写入限制"拆成两件事。
    ///
    /// 注意：sensitive 环境变量（token/secret/password/api_key 形态）仍然照
    /// 剥不误。这一档放行的是**凭证文件**（靠真实 HOME 读到），不是环境里的
    /// 明文 token。
    case workspaceWriteNetworkCredentialed
    case escalated
}

struct AgentSandboxDecision: Equatable {
    let mode: AgentSandboxMode
    let requiresUserApproval: Bool
    let requiresTypedConfirmation: Bool
    let reason: String
    let prefixRule: [String]?
    /// typed confirmation 的成因是否含凭据/敏感路径命中（`.env`、`~/.ssh`、
    /// 凭据词）。环境信任声明可以把 destructive 类降为“送 AI 裁判”，但带
    /// 此标记的命令在任何声明下仍然只认人工——凭据外读是注入攻击的终点站，
    /// 这道门不接受任何来自模型侧的说服。
    var credentialSensitive: Bool = false
    /// 命令跑的是**项目自己仓库里的脚本**（见 `AgentWorkspaceScriptPolicy`），
    /// 因此走 `.escalated` 是为了脱开 seatbelt，而不是因为它可疑。两者在
    /// mode 上没法区分，但放行策略必须区分：可疑的 escalated 不进静态免批
    /// 名单，项目脚本进——否则本来免批的 `./build.sh` 会突然要人点确认。
    /// 只在没有任何危险信号（破坏性命令、凭据路径、越界路径）时才置位。
    var workspaceScriptTrusted: Bool = false

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
        "cargo", "npm", "pnpm", "yarn", "ruby", "node", "python", "python3",
        "vite", "nginx"
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
        "vite", "nginx",
        "mkdir", "touch", "mktemp"
    ]

    /// Build commands that routinely fetch dependencies as part of building.
    /// `go build` resolves modules through GOPROXY on a cold cache, `cargo
    /// build` hits crates.io, `npm run build` may trigger lifecycle hooks that
    /// install. Denying them network produced failures that *look* like broken
    /// DNS (seatbelt makes `getaddrinfo` fail as "nodename nor servname
    /// provided"), which sent debugging down the wrong path entirely. Writes
    /// stay confined to the workspace; only the network rule differs from the
    /// rest of `lowRiskWriteHeads`.
    nonisolated private static let networkCapableBuildHeads: Set<String> = [
        "make", "xcodebuild", "swift", "go", "cargo",
        "npm", "pnpm", "yarn", "ruby", "node", "python", "python3", "rake",
        "vite"
    ]

    nonisolated private static let networkHeads: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "gh", "brew",
        "mysql", "mariadb", "kubectl"
    ]

    /// Read-only network diagnostics. They resolve names or probe reachability
    /// and cannot write files, transfer payloads, or authenticate anywhere, so
    /// they run under `readOnlyNetwork` without an approval prompt. Keeping
    /// them out of the sandbox's network grant was a pure loss: the agent
    /// could not even confirm whether a host resolved before concluding a
    /// build failure was "a DNS problem".
    nonisolated private static let diagnosticNetworkHeads: Set<String> = [
        "ping", "ping6", "dig", "host", "nslookup",
        "traceroute", "traceroute6", "whois",
        "ifconfig", "netstat", "route", "arp", "scutil", "ipconfig"
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
        "id_rsa", "id_ed25519"
    ]

    /// Credential nouns are intentionally boundary-matched. Product and
    /// namespace names such as `tokenhub` are ordinary identifiers; treating
    /// every substring containing "token" as a secret upgrades harmless
    /// commands to danger-tier confirmation.
    nonisolated private static let sensitiveCredentialMarkers: [String] = [
        "token", "tokens", "secret", "secrets", "credential", "credentials"
    ]

    nonisolated private static let pipedTextFilterHeads: Set<String> = [
        "grep", "egrep", "fgrep", "rg"
    ]

    nonisolated private static let pipedTextFilterFlagsWithoutValues: Set<String> = [
        "-i", "--ignore-case", "-v", "--invert-match", "-w", "--word-regexp",
        "-x", "--line-regexp", "-F", "--fixed-strings", "-E", "--extended-regexp",
        "-n", "--line-number", "-q", "--quiet", "-s", "--no-messages"
    ]

    nonisolated private static let sandboxExecPath = "/usr/bin/sandbox-exec"

    nonisolated static func decision(
        toolName: String,
        arguments: [String: AgentJSONValue],
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
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
            return commandDecision(
                command: command,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            )
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
                mode: .readOnlyNetwork,
                requiresUserApproval: false,
                requiresTypedConfirmation: false,
                reason: "GET-only public webpage read; URL and redirects are validated locally before access.",
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
        case "claude_code", "codex_cli", "hermes_cli", "cursor_agent", "cline_cli", "opencode_cli":
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
            return commandDecision(
                command: command,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            )
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

    nonisolated static func commandDecision(
        command: String,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> AgentSandboxDecision {
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

        guard let expansionResolution = SafeCommand.resolveProvablySafeShellExpansions(
            in: commandWithHeredocBodiesRemoved(trimmed)
        ) else {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: true,
                reason: "Shell expansion is destructive, unknown, or cannot be bounded safely.",
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }
        let policyCommand = expansionResolution.command
        for substitution in expansionResolution.substitutions {
            let substitutionDecision = commandDecision(
                command: substitution,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            )
            guard substitutionDecision.mode == .readOnly,
                  !substitutionDecision.requiresUserApproval,
                  !substitutionDecision.requiresTypedConfirmation else {
                return AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: true,
                    requiresTypedConfirmation: true,
                    reason: "Command substitution is not a bounded read-only workspace operation.",
                    prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
                )
            }
        }
        let hasRedirection = containsRedirection(policyCommand)
        let redactedJudgeCommand = AgentInjectionDefense.redactedCommandForSafetyJudge(trimmed)
        let permitsRedactedCredentialJudge = redactedJudgeCommand != trimmed
            && SafeCommand.classify(command: trimmed) == .needsJudgment
            && SafeCommand.containsNetworkFetcherInvocation(policyCommand)

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
        /// 需要真实 HOME / ssh-agent（凭证文件），但**不**需要放开写入限制。
        var needsWorkspaceCredentials = false
        var needsReadOnlyNetwork = false
        var needsEscalation = expansionResolution.requiresJudgment
        var needsConfirmation = false
        var credentialSensitive = false
        /// 命令链里至少有一段跑的是本仓库脚本；只有在整条链都没有踩到危险
        /// 信号时才生效（危险信号会先走下面的 `needsEscalation` 分支）。
        var hasTrustedWorkspaceScript = false
        var reasons: [String] = expansionResolution.requiresJudgment
            ? ["A bounded read-only command substitution requires intelligent review of the complete command."]
            : []
        var workingDirectory = rootDirectory?.standardizedFileURL

        if chain.requiresBackgroundJudgment {
            needsWorkspaceWrite = true
            reasons.append("Background shell execution requires approval.")
        }

        for (segmentIndex, segment) in chain.segments.enumerated() {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text) else {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Unable to parse command segment \(segmentIndex + 1) safely.")
                continue
            }
            if rawTokens.allSatisfy(isEnvironmentAssignment),
               rawTokens.contains(where: assignmentContainsSafeCommandSubstitution) {
                let assignmentValues = rawTokens.map(environmentAssignmentValue)
                if rawTokens.contains(where: environmentAssignmentKeyLooksSensitive) {
                    needsEscalation = true
                    needsConfirmation = true
                    credentialSensitive = true
                    reasons.append("Environment assignment uses a credential-like variable name.")
                }
                if assignmentValues.contains(where: referencesSensitivePath) {
                    needsEscalation = true
                    needsConfirmation = true
                    credentialSensitive = true
                    reasons.append("Environment assignment references a sensitive path or credential-like value.")
                }
                if assignmentValues.contains(where: referencesSandboxRemappedHome) {
                    needsEscalation = true
                    reasons.append("Home-relative paths require access to the user's real home outside the workspace sandbox.")
                }
                if assignmentValues.contains(where: { token in
                    guard looksLikePath(token),
                          let resolved = resolvePath(
                              token,
                              workingDirectory: workingDirectory,
                              rootDirectory: rootDirectory
                          ) else {
                        return false
                    }
                    return !isInsideWorkspace(
                        resolved,
                        rootDirectory: rootDirectory,
                        additionalWorkspaceRoots: additionalWorkspaceRoots
                    )
                }) {
                    needsEscalation = true
                    reasons.append("Environment assignment references a path outside the workspace and must preserve the real target before launch.")
                }
                continue
            }
            if rawTokens.allSatisfy(isEnvironmentAssignment) {
                let assignmentValues = rawTokens.map(environmentAssignmentValue)
                if rawTokens.contains(where: environmentAssignmentKeyLooksSensitive) {
                    needsEscalation = true
                    if !permitsRedactedCredentialJudge {
                        needsConfirmation = true
                    }
                    credentialSensitive = true
                    reasons.append(
                        permitsRedactedCredentialJudge
                            ? "Credential assignment will be redacted locally before intelligent review."
                            : "Environment assignment uses a credential-like variable name."
                    )
                }
                if assignmentValues.contains(where: referencesSensitivePath) {
                    needsEscalation = true
                    needsConfirmation = true
                    credentialSensitive = true
                    reasons.append("Environment assignment references a sensitive path or credential-like value.")
                }
                if assignmentValues.contains(where: referencesSandboxRemappedHome) {
                    needsEscalation = true
                    reasons.append("Home-relative paths require access to the user's real home outside the workspace sandbox.")
                }
                continue
            }
            guard let invocation = shellInvocation(from: rawTokens) else {
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
                if !permitsRedactedCredentialJudge {
                    needsConfirmation = true
                }
                credentialSensitive = true
                reasons.append(
                    permitsRedactedCredentialJudge
                        ? "Credential assignment will be redacted locally before intelligent review."
                        : "Environment assignment uses a credential-like variable name."
                )
            }

            if assignmentValues.contains(where: referencesSensitivePath) {
                needsEscalation = true
                needsConfirmation = true
                credentialSensitive = true
                reasons.append("Environment assignment references a sensitive path or credential-like value.")
            }

            if assignmentValues.contains(where: { token in
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) else {
                    return false
                }
                return !isInsideWorkspace(
                    resolved,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                )
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
                    let resolved = resolvePath(
                        next,
                        workingDirectory: workingDirectory,
                        rootDirectory: rootDirectory
                    ) ?? (isSafeRelativeDirectoryHop(next)
                        ? resolveRelativeDirectoryHop(next, workingDirectory: workingDirectory)
                        : nil)
                    if let resolved,
                       isInsideWorkspace(
                           resolved,
                           rootDirectory: rootDirectory,
                           additionalWorkspaceRoots: additionalWorkspaceRoots
                       ) {
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

            if isRebuildableWorkspaceCleanup(
                tokens: tokens,
                workingDirectory: workingDirectory,
                rootDirectory: rootDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            ) {
                needsWorkspaceWrite = true
                reasons.append("Removing a rebuildable generated directory inside the workspace is a bounded cleanup operation.")
            } else if destructiveHeads.contains(head) {
                needsEscalation = true
                needsConfirmation = true
                reasons.append("Destructive or privilege-changing command `\(head)` requires typed confirmation.")
            } else if diagnosticNetworkHeads.contains(head) {
                needsReadOnlyNetwork = true
            } else if networkHeads.contains(head) {
                switch classifyNetworkReadOnly(head: head, tokens: tokens) {
                case .alwaysSafe:
                    needsReadOnlyNetwork = true
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
                    // 依赖安装是最依赖真实 HOME 的一类：`~/.npmrc`、`~/.gitconfig`
                    // （git+ssh 依赖）、`~/.cargo/config`、`~/.gem/credentials` 全在
                    // 那里。HOME 被换成临时目录时，私有源直接 401、走 SSH 的依赖
                    // 直接失败。
                    needsWorkspaceCredentials = true
                    reasons.append("Package dependency installation may write inside the workspace, needs registry network access, and reads its credentials from the real home directory.")
                    continue
                }
                switch SafeCommand.classify(command: segment.text) {
                case .alwaysSafe:
                    // A SafeCommand-certified call is auto-approvable, but some
                    // of those still write (go build, npm run build, mkdir,
                    // and the reversible local `git commit`).
                    // Bump only those to workspace-write; read-only certs like
                    // `git diff` stay read-only. See `lowRiskWriteHeads`.
                    if lowRiskWriteHeads.contains(head)
                        || SafeCommand.isLocalGitCommit(command: segment.text) {
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

                // Deliberately outside the switch: whether a build tool lands
                // in `alwaysSafe` or `needsJudgment` is an implementation
                // detail of SafeCommand, but either way it ends up in a
                // workspace-write profile and needs the registry. Global
                // installs are excluded — they write outside the workspace,
                // which the sandbox denies regardless of the network rule.
                let isWorkspaceScript = AgentWorkspaceScriptPolicy.matches(
                    tokens: tokens,
                    workingDirectory: workingDirectory,
                    roots: [rootDirectory].compactMap { $0 } + additionalWorkspaceRoots
                )
                if isWorkspaceScript, !AgentPackageCommandPolicy.hasGlobalInstallScope(tokens),
                   AgentWorkspaceScriptPolicy.trustedScriptURL(
                       tokens: tokens,
                       workingDirectory: workingDirectory,
                       roots: [rootDirectory].compactMap { $0 } + additionalWorkspaceRoots
                   ) != nil {
                    // 用户确认过可信的目录里的脚本，按项目自己的代码对待：不再
                    // 关进 seatbelt。沙箱对它们只挡住了正事（真实 HOME、网络、
                    // `~/.ssh`），挡不住任何东西——脚本内容本来就是这个仓库的
                    // 一部分。没确认过的目录一律当作不可信，照旧关在沙箱里。
                    hasTrustedWorkspaceScript = true
                    reasons.append("Command runs a script from a folder you marked as trusted, so it runs outside the workspace sandbox.")
                }
                if (networkCapableBuildHeads.contains(head) || isWorkspaceScript),
                   !AgentPackageCommandPolicy.hasGlobalInstallScope(tokens) {
                    needsWorkspaceNetwork = true
                    // 光有网络不够：这些工具的配置和凭证都在真实 HOME 里
                    // （`~/.npmrc`、`~/.gitconfig`、`~/.cargo/config`、
                    // `~/.gem/credentials`、`~/.ssh` 下的 git-over-ssh 依赖）。
                    // HOME 被指到临时目录时，私有 registry 拉不动、走 SSH 的
                    // 依赖必然失败，而且 `ruby scripts/deploy.rb` 这类**把网络
                    // 与 ssh 藏在脚本里**的命令，从命令头上根本看不出来——它
                    // 正是用户会拿来做部署的形态。
                    needsWorkspaceCredentials = true
                    reasons.append("Command `\(head)` may fetch dependencies from a package registry and read its configuration from the real home directory.")
                }
            }

            if !isSSHAgentDirectoryListing(tokens),
               credentialScanTokens(head: head, tokens: tokens)
                .contains(where: { token in
                    referencesSensitivePath(token)
                        && !AgentWorkspaceTemplatePolicy.isPublicTemplate(
                            token,
                            workingDirectory: workingDirectory,
                            roots: [rootDirectory].compactMap { $0 } + additionalWorkspaceRoots
                        )
                        && !isWorkspaceLocalMarkerOnlyPath(
                            token,
                            workingDirectory: workingDirectory,
                            rootDirectory: rootDirectory,
                            additionalWorkspaceRoots: additionalWorkspaceRoots
                        )
                }),
               !isPipedTextFilterUsingOnlyPattern(
                   head: head,
                   tokens: tokens,
                   runsInPipeline: segment.runsInPipeline
               ) {
                needsEscalation = true
                needsConfirmation = true
                credentialSensitive = true
                reasons.append("Command references a sensitive path or credential-like value.")
            }

            if localPathTokens.contains(where: { token in
                guard looksLikePath(token),
                      let resolved = resolvePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) else {
                    return false
                }
                return !isInsideWorkspace(
                    resolved,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                )
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
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed),
                credentialSensitive: credentialSensitive
            )
        }

        // 本仓库脚本：脱开 seatbelt，但审批门槛不变（仍然 requiresUserApproval，
        // 由审批档位和裁判决定放不放）。放在 `needsEscalation` 之后，任何真正
        // 的危险信号都先于它成立，带 typed confirmation 的那条路不受影响。
        if hasTrustedWorkspaceScript {
            return AgentSandboxDecision(
                mode: .escalated,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: reasons.uniqued().joined(separator: " "),
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed),
                workspaceScriptTrusted: true
            )
        }

        if needsWorkspaceWrite {
            let workspaceMode: AgentSandboxMode
            if needsWorkspaceNetwork {
                workspaceMode = needsWorkspaceCredentials
                    ? .workspaceWriteNetworkCredentialed
                    : .workspaceWriteNetwork
            } else {
                workspaceMode = .workspaceWrite
            }
            return AgentSandboxDecision(
                mode: workspaceMode,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: reasons.uniqued().joined(separator: " "),
                prefixRule: AgentCommandAuthorization.prefixRule(for: trimmed)
            )
        }

        if needsReadOnlyNetwork {
            return AgentSandboxDecision(
                mode: .readOnlyNetwork,
                requiresUserApproval: false,
                requiresTypedConfirmation: false,
                reason: "Command uses a statically verified read-only network operation with filesystem writes denied.",
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

    nonisolated static func canAutoApproveWorkspaceWriteCommand(
        command: String,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> Bool {
        guard let rootDirectory else { return false }

        let decision = commandDecision(
            command: command,
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )
        // 凭证档必须和另外两档一样留在自动放行的名单里：它只是"同样的写入
        // 限制 + 真实 HOME"，风险等级没变。漏掉它会让 `npm install`、
        // `go build` 这类本来免批的命令突然全部要人点确认。
        // 项目仓库脚本走 `.escalated`（脱 seatbelt），但成因是"这是本项目的
        // 代码"，不是"这条命令可疑"。免批名单按成因收，不按档位收，否则
        // `./build.sh` 会从免批变成每次点确认。
        let autoApprovableModes: [AgentSandboxMode] = decision.workspaceScriptTrusted
            ? [.workspaceWrite, .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed, .escalated]
            : [.workspaceWrite, .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed]
        guard autoApprovableModes.contains(decision.mode),
              decision.requiresUserApproval,
              !decision.requiresTypedConfirmation else {
            return false
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expansionResolution = SafeCommand.resolveProvablySafeShellExpansions(
            in: commandWithHeredocBodiesRemoved(trimmed)
        ),
              !expansionResolution.requiresJudgment,
              let chain = AgentShellCommandParser.parse(expansionResolution.command),
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
                credentialHeads.contains(head) {
                return false
            }

            if destructiveHeads.contains(head) {
                guard isRebuildableWorkspaceCleanup(
                    tokens: tokens,
                    workingDirectory: workingDirectory,
                    rootDirectory: root,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                ) else {
                    return false
                }
                continue
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
                    let resolved = resolvePath(
                        next,
                        workingDirectory: workingDirectory,
                        rootDirectory: root
                    ) ?? (isSafeRelativeDirectoryHop(next)
                        ? resolveRelativeDirectoryHop(next, workingDirectory: workingDirectory)
                        : nil)
                    guard let resolved,
                          isInsideWorkspace(
                            resolved,
                            rootDirectory: root,
                            additionalWorkspaceRoots: additionalWorkspaceRoots
                          ) else {
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
                if !isInsideWorkspace(
                    resolved,
                    rootDirectory: root,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                ) {
                    return false
                }
            }
        }

        return true
    }

    /// Allows only recursive/force removal of well-known generated folders
    /// whose resolved targets stay inside an authorized workspace. This is
    /// deliberately narrower than a generic `rm` allowlist: no globs, no
    /// workspace root, no parent traversal outside the root, and no arbitrary
    /// directory merely named by the caller as disposable.
    nonisolated private static func isRebuildableWorkspaceCleanup(
        tokens: [String],
        workingDirectory: URL?,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL]
    ) -> Bool {
        guard tokens.first?.lowercased() == "rm" else { return false }

        var sawRecursive = false
        var targets: [String] = []
        for token in tokens.dropFirst() {
            if token == "--" { continue }
            if token.hasPrefix("-") {
                let flags = token.dropFirst()
                guard !flags.isEmpty,
                      flags.allSatisfy({ $0 == "r" || $0 == "R" || $0 == "f" }) else {
                    return false
                }
                if flags.contains("r") || flags.contains("R") {
                    sawRecursive = true
                }
                continue
            }
            targets.append(token)
        }

        guard sawRecursive, !targets.isEmpty else { return false }
        let rebuildableNames: Set<String> = [
            "node_modules", ".vite", ".parcel-cache", ".turbo", ".next",
            ".build", "dist", "deriveddata", "target"
        ]
        let rebuildableGoCacheSuffixes: Set<String> = [
            ".cache/go-build", ".cache/go-mod", ".gocache", ".gomodcache"
        ]

        return targets.allSatisfy { target in
            guard !target.contains("*") && !target.contains("?") && !target.contains("[") && !target.contains("$") && !target.contains("`"),
                  !referencesSensitivePath(target),
                  let resolved = resolveCleanupTarget(
                    target,
                    workingDirectory: workingDirectory,
                    rootDirectory: rootDirectory
                  ),
                  isInsideWorkspace(
                    resolved,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                  ) else {
                return false
            }

            let standardized = resolved.standardizedFileURL
            let authorizedRoots = ([rootDirectory].compactMap { $0 } + additionalWorkspaceRoots)
                .map(\.standardizedFileURL)
            guard !authorizedRoots.contains(standardized) else { return false }

            let normalizedPath = standardized.path.lowercased()
            let name = standardized.lastPathComponent.lowercased()
            return rebuildableNames.contains(name)
                || rebuildableGoCacheSuffixes.contains(where: { normalizedPath.hasSuffix("/\($0)") })
        }
    }

    /// Cleanup targets are commonly bare relative directory names such as
    /// `node_modules`; the general path detector intentionally ignores those
    /// because arbitrary command arguments are not necessarily paths.
    nonisolated private static func resolveCleanupTarget(
        _ raw: String,
        workingDirectory: URL?,
        rootDirectory: URL?
    ) -> URL? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if cleaned.hasPrefix("/") || cleaned.hasPrefix("~") {
            return resolvePath(
                cleaned,
                workingDirectory: workingDirectory,
                rootDirectory: rootDirectory
            )
        }
        let base = workingDirectory ?? rootDirectory?.standardizedFileURL
        return base?.appendingPathComponent(cleaned).standardizedFileURL
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

        guard let expansionResolution = SafeCommand.resolveProvablySafeShellExpansions(
            in: commandWithHeredocBodiesRemoved(trimmed)
        ),
              !expansionResolution.requiresJudgment,
              let chain = AgentShellCommandParser.parse(expansionResolution.command),
              !chain.segments.isEmpty else {
            return true
        }

        for segment in chain.segments {
            guard let rawTokens = AgentCommandAuthorization.shellTokens(from: segment.text) else {
                return true
            }
            if rawTokens.allSatisfy(isEnvironmentAssignment),
               rawTokens.contains(where: assignmentContainsSafeCommandSubstitution) {
                continue
            }
            guard let invocation = shellInvocation(from: rawTokens) else { return true }
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

    /// Host-owned temp directory every non-escalated command is pointed at
    /// (`TMPDIR` and friends). Also the parent of the synthetic HOME.
    nonisolated static var sandboxTemporaryDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-agent-sandbox-tmp", isDirectory: true)
    }

    /// 现在恒为 false：每一档都用真实 HOME。
    ///
    /// 这堵墙和拒网络是同一类假墙，而且更假：seatbelt 的 `(allow file-read*)`
    /// 无条件放行，`/Users/<you>/.ssh/id_rsa` 在任何一档下都读得到——改写
    /// `HOME` 挡住的只是**按名字找**，挡不住按路径读。挡不住恶意，却挡死了
    /// 正事：`~/.npmrc`、`~/.kube/config`、corepack 缓存、`~/.cargo` 全部查无
    /// 此人，工具表现得像刚装完系统，于是重新下载、重新登录、重新配置。
    ///
    /// 换掉它的是两样**真**的东西，都在 seatbelt 里，见 `seatbeltProfile`：
    /// 主目录整体只读（写入白名单只有 workspace、临时目录和一小撮缓存/包
    /// 目录），以及 `credentialReadDenials` 那组 `(deny file-read* …)`——凭据
    /// 目录在非凭证档是**内核级**拒绝，比今天严。
    ///
    /// 保留这个函数是因为失败提示和测试都读它；它现在只回答"有没有改写过
    /// HOME"，答案永远是没有。
    nonisolated static func redirectsHome(_ mode: AgentSandboxMode) -> Bool { false }

    /// 非凭证档下被 seatbelt 拒读的凭据路径（相对真实主目录）。
    ///
    /// 名单刻意短：只收**纯凭据存放点**，不收带 token 的普通配置。
    /// `~/.npmrc`、`~/.kube/config`、`~/.gitconfig` 不在其中——它们正是用户
    /// 希望能用起来的东西，而真正的私钥/长期凭据在下面这几条里。
    nonisolated static let credentialReadDenials: [String] = [
        ".ssh",
        ".aws",
        ".gnupg",
        ".netrc",
        ".git-credentials",
        ".pypirc",
        ".gem/credentials",
        ".docker/config.json",
        ".config/gh",
        "Library/Keychains",
    ]

    /// 主目录下允许写入的缓存与包目录。
    ///
    /// 必须有：合成 HOME 时代这些写入落在 `TMPDIR` 底下，是**成功**的（只是
    /// 每次都冷）。HOME 指回真实主目录后，不开这个口子它们会从"慢"变成
    /// EPERM——那是比原来更糟的结果。名单只收缓存与包存放点，主目录其余
    /// 部分保持只读。
    nonisolated static let homeCacheWriteAllowances: [String] = [
        ".cache",
        ".npm",
        ".yarn",
        ".pnpm-store",
        ".bun",
        ".deno",
        ".cargo",
        ".rustup",
        ".gradle",
        ".m2/repository",
        "go/pkg/mod",
        "Library/Caches",
        "Library/pnpm",
    ]

    /// 是否对 `mode` 施加凭据读拒绝。凭证档就是"给钥匙"那一档，escalated
    /// 根本不套 seatbelt。
    nonisolated static func deniesCredentialReads(_ mode: AgentSandboxMode) -> Bool {
        switch mode {
        case .readOnly, .readOnlyNetwork, .workspaceWrite, .workspaceWriteNetwork:
            return true
        case .workspaceWriteNetworkCredentialed, .escalated:
            return false
        }
    }

    nonisolated static func sandboxedEnvironment(
        mode: AgentSandboxMode,
        rootDirectory: URL?,
        command: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for key in environment.keys where keyLooksSensitive(key) {
            environment.removeValue(forKey: key)
        }
        environment["WILLDEEP_AGENT_SANDBOX"] = mode.rawValue
        environment["WILLDEEP_WORKSPACE_ROOT"] = rootDirectory?.standardizedFileURL.path ?? ""

        if mode != .escalated {
            let sandboxTemporaryDirectory = sandboxTemporaryDirectoryURL
            try? FileManager.default.createDirectory(
                at: sandboxTemporaryDirectory,
                withIntermediateDirectories: true
            )
            // HOME 不再改写：见 `redirectsHome`。挡凭据的活交给 seatbelt 的
            // `credentialReadDenials`，那是内核级的，比改一个环境变量真。
            //
            // `GIT_CONFIG_GLOBAL` / `KUBECONFIG` 这两处旧的窄例外随之作废：
            // 它们当初存在，就是为了在合成 HOME 下把某一个工具单独领回真实
            // 配置。现在整个主目录都读得到，打这两个补丁反而是多余的分叉。
            // Node/Playwright inherit the GUI process' TMPDIR by default. On
            // macOS that path can be a parent of Foundation's actual
            // temporaryDirectory, while the seatbelt profile only allows the
            // latter. Keep every common temp variable on one host-created,
            // explicitly allowed directory so transform caches and browser
            // profiles do not fail with a misleading EPERM.
            environment["TMPDIR"] = sandboxTemporaryDirectory.path
            environment["TMP"] = sandboxTemporaryDirectory.path
            environment["TEMP"] = sandboxTemporaryDirectory.path
            // ssh-agent 同理：凭证档保留，其余档位一律断掉。
            if mode != .workspaceWriteNetworkCredentialed {
                environment["SSH_AUTH_SOCK"] = nil
            }
            // token 类环境变量**所有非 escalated 档都剥**，凭证档也不例外。
            // `gh` 在真实 HOME 下会从 ~/.config/gh 读到自己的凭证，不需要我们
            // 把明文 token 塞进它的环境。
            environment["GITHUB_TOKEN"] = nil
            environment["GH_TOKEN"] = nil
        }
        return environment
    }

    nonisolated static func shellLaunch(
        command: String,
        mode: AgentSandboxMode,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
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
            arguments: [
                "-p",
                seatbeltProfile(
                    mode: mode,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                ),
                "/bin/sh",
                "-c",
                command,
            ]
        )
    }

    /// Launch a known executable with a typed argv vector. External coding
    /// agents use this path so prompts and paths are never reparsed by a shell.
    /// The process still inherits the same seatbelt profile as run_command.
    nonisolated static func processLaunch(
        executableURL: URL,
        arguments: [String],
        mode: AgentSandboxMode,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
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
                seatbeltProfile(
                    mode: mode,
                    rootDirectory: rootDirectory,
                    additionalWorkspaceRoots: additionalWorkspaceRoots
                ),
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
        case .workspaceWrite, .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed:
            return false
        case .readOnly, .readOnlyNetwork:
            break
        }

        guard SafeCommand.classify(command: command) == .alwaysSafe,
              let expansionResolution = SafeCommand.resolveProvablySafeShellExpansions(in: command),
              !expansionResolution.requiresJudgment,
              let chain = AgentShellCommandParser.parse(expansionResolution.command),
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
            // network ops, but they still belong inside the profile: it is
            // what keeps their writes in the workspace. (Network itself is no
            // longer denied in any mode — see `deniesNetwork`.)
            if networkHeads.contains(head)
                || credentialHeads.contains(head)
                || diagnosticNetworkHeads.contains(head) {
                return false
            }
        }
        return true
    }

    /// Sandbox modes whose seatbelt profile carries `(deny network*)`.
    nonisolated static func canEnforceLocalTaskVerification(command: String, mode: AgentSandboxMode) -> Bool {
        (mode == .readOnly || mode == .workspaceWrite)
            && FileManager.default.isExecutableFile(atPath: sandboxExecPath)
            && !shouldRunWithoutSeatbelt(command: command, mode: mode)
    }

    /// Sandbox modes whose seatbelt profile carries `(deny network*)`.
    /// 现在恒为 false：seatbelt 不再拒网络。
    ///
    /// 拒网络原本是想挡外泄，但这道墙从来就没合拢过。profile 里
    /// `(allow file-read*)` 在**每一档**都无条件放行，写入又对整个 workspace
    /// 开着——读到密钥写进 workspace、下一条带网络的命令再发出去，两步就绕过
    /// 去了，而这两步都在同一个审批档位里。挡住的只有正事：装依赖、拉镜像、
    /// 调接口，而且 seatbelt 把拒绝伪装成域名解析失败，agent 会一头扎进 DNS
    /// 里查半天（这条弯路在事故记录里反复出现）。
    ///
    /// 真正管用的是另外三样，一样没动：写入仍然只限 workspace 与临时目录；
    /// 凭据路径与破坏性命令仍然在策略层要人工确认；未确认信任的目录里的脚本
    /// 仍然进沙箱。保留 `…Network` 那几档是为了审计日志读得出当初的判定，
    /// 不再对应两种运行时行为。
    nonisolated static func deniesNetwork(_ mode: AgentSandboxMode) -> Bool { false }

    /// Name-resolution failures a denied-network seatbelt profile produces.
    /// Deliberately matched only under `deniesNetwork` modes — see the call
    /// site in `looksLikeSandboxDenial`.
    nonisolated private static let networkDenialMarkers: [String] = [
        "nodename nor servname provided",
        "name or service not known",
        "temporary failure in name resolution",
        "no such host",
        "could not resolve host",
        "could not resolve proxy",
        "getaddrinfo enotfound",
        "getaddrinfo eai_again",
        "unknownhostexception",
        "failed to lookup address information",
        "dns lookup failed",
        "network is unreachable",
        "network access denied",
        "network access is disabled",
        "socket: operation not permitted"
    ]

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
                    .pathOutsideWorkspace, .symlinkOutsideWorkspace, .notFound,
                    .notRegular, .binaryFile,
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
            "read-only file system",
            "eperm:",
            "eacces:",
            // Node/undici report a seatbelt-refused socket as
            // `connect EPERM 127.0.0.1:7890` (typically the local proxy) and
            // carry `code: 'EPERM'` in the error object — neither form has the
            // colon the two markers above rely on. corepack downloading yarn
            // through the proxy died exactly like this and was read as a
            // proxy problem for fourteen minutes.
            "connect eperm",
            "code: 'eperm'",
            "code: 'eacces'",
            "npm err! code eacces",
            "you don't have permission",
            "you don’t have permission",
            "not permitted in sandbox",
        ]
        if strongMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }

        // Seatbelt does not surface a "network denied" error. It makes name
        // resolution fail, so every runtime reports it as a DNS fault instead:
        // Go says "no such host", libc says "nodename nor servname provided",
        // Node says "getaddrinfo ENOTFOUND". Read as-is these look like a
        // broken resolver and send debugging entirely the wrong way. Only
        // treat them as a denial in the modes that actually deny network —
        // under an allowed-network profile a DNS failure is a real DNS
        // failure and must not be misreported as a sandbox problem.
        if deniesNetwork(sandboxMode),
           networkDenialMarkers.contains(where: { lowered.contains($0) }) {
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
        case .readOnly, .readOnlyNetwork:
            restrictions = "reads allowed except a short credential list; writes denied except the temp dir and the caches under ~; network allowed; the real HOME is readable"
        case .workspaceWrite, .workspaceWriteNetwork:
            restrictions = "writes allowed only inside the workspace, the temp dir and the caches under ~; network allowed; the real HOME is readable except a short credential list"
        case .workspaceWriteNetworkCredentialed:
            restrictions = "writes allowed only inside the workspace, the temp dir and the caches under ~; network allowed; the real HOME, ~/.ssh and ssh-agent are all available"
        }
        let networkNote = deniesNetwork(effectiveMode)
            ? " Network is denied in this mode, and seatbelt expresses that as a name-resolution or connect failure: errors such as 'no such host', 'nodename nor servname provided', 'getaddrinfo ENOTFOUND', 'could not resolve host', or 'connect EPERM 127.0.0.1:<port>' (a local proxy refused) mean the sandbox blocked the connection — the machine's DNS and proxy are fine. Do not debug DNS, proxies, HTTP(S)_PROXY, or /etc/resolv.conf."
            : ""
        // The real HOME is visible now, but a short credential list is denied
        // at the kernel. Naming it matters: a bare "operation not permitted"
        // on ~/.ssh reads like a broken key or a permissions mistake on the
        // machine, and the fix for that is nothing like the fix for this.
        let homeNote = deniesCredentialReads(effectiveMode)
            ? " The real HOME is readable, but these are denied by the sandbox itself: \(credentialReadDenials.map { "~/" + $0 }.joined(separator: ", ")). A permission error on one of those is this rule, not a broken key or a machine misconfiguration — do not chmod anything, regenerate a key, or re-run ssh-add. Say in one line that the command needs credentials so the host can re-run it with them."
            : ""
        return "[sandbox] This command ran inside WillDeep's macOS sandbox (\(effectiveMode.rawValue): \(restrictions)).\(networkNote)\(homeNote) If the failure above looks like 'permission denied' / 'operation not permitted', do NOT retry the identical command — the sandbox will deny it again. Instead: use read_file/edit_file/create_file for file work, keep paths inside the workspace, or say in one line that the command needs the network or the user's real home so the host can run it outside the sandbox."
    }

    /// Argument flag stamped onto a tool call while waiting for the user to
    /// approve re-running outside the sandbox after a denial.
    nonisolated static let sandboxEscalationRequestArgumentKey = "_sandbox_escalation_request"
    nonisolated static let sandboxDenialDetailArgumentKey = "_sandbox_denial_detail"

    nonisolated static func scrub(_ text: String) -> String {
        var result = AgentInjectionDefense.redactedCommandForSafetyJudge(text)
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{8,}"#,
            #"gh[pousr]_[A-Za-z0-9_]{20,}"#,
            #"sk[-_][A-Za-z0-9_-]{12,}"#,
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

    nonisolated private static func seatbeltProfile(
        mode: AgentSandboxMode,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> String {
        // git 等工具几乎所有子命令都会以写模式打开 /dev/null（重定向 hook/pager/gpg
        // 探测输出），交互探测会打开 /dev/tty；(deny default) 下不放行会导致命令恒 EPERM。
        var writeAllows: [String] = [
            "(literal \"/dev/null\")",
            "(literal \"/dev/tty\")"
        ]
        var seen = Set<String>()
        // Seatbelt matches the kernel-resolved vnode path, so a root spelled
        // through a symlink never matches its own subpath rule: `/tmp/x` and
        // `$TMPDIR` (`/var/folders/…`) resolve to `/private/…` and were
        // silently unwritable. Emit the realpath alongside the standardized
        // spelling for every allowed root, temporary directory included.
        func allowSubpath(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            var paths = [standardized]
            if let resolvedPointer = realpath(standardized, nil) {
                paths.append(String(cString: resolvedPointer))
                free(resolvedPointer)
            }
            for path in paths where seen.insert(path).inserted {
                writeAllows.append("(subpath \(profileString(path)))")
            }
        }
        allowSubpath(FileManager.default.temporaryDirectory)
        if mode == .workspaceWrite
            || mode == .workspaceWriteNetwork
            || mode == .workspaceWriteNetworkCredentialed {
            for rootURL in [rootDirectory].compactMap({ $0 }) + additionalWorkspaceRoots {
                allowSubpath(rootURL)
            }
        }
        // 主目录下的缓存与包目录。每一档都给，包括只读档：合成 HOME 时代
        // 这些写入落在 TMPDIR 里本来就是成功的，只读档也不例外（`go list`
        // 会写 build cache）。不给的话，HOME 指回真实主目录反而让它们从
        // "慢"变成 EPERM。主目录其余部分保持只读。
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in homeCacheWriteAllowances {
            allowSubpath(home.appendingPathComponent(relative))
        }
        let writeRule = "(allow file-write* \(writeAllows.joined(separator: " ")))"
        // SBPL 后匹配优先，所以这组 deny 必须排在 `(allow file-read*)` 之后
        // 才生效。这是仓库里**第一条真正的读限制**——在此之前主目录的私钥
        // 在每一档下都读得到，挡住它的只是一个改写过的 HOME 环境变量。
        var readDenies = ""
        if deniesCredentialReads(mode) {
            var denyTargets: [String] = []
            var seenDenies = Set<String>()
            for relative in credentialReadDenials {
                let url = home.appendingPathComponent(relative)
                let standardized = url.standardizedFileURL.path
                var paths = [standardized]
                if let resolvedPointer = realpath(standardized, nil) {
                    paths.append(String(cString: resolvedPointer))
                    free(resolvedPointer)
                }
                for path in paths where seenDenies.insert(path).inserted {
                    // subpath 覆盖目录，literal 覆盖单文件（`.netrc`、
                    // `.docker/config.json`）；两条都发，多余的那条无害。
                    denyTargets.append("(subpath \(profileString(path)))")
                    denyTargets.append("(literal \(profileString(path)))")
                }
            }
            readDenies = "\n(deny file-read* \(denyTargets.joined(separator: " ")))"
        }
        // 恒放行，理由见 `deniesNetwork`。这两个必须一起改：`deniesNetwork`
        // 是失败提示和拒绝识别读的那份"沙箱现在拦了什么"，与 profile 说的
        // 不一致就会去解释一个并不存在的拒绝。
        let networkRule = "(allow network*)"
        return """
        (version 1)
        (deny default)
        (allow process*)
        (allow signal (target self))
        (allow sysctl-read)
        (allow file-read*)\(readDenies)
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

    nonisolated private static func assignmentContainsSafeCommandSubstitution(
        _ assignment: String
    ) -> Bool {
        assignment.contains(SafeCommand.safeCommandSubstitutionPlaceholder)
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
        case "mysql", "mariadb":
            return SafeCommand.classifyDatabaseClient(firstToken: head, tokens: tokens)
        case "kubectl":
            // kubectl 进这张表只是为了拿到网络，它的读写边界早就由
            // SafeCommand 分得很细（`get` / `describe` / `rollout status`
            // 只读，`set image` 送审，`get secret` 直接危险）。走 default
            // 会把只读巡检也打成需审批，白丢掉一整类免打扰的诊断命令。
            return SafeCommand.classifyKubectl(tokens: tokens)
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

    nonisolated private static func isInsideWorkspace(
        _ url: URL,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> Bool {
        let path = url.standardizedFileURL.path
        return ([rootDirectory].compactMap { $0 } + additionalWorkspaceRoots).contains { rootURL in
            let root = rootURL.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
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

    /// Listing these directories exposes names/metadata, not private-key bytes.
    /// Only remove the mandatory credential prompt: normal Smart review still
    /// judges the whole command, including ssh-add and every chained segment.
    nonisolated private static func isSSHAgentDirectoryListing(_ tokens: [String]) -> Bool {
        guard let head = tokens.first, head == "ls" || head == "/bin/ls" else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["~", "$HOME", "${HOME}", home]
        let paths = Set(roots.flatMap { root in
            ["\(root)/.ssh", "\(root)/.ssh/agent", "\(root)/.ssh/sockets"]
        })
        let metadataFlags = Set("aAldhF1")
        var hasPath = false
        for token in tokens.dropFirst() {
            if token == "2>&1" || token == "2>/dev/null" { continue }
            if token.hasPrefix("-"), token.count > 1,
               token.dropFirst().allSatisfy({ metadataFlags.contains($0) }) { continue }
            let path = token.hasSuffix("/") ? String(token.dropLast()) : token
            guard paths.contains(path) else { return false }
            hasPath = true
        }
        return hasPath
    }

    nonisolated private static func referencesSensitivePath(_ token: String) -> Bool {
        let lower = token.lowercased()
        if sensitivePathFragments.contains(where: { lower.contains($0) }) {
            return true
        }
        if referencesDotEnvFile(lower) {
            return true
        }
        if sensitiveOptionNameLooksSensitive(lower) {
            return true
        }
        return sensitiveCredentialMarkers.contains { marker in
            containsIdentifierBoundedMarker(marker, in: lower)
        }
    }

    /// 只有这三个命令的 `-i` 表示身份密钥。`rsync -i` 是
    /// `--itemize-changes`，与凭据无关，故意不在列内。
    nonisolated private static let sshIdentityHeads: Set<String> = ["ssh", "scp", "sftp"]

    /// `ssh -i ~/.ssh/id_rsa host` 里的私钥是**认证材料**，不是被读出来外
    /// 传的目标——这正是 SSH 密钥存在的意义。把它算作敏感读，会让每一条
    /// 上服务器的运维命令都升到打字确认，而打字确认一票否决送裁判的资格。
    ///
    /// 只剔除 `-i` 的取值本身（含 `-i<path>` 黏连形态）。命令里其余 token
    /// 照常扫描：`ssh host 'cat ~/.ssh/id_rsa'` 的远端读取、`scp
    /// host:~/.ssh/id_rsa .` 的取回，都仍然命中。
    nonisolated private static func sshTokensExcludingIdentityFile(
        _ rest: [String]
    ) -> [String] {
        var scanned: [String] = []
        var index = 0
        while index < rest.count {
            let token = rest[index]
            if token == "-i" {
                index += 2
                continue
            }
            if token.hasPrefix("-i"), !token.hasPrefix("--"), token.count > 2 {
                index += 1
                continue
            }
            scanned.append(token)
            index += 1
        }
        return scanned
    }

    /// `.env` 只有落在路径末段才是凭据文件。裸子串匹配会把 kubectl 的
    /// `containers[0].envFrom` 和 `.env[?(@.name=="X")]` 这类 jsonpath 判成
    /// 读密钥——审计日志里这是「敏感路径」误伤的头号形态：纯只读的
    /// `kubectl get deployment -o jsonpath=…` 被顶到打字确认，而打字确认
    /// 恰恰一票否决了送裁判的资格，于是每一条都必须人工点。
    ///
    /// 判据：按 `/` 切段后，某一段本身是 `.env`，或以 `.env.` 开头
    /// （`.env.local`、`.env.production`）。`.envfrom`、`.env[`、
    /// `.environment` 都不再命中；`~/.env`、`/srv/app/.env.local` 照常命中。
    nonisolated private static func referencesDotEnvFile(_ lower: String) -> Bool {
        lower
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".env" || $0.hasPrefix(".env.") }
    }

    /// A credential noun used as the sole pattern of a piped text filter is
    /// not itself a credential read. For example, `kubectl get ns | grep -i
    /// token` only filters the already-visible namespace list. Any additional
    /// positional argument could be a file, so those shapes remain gated.
    nonisolated private static func isPipedTextFilterUsingOnlyPattern(
        head: String,
        tokens: [String],
        runsInPipeline: Bool
    ) -> Bool {
        guard runsInPipeline,
              pipedTextFilterHeads.contains(head),
              tokens.count >= 2 else {
            return false
        }

        var positionalArguments: [String] = []
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") {
                guard pipedTextFilterFlagsWithoutValues.contains(token) else {
                    return false
                }
                continue
            }
            positionalArguments.append(token)
        }

        return positionalArguments.count == 1
    }

    /// 参与凭据词扫描的参数集合。`git commit` 的提交信息是惰性文本：一段
    /// “支持 Bearer Token 双认证”的说明不读取任何凭据，却会因 message 里出现
    /// token/secret 字样被升到人工确认（审计日志实锤的高频误伤）。这里只剔除
    /// message 参数本身——`-m`/`--message` 的取值、`--message=…`/`-m…` 的黏连
    /// 形态；路径、flag 与其余参数照常扫描，非 `git commit` 命令原样返回。
    nonisolated private static func credentialScanTokens(
        head: String,
        tokens: [String]
    ) -> [String] {
        let rest = Array(tokens.dropFirst())
        if sshIdentityHeads.contains(where: { head == $0 || head.hasSuffix("/\($0)") }) {
            return sshTokensExcludingIdentityFile(rest)
        }
        guard head == "git" || head.hasSuffix("/git"),
              rest.contains(where: { $0.lowercased() == "commit" }) else {
            return rest
        }
        var scanned: [String] = []
        var index = 0
        while index < rest.count {
            let token = rest[index]
            let lower = token.lowercased()
            let isShortMessageFlagCluster = lower.hasPrefix("-")
                && !lower.hasPrefix("--")
                && lower.hasSuffix("m")
            if lower == "--message" || isShortMessageFlagCluster {
                scanned.append(token)
                index += 2
                continue
            }
            if lower.hasPrefix("--message=")
                || (lower.hasPrefix("-m") && !lower.hasPrefix("--") && lower.count > 2) {
                index += 1
                continue
            }
            scanned.append(token)
            index += 1
        }
        return scanned
    }

    /// 工作区内“词撞名”路径豁免。`internal/auth/token.go`、`docs/secrets.md`
    /// 这类工作区内文件，`read_file` 工具本就免审可读，命令行读它却要人工点，
    /// 纯粹是同一份数据走两条门的不一致。豁免只覆盖**凭据词命中**且 token
    /// 能解析为工作区内路径的情况：`.env`、`~/.ssh` 等 sensitivePathFragments
    /// 与敏感选项名（`--token=…`）永不豁免，工作区外路径也不豁免。
    nonisolated private static func isWorkspaceLocalMarkerOnlyPath(
        _ token: String,
        workingDirectory: URL?,
        rootDirectory: URL?,
        additionalWorkspaceRoots: [URL]
    ) -> Bool {
        let lower = token.lowercased()
        // `.env` 单独判：它已从 sensitivePathFragments 里拿出来（那份列表
        // 是裸子串匹配，会把 kubectl 的 `.envFrom` 一并判成密钥），但豁免
        // 侧的语义没变——工作区内的 `./.env` 仍是真凭据文件，和 `~/.ssh`
        // 一样永不豁免。漏掉这一行，工作区内的 `.env` 就会被当成「词撞名」
        // 放行。
        guard !sensitivePathFragments.contains(where: { lower.contains($0) }),
              !referencesDotEnvFile(lower),
              !sensitiveOptionNameLooksSensitive(lower) else {
            return false
        }
        guard !hasBareCredentialComponent(lower) else { return false }
        // 豁免侧用自己的路径识别，比通用 looksLikePath 宽：通用检测器驱动
        // “升级”，把 `internal/auth/token.go` 这类裸相对路径当路径会过度
        // 打扰；这里驱动“豁免”，恰恰以多段相对路径为主形态。含 shell
        // 元字符 / URL / 赋值形态的 token 一律不认，flag 不认，单段裸词
        //（如 `kubectl get secret` 的资源词）因为不含 `/` 也不认。
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !cleaned.isEmpty, !cleaned.hasPrefix("-") else { return false }
        guard !cleaned.contains(where: { ":=*?$`(){}[]<>|&;".contains($0) }) else {
            return false
        }
        let resolved: URL
        if let viaGeneralDetector = resolvePath(
            cleaned,
            workingDirectory: workingDirectory,
            rootDirectory: rootDirectory
        ) {
            resolved = viaGeneralDetector
        } else if cleaned.contains("/"), !cleaned.hasPrefix("~") {
            guard let base = workingDirectory ?? rootDirectory?.standardizedFileURL else {
                return false
            }
            resolved = base.appendingPathComponent(cleaned).standardizedFileURL
        } else {
            return false
        }
        return isInsideWorkspace(
            resolved,
            rootDirectory: rootDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )
    }

    /// 目录段里只有这几个词能单独定性。`tokens/`、`token/` 不在其列：设计
    /// token、API token 模型、分词器都常年占用这个目录名，把它算成凭据库会
    /// 把 1.280.0-rc2 刚消掉的那类误伤原样请回来。
    nonisolated private static let bareCredentialStoreNames: Set<String> = [
        "secret", "secrets", "credential", "credentials"
    ]

    /// 词撞名豁免只该覆盖**恰好含凭据词的普通文件**（`internal/auth/token.go`、
    /// `docs/secrets.md`），不该覆盖**本身就是凭据的文件**。分界有两条：
    ///
    /// - 末段没有扩展名且整段就是凭据词（`secrets/credentials`、`deploy/token`）
    ///   ——这不是撞名，是自报家门；
    /// - 途经的目录段整段叫 `secrets` / `credentials`（`config/secrets/db.yml`）
    ///   ——目录本身声明了里面装什么。
    ///
    /// 豁免的立论是「`read_file` 本就免审可读同一文件」，对源码成立；把它推广
    /// 到裸凭据名，等于用一致性论证把凭据读取一并放行了。
    nonisolated private static func hasBareCredentialComponent(_ lower: String) -> Bool {
        let components = lower.split(separator: "/").map(String.init)
        guard let last = components.last else { return false }
        if !last.contains("."), sensitiveCredentialMarkers.contains(last) {
            return true
        }
        return components.dropLast().contains { bareCredentialStoreNames.contains($0) }
    }

    nonisolated private static func sensitiveOptionNameLooksSensitive(_ lower: String) -> Bool {
        guard lower.hasPrefix("-") else { return false }
        let optionName = lower.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lower
        return sensitiveCredentialMarkers.contains { marker in
            optionName.hasSuffix(marker)
                || containsIdentifierBoundedMarker(marker, in: optionName)
        }
    }

    /// 下划线算标识符字符，不算边界：`token_plan_quota.go`、`secret_santa.rb`
    /// 这类 snake_case 名字里的 token/secret 是普通标识符片段，不是凭据引用。
    /// 审计日志实测这是敏感词升级里最大的误伤源（读工作区源码文件也要人工点）。
    /// 连字符仍然是边界——`tokenhub-secret` 是 k8s secret 对象名，必须继续命中。
    nonisolated private static func containsIdentifierBoundedMarker(
        _ marker: String,
        in value: String
    ) -> Bool {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(of: marker, range: searchStart..<value.endIndex) {
            let isLeadingBoundary = range.lowerBound == value.startIndex
                || !isIdentifierCharacter(value[value.index(before: range.lowerBound)])
            let isTrailingBoundary = range.upperBound == value.endIndex
                || !isIdentifierCharacter(value[range.upperBound])
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

    nonisolated private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || isASCIIAlphaNumeric(character)
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
