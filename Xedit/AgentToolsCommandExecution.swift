//
//  AgentToolsCommandExecution.swift
//  WillDeep
//
//  AgentToolRunner 的 run_command 执行路径：本地命令环境、前台/后台执行，
//  以及输出收集与取消控制的内部辅助类型。自 AgentTools.swift 拆出，行为不变。
//

import Foundation

extension AgentToolRunner {
    // MARK: run_command

    // 20s/120s starved real builds and test runs: the command got killed,
    // the model retried with a bigger timeout_seconds, and every retry cost
    // a full model round trip. 60s absorbs typical lint/test/build steps;
    // long jobs should still go through run_in_background.
    nonisolated private static let defaultCommandTimeout: TimeInterval = 60
    nonisolated private static let maxCommandTimeout: TimeInterval = 600
    nonisolated private static let maxCommandOutput = 32 * 1024
    nonisolated static let supplementalCommandPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        // User-local install prefixes. When the app is launched from
        // Finder/Dock it inherits the minimal launchd PATH, so delegated
        // CLIs (claude/codex/cursor/cline) and the child processes they
        // fork — node, uv, python, git — can't find tools installed here.
        // We resolve the four agent executables by absolute path already,
        // but their children still need these on PATH.
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.cargo/bin",
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

    static func localCommandEnvironment(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        settings: EditorTerminalSettings
    ) -> [String: String] {
        EditorTerminalLaunchEnvironment.variables(
            from: shellEnvironment(from: base),
            settings: settings,
            injectClaudeCodeCompatibility: false,
            markAsAgentTerminal: true
        )
    }

    static func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval = maxCommandTimeout
    ) async throws -> AgentToolResult {
        // `monitor` arrives here already authorized as this very command.
        if AgentMonitorTool.isMonitorInvocation(arguments) {
            return try await AgentMonitorTool.start(arguments: arguments, context: context)
        }
        var effectiveArguments = arguments
        let selectedBackgroundAutomatically =
            arguments["run_in_background"] == nil
            && AgentRunCommandExecutionPolicy.shouldRunInBackground(arguments: arguments)
        if selectedBackgroundAutomatically {
            effectiveArguments["run_in_background"] = .bool(true)
        }
        if let backend = context.remoteBackend {
            return try await backend.runCommand(
                arguments: effectiveArguments,
                context: context,
                foregroundMaxTimeout: foregroundMaxTimeout
            )
        }
        let root = context.rootDirectory?.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let command = effectiveArguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let timeoutArg = effectiveArguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))

        // Background path: hand the Process off to the registry, return
        // immediately with the job handle, let the agent loop pull the
        // completion event at the top of a later turn.
        let wantsBackground = effectiveArguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let inferredActivity = AgentRunCommandExecutionPolicy.inferredActivityKind(for: command)
            let requestedLifetime: AgentBackgroundJobLifetime?
            if let rawLifetime = effectiveArguments["lifetime"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(), !rawLifetime.isEmpty {
                guard let parsed = AgentBackgroundJobLifetime(rawValue: rawLifetime) else {
                    throw AgentToolError.invalidArgument("lifetime must be turn, phase, goal, or persistent")
                }
                requestedLifetime = parsed
            } else {
                requestedLifetime = nil
            }
            var jobLifetime = requestedLifetime
                ?? (inferredActivity == .server
                    ? (context.goalPhaseID == nil ? .persistent : .phase)
                    : .turn)
            if jobLifetime == .phase, context.goalPhaseID == nil {
                jobLifetime = context.isGoalMode ? .goal : .turn
            }
            let bgTimeout: Double? = effectiveArguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let job: AgentBackgroundJob
            do {
                job = try await MainActor.run {
                    try registry.start(
                        command: command,
                        workingDirectory: root,
                        additionalWorkspaceRoots: Array(context.workspaceRoots.dropFirst()),
                        runtimeID: runtimeID,
                        turnID: context.turnID,
                        timeoutSeconds: bgTimeout,
                        sandboxMode: context.sandboxMode,
                        environment: context.localCommandEnvironment,
                        displayCommand: AgentSecretStore.redact(command, secretValues: context.secretRedactionValues),
                        secretRedactionValues: context.secretRedactionValues,
                        lifetime: jobLifetime,
                        goalPhaseID: jobLifetime == .phase ? context.goalPhaseID : nil,
                        survivesTurnStop: requestedLifetime == .persistent,
                        label: effectiveArguments["label"]?.stringValue(),
                        automaticSandboxRetryApprovalSource: context
                            .automaticBackgroundSandboxRetryApprovalSource
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgentToolError.commandFailed(
                    -1,
                    AgentSecretStore.redact(error.localizedDescription, secretValues: context.secretRedactionValues)
                )
            }
            let cwd = job.workingDirectoryPath ?? root.path
            let timeoutLine = bgTimeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            let selectionLine = selectedBackgroundAutomatically
                ? "\nBackground mode: selected automatically for this test/build/server command."
                : ""
            let lifetimeLine = "\nLifetime: \(job.lifetime.rawValue)"
            let payload = """
            Started background job \(job.displayHandle).
            Command: \(AgentSecretStore.redact(command, secretValues: context.secretRedactionValues))
            PID: \(job.pid)
            cwd: \(cwd)\(timeoutLine)\(selectionLine)\(lifetimeLine)

            The job is running. You will receive a `<background-task-notification>` system message at the start of a later turn when it finishes (or fails). Until then, call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop it.
            """
            let activityLabel = effectiveArguments["label"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = activityLabel.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
                ?? AgentRunCommandExecutionPolicy.inferredActivityKind(for: command)?.operationName
                ?? job.displayHandle
            return AgentToolResult(
                summary: "▶ \(summary) · \(job.displayHandle)",
                payload: payload
            )
        }

        try Task.checkCancellation()
        let cancellationController = ForegroundCommandCancellationController()
        let commandTask = Task.detached(priority: .userInitiated) { () -> CommandOutcome in
            let process = Process()
            defer { cancellationController.clear(process) }
            let launch = AgentSandboxPolicy.shellLaunch(
                command: command,
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory,
                additionalWorkspaceRoots: Array(context.workspaceRoots.dropFirst())
            )
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.currentDirectoryURL = root
            let baseEnvironment = context.localCommandEnvironment ?? shellEnvironment()
            var environment = AgentSandboxPolicy.sandboxedEnvironment(
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory,
                command: command,
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
            do {
                try process.run()
                cancellationController.bind(process)
            } catch {
                // Do not start pipe readers until launch succeeds. A failed
                // Process.run() leaves no producer behind; closing a handle
                // while readDataToEndOfFile() is already running can raise an
                // Objective-C NSFileHandleOperationException, which bypasses
                // Swift error handling and crashes the entire app/test host.
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                return CommandOutcome(
                    exitStatus: -1,
                    stdout: "",
                    stderr: AgentSecretStore.redact(error.localizedDescription, secretValues: context.secretRedactionValues),
                    timedOut: false,
                    launchFailed: true
                )
            }
            let stdoutDrain = Task.detached(priority: .utility) {
                stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
            let stderrDrain = Task.detached(priority: .utility) {
                stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }

            let timeoutWorkItem = DispatchWorkItem {
                runState.markTimedOut()
                if process.isRunning {
                    AgentProcessSupport.terminateProcessTree(process)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            await AgentProcessSupport.waitUntilExit(process)
            timeoutWorkItem.cancel()
            await stdoutDrain.value
            await stderrDrain.value

            return CommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: AgentSecretStore.redact(
                    AgentSandboxPolicy.scrub(stdoutCollector.stringValue),
                    secretValues: context.secretRedactionValues
                ),
                stderr: AgentSecretStore.redact(
                    AgentSandboxPolicy.scrub(stderrCollector.stringValue),
                    secretValues: context.secretRedactionValues
                ),
                timedOut: runState.didTimeout,
                launchFailed: false
            )
        }
        let outcome = await withTaskCancellationHandler {
            await commandTask.value
        } onCancel: {
            commandTask.cancel()
            cancellationController.cancel()
        }
        try Task.checkCancellation()

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
        return AgentToolResult(summary: summary, payload: trimmed, commandExitCode: status)
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

    /// Bridges structured Task cancellation to Foundation.Process. Without
    /// this, stopping an Agent turn only cancelled the awaiter while the shell
    /// kept running until its timeout and continued consuming resources.
    private nonisolated final class ForegroundCommandCancellationController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        func bind(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel {
                terminate(process)
            }
        }

        func clear(_ process: Process) {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let process = process
            lock.unlock()
            if let process {
                terminate(process)
            }
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            AgentProcessSupport.terminateProcessTree(process)
        }
    }
}
