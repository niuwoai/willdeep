//
//  AgentRemoteRuntime.swift
//  WillDeep
//
//  Runtime backends let Agent tools execute against either the local
//  workspace or a configured remote host. SSH uses the user's existing
//  OpenSSH config; daemon runtimes use short bearer tokens stored in
//  Keychain by AgentRemoteRuntimeModels.swift.
//

import Foundation
import Darwin

protocol AgentRemoteRuntimeBackend {
    var descriptor: RuntimeDescriptor { get }
    func probe() async throws -> RuntimeDescriptor
    func searchFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult
    func grepFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult
    func readFile(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult
    func listDirectory(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult
    func gitStatus() async throws -> AgentToolResult
    func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval
    ) async throws -> AgentToolResult
}

struct SSHRuntimeBackend: AgentRemoteRuntimeBackend {
    let descriptor: RuntimeDescriptor

    private let defaultTimeout: TimeInterval = 20
    /// run_command default only. Internal probes (git status, workspace
    /// checks) stay on the shorter `defaultTimeout` so a hung host fails fast.
    private let defaultCommandTimeout: TimeInterval = 60
    private let maxForegroundTimeout: TimeInterval = 120
    private let maxOutputBytes = 32 * 1024

    func probe() async throws -> RuntimeDescriptor {
        let command = """
        wd_val() { if command -v "$1" >/dev/null 2>&1; then shift; "$@" 2>/dev/null | head -n 1; fi; }
        wd_cfg() { "$@" 2>/dev/null | head -n 1 | sed 's/^undefined$//;s/^null$//'; }
        printf '__willdeep_probe_v2__\\n'
        printf 'platform=%s\\n' "$(uname -s 2>/dev/null || true)"
        printf 'arch=%s\\n' "$(uname -m 2>/dev/null || true)"
        printf 'pwd=%s\\n' "$(pwd 2>/dev/null || true)"
        printf 'git=%s\\n' "$(command -v git 2>/dev/null || true)"
        printf 'rg=%s\\n' "$(command -v rg 2>/dev/null || true)"
        printf 'shell=%s\\n' "$(command -v bash 2>/dev/null || command -v sh 2>/dev/null || true)"
        printf 'node=%s\\n' "$(wd_val node node --version)"
        printf 'npm=%s\\n' "$(wd_val npm npm --version)"
        printf 'yarn=%s\\n' "$(wd_val yarn yarn --version)"
        printf 'python=%s\\n' "$(python3 --version 2>/dev/null | head -n 1 || python --version 2>/dev/null | head -n 1 || true)"
        printf 'pip=%s\\n' "$(pip3 --version 2>/dev/null | head -n 1 || pip --version 2>/dev/null | head -n 1 || true)"
        printf 'ruby=%s\\n' "$(wd_val ruby ruby --version)"
        printf 'go=%s\\n' "$(wd_val go go version)"
        printf 'java=%s\\n' "$(java -version 2>&1 | head -n 1 || true)"
        printf 'gh=%s\\n' "$(wd_val gh gh --version)"
        printf 'gh_auth=%s\\n' "$(if command -v gh >/dev/null 2>&1; then gh auth status 2>&1 | head -n 1; fi)"
        printf 'agent_claude=%s\\n' "$(command -v claude 2>/dev/null || true)"
        printf 'agent_codex=%s\\n' "$(command -v codex 2>/dev/null || true)"
        printf 'agent_cursor=%s\\n' "$(command -v cursor-agent 2>/dev/null || command -v cursor 2>/dev/null || true)"
        printf 'agent_cline=%s\\n' "$(command -v cline 2>/dev/null || true)"
        printf 'agent_opencode=%s\\n' "$(command -v opencode 2>/dev/null || true)"
        printf 'npm_registry=%s\\n' "$(wd_cfg npm config get registry)"
        printf 'npm_proxy=%s\\n' "$(wd_cfg npm config get proxy)"
        printf 'npm_https_proxy=%s\\n' "$(wd_cfg npm config get https-proxy)"
        printf 'yarn_registry=%s\\n' "$(wd_cfg yarn config get npmRegistryServer || wd_cfg yarn config get registry)"
        printf 'pip_proxy=%s\\n' "$(wd_cfg pip3 config get global.proxy || wd_cfg pip config get global.proxy || true)"
        printf 'env_http_proxy=%s\\n' "${http_proxy:-${HTTP_PROXY:-}}"
        printf 'env_https_proxy=%s\\n' "${https_proxy:-${HTTPS_PROXY:-}}"
        printf 'env_no_proxy=%s\\n' "${no_proxy:-${NO_PROXY:-}}"
        """
        let outcome = await runSSH(remoteCommand: command, timeout: defaultTimeout)
        try throwIfFailed(outcome)
        let lines = outcome.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "__willdeep_probe_v2__" else {
            throw AgentToolError.commandFailed(-1, "Unexpected SSH probe response.")
        }
        let fields = parseProbeFields(lines.dropFirst())
        var updated = descriptor.normalized
        updated.platform = RuntimePlatform.parse(fields["platform"] ?? "")
        updated.arch = RuntimeArch.parse(fields["arch"] ?? "")
        updated.capabilities = RuntimeCapabilities(
            hasGit: nonEmpty(fields["git"]) != nil,
            hasRipgrep: nonEmpty(fields["rg"]) != nil,
            shellPath: nonEmpty(fields["shell"]),
            nodeVersion: nonEmpty(fields["node"]),
            npmVersion: nonEmpty(fields["npm"]),
            yarnVersion: nonEmpty(fields["yarn"]),
            pythonVersion: nonEmpty(fields["python"]),
            pipVersion: nonEmpty(fields["pip"]),
            rubyVersion: nonEmpty(fields["ruby"]),
            goVersion: nonEmpty(fields["go"]),
            javaVersion: nonEmpty(fields["java"]),
            ghVersion: nonEmpty(fields["gh"]),
            ghAuthStatus: nonEmpty(fields["gh_auth"]),
            npmRegistry: nonEmpty(fields["npm_registry"]),
            yarnRegistry: nonEmpty(fields["yarn_registry"]),
            npmProxy: redactedOptionalProxy(fields["npm_proxy"]),
            npmHTTPSProxy: redactedOptionalProxy(fields["npm_https_proxy"]),
            pipProxy: redactedOptionalProxy(fields["pip_proxy"]),
            proxyEnvironment: [
                "http_proxy": redactedOptionalProxy(fields["env_http_proxy"]),
                "https_proxy": redactedOptionalProxy(fields["env_https_proxy"]),
                "no_proxy": nonEmpty(fields["env_no_proxy"])
            ].compactMapValues { $0 },
            agentCLIPaths: [
                AgentExecutionAgent.claudeCode.rawValue: nonEmpty(fields["agent_claude"]),
                AgentExecutionAgent.codexCLI.rawValue: nonEmpty(fields["agent_codex"]),
                AgentExecutionAgent.cursorAgent.rawValue: nonEmpty(fields["agent_cursor"]),
                AgentExecutionAgent.clineCLI.rawValue: nonEmpty(fields["agent_cline"]),
                AgentExecutionAgent.openCode.rawValue: nonEmpty(fields["agent_opencode"]),
            ].compactMapValues { $0 }
        )
        updated.lastProbeAt = Date()
        return updated
    }

    func searchFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let query = try requiredString("query", in: arguments)
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), 200)
        let path = try RemotePathValidator.relativePath(arguments["path"]?.stringValue(), workspaceRoot: descriptor.defaultWorkspacePath)
        let command = [
            "rg",
            "--line-number",
            "--no-heading",
            "--color", "never",
            "-i",
            "-F",
            AgentToolRunner.shellQuoted(query),
            AgentToolRunner.shellQuoted(path)
        ].joined(separator: " ") + " | head -n \(limit)"
        let payload = try await runWorkspaceCommand(command, timeout: defaultTimeout, allowNonZeroNoOutput: true)
        let count = payload.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): \(count) match\(count == 1 ? "" : "es") for \"\(query)\"",
            payload: payload.isEmpty ? "No matches found for \"\(query)\" on \(descriptor.displayName)." : payload
        )
    }

    func grepFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let pattern = try requiredString("pattern", in: arguments)
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), 200)
        let path = try RemotePathValidator.relativePath(arguments["path"]?.stringValue(), workspaceRoot: descriptor.defaultWorkspacePath)
        var parts = [
            "rg",
            "--line-number",
            "--no-heading",
            "--color", "never"
        ]
        if arguments["case_sensitive"]?.rawAny as? Bool != true {
            parts.append("-i")
        }
        if let include = arguments["include"]?.stringValue(), !include.isEmpty {
            parts += ["--glob", AgentToolRunner.shellQuoted(include)]
        }
        parts += [AgentToolRunner.shellQuoted(pattern), AgentToolRunner.shellQuoted(path)]
        let payload = try await runWorkspaceCommand(parts.joined(separator: " ") + " | head -n \(limit)", timeout: defaultTimeout, allowNonZeroNoOutput: true)
        let count = payload.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): \(count) match\(count == 1 ? "" : "es") for /\(pattern)/",
            payload: payload.isEmpty ? "No matches found for /\(pattern)/ on \(descriptor.displayName)." : payload
        )
    }

    func readFile(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let path = try requiredString("path", in: arguments)
        let requested = arguments["max_bytes"]?.intValue() ?? 64 * 1024
        let limit = max(1, min(requested, 256 * 1024))
        let relative = try RemotePathValidator.relativePath(path, workspaceRoot: descriptor.defaultWorkspacePath)
        let command = "test -f \(AgentToolRunner.shellQuoted(relative)) && head -c \(limit + 1) \(AgentToolRunner.shellQuoted(relative)) | base64"
        let base64Text = try await runWorkspaceCommand(command, timeout: defaultTimeout, allowNonZeroNoOutput: false)
        let compact = base64Text.replacingOccurrences(of: "\n", with: "")
        let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) ?? Data()
        let truncated = data.count > limit
        let usable = truncated ? data.prefix(limit) : data
        let text = String(data: usable, encoding: .utf8) ?? AppState.decodeText(from: Data(usable))
        var numbered: [String] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            numbered.append(String(format: "%5d  %@", lineNumber, String(line)))
        }
        if truncated {
            numbered.append("...[truncated, read \(limit) bytes]")
        }
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): \(path) (\(lineNumber) line\(lineNumber == 1 ? "" : "s"))",
            payload: numbered.joined(separator: "\n")
        )
    }

    func listDirectory(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let rawPath = arguments["path"]?.stringValue() ?? "."
        let relative = try RemotePathValidator.relativePath(rawPath, workspaceRoot: descriptor.defaultWorkspacePath)
        let command = "test -d \(AgentToolRunner.shellQuoted(relative)) && LC_ALL=C ls -la \(AgentToolRunner.shellQuoted(relative)) | sed -n '1,400p'"
        let payload = try await runWorkspaceCommand(command, timeout: defaultTimeout, allowNonZeroNoOutput: false)
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): \(rawPath.isEmpty ? "." : rawPath)",
            payload: payload.isEmpty ? "(empty directory)" : payload
        )
    }

    func gitStatus() async throws -> AgentToolResult {
        let payload = try await runWorkspaceCommand("git status --porcelain=v1 -b", timeout: defaultTimeout, allowNonZeroNoOutput: false)
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let branchLine = lines.first ?? "## detached"
        let changes = max(0, lines.filter { !$0.isEmpty }.count - 1)
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): \(branchLine.replacingOccurrences(of: "## ", with: "")), \(changes) change\(changes == 1 ? "" : "s")",
            payload: payload.isEmpty ? "Remote Git status returned no output." : payload
        )
    }

    func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval
    ) async throws -> AgentToolResult {
        let command = try requiredString("command", in: arguments)
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))
        let remoteCommand = workspaceWrappedCommand(command)

        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let inferredActivity = AgentRunCommandExecutionPolicy.inferredActivityKind(for: command)
            let requestedLifetime: AgentBackgroundJobLifetime?
            if let rawLifetime = arguments["lifetime"]?.stringValue()?
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
            let bgTimeout: Double? = arguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let sshCommand = sshShellCommand(remoteCommand: remoteCommand)
            let job = try await MainActor.run {
                try registry.start(
                    command: sshCommand,
                    workingDirectory: nil,
                    runtimeID: runtimeID,
                    turnID: context.turnID,
                    timeoutSeconds: bgTimeout,
                    runtimeDisplayName: descriptor.displayName,
                    runtimeIDForDisplay: descriptor.id,
                    lifetime: jobLifetime,
                    goalPhaseID: jobLifetime == .phase ? context.goalPhaseID : nil
                )
            }
            let timeoutLine = bgTimeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            let payload = """
            Started remote background job \(job.displayHandle).
            Runtime: \(descriptor.displayName) (\(descriptor.sshTarget))
            Command: \(command)
            Local SSH PID: \(job.pid)
            cwd: \(descriptor.defaultWorkspacePath)\(timeoutLine)

            The job is running through SSH. You will receive a `<background-task-notification>` system message when it finishes.
            """
            return AgentToolResult(summary: "▶ \(job.displayHandle) started on \(descriptor.displayName)", payload: payload)
        }

        let outcome = await runSSH(remoteCommand: remoteCommand, timeout: timeout)
        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        let combined = trimOutput("runtime=\(descriptor.displayName)\nexit=\(outcome.exitStatus)\n--- stdout ---\n\(outcome.stdout)\n--- stderr ---\n\(outcome.stderr)")
        if outcome.exitStatus != 0 {
            throw AgentToolError.commandFailed(outcome.exitStatus, combined)
        }
        let firstLine = outcome.stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return AgentToolResult(
            summary: "remote \(descriptor.displayName): exit 0\(firstLine.isEmpty ? "" : ": " + firstLine.prefix(60))",
            payload: combined
        )
    }

    func workspaceWrappedCommand(_ command: String) -> String {
        "cd \(AgentToolRunner.shellQuoted(descriptor.defaultWorkspacePath)) && \(command)"
    }

    func sshShellCommand(remoteCommand: String) -> String {
        (["/usr/bin/ssh"] + sshArguments(remoteCommand: remoteCommand))
            .map(AgentToolRunner.shellQuoted)
            .joined(separator: " ")
    }

    private func runWorkspaceCommand(_ command: String, timeout: TimeInterval, allowNonZeroNoOutput: Bool) async throws -> String {
        let outcome = await runSSH(remoteCommand: workspaceWrappedCommand(command), timeout: timeout)
        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        if outcome.exitStatus != 0 {
            if allowNonZeroNoOutput, outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ""
            }
            throw AgentToolError.commandFailed(outcome.exitStatus, trimOutput("exit=\(outcome.exitStatus)\n--- stdout ---\n\(outcome.stdout)\n--- stderr ---\n\(outcome.stderr)"))
        }
        return outcome.stdout
    }

    private func runSSH(remoteCommand: String, timeout: TimeInterval) async -> SSHCommandOutcome {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(remoteCommand: remoteCommand)
            process.environment = AgentToolRunner.shellEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            AgentToolRunner.closeStandardInput(for: process)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdoutCollector = SSHCommandOutputCollector(limit: maxOutputBytes)
            let stderrCollector = SSHCommandOutputCollector(limit: maxOutputBytes)
            let runState = SSHCommandRunState()

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
                return SSHCommandOutcome(exitStatus: -1, stdout: "", stderr: error.localizedDescription, timedOut: false, launchFailed: true)
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
            if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() {
                stdoutCollector.append(tail)
            }
            if let tail = try? stderrPipe.fileHandleForReading.readToEnd() {
                stderrCollector.append(tail)
            }

            return SSHCommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: stdoutCollector.stringValue,
                stderr: stderrCollector.stringValue,
                timedOut: runState.didTimeout,
                launchFailed: false
            )
        }.value
    }

    private func throwIfFailed(_ outcome: SSHCommandOutcome) throws {
        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        if outcome.exitStatus != 0 {
            throw AgentToolError.commandFailed(outcome.exitStatus, trimOutput(outcome.stderr))
        }
    }

    private func trimOutput(_ value: String) -> String {
        if value.count > maxOutputBytes {
            return String(value.prefix(maxOutputBytes)) + "\n...[truncated]"
        }
        return value
    }

    private func requiredString(_ name: String, in arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private nonisolated func sshArguments(remoteCommand: String) -> [String] {
        var args = ["-o", "BatchMode=yes", "-p", "\(descriptor.port)"]
        if let identityFilePath = descriptor.identityFilePath, !identityFilePath.isEmpty {
            args += ["-i", expandedIdentityFilePath(identityFilePath)]
        }
        args += [descriptor.sshTarget, remoteCommand]
        return args
    }

    private nonisolated func expandedIdentityFilePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func parseProbeFields<S: Sequence>(_ lines: S) -> [String: String] where S.Element == String {
        var fields: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            fields[key] = value
        }
        return fields
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func redactedOptionalProxy(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        return Self.redactProxyCredential(value)
    }

    static func redactProxyCredential(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              components.user != nil || components.password != nil else {
            return value
        }
        components.user = components.user == nil ? nil : "redacted"
        components.password = components.password == nil ? nil : "redacted"
        return components.string ?? value
    }
}

struct DaemonRuntimeBackend: AgentRemoteRuntimeBackend {
    let descriptor: RuntimeDescriptor
    let session: URLSession
    private let tokenOverride: String?
    private let recoveryDelays: [Duration]
    private let slowRecoveryDelay: Duration

    init(descriptor: RuntimeDescriptor, session: URLSession = .shared, tokenOverride: String? = nil,
         recoveryDelays: [Duration] = AgentDaemonRecoveryPolicy.fastDelays,
         slowRecoveryDelay: Duration = AgentDaemonRecoveryPolicy.slowDelay) {
        self.descriptor = descriptor
        self.session = session
        self.tokenOverride = tokenOverride
        self.recoveryDelays = recoveryDelays
        self.slowRecoveryDelay = slowRecoveryDelay
    }

    private let defaultTimeout: TimeInterval = 20
    /// run_command default only; internal probes stay on `defaultTimeout`.
    private let defaultCommandTimeout: TimeInterval = 60
    private let maxForegroundTimeout: TimeInterval = 120
    private let maxOutputBytes = 32 * 1024
    private let exitConfirmationRequestTimeout: TimeInterval = 5

    func probe() async throws -> RuntimeDescriptor {
        let report: DaemonProbeReport = try await request(method: "GET", path: "/v1/probe", query: [])
        var updated = descriptor.normalized
        updated.platform = RuntimePlatform.parse(report.platform)
        updated.arch = RuntimeArch.parse(report.arch)
        updated.defaultWorkspacePath = report.workspace.isEmpty ? updated.defaultWorkspacePath : report.workspace
        updated.capabilities = RuntimeCapabilities(
            hasGit: report.tools["git"] != nil,
            hasRipgrep: report.tools["rg"] != nil,
            shellPath: report.tools["bash"] ?? report.tools["sh"],
            nodeVersion: report.tools["node"],
            npmVersion: report.tools["npm"],
            yarnVersion: report.tools["yarn"],
            pythonVersion: report.tools["python"],
            pipVersion: report.tools["pip"],
            rubyVersion: report.tools["ruby"],
            goVersion: report.tools["go"],
            javaVersion: report.tools["java"],
            ghVersion: report.tools["gh"],
            ghAuthStatus: report.githubCLIAuthLine,
            npmRegistry: report.registries["npm"],
            yarnRegistry: report.registries["yarn"],
            npmProxy: report.proxies["npm_proxy"],
            npmHTTPSProxy: report.proxies["npm_https_proxy"],
            pipProxy: report.proxies["pip_proxy"],
            proxyEnvironment: [
                "http_proxy": report.proxies["http_proxy"],
                "https_proxy": report.proxies["https_proxy"],
                "no_proxy": report.proxies["no_proxy"]
            ].compactMapValues { $0 },
            agentCLIPaths: [
                AgentExecutionAgent.claudeCode.rawValue: report.tools["claude"],
                AgentExecutionAgent.codexCLI.rawValue: report.tools["codex"],
                AgentExecutionAgent.cursorAgent.rawValue: report.tools["cursor-agent"] ?? report.tools["cursor"],
                AgentExecutionAgent.clineCLI.rawValue: report.tools["cline"],
                AgentExecutionAgent.openCode.rawValue: report.tools["opencode"],
            ].compactMapValues { $0 }
        )
        updated.capabilities.supportsIdempotentJobStart = report.idempotentJobStart
        updated.capabilities.supportsStartRequestRecovery = report.startRequestRecovery
        updated.capabilities.supportsMonotonicRunDeadline = report.monotonicRunDeadline
        updated.lastProbeAt = Date()
        return updated
    }

    func searchFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let query = try requiredString("query", in: arguments)
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), 200)
        let path = arguments["path"]?.stringValue() ?? "."
        let response: DaemonSearchData = try await request(
            method: "GET",
            path: "/v1/search",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        let payload = response.matches.joined(separator: "\n")
        return AgentToolResult(
            summary: "daemon \(descriptor.displayName): \(response.matches.count) match\(response.matches.count == 1 ? "" : "es") for \"\(query)\"",
            payload: payload.isEmpty ? "No matches found for \"\(query)\" on \(descriptor.displayName)." : payload
        )
    }

    func grepFiles(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        // The daemon MVP exposes fixed-string search. For regex grep we
        // ask the daemon to execute rg inside the bounded workspace.
        let pattern = try requiredString("pattern", in: arguments)
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), 200)
        let path = try RemotePathValidator.relativePath(arguments["path"]?.stringValue(), workspaceRoot: descriptor.defaultWorkspacePath)
        var parts = ["rg", "--line-number", "--no-heading", "--color", "never"]
        if arguments["case_sensitive"]?.boolValue() != true {
            parts.append("-i")
        }
        if let include = arguments["include"]?.stringValue(), !include.isEmpty {
            parts += ["--glob", AgentToolRunner.shellQuoted(include)]
        }
        parts += [AgentToolRunner.shellQuoted(pattern), AgentToolRunner.shellQuoted(path)]
        return try await runForegroundCommand(
            parts.joined(separator: " ") + " | head -n \(limit)",
            summaryPrefix: "daemon \(descriptor.displayName): grep"
        )
    }

    func readFile(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let path = try requiredString("path", in: arguments)
        let response: DaemonReadData = try await request(
            method: "GET",
            path: "/v1/fs/read",
            query: [URLQueryItem(name: "path", value: path)]
        )
        let data = Data(base64Encoded: response.contentBase64, options: [.ignoreUnknownCharacters]) ?? Data()
        let requested = arguments["max_bytes"]?.intValue() ?? 64 * 1024
        let limit = max(1, min(requested, 256 * 1024))
        let truncated = data.count > limit
        let usable = truncated ? data.prefix(limit) : data
        let text = String(data: usable, encoding: .utf8) ?? AppState.decodeText(from: Data(usable))
        var numbered: [String] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            numbered.append(String(format: "%5d  %@", lineNumber, String(line)))
        }
        if truncated {
            numbered.append("...[truncated, read \(limit) bytes]")
        }
        return AgentToolResult(
            summary: "daemon \(descriptor.displayName): \(path) (\(lineNumber) line\(lineNumber == 1 ? "" : "s"))",
            payload: numbered.joined(separator: "\n")
        )
    }

    func listDirectory(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let rawPath = arguments["path"]?.stringValue() ?? "."
        let response: DaemonListData = try await request(
            method: "GET",
            path: "/v1/fs/list",
            query: [URLQueryItem(name: "path", value: rawPath)]
        )
        let lines = response.entries.map { entry in
            let label = entry.isDir ? "[dir]" : "[file]"
            return "\(label) \(entry.name)\(entry.isDir ? "/" : " \(entry.size)B")"
        }
        return AgentToolResult(
            summary: "daemon \(descriptor.displayName): \(rawPath) (\(response.entries.count) entr\(response.entries.count == 1 ? "y" : "ies"))",
            payload: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
        )
    }

    func gitStatus() async throws -> AgentToolResult {
        let response: DaemonGitStatusData = try await request(method: "GET", path: "/v1/git/status", query: [])
        let lines = response.status.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let branchLine = lines.first ?? "## detached"
        let changes = max(0, lines.filter { !$0.isEmpty }.count - 1)
        return AgentToolResult(
            summary: "daemon \(descriptor.displayName): \(branchLine.replacingOccurrences(of: "## ", with: "")), \(changes) change\(changes == 1 ? "" : "s")",
            payload: response.status.isEmpty ? "Daemon Git status returned no output." : response.status
        )
    }

    func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval
    ) async throws -> AgentToolResult {
        let command = try requiredString("command", in: arguments)
        var effective = arguments
        effective["run_in_background"] = .bool(arguments["run_in_background"]?.boolValue() ?? false)
        let ownedBackground = effective["run_in_background"]?.boolValue() == true
            && context.jobRegistry != nil && context.runtimeID != nil
        effective["timeout_seconds"] = arguments["timeout_seconds"]
            ?? .number(ownedBackground ? Double(AgentDaemonRunDeadline.maximumCommandSeconds) : defaultCommandTimeout)
        var specification = AgentDaemonExecution(command: command,
            displayCommand: AgentSecretStore.redact(command, secretValues: context.secretRedactionValues))
        try specification.applyCommandOwnership(arguments: arguments, context: context)
        return try await runDaemonExecution(specification: specification, arguments: effective,
            context: context, foregroundMaxTimeout: foregroundMaxTimeout)
    }

    func runExecutor(
        specification: AgentExecutorProcessSpecification,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval
    ) async throws -> AgentToolResult {
        try await runDaemonExecution(specification: AgentDaemonExecution(specification), arguments: arguments,
            context: context, foregroundMaxTimeout: foregroundMaxTimeout)
    }

    private func runDaemonExecution(
        specification: AgentDaemonExecution, arguments: [String: AgentJSONValue],
        context: AgentToolContext, foregroundMaxTimeout: TimeInterval
    ) async throws -> AgentToolResult {
        let registry = await MainActor.run { context.jobRegistry ?? AgentJobRegistry() }
        let runtimeID = context.runtimeID ?? UUID()
        // Without a session owner there is nowhere to deliver a detached
        // result. Match local run_command: keep this call in the foreground.
        let wantsBackground = (arguments["run_in_background"]?.boolValue() ?? true)
            && context.jobRegistry != nil && context.runtimeID != nil
        let timeoutArg = arguments["timeout_seconds"]?.intValue()
            ?? Int(foregroundMaxTimeout)
        let maximum = wantsBackground ? 3600 * 6 : min(3600 * 6, max(1, Int(foregroundMaxTimeout)))
        let timeout = min(max(timeoutArg, 1), maximum)
        try await registry.checkTurnAdmission(runtimeID: runtimeID, turnID: context.turnID)
        let preparation = await MainActor.run { () -> AgentDaemonStartPreparation? in
            guard descriptor.capabilities.supportsStartRequestRecovery == true,
                  descriptor.capabilities.supportsIdempotentJobStart == true,
                  let registry = context.jobRegistry, context.runtimeID != nil else { return nil }
            return AgentDaemonStartPreparation(journal: registry.daemonStartJournal)
        }
        let job: DaemonJobData
        do {
            job = try await startWithRequestReceipt(body: specification.startBody(timeout: timeout), context: context,
                onPrepared: { instance, key, serverDeadline in
                    guard let preparation, let runtimeID = context.runtimeID else { return }
                    try await checkStartAdmission(context)
                    let created = Date()
                    let deadline = min(created.addingTimeInterval(Double(timeout)), context.executionBudget?.deadline ?? .distantFuture)
                    var receipt = AgentDaemonStartReceipt(id: UUID(), runtimeID: runtimeID, turnID: context.turnID,
                        remoteRuntimeID: descriptor.id,
                        endpointFingerprint: AgentDaemonStartReceipt.fingerprint(descriptor.daemonEndpointURL?.absoluteString ?? ""),
                        workspaceFingerprint: AgentDaemonStartReceipt.fingerprint(descriptor.defaultWorkspacePath),
                        instanceID: instance, requestID: key, executor: specification.executor,
                        createdAt: created, deadline: deadline, publishesCompletion: wantsBackground)
                    receipt.serverDeadlineElapsedMilliseconds = serverDeadline
                    if specification.executor == nil {
                        receipt.isCommand = true
                        receipt.lifetime = specification.lifetime
                        receipt.goalPhaseID = specification.goalPhaseID
                        receipt.survivesTurnStop = specification.survivesTurnStop
                    }
                    try await preparation.prepare(receipt)
                })
        } catch {
            if let receipt = await preparation?.receipt {
                // POST may have committed even when cancellation won locally.
                // Attach recovery under the original owner, then preserve the caller error.
                let isRecoverable = error is AgentDaemonStartUncertainError && !Task.isCancelled
                let awaitsExit = isRecoverable && !wantsBackground
                do {
                    let recovered = try await runManagedExecutor(remoteJob: .init(id: receipt.jobID, command: "", cwd: descriptor.defaultWorkspacePath,
                            pid: nil, exitCode: nil), specification: specification, registry: registry,
                        runtimeID: receipt.runtimeID, turnID: receipt.turnID, timeout: timeout,
                        wantsBackground: !awaitsExit, secretRedactionValues: context.secretRedactionValues,
                        startReceipt: receipt, recoveryOnly: true)
                    if isRecoverable {
                        try Task.checkCancellation()
                        if awaitsExit { return recovered }
                        return AgentToolResult(summary: L10n.JobReceipt.reconnecting,
                            payload: "job_\(receipt.id.uuidString.prefix(6).lowercased()): \(L10n.JobReceipt.unconfirmed)")
                    }
                } catch {
                    if awaitsExit || Task.isCancelled { throw error }
                    await registry.recordRemoteMonitoringFailure(id: receipt.id, detail: AgentSecretStore.redact(
                        error.localizedDescription, secretValues: context.secretRedactionValues))
                }
            }
            throw error
        }
        return try await runManagedExecutor(
                remoteJob: job,
                specification: specification,
                registry: registry,
                runtimeID: runtimeID,
                turnID: context.turnID,
                timeout: timeout,
                wantsBackground: wantsBackground,
                secretRedactionValues: context.secretRedactionValues,
                startReceipt: await preparation?.receipt
        )
    }

    private func runManagedExecutor(
        remoteJob: DaemonJobData,
        specification: AgentDaemonExecution,
        registry: AgentJobRegistry,
        runtimeID: UUID,
        turnID: UUID?,
        timeout: Int,
        wantsBackground: Bool,
        secretRedactionValues: [String],
        startReceipt: AgentDaemonStartReceipt? = nil,
        recoveryOnly: Bool = false,
        restoredCancellation: Bool = false,
        statusOnlyRecovery: Bool = false
    ) async throws -> AgentToolResult {
        let localJobID = startReceipt?.id ?? UUID()
        if startReceipt != nil, !(await registry.claimDaemonStartReceipt(localJobID)) {
            return AgentToolResult(summary: L10n.JobReceipt.reconnecting, payload: localJobID.uuidString)
        }
        let (localJob, monitor) = await MainActor.run {
            let remaining = startReceipt.map { max(0, $0.deadline.timeIntervalSinceNow) } ?? Double(timeout)
            let monitor = AgentDaemonJobMonitor(registry: registry, jobID: localJobID,
                monitoringDuration: .seconds(remaining) + AgentDaemonRecoveryPolicy.cleanupWindow, fastDelays: recoveryDelays,
                slowDelay: slowRecoveryDelay,
                stream: { [weak registry] cursor in
                    // Original per-request redaction values were deliberately
                    // not persisted. Do not replay raw logs into a new model context.
                    if statusOnlyRecovery { throw AgentDaemonEventCursor.ProtocolFailure.capabilityLost }
                    guard let registry else { throw CancellationError() }
                    return try await streamExecutorEvents(remoteJobID: remoteJob.id,
                        specification: specification, registry: registry, localJobID: localJobID,
                        secretRedactionValues: secretRedactionValues, cursorStore: cursor).exitCode
                }, lookup: {
                    if let startReceipt {
                        let resolved = try await reconcileStart(startReceipt)
                        guard let code = resolved?.exitCode else { return nil }
                        guard let exact = Int32(exactly: code) else { throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence }
                        if resolved?.timedOut == true { await registry.recordRemoteTimeout(id: localJobID) }
                        return exact
                    }
                    let latest: DaemonJobData = try await request(method: "GET", path: "/v1/run/jobs/\(remoteJob.id)",
                        query: [], timeoutSeconds: exitConfirmationRequestTimeout)
                    guard latest.id == remoteJob.id else { throw AgentJobError.jobNotFound(remoteJob.id) }
                    guard let code = latest.exitCode else { return nil }
                    guard let exact = Int32(exactly: code) else { throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence }
                    if latest.timedOut == true { await registry.recordRemoteTimeout(id: localJobID) }
                    return exact
                }, cancel: {
                    if let startReceipt, try await reconcileStart(startReceipt) == nil { return false }
                    let result: DaemonKillData = try await request(method: "DELETE", path: "/v1/run/jobs/\(remoteJob.id)",
                        query: [], timeoutSeconds: exitConfirmationRequestTimeout)
                    return result.killed
                }, describeError: { error in
                    AgentSecretStore.redact(error.localizedDescription, secretValues: secretRedactionValues)
                }, persistTerminal: { code in
                    if let startReceipt { try registry.persistDaemonTerminal(startReceipt, exitCode: code) }
                })
            let job = registry.registerManagedExecutor(
                id: localJobID,
                executor: specification.executor,
                displayCommand: specification.executor.map { "\($0.rawValue) via \(descriptor.displayName)" }
                    ?? specification.displayCommand,
                workingDirectory: specification.workingDirectory
                    ?? URL(fileURLWithPath: descriptor.defaultWorkspacePath),
                runtimeID: runtimeID,
                turnID: turnID,
                timeoutSeconds: statusOnlyRecovery && startReceipt?.serverDeadlineElapsedMilliseconds != nil
                    ? nil : max(0.001, remaining),
                publishesCompletion: !restoredCancellation && (startReceipt?.publishesCompletion ?? wantsBackground),
                runtimeDisplayName: descriptor.displayName,
                remoteRuntimeID: descriptor.id,
                remotePID: remoteJob.pid.flatMap(Int32.init(exactly:)),
                requiresExitReceipt: true,
                originalStartedAt: startReceipt?.createdAt,
                expiredOnRegistration: startReceipt != nil && remaining <= 0 && !restoredCancellation
                    && startReceipt?.serverDeadlineElapsedMilliseconds == nil,
                lifetime: specification.lifetime,
                goalPhaseID: specification.goalPhaseID,
                survivesTurnStop: specification.survivesTurnStop,
                secretRedactionValues: secretRedactionValues,
                beforeCancellation: {
                    if let startReceipt { try registry.daemonStartJournal.requestCancellation(startReceipt) }
                },
                cancellation: {
                    Task { @MainActor in monitor.requestCancellation() }
                }
            )
            if restoredCancellation { _ = registry.kill(id: localJobID) }
            return (job, monitor)
        }

        guard localJob.isAlive else { throw CancellationError() }
        await monitor.start()
        // Late remote acceptance is tracked and cancelled above even though
        // the stopped caller must not report it as freshly started work.
        if !recoveryOnly { try await registry.checkTurnAdmission(runtimeID: runtimeID, turnID: turnID) }

        if wantsBackground {
            let kind = specification.executor.map { "structured \($0.rawValue)" } ?? "command"
            let transportNote = specification.executor == nil
                ? "Command output is streaming into WillDeep."
                : "The prompt was sent over stdin, outside argv and the shell. Structured daemon events are streaming into WillDeep."
            return AgentToolResult(
                summary: "▶ \(localJob.displayHandle) started on \(descriptor.displayName)",
                payload: """
                Started \(kind) job \(localJob.displayHandle).
                Runtime: \(descriptor.displayName)
                Remote job: \(remoteJob.id)
                Remote PID: \(remoteJob.pid ?? 0)
                cwd: \(remoteJob.cwd)

                \(transportNote) Use `get_job_output`, `list_jobs`, or `kill_job` with local job id `\(localJob.displayHandle)`.
                """
            )
        }

        let completedJob = try await withTaskCancellationHandler {
            try await registry.waitForTerminal(id: localJobID, forRuntime: runtimeID)
        } onCancel: {
            Task { @MainActor in _ = registry.killForStoppedTurn(id: localJobID) }
        }
        await MainActor.run {
            registry.markCompletionSurfaced(id: localJobID, forRuntime: runtimeID)
        }
        let detail = await MainActor.run {
            if specification.executor == nil { return registry.output(id: localJobID, tailLines: nil) }
            let result = registry.executorResultText(id: localJobID)
            return result.isEmpty
                ? registry.output(id: localJobID, tailLines: nil)
                : result
        }
        switch completedJob.status {
        case .completed:
            if specification.executor == nil {
                let prefix = specification.summaryPrefix ?? "daemon \(descriptor.displayName)"
                let output = trimOutput(detail)
                let payload = specification.summaryPrefix == nil
                    ? "runtime=\(descriptor.displayName)\njob=\(localJob.displayHandle)\nexit=0\n--- output ---\n\(output)"
                    : (output.isEmpty ? "(no output)" : output)
                return AgentToolResult(summary: "\(prefix): exit 0", payload: payload)
            }
            let usage = AgentToolRunner.structuredUsageSummary(
                completedJob.executorUsage
            )
            let sessionLine = completedJob.executorSessionID.map {
                "\n\nSession: \($0)"
            } ?? ""
            return AgentToolResult(
                summary: "daemon \(descriptor.displayName): \(specification.executor?.rawValue ?? "command") completed\(usage)",
                payload: detail + sessionLine
            )
        case .timedOut:
            throw AgentToolError.commandTimeout
        case .running:
            throw AgentToolError.commandFailed(
                -1,
                "Daemon executor did not reach a terminal state."
            )
        case .failed, .killed, .launchFailed:
            throw AgentToolError.commandFailed(
                completedJob.exitCode ?? -1,
                detail
            )
        }
    }

    private func streamExecutorEvents(
        remoteJobID: String,
        specification: AgentDaemonExecution,
        registry: AgentJobRegistry,
        localJobID: UUID,
        secretRedactionValues: [String],
        cursorStore: AgentDaemonEventCursorStore
    ) async throws -> DaemonExecutorStreamTerminal {
        var cursor = cursorStore.load()
        defer { cursorStore.save(cursor) }
        var retryIndex = 0
        while true {
            do {
                return try await readExecutorEventStream(remoteJobID: remoteJobID,
                    specification: specification, registry: registry, localJobID: localJobID,
                    secretRedactionValues: secretRedactionValues, cursor: &cursor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                guard cursor.supportsResume, retryIndex < recoveryDelays.count,
                      !(error is AgentDaemonEventCursor.ProtocolFailure) else { throw error }
                if case AgentToolError.httpFailed(let code, _) = error,
                   (400..<500).contains(code), code != 408, code != 429 { throw error }
                try await Task.sleep(for: recoveryDelays[retryIndex])
                retryIndex += 1
            }
        }
    }

    private func readExecutorEventStream(remoteJobID: String,
        specification: AgentDaemonExecution, registry: AgentJobRegistry,
        localJobID: UUID, secretRedactionValues: [String],
        cursor: inout AgentDaemonEventCursor) async throws -> DaemonExecutorStreamTerminal {
        let request = try eventStreamRequest(jobID: remoteJobID, after: cursor.after)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AgentToolError.httpFailed(
                status,
                "Daemon event stream failed."
            )
        }
        try cursor.negotiate(resumable: (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-Job-Event-Cursor") == "1")
        await registry.recordRemoteRecovery(id: localJobID, recovering: false)
        var terminal: DaemonExecutorStreamTerminal?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(
                in: .whitespaces
            )
            guard let data = json.data(using: .utf8),
                  let event = try? JSONDecoder.willdeepDaemon.decode(
                    DaemonJobEventData.self,
                    from: data
                  ) else {
                // EOF may truncate the final JSON line. The cursor has not
                // advanced, so a capable daemon can replay it safely.
                throw AgentJobError.exitUnconfirmed(remoteJobID, L10n.JobReceipt.unconfirmed)
            }
            let admission = try cursor.accept(jobID: event.jobID, expectedJobID: remoteJobID,
                sequence: event.sequence, isGap: event.stream == "gap")
            if admission == .duplicate { continue }
            if admission == .deliver(hasGap: true) {
                await MainActor.run {
                    registry.recordManagedExecutorEvents(id: localJobID,
                        events: [AgentExecutorEvent(kind: .warning, detail: L10n.JobReceipt.outputGap, status: .running)])
                }
            }
            if event.stream == "gap" { continue }
            if let error = event.error, !error.isEmpty {
                let detail = AgentSecretStore.redact(error, secretValues: secretRedactionValues)
                await MainActor.run {
                    registry.recordManagedExecutorEvents(id: localJobID,
                        events: [AgentExecutorEvent(kind: .warning, detail: detail, status: .running)])
                }
            }
            if let exitCode = event.exitCode {
                guard event.stream == "exit", let code = Int32(exactly: exitCode) else {
                    throw AgentJobError.exitUnconfirmed(remoteJobID, L10n.JobReceipt.unconfirmed)
                }
                if event.timedOut == true { await registry.recordRemoteTimeout(id: localJobID) }
                terminal = code == 0 ? .completed : .failedCode(code)
            }
            if specification.executor == nil {
                if event.stream == "stdout" || event.stream == "stderr" {
                    await registry.recordManagedCommandOutput(id: localJobID, text: event.data + "\n",
                        stream: event.stream == "stderr" ? .stderr : .stdout)
                }
                if let terminal { return terminal }
                continue
            }
            var normalized = specification.decoder.decode(line: event.data)
            if event.stream == "stderr",
               normalized.isEmpty || normalized.allSatisfy({
                   $0.kind == .raw
               }),
               !event.data.trimmingCharacters(
                in: .whitespacesAndNewlines
               ).isEmpty {
                normalized = [AgentExecutorEvent(
                    kind: .warning,
                    detail: AgentSecretStore.redact(
                        event.data.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                        secretValues: secretRedactionValues
                    ),
                    status: .running
                )]
            }
            normalized = redactedExecutorEvents(
                normalized,
                secretValues: secretRedactionValues
            )
            if !normalized.isEmpty {
                await MainActor.run {
                    registry.recordManagedExecutorEvents(
                        id: localJobID,
                        events: normalized
                    )
                }
            }
            if let terminal { return terminal }
        }
        throw AgentJobError.exitUnconfirmed(remoteJobID, L10n.JobReceipt.unconfirmed)
    }

    private func redactedExecutorEvents(
        _ events: [AgentExecutorEvent],
        secretValues: [String]
    ) -> [AgentExecutorEvent] {
        func redact(_ value: String?) -> String? {
            value.map {
                AgentSecretStore.redact($0, secretValues: secretValues)
            }
        }
        return events.map { event in
            var copy = event
            copy.sessionID = redact(event.sessionID)
            copy.itemID = redact(event.itemID)
            copy.parentID = redact(event.parentID)
            copy.title = redact(event.title)
            copy.detail = redact(event.detail)
            copy.toolName = redact(event.toolName)
            copy.filePath = redact(event.filePath)
            copy.rawJSON = redact(event.rawJSON)
            return copy
        }
    }

    private func eventStreamRequest(jobID: String, after: Int64) throws -> URLRequest {
        guard let baseURL = descriptor.daemonEndpointURL else {
            throw AgentToolError.invalidArgument(
                "Daemon endpoint URL is not configured."
            )
        }
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("run")
            .appendingPathComponent("jobs")
            .appendingPathComponent(jobID)
            .appendingPathComponent("events")
        var request = URLRequest(url: url)
        request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
        request.timeoutInterval = TimeInterval(3600 * 6)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let token = tokenOverride ?? RemoteRuntimeSecretStore.daemonToken(runtimeID: descriptor.id)
        if !token.isEmpty {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }

    func listJobs() async throws -> AgentToolResult {
        AgentToolResult(summary: "daemon jobs", payload: "Daemon job listing is not exposed by this daemon version. Use the job id returned by run_command with get_job_output or kill_job.")
    }

    func getJobOutput(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let id = try requiredString("job_id", in: arguments)
        let job = try await getJob(id: id)
        let output = try await jobOutput(id: id)
        return AgentToolResult(
            summary: "\(id): \(job.exitCode == nil ? "running" : "exit \(job.exitCode ?? -1)")",
            payload: "daemon \(descriptor.displayName) job \(id)\n--- output ---\n\(output.output.isEmpty ? "(no output captured yet)" : output.output)"
        )
    }

    func killJob(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let id = try requiredString("job_id", in: arguments)
        _ = try await killJob(id: id)
        return AgentToolResult(summary: "\(id): \(L10n.JobReceipt.stopping)", payload: "Sent kill request to daemon job \(id) on \(descriptor.displayName). \(L10n.JobReceipt.unconfirmed)")
    }

    private func runForegroundCommand(_ command: String, summaryPrefix: String) async throws -> AgentToolResult {
        try await runDaemonExecution(specification: .init(command: command, displayCommand: summaryPrefix,
            summaryPrefix: summaryPrefix), arguments: ["run_in_background": .bool(false),
                "timeout_seconds": .number(defaultTimeout)], context: AgentToolContext(rootDirectory: nil),
            foregroundMaxTimeout: maxForegroundTimeout)
    }

    private func startWithRequestReceipt(body: [String: Any], context: AgentToolContext?,
        onPrepared: (@Sendable (String, String, Int64?) async throws -> Void)? = nil) async throws -> DaemonJobData {
        try await checkStartAdmission(context)
        if context?.executionBudget?.deadline != nil,
           descriptor.capabilities.supportsMonotonicRunDeadline != true
            || descriptor.capabilities.supportsIdempotentJobStart != true {
            throw AgentToolError.invalidArgument(L10n.JobReceipt.deadlineUnsupported)
        }
        guard descriptor.capabilities.supportsIdempotentJobStart == true else {
            // An old daemon cannot promise deduplication. Never blindly replay
            // a non-idempotent POST merely because its response was lost.
            return try await request(method: "POST", path: "/v1/run/start", query: [], body: body)
        }
        let identity: DaemonRunIdentity = try await request(method: "GET", path: "/v1/run/identity", query: [],
            timeoutSeconds: startReceiptTimeout(context))
        guard identity.instanceID.utf8.count == 32,
              identity.instanceID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AgentToolError.invalidArgument("Daemon returned an invalid process instance identity.")
        }
        let key = UUID().uuidString.lowercased()
        let jobID = "job-\(identity.instanceID)-request-\(key)"
        var keyedBody = body
        keyedBody["request_id"] = key
        keyedBody["expected_instance_id"] = identity.instanceID
        try await checkStartAdmission(context)
        let serverDeadline = try AgentDaemonRunDeadline.resolve(localDeadline: context?.executionBudget?.deadline,
            serverElapsedMilliseconds: identity.elapsedMilliseconds,
            timeoutSeconds: body["timeout_seconds"] as? Int ?? AgentDaemonRunDeadline.maximumCommandSeconds)
        if let serverDeadline { keyedBody["deadline_elapsed_milliseconds"] = serverDeadline }
        try await onPrepared?(identity.instanceID, key, serverDeadline)
        let delays: [Duration] = [.zero] + Array(recoveryDelays.dropFirst().prefix(2))
        for (attempt, delay) in delays.enumerated() {
            try await Task.sleep(for: delay)
            try await checkStartAdmission(context)
            do {
                let job: DaemonJobData = try await request(method: "POST", path: "/v1/run/start", query: [],
                    body: keyedBody, timeoutSeconds: startReceiptTimeout(context))
                guard job.id == jobID else { throw AgentDaemonStartUncertainError(jobID: jobID) }
                return job
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                let retryable: Bool
                if case AgentToolError.httpFailed(let status, _) = error {
                    if status == 410, serverDeadline != nil { throw AgentToolExecutionBudgetError.exhausted }
                    retryable = [408, 429, 500, 502, 503, 504].contains(status)
                    if attempt == 0, (400..<500).contains(status), !retryable { throw error }
                } else if let transport = error as? URLError {
                    retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                 .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed].contains(transport.code)
                } else { retryable = error is DecodingError }
                guard retryable, attempt + 1 < delays.count else {
                    throw AgentDaemonStartUncertainError(jobID: jobID)
                }
            }
        }
        throw AgentDaemonStartUncertainError(jobID: jobID)
    }

    private func checkStartAdmission(_ context: AgentToolContext?) async throws {
        try Task.checkCancellation()
        try await context?.executionBudget?.checkCurrentOwner()
        if let registry = context?.jobRegistry, let runtimeID = context?.runtimeID {
            try await registry.checkTurnAdmission(runtimeID: runtimeID, turnID: context?.turnID)
        }
    }

    private func startReceiptTimeout(_ context: AgentToolContext?) -> TimeInterval {
        min(defaultTimeout, max(0.001, context?.executionBudget?.deadline?.timeIntervalSinceNow ?? defaultTimeout))
    }

    private func getJob(id: String) async throws -> DaemonJobData {
        try await request(method: "GET", path: "/v1/run/jobs/\(id)", query: [])
    }

    private func reconcileStart(_ receipt: AgentDaemonStartReceipt) async throws -> DaemonJobData? {
        guard receipt.matches(descriptor) else { throw AgentDaemonStartJournalError.conflictingReceipt }
        let resolution: DaemonStartResolution = try await request(method: "POST",
            path: "/v1/run/requests/\(receipt.requestID)/reconcile", query: [],
            body: ["expected_instance_id": receipt.instanceID], timeoutSeconds: exitConfirmationRequestTimeout)
        guard resolution.instanceID == receipt.instanceID, resolution.requestID == receipt.requestID else {
            throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence
        }
        switch resolution.state {
        case "pending":
            guard resolution.job == nil else { throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence }
            return nil
        case "not_started":
            guard resolution.job == nil else { throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence }
            throw AgentDaemonStartResolutionError.notStarted
        case "started":
            guard let job = resolution.job, job.id == receipt.jobID else { throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence }
            return job
        default: throw AgentDaemonEventCursor.ProtocolFailure.invalidSequence
        }
    }

    /// Resume an existing receipt only. No executable or prompt is reconstructed
    /// and no /run/start request can be emitted from this entry point.
    func restoreStartReceipt(_ pending: AgentDaemonStartJournal.Pending, registry: AgentJobRegistry) async throws {
        let receipt = pending.receipt
        guard receipt.matches(descriptor), descriptor.capabilities.supportsStartRequestRecovery == true else {
            throw AgentDaemonStartJournalError.conflictingReceipt
        }
        let specification = AgentDaemonExecution(receipt: receipt, workspace: descriptor.defaultWorkspacePath)
        _ = try await runManagedExecutor(remoteJob: .init(id: receipt.jobID, command: "", cwd: descriptor.defaultWorkspacePath,
                pid: nil, exitCode: nil), specification: specification, registry: registry, runtimeID: receipt.runtimeID,
            turnID: receipt.turnID, timeout: max(1, Int(receipt.deadline.timeIntervalSinceNow)),
            wantsBackground: true, secretRedactionValues: [], startReceipt: receipt, recoveryOnly: true,
            restoredCancellation: pending.cancellationRequested, statusOnlyRecovery: true)
    }

    private func jobOutput(id: String) async throws -> DaemonJobOutputData {
        try await request(method: "GET", path: "/v1/run/jobs/\(id)/output", query: [])
    }

    private func killJob(id: String) async throws -> DaemonKillData {
        try await request(method: "DELETE", path: "/v1/run/jobs/\(id)", query: [])
    }

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: Any]? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> T {
        guard let baseURL = descriptor.daemonEndpointURL else {
            throw AgentToolError.invalidArgument("Daemon endpoint URL is not configured.")
        }
        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw AgentToolError.invalidArgument("Invalid daemon URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutSeconds ?? maxForegroundTimeout
        let token = tokenOverride ?? RemoteRuntimeSecretStore.daemonToken(runtimeID: descriptor.id)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder.willdeepDaemon.decode(DaemonEnvelope<T>.self, from: data))?.error
            throw AgentToolError.httpFailed(status, detail ?? "Daemon request failed.")
        }
        let envelope = try JSONDecoder.willdeepDaemon.decode(DaemonEnvelope<T>.self, from: data)
        guard (200..<300).contains(status), envelope.ok else {
            throw AgentToolError.httpFailed(status, envelope.error ?? "Daemon request failed.")
        }
        guard let decoded = envelope.data else {
            throw AgentToolError.httpFailed(status, "Daemon response did not contain data.")
        }
        return decoded
    }

    private func requiredString(_ name: String, in arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private func trimOutput(_ value: String) -> String {
        if value.count > maxOutputBytes {
            return String(value.prefix(maxOutputBytes)) + "\n...[truncated]"
        }
        return value
    }

    private func structuredResultText(
        events: [AgentExecutorEvent],
        fallback: String
    ) -> String {
        if let final = events.reversed().first(where: {
            $0.kind == .finished
                && $0.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
        })?.detail {
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let messages = events.compactMap { event -> String? in
            guard (event.kind == .message && event.status != .running)
                    || event.kind == .warning else {
                return nil
            }
            return event.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !messages.isEmpty {
            return messages.joined(separator: "\n\n")
        }
        return trimOutput(fallback)
    }
}

private struct DaemonEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let data: T?
}

private struct DaemonProbeReport: Decodable {
    let idempotentJobStart: Bool?
    let startRequestRecovery: Bool?
    let monotonicRunDeadline: Bool?
    let platform: String
    let arch: String
    let workspace: String
    let tools: [String: String]
    let registries: [String: String]
    let proxies: [String: String]
    let githubCLIAuthLine: String?

    enum CodingKeys: String, CodingKey {
        case platform, arch, workspace, tools, registries, proxies
        case githubCLIAuthLine = "github_cli_auth_line"
        case idempotentJobStart = "idempotent_job_start"
        case startRequestRecovery = "start_request_recovery"
        case monotonicRunDeadline = "monotonic_run_deadline"
    }
}

private struct DaemonSearchData: Decodable {
    let matches: [String]
}

private struct DaemonReadData: Decodable {
    let path: String
    let contentBase64: String

    enum CodingKeys: String, CodingKey {
        case path
        case contentBase64 = "content_base64"
    }
}

private struct DaemonListData: Decodable {
    let entries: [DaemonListEntry]
}

private struct DaemonListEntry: Decodable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDir = "is_dir"
    }
}

private struct DaemonGitStatusData: Decodable {
    let status: String
}

private struct DaemonJobData: Decodable {
    let id: String
    let command: String
    let cwd: String
    let pid: Int?
    let exitCode: Int?
    var timedOut: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, command, cwd, pid
        case exitCode = "exit_code"
        case timedOut = "timed_out"
    }
}

private struct DaemonRunIdentity: Decodable {
    let instanceID: String
    let elapsedMilliseconds: Int64?
    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case elapsedMilliseconds = "elapsed_milliseconds"
    }
}

private struct DaemonStartResolution: Decodable {
    let requestID: String
    let instanceID: String
    let state: String
    let job: DaemonJobData?
    enum CodingKeys: String, CodingKey {
        case state, job
        case requestID = "request_id"
        case instanceID = "instance_id"
    }
}

private struct DaemonJobOutputData: Decodable {
    let output: String
}

private struct DaemonJobEventData: Decodable {
    let jobID: String?
    let sequence: Int64?
    let stream: String
    let data: String
    let exitCode: Int?
    let error: String?
    let timedOut: Bool?

    enum CodingKeys: String, CodingKey {
        case stream, data, sequence, error
        case jobID = "job_id"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
    }
}

private enum DaemonExecutorStreamTerminal {
    case completed
    case failed
    case failedCode(Int32)
    case cancelled

    var jobStatus: AgentBackgroundJob.Status {
        switch self {
        case .completed:
            return .completed
        case .cancelled:
            return .killed
        case .failed, .failedCode:
            return .failed
        }
    }

    var exitCode: Int32 {
        switch self {
        case .completed:
            return 0
        case .failedCode(let code):
            return code
        case .failed:
            return -1
        case .cancelled:
            return SIGTERM
        }
    }
}

private struct DaemonKillData: Decodable {
    let killed: Bool
}

private extension JSONDecoder {
    static var willdeepDaemon: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct SSHCommandOutcome: Sendable {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchFailed: Bool
}

private nonisolated final class SSHCommandOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
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
        var text = String(data: snapshot, encoding: .utf8) ?? ""
        if didTruncate { text += "\n...[truncated]" }
        return text
    }
}

private nonisolated final class SSHCommandRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    var didTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}
