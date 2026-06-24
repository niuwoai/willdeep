//
//  AgentTools.swift
//  WillDeep
//
//  Built-in tools exposed to the project agent: search, read, list,
//  run command, and git status. Each tool declares a risk tier so the
//  AppState can decide whether to auto-allow, prompt, or require an
//  explicit confirm word before executing.
//

import Foundation
import Darwin

// MARK: - Tool runner

enum AgentToolRunner {
    static func run(
        name: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        switch name {
        case "search_files":
            return try await AgentFileTools.searchFiles(arguments: arguments, context: context)
        case "grep_files":
            return try await AgentFileTools.grepFiles(arguments: arguments, context: context)
        case "read_file":
            return try await AgentFileTools.readFile(arguments: arguments, context: context)
        case "list_directory":
            return try await AgentFileTools.listDirectory(arguments: arguments, context: context)
        case "glob":
            // Compatibility alias for the `glob` tool some models hallucinate;
            // read-only workspace path scan. See AgentFileTools.glob.
            return try await AgentFileTools.glob(arguments: arguments, context: context)
        case "git_status":
            return try await AgentFileTools.gitStatus(context: context)
        case "run_command":
            return try await runCommand(arguments: arguments, context: context)
        case "terminal_snapshot":
            return try await AgentTerminalTools.snapshot(arguments: arguments, context: context)
        case "terminal_send_command":
            return try await AgentTerminalTools.sendCommand(arguments: arguments, context: context)
        case "terminal_send_control":
            return try await AgentTerminalTools.sendControl(arguments: arguments, context: context)
        case "apply_patch":
            return try await applyPatch(arguments: arguments, context: context)
        case "claude_code":
            return try await claudeCode(arguments: arguments, context: context)
        case "codex_cli":
            return try await codexCLI(arguments: arguments, context: context)
        case "cursor_agent":
            return try await cursorAgent(arguments: arguments, context: context)
        case "cline_cli":
            return try await clineCLI(arguments: arguments, context: context)
        case "lark_cli":
            return try await larkCLI(arguments: arguments)
        case "list_jobs":
            return try await listJobs(arguments: arguments, context: context)
        case "get_job_output":
            return try await getJobOutput(arguments: arguments, context: context)
        case "kill_job":
            return try await killJob(arguments: arguments, context: context)
        case "list_skills":
            return try AgentSkillCatalog.listSkills(arguments: arguments)
        case "read_skill":
            return try AgentSkillCatalog.readSkill(arguments: arguments)
        case "add_memory":
            return try AgentSelfLearning.addMemory(arguments: arguments, rootDirectory: context.rootDirectory)
        case "create_user_skill":
            return try AgentSelfLearning.createUserSkill(arguments: arguments)
        case "update_user_skill":
            return try AgentConfigurationTools.updateUserSkill(arguments: arguments)
        case "delete_user_skill":
            return try AgentConfigurationTools.deleteUserSkill(arguments: arguments)
        case "search_mcp_servers":
            return try await AgentSelfLearning.searchMCPServers(arguments: arguments)
        case "suggest_mcp_server":
            return try AgentSelfLearning.suggestMCPServer(arguments: arguments, rootDirectory: context.rootDirectory)
        case "configure_mcp_server":
            return try AgentConfigurationTools.configureMCPServer(arguments: arguments)
        case "web_search":
            return try await AgentWebTools.webSearch(arguments: arguments)
        case "web_fetch":
            return try await AgentWebTools.webFetch(arguments: arguments)
        case "generate_image":
            return try await generateImage(arguments: arguments)
        case "visual_qa_screenshot":
            return try await AgentVisualQATools.analyzeScreenshot(arguments: arguments, context: context)
        case "chrome_status":
            return try await AgentChromeTools.status(arguments: arguments)
        case "chrome_read_page":
            return try await AgentChromeTools.readPage(arguments: arguments)
        case "chrome_read_selection":
            return try await AgentChromeTools.readSelection(arguments: arguments)
        case "chrome_click":
            return try await AgentChromeTools.click(arguments: arguments)
        case "chrome_type":
            return try await AgentChromeTools.typeText(arguments: arguments)
        case "chrome_capture_tab":
            return try await AgentChromeTools.captureTab(arguments: arguments)
        case "chrome_debugger_command":
            return try await AgentChromeTools.debuggerCommand(arguments: arguments)
        case "list_mcp_servers":
            return try AgentMCPBridge.listServers()
        case "list_mcp_tools":
            return try await AgentMCPBridge.listTools(arguments: arguments)
        case "call_mcp_tool":
            return try await AgentMCPBridge.callTool(arguments: arguments)
        case "show_widget":
            return try await showWidget(arguments: arguments, context: context)
        case "run_workflow":
            return try await runWorkflow(arguments: arguments, context: context)
        default:
            throw AgentToolError.unknownTool(name)
        }
    }

    // MARK: apply_patch

    private static func applyPatch(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rootDirectory = context.rootDirectory else {
            throw AgentToolError.noWorkspace
        }
        guard let rawDiff = arguments["diff"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDiff.isEmpty else {
            throw AgentToolError.missingArgument("diff")
        }
        guard let sink = context.patchProposalSink else {
            throw AgentToolError.invalidArgument("apply_patch is only available inside an interactive WillDeep agent session.")
        }

        let extractedBlocks = AgentPatchApplier.extractDiffBlocks(from: rawDiff)
        let diff = extractedBlocks.count == 1 ? extractedBlocks[0] : rawDiff
        let changes: [AgentPatchFileChange]
        do {
            changes = try AgentPatchApplier.parse(diff)
        } catch {
            throw AgentToolError.invalidArgument(error.localizedDescription)
        }

        let root = rootDirectory.standardizedFileURL
        let rootPath = root.path
        for change in changes {
            let url = root.appendingPathComponent(change.path).standardizedFileURL
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
                throw AgentToolError.pathOutsideWorkspace(change.path)
            }
            if change.isNewFile {
                // Creation diff: the file must NOT already exist (use a
                // modify diff to change an existing file).
                if FileManager.default.fileExists(atPath: url.path) {
                    throw AgentToolError.invalidArgument("apply_patch new-file diff targets a path that already exists: \(change.path). Use a normal modify diff instead.")
                }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentToolError.notFound(change.path)
                }
            }
        }

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle : nil
        let proposal = try await sink(title, diff)
        let files = changes.map(\.path)
        let fileList = files.map { "- \($0)" }.joined(separator: "\n")
        let fileLabel = files.count == 1 ? "1 file" : "\(files.count) files"
        let statusLine: String
        switch proposal.status {
        case .applied:
            statusLine = "Patch status: applied. The existing patch applier wrote the changes to disk."
        case .failed:
            statusLine = "Patch status: failed\(proposal.statusMessage.map { ": \($0)" } ?? ".")"
        case .rejected:
            statusLine = "Patch status: rejected."
        case .pending:
            statusLine = "Patch status: pending. No files were modified; the user must click Apply before this patch writes to disk."
        }

        return AgentToolResult(
            summary: proposal.status == .applied ? "patch applied: \(fileLabel)" : "patch queued: \(fileLabel)",
            payload: """
            Patch proposal queued in the right-side diff panel.

            Patch ID: \(proposal.id.uuidString)
            Title: \(proposal.title)
            \(statusLine)
            Files:
            \(fileList)
            """
        )
    }

    private static func generateImage(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        let rawSize = arguments["size"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let size = rawSize.isEmpty ? "1024x1024" : rawSize
        let rawModel = arguments["model"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? nil : rawModel
        let image = try await SomeIMClient.generateImage(prompt: prompt, size: size, model: model)
        return AgentToolResult(
            summary: "Generated image: \(image.fileURL.lastPathComponent)",
            payload: """
            Generated image with some.im model `\(image.model)`.

            Local file:
            \(image.fileURL.path)
            """
        )
    }

    // MARK: run_command

    nonisolated private static let defaultCommandTimeout: TimeInterval = 20
    nonisolated private static let maxCommandTimeout: TimeInterval = 120
    nonisolated private static let maxCommandOutput = 32 * 1024
    nonisolated static let supplementalCommandPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    nonisolated static func shellEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in supplementalCommandPathEntries where !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    private static func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval = maxCommandTimeout
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.runCommand(
                arguments: arguments,
                context: context,
                foregroundMaxTimeout: foregroundMaxTimeout
            )
        }
        let root = context.rootDirectory?.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let command = arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))

        // Background path: hand the Process off to the registry, return
        // immediately with the job handle, let the agent loop pull the
        // completion event at the top of a later turn.
        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let bgTimeout: Double? = arguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let job: AgentBackgroundJob
            do {
                job = try await MainActor.run {
                    try registry.start(
                        command: command,
                        workingDirectory: root,
                        runtimeID: runtimeID,
                        timeoutSeconds: bgTimeout,
                        sandboxMode: context.sandboxMode
                    )
                }
            } catch {
                throw AgentToolError.commandFailed(-1, error.localizedDescription)
            }
            let cwd = job.workingDirectoryPath ?? root.path
            let timeoutLine = bgTimeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            let payload = """
            Started background job \(job.displayHandle).
            Command: \(command)
            PID: \(job.pid)
            cwd: \(cwd)\(timeoutLine)

            The job is running. You will receive a `<background-task-notification>` system message at the start of a later turn when it finishes (or fails). Until then, call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop it.
            """
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: payload
            )
        }

        let outcome = await Task.detached(priority: .userInitiated) { () -> CommandOutcome in
            let process = Process()
            let launch = AgentSandboxPolicy.shellLaunch(
                command: command,
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory
            )
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.currentDirectoryURL = root
            let baseEnvironment = shellEnvironment()
            var environment = AgentSandboxPolicy.sandboxedEnvironment(
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory,
                base: baseEnvironment
            )
            // `shellEnvironment()` 复制宿主进程的环境,里面带着宿主的
            // `$PWD`。`sh`/`bash` 的 `pwd` builtin 信任 `$PWD`,于是即便
            // 我们已经 chdir 到 `root`,`pwd` 仍会打印宿主那个陈旧的目
            // 录(CI 上就是 runner 的工作目录,本地恰好可能一致所以测
            // 不出来)。把 `$PWD` 同步成真实 cwd,`pwd` 才反映实际工作
            // 目录 —— 也修掉 testRunCommandUsesHomeDirectoryWithoutWorkspace。
            environment["PWD"] = root.path
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            closeStandardInput(for: process)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let outputLimit = maxCommandOutput
            let stdoutCollector = CommandOutputCollector(limit: outputLimit)
            let stderrCollector = CommandOutputCollector(limit: outputLimit)
            let runState = CommandRunState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stdoutCollector.append(data) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrCollector.append(data) }
            }
            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                return CommandOutcome(exitStatus: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, launchFailed: true)
            }

            let timeoutWorkItem = DispatchWorkItem {
                runState.markTimedOut()
                if process.isRunning {
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            process.waitUntilExit()
            timeoutWorkItem.cancel()

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.append(stdoutPipe.fileHandleForReading.availableData)
            stderrCollector.append(stderrPipe.fileHandleForReading.availableData)

            return CommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: AgentSandboxPolicy.scrub(stdoutCollector.stringValue),
                stderr: AgentSandboxPolicy.scrub(stderrCollector.stringValue),
                timedOut: runState.didTimeout,
                launchFailed: false
            )
        }.value

        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        let stdout = outcome.stdout
        let stderr = outcome.stderr
        let status = outcome.exitStatus

        let combined = "exit=\(status)\n--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)"
        let trimmed: String
        if combined.count > maxCommandOutput {
            trimmed = trimDelegatedCommandPayload(combined, maxCharacters: maxCommandOutput)
        } else {
            trimmed = combined
        }

        if status != 0 {
            throw AgentToolError.commandFailed(status, trimmed)
        }

        let firstLine = stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let summary = "exit 0\(firstLine.isEmpty ? "" : ": " + firstLine.prefix(60))"
        return AgentToolResult(summary: summary, payload: trimmed)
    }

    nonisolated static func closeStandardInput(for process: Process) {
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe
    }

    nonisolated static func trimDelegatedCommandPayload(_ raw: String, maxCharacters: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters, maxCharacters > 400 else { return trimmed }
        let headCount = max(200, maxCharacters / 5)
        let tailCount = maxCharacters - headCount - 96
        let headEnd = trimmed.index(trimmed.startIndex, offsetBy: headCount)
        let tailStart = trimmed.index(trimmed.endIndex, offsetBy: -tailCount)
        return """
        \(trimmed[..<headEnd])

        [...middle output truncated; showing final diagnostics below...]

        \(trimmed[tailStart...])
        """
    }

    // MARK: claude_code

    /// Permission modes we forward to `claude -p`. Deliberately NOT
    /// including `bypassPermissions` — headless full-bypass from a
    /// model-initiated tool call is an instruction-injection foot-gun.
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
        model: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "-p", shellQuoted(prompt),
            "--output-format", "text",
            "--permission-mode", permissionMode,
        ]
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        return parts.joined(separator: " ")
    }

    /// Delegate a task to the Claude Code CLI in headless mode. Thin
    /// composer over `runCommand`: builds the `claude -p …` command
    /// line, then rides the exact same foreground/background plumbing
    /// (job registry, output buffers, kill, completion notifications).
    private static func claudeCode(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }

        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "acceptEdits"
        guard claudeCodePermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(claudeCodePermissionModes.sorted().joined(separator: ", "))"
            )
        }

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

        let command = claudeCodeCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue()
        )

        // Claude Code tasks routinely run for minutes. Agent-initiated
        // calls still default to background jobs, but Composer can force
        // foreground and wait for the final response without inheriting
        // the ordinary 120s shell-command ceiling.
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

    // MARK: codex_cli / cursor_agent / cline_cli

    nonisolated static let delegatedAgentForegroundTimeout: TimeInterval = 3600 * 6
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
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func cursorAgentExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "cursor", preferredPaths: [
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

    nonisolated static func executablePath(
        commandName: String,
        preferredPaths: [String],
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            candidates.append(path)
        }

        preferredPaths.forEach(append)
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            append("\(entry)/\(commandName)")
        }
        return candidates.first(where: isExecutable)
    }

    nonisolated static func codexCLICommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
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
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--cd", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
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

    private static func codexCLI(
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
        let command = codexCLICommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    private static func cursorAgent(
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

    private static func clineCLI(
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

    // MARK: list_jobs / get_job_output / kill_job

    // MARK: lark_cli

    private static func larkCLI(
        arguments: [String: AgentJSONValue]
    ) async throws -> AgentToolResult {
        guard let cliArguments = arguments["arguments"]?.stringArrayValue() else {
            throw AgentToolError.missingArgument("arguments")
        }
        let normalized = AgentLarkCLI.normalizedArguments(cliArguments)
        guard !normalized.isEmpty else {
            throw AgentToolError.invalidArgument("arguments must include at least one lark-cli subcommand.")
        }
        return try await AgentLarkCLI.run(
            arguments: normalized,
            timeoutSeconds: arguments["timeout_seconds"]?.intValue()
        )
    }

    /// Snapshot of background jobs for the current runtime. Returns a
    /// stable text format (one job per line) so the model can quote
    /// handles back into `get_job_output` / `kill_job` without parsing
    /// JSON.
    private static func listJobs(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.listJobs()
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            return AgentToolResult(summary: "no jobs", payload: "Background job registry not available in this context.")
        }
        let onlyAlive = arguments["only_alive"]?.boolValue() ?? false
        let allJobs = await MainActor.run { registry.jobs(forRuntime: runtimeID) }
        let filtered = onlyAlive ? allJobs.filter { $0.isAlive } : allJobs
        guard !filtered.isEmpty else {
            return AgentToolResult(
                summary: "no jobs",
                payload: onlyAlive ? "No alive background jobs." : "No background jobs in this session."
            )
        }
        let lines = filtered.map { describe(job: $0) }
        let payload = lines.joined(separator: "\n")
        let aliveCount = filtered.filter { $0.isAlive }.count
        let summary = "\(filtered.count) job\(filtered.count == 1 ? "" : "s") (\(aliveCount) alive)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    private static func getJobOutput(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.getJobOutput(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let tailLines = arguments["tail_lines"]?.intValue()
        let snapshot: (job: AgentBackgroundJob, output: String)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            return (job, registry.output(id: job.id, tailLines: tailLines))
        }
        guard let snapshot else {
            throw AgentJobError.jobNotFound(handle)
        }
        let header = describe(job: snapshot.job)
        let body = snapshot.output.isEmpty ? "(no output captured yet)" : snapshot.output
        return AgentToolResult(
            summary: "\(snapshot.job.displayHandle): \(snapshot.job.status.rawValue)",
            payload: "\(header)\n--- output ---\n\(body)"
        )
    }

    private static func killJob(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.killJob(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let result: (job: AgentBackgroundJob, didSignal: Bool)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            let signaled = registry.kill(id: job.id)
            return (job, signaled)
        }
        guard let result else {
            throw AgentJobError.jobNotFound(handle)
        }
        if result.didSignal {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) killed",
                payload: "Sent SIGTERM to \(result.job.displayHandle) (pid \(result.job.pid)). A completion notice will arrive on the next turn."
            )
        } else {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) not running",
                payload: "\(result.job.displayHandle) was already \(result.job.status.rawValue); nothing to kill."
            )
        }
    }

    private static func describe(job: AgentBackgroundJob) -> String {
        let exit = job.exitCode.map { "exit=\($0)" } ?? "exit=…"
        let durationText = formatDuration(job.duration)
        let trimmedCommand = job.command.count > 100
            ? String(job.command.prefix(100)) + "…"
            : job.command
        return "\(job.displayHandle) [\(job.status.rawValue)] \(exit) · \(durationText) · pid=\(job.pid) · \(trimmedCommand)"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h\(mm)m"
    }

    // MARK: helpers

    private struct CommandOutcome: Sendable {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let launchFailed: Bool
    }

    private nonisolated final class CommandOutputCollector: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private var truncated = false
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        var stringValue: String {
            lock.lock()
            let snapshot = data
            let didTruncate = truncated
            lock.unlock()

            var text = String(data: snapshot, encoding: .utf8) ?? AppState.decodeText(from: snapshot)
            if didTruncate {
                text += "\n...[truncated]"
            }
            return text
        }
    }

    private nonisolated final class CommandRunState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeout: Bool {
            lock.lock()
            let value = timedOut
            lock.unlock()
            return value
        }
    }

    // MARK: show_widget (1.84.0-rc1)

    /// `show_widget` 工具 handler。把模型生成的 HTML 推到
    /// `AgentWidgetRegistry`，由 AppStateAgentLoop 在下一轮 turn 顶部
    /// drain 出来 append `.widget` 消息到 transcript。返回值只是 ack
    /// 字符串（"widget queued"），所以 LLM 不会看到 raw HTML 占用上
    /// 下文。如果调用上下文没有 runtimeID（比如 ad-hoc skill harness
    /// 路径），返回错误让模型知道这条管线在该环境下不可用。
    private static func showWidget(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        guard let html = arguments["html"]?.stringValue(), !html.isEmpty else {
            throw AgentToolError.missingArgument("html")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "show_widget unavailable",
                payload: "show_widget is only available in conversational agent runtimes (no runtime id in this call context)."
            )
        }
        let bytes = html.utf8.count
        if bytes > 1_048_576 {
            return AgentToolResult(
                summary: "Refused (>1 MB)",
                payload: "show_widget refused: html payload is \(bytes) bytes (>1 MB). Trim it down or split into multiple widgets."
            )
        }
        let widget = AgentWidget(title: title, html: html)
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        }
        let kbLabel = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        return AgentToolResult(
            summary: "Queued widget: \(title)",
            payload: "widget queued: \"\(title)\" (\(kbLabel)) — will appear in the transcript at the start of the next turn."
        )
    }

    // MARK: run_workflow (1.84.0-rc2)

    /// Agent 自己派 workflow（无需用户 slash 命令）。handler 通过
    /// `AppState.startWorkflow` 走和 composer slash 同款入口 ——
    /// AppState 创建 .workflowReport message + 起后台 Task 跑
    /// WorkflowEngine。本工具返回简短 ack；后续 turn 顶部 LLM 自然能在
    /// transcript 里读到 workflow card 的 summary。
    private static func runWorkflow(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let name = arguments["workflow_name"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AgentToolError.missingArgument("workflow_name")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "run_workflow unavailable",
                payload: "run_workflow is only available in conversational agent runtimes."
            )
        }
        let normalizedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard let workflow = await MainActor.run(body: {
            WorkflowRegistry.find(name: normalizedName)
                ?? WorkflowRegistry.find(slashCommand: "/\(normalizedName)")
        }) else {
            let known = await MainActor.run { WorkflowRegistry.all.map { $0.name }.joined(separator: ", ") }
            return AgentToolResult(
                summary: "Unknown workflow",
                payload: "Unknown workflow `\(name)`. Available: \(known)."
            )
        }
        let args = arguments["args"]?.stringValue() ?? ""
        let result = await MainActor.run { () -> (Bool, String) in
            // 用 runtime 自己的 startWorkflow 路径 —— 它会找到该 runtime
            // 的 messages / 状态并塞 workflow card 进去。
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return (false, "no app state for runtime \(runtimeID)")
            }
            let claimed = appState.startWorkflow(slashCommand: workflow.slashCommand, args: args)
            return (claimed, claimed ? "started" : "could not start (workflow rejected args)")
        }
        if result.0 {
            let argsHint = args.isEmpty ? "" : " with args: \(args)"
            return AgentToolResult(
                summary: "Started \(workflow.displayTitle)",
                payload: "workflow `\(workflow.name)` queued\(argsHint). Card will appear in the transcript with live agent counts; final report joins the transcript when synthesize finishes."
            )
        }
        return AgentToolResult(
            summary: "Failed to start \(workflow.displayTitle)",
            payload: "Could not start workflow `\(workflow.name)`: \(result.1)."
        )
    }

}
