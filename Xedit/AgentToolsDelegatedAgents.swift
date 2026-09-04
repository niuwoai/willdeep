//
//  AgentToolsDelegatedAgents.swift
//  WillDeep
//
//  AgentToolRunner 的委派执行器工具：claude_code、codex_cli、cursor_agent、hermes_cli、cline_cli 的可执行文件探测、命令行构造与执行。
//  自 AgentTools.swift 拆出，行为不变。
//

import Foundation

extension AgentToolRunner {
    // MARK: claude_code

    /// Permission modes accepted from model-authored `claude_code` calls.
    /// `bypassPermissions` remains unavailable here; only the host-derived
    /// unattended-dispatch bit may select it below.
    nonisolated static let claudeCodePermissionModes: Set<String> = ["plan", "acceptEdits", "default"]

    /// Locate the Claude Code CLI. Checks the native-installer location
    /// (`~/.local/bin`) and the legacy alias first, then every PATH
    /// entry from the augmented shell environment. Returns an absolute
    /// path so the composed command doesn't depend on PATH at run time.
    nonisolated static func claudeCodeExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(entry)/claude")
        }
        return candidates.first(where: isExecutable)
    }

    /// POSIX single-quote escaping: safe to embed arbitrary text
    /// (including the task prompt) into a `/bin/sh -c` command line.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func claudeCodeCommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        imagePaths: [String] = [],
        agent: String? = nil
    ) -> String {
        var parts = [shellQuoted(executable)]
        let imageDirectories = Array(Set(imagePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })).sorted()
        for directory in imageDirectories {
            parts += ["--add-dir", shellQuoted(directory)]
        }
        parts += [
            "-p", shellQuoted(prompt),
            "--output-format", "text",
        ]
        if permissionMode == "bypassPermissions" {
            parts.append("--dangerously-skip-permissions")
        } else {
            parts += ["--permission-mode", permissionMode]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        if let agent, !agent.isEmpty {
            parts += ["--agent", shellQuoted(agent)]
        }
        return parts.joined(separator: " ")
    }

    /// Delegate a task to the Claude Code CLI in headless mode. Thin
    /// composer over `runCommand`: builds the `claude -p …` command
    /// line, then rides the exact same foreground/background plumbing
    /// (job registry, output buffers, kill, completion notifications).
    static func claudeCode(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }

        let requestedPermissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "acceptEdits"
        guard claudeCodePermissionModes.contains(requestedPermissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(claudeCodePermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let permissionMode = claudeCodeCLIPermissionMode(
            requestedPermissionMode,
            unattended: context.isUnattendedDispatchTask
        )

        let executable: String
        if context.remoteBackend != nil {
            executable = "claude"
        } else if let localExecutable = claudeCodeExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Claude Code CLI not found on this Mac. Install it first (e.g. `npm install -g @anthropic-ai/claude-code` or the native installer from https://claude.com/claude-code), then retry. Tell the user instead of retrying blindly."
            )
        }
        let agent = arguments["agent"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let agent, !LocalAgentCLIProfile.profileNameIsSafe(agent) {
            throw AgentToolError.invalidArgument(
                "agent must contain only letters, numbers, dot, underscore, or hyphen"
            )
        }

        if agent == nil,
           context.remoteBackend == nil,
           arguments["use_visible_terminal"]?.boolValue() != true {
            let root = context.rootDirectory?.standardizedFileURL
                ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let environment = context.localCommandEnvironment ?? shellEnvironment()
            let acpExecutable = claudeCodeACPExecutablePath(
                environment: environment
            )
            let capabilities = AgentExecutorCapabilityResolver.select(
                executor: .claudeCode,
                isRemote: false,
                usesDaemon: false,
                usesVisibleTerminal: false,
                hasHostApproval: context.delegatedApprovalHandler != nil,
                hasACPAdapter: acpExecutable != nil
            )
            if capabilities.transport == .agentClientProtocol,
               let acpExecutable {
                let configuration = AgentACPConfiguration(
                    executableURL: URL(fileURLWithPath: acpExecutable),
                    claudeExecutableURL: URL(fileURLWithPath: executable),
                    prompt: prompt,
                    model: arguments["model"]?.stringValue(),
                    sessionID: delegatedAgentSessionID(arguments),
                    imagePaths: delegatedImagePaths(arguments),
                    workingDirectory: root,
                    environment: environment,
                    sandboxMode: context.sandboxMode,
                    permissionMode: permissionMode,
                    secretRedactionValues: context.secretRedactionValues
                )
                return try await runACPDelegatedAgent(
                    configuration,
                    arguments: arguments,
                    context: context
                )
            }
            let specification = AgentExecutorProcessFactory.claudeCode(
                executable: executable,
                prompt: prompt,
                permissionMode: permissionMode,
                model: arguments["model"]?.stringValue(),
                sessionID: delegatedAgentSessionID(arguments),
                imagePaths: delegatedImagePaths(arguments),
                workingDirectory: root,
                additionalWorkspaceRoots: Array(context.workspaceRoots.dropFirst()),
                environment: environment,
                sandboxMode: context.sandboxMode
            )
            return try await runStructuredDelegatedAgent(
                specification,
                arguments: arguments,
                context: context
            )
        }
        if agent == nil,
           let daemonBackend = context.daemonBackend,
           arguments["use_visible_terminal"]?.boolValue() != true {
            let root = URL(
                fileURLWithPath: context.workspaceLocation?.path
                    ?? daemonBackend.descriptor.defaultWorkspacePath
            )
            let specification = AgentExecutorProcessFactory.claudeCode(
                executable: executable,
                prompt: prompt,
                permissionMode: permissionMode,
                model: arguments["model"]?.stringValue(),
                sessionID: delegatedAgentSessionID(arguments),
                imagePaths: delegatedImagePaths(arguments),
                workingDirectory: root,
                environment: [:],
                sandboxMode: context.sandboxMode
            )
            return try await daemonBackend.runExecutor(
                specification: specification,
                arguments: arguments,
                context: context,
                foregroundMaxTimeout: delegatedAgentForegroundTimeout
            )
        }

        let command = claudeCodeCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            imagePaths: delegatedImagePaths(arguments),
            agent: agent
        )

        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }


    // MARK: codex_cli / hermes_cli / cursor_agent / cline_cli

    // 前台委派的墙钟兜底。原来是 6 小时，用户视角约等于「永远卡住」。真正拦
    // 静默挂起的是各执行器的 idle 看门狗（见 AgentCodexAppServer.idleTimeout）；
    // 这个墙钟只当合理上限。需要更长的任务应转后台运行（后台无此墙钟）。
    nonisolated static let delegatedAgentForegroundTimeout: TimeInterval = 3600
    nonisolated static let codexCLIPermissionModes: Set<String> = ["plan", "workspaceWrite", "default"]
    nonisolated static let cursorAgentPermissionModes: Set<String> = ["plan", "ask", "default"]
    nonisolated static let clineCLIPermissionModes: Set<String> = ["plan", "act", "default"]

    nonisolated static func delegatedAgentForwardedCommandArguments(
        command: String,
        sourceArguments arguments: [String: AgentJSONValue]
    ) -> [String: AgentJSONValue] {
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        var forwarded: [String: AgentJSONValue] = [
            "command": .string(command),
            "run_in_background": .bool(runInBackground),
        ]
        if let timeout = arguments["timeout_seconds"]?.intValue() {
            forwarded["timeout_seconds"] = .number(Double(timeout))
        } else if !runInBackground {
            forwarded["timeout_seconds"] = .number(delegatedAgentForegroundTimeout)
        }
        return forwarded
    }

    nonisolated static func codexCLIExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "codex", preferredPaths: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ], environment: environment, isExecutable: isExecutable)
    }

    /// Locate the Cursor Agent CLI. The standalone installer
    /// (`curl https://cursor.com/install | bash`) drops a `cursor-agent`
    /// binary in `~/.local/bin` and does NOT provide a `cursor` command,
    /// so prefer `cursor-agent`. Fall back to the `cursor` editor launcher
    /// (installed by Cursor.app), which forwards its `agent` subcommand to
    /// the same headless agent. Both accept the `agent …` command we
    /// compose, so callers don't need to know which one was found.
    nonisolated static func cursorAgentExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        if let standalone = executablePath(commandName: "cursor-agent", preferredPaths: [
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
        ], environment: environment, isExecutable: isExecutable) {
            return standalone
        }
        return executablePath(commandName: "cursor", preferredPaths: [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func clineCLIExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "cline", preferredPaths: [
            "\(NSHomeDirectory())/.local/bin/cline",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func hermesCLIExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "hermes", preferredPaths: [
            "\(NSHomeDirectory())/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func codexCLICommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?,
        imagePaths: [String] = [],
        profile: String? = nil
    ) -> String {
        let sandbox = permissionMode == "plan" ? "read-only" : "workspace-write"
        var parts = [
            shellQuoted(executable),
            "-a", "never",
            "exec",
            "--color", "never",
            "--skip-git-repo-check",
            "--sandbox", sandbox,
        ]
        if let profile, !profile.isEmpty {
            parts += ["--profile", shellQuoted(profile)]
        }
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--cd", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        if !imagePaths.isEmpty {
            parts.append("--image")
            parts += imagePaths.map(shellQuoted)
            parts.append("--")
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    nonisolated static func cursorAgentCommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "agent",
            "--print",
            "--output-format", "text",
            "--sandbox", "enabled",
            "--trust",
        ]
        switch permissionMode {
        case "plan":
            parts += ["--mode", "plan"]
        case "ask":
            parts += ["--mode", "ask"]
        default:
            break
        }
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--workspace", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    nonisolated static func clineCLICommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "--json",
        ]
        if permissionMode == "plan" {
            parts.append("--plan")
        }
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--cwd", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    nonisolated static func hermesCLICommandLine(
        executable: String,
        prompt: String,
        model: String?,
        provider: String?,
        profile: String?,
        planningOnly: Bool = false,
        homeDirectory: String? = NSHomeDirectory()
    ) -> String {
        let normalizedProfile = profile?.isEmpty == false ? profile! : "default"
        let profileSuffix = normalizedProfile == "default"
            ? "/.hermes"
            : "/.hermes/profiles/\(normalizedProfile)"
        let hermesHome: String
        if let homeDirectory {
            hermesHome = shellQuoted("\(homeDirectory)\(profileSuffix)")
        } else {
            // Remote execution must resolve the remote account's home, not
            // serialize this Mac's local NSHomeDirectory into the command.
            hermesHome = "\"$HOME\(profileSuffix)\""
        }
        var parts = [
            "/usr/bin/env",
            "HERMES_HOME=\(hermesHome)",
            shellQuoted(executable),
            "--oneshot", shellQuoted(prompt),
        ]
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        if let provider, !provider.isEmpty {
            parts += ["--provider", shellQuoted(provider)]
        }
        if planningOnly {
            // Hermes --oneshot bypasses its interactive approval prompts.
            // Planning therefore receives an intentionally empty toolset so
            // the external planner cannot mutate the workspace.
            parts += ["--toolsets", "context_engine"]
        }
        return parts.joined(separator: " ")
    }

    static func codexCLI(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "workspaceWrite"
        guard codexCLIPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(codexCLIPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "codex"
        } else if let localExecutable = codexCLIExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Codex CLI not found on this Mac. Install Codex CLI or the Codex desktop app, then retry. Tell the user instead of retrying blindly."
            )
        }
        let profile = arguments["profile"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let profile, !LocalAgentCLIProfile.profileNameIsSafe(profile) {
            throw AgentToolError.invalidArgument(
                "profile must contain only letters, numbers, dot, underscore, or hyphen"
            )
        }
        if profile == nil,
           context.remoteBackend == nil,
           arguments["use_visible_terminal"]?.boolValue() != true {
            let root = context.rootDirectory?.standardizedFileURL
                ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            if context.delegatedApprovalHandler != nil {
                let configuration = AgentCodexAppServerConfiguration(
                    executableURL: URL(fileURLWithPath: executable),
                    prompt: prompt,
                    model: arguments["model"]?.stringValue(),
                    sessionID: delegatedAgentSessionID(arguments),
                    imagePaths: delegatedImagePaths(arguments),
                    workingDirectory: root,
                    environment: context.localCommandEnvironment
                        ?? shellEnvironment(),
                    sandboxMode: context.sandboxMode,
                    permissionMode: permissionMode,
                    secretRedactionValues: context.secretRedactionValues
                )
                return try await runCodexAppServerDelegatedAgent(
                    configuration,
                    arguments: arguments,
                    context: context
                )
            }
            let specification = AgentExecutorProcessFactory.codexCLI(
                executable: executable,
                prompt: prompt,
                permissionMode: permissionMode,
                model: arguments["model"]?.stringValue(),
                sessionID: delegatedAgentSessionID(arguments),
                workspacePath: context.workspaceLocation?.path
                    ?? context.rootDirectory?.standardizedFileURL.path,
                imagePaths: delegatedImagePaths(arguments),
                workingDirectory: root,
                additionalWorkspaceRoots: Array(context.workspaceRoots.dropFirst()),
                environment: context.localCommandEnvironment ?? shellEnvironment(),
                sandboxMode: context.sandboxMode
            )
            return try await runStructuredDelegatedAgent(
                specification,
                arguments: arguments,
                context: context
            )
        }
        if profile == nil,
           let daemonBackend = context.daemonBackend,
           arguments["use_visible_terminal"]?.boolValue() != true {
            let workspacePath = context.workspaceLocation?.path
                ?? daemonBackend.descriptor.defaultWorkspacePath
            let specification = AgentExecutorProcessFactory.codexCLI(
                executable: executable,
                prompt: prompt,
                permissionMode: permissionMode,
                model: arguments["model"]?.stringValue(),
                sessionID: delegatedAgentSessionID(arguments),
                workspacePath: workspacePath,
                imagePaths: delegatedImagePaths(arguments),
                workingDirectory: URL(fileURLWithPath: workspacePath),
                environment: [:],
                sandboxMode: context.sandboxMode
            )
            return try await daemonBackend.runExecutor(
                specification: specification,
                arguments: arguments,
                context: context,
                foregroundMaxTimeout: delegatedAgentForegroundTimeout
            )
        }
        let command = codexCLICommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path,
            imagePaths: delegatedImagePaths(arguments),
            profile: profile
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }



    static func cursorAgent(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        guard cursorAgentPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(cursorAgentPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "cursor"
        } else if let localExecutable = cursorAgentExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Cursor Agent CLI not found on this Mac. Install Cursor and its command line launcher first, then retry. Tell the user instead of retrying blindly."
            )
        }
        let command = cursorAgentCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    static func hermesCLI(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let executable: String
        if context.remoteBackend != nil {
            executable = "hermes"
        } else if let localExecutable = hermesCLIExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Hermes CLI not found on this Mac. Install Hermes Agent, then retry."
            )
        }
        let profile = arguments["hermes_profile"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        guard LocalAgentCLIProfile.profileNameIsSafe(profile) else {
            throw AgentToolError.invalidArgument(
                "hermes_profile must contain only letters, numbers, dot, underscore, or hyphen"
            )
        }
        let command = hermesCLICommandLine(
            executable: executable,
            prompt: prompt,
            model: arguments["model"]?.stringValue(),
            provider: arguments["provider"]?.stringValue(),
            profile: profile,
            planningOnly: arguments["permission_mode"]?.stringValue() == "plan",
            homeDirectory: context.remoteBackend == nil ? NSHomeDirectory() : nil
        )
        return try await runDelegatedAgentCommand(
            command,
            arguments: arguments,
            context: context
        )
    }

    static func clineCLI(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "act"
        guard clineCLIPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(clineCLIPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "cline"
        } else if let localExecutable = clineCLIExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Cline CLI not found on this Mac. Install it first with `npm install -g cline`, then retry. Tell the user instead of retrying blindly."
            )
        }
        let normalizedMode = permissionMode == "default" ? "act" : permissionMode
        let command = clineCLICommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: normalizedMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    private static func delegatedAgentPrompt(arguments: [String: AgentJSONValue]) throws -> String {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        return prompt
    }

    private static func runDelegatedAgentCommand(
        _ command: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if arguments["use_visible_terminal"]?.boolValue() == true,
           context.remoteBackend == nil,
           let controller = context.terminalController,
           let sessionID = context.runtimeID {
            let timeout = arguments["timeout_seconds"]?.intValue()
                .map(TimeInterval.init) ?? delegatedAgentForegroundTimeout
            let label = arguments["visible_terminal_label"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayCommand = label.flatMap { $0.isEmpty ? nil : $0 }
                ?? L10n.AgentTerminal.delegatedTask
            return try await controller.runCommandInDelegatedShellTab(
                command,
                sessionID: sessionID,
                displayCommand: displayCommand,
                timeout: timeout,
                secretRedactionValues: context.secretRedactionValues,
                progressSink: context.delegatedProgressSink
            )
        }
        var forwarded = delegatedAgentForwardedCommandArguments(
            command: command,
            sourceArguments: arguments
        )
        if context.daemonBackend != nil, forwarded["timeout_seconds"] == nil {
            forwarded["timeout_seconds"] = .number(delegatedAgentForegroundTimeout)
        }
        return try await runCommand(
            arguments: forwarded,
            context: context,
            foregroundMaxTimeout: delegatedAgentForegroundTimeout
        )
    }
}
