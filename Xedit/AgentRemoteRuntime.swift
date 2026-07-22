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
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))
        let remoteCommand = workspaceWrappedCommand(command)

        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
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
                    runtimeIDForDisplay: descriptor.id
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

    private let defaultTimeout: TimeInterval = 20
    private let maxForegroundTimeout: TimeInterval = 120
    private let maxOutputBytes = 32 * 1024
    private let foregroundJobPollIntervalNanoseconds: UInt64 = 1_000_000_000

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
            ].compactMapValues { $0 }
        )
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
        let timeoutArg = arguments["timeout_seconds"]?.intValue() ?? Int(defaultTimeout)
        let timeout = min(max(timeoutArg, 1), 3600 * 6)
        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        let job = try await startJob(command: command, timeoutSeconds: timeout)
        if wantsBackground {
            let payload = """
            Started daemon background job \(job.id).
            Runtime: \(descriptor.displayName)
            Command: \(command)
            Remote PID: \(job.pid ?? 0)
            cwd: \(job.cwd)

            Use `get_job_output` with job_id `\(job.id)` or `kill_job` to inspect or stop it.
            """
            return AgentToolResult(summary: "▶ \(job.id) started on \(descriptor.displayName)", payload: payload)
        }

        let deadline = Date().addingTimeInterval(min(TimeInterval(timeout), max(1, foregroundMaxTimeout)))
        var latest = job
        while latest.exitCode == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: foregroundJobPollIntervalNanoseconds)
            latest = try await getJob(id: job.id)
        }
        if latest.exitCode == nil {
            _ = try? await killJob(id: job.id)
            throw AgentToolError.commandTimeout
        }
        let output = try await jobOutput(id: job.id)
        let combined = trimOutput("runtime=\(descriptor.displayName)\njob=\(job.id)\nexit=\(latest.exitCode ?? -1)\n--- output ---\n\(output.output)")
        if latest.exitCode != 0 {
            throw AgentToolError.commandFailed(Int32(latest.exitCode ?? -1), combined)
        }
        let firstLine = output.output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return AgentToolResult(
            summary: "daemon \(descriptor.displayName): exit 0\(firstLine.isEmpty ? "" : ": " + firstLine.prefix(60))",
            payload: combined
        )
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
        return AgentToolResult(summary: "\(id) killed", payload: "Sent kill request to daemon job \(id) on \(descriptor.displayName).")
    }

    private func runForegroundCommand(_ command: String, summaryPrefix: String) async throws -> AgentToolResult {
        let job = try await startJob(command: command, timeoutSeconds: Int(defaultTimeout))
        var latest = job
        let deadline = Date().addingTimeInterval(maxForegroundTimeout)
        while latest.exitCode == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: foregroundJobPollIntervalNanoseconds)
            latest = try await getJob(id: job.id)
        }
        if latest.exitCode == nil {
            _ = try? await killJob(id: job.id)
            throw AgentToolError.commandTimeout
        }
        let output = try await jobOutput(id: job.id)
        let combined = trimOutput(output.output)
        if latest.exitCode != 0 {
            throw AgentToolError.commandFailed(Int32(latest.exitCode ?? -1), combined)
        }
        return AgentToolResult(summary: "\(summaryPrefix): exit 0", payload: combined.isEmpty ? "(no output)" : combined)
    }

    private func startJob(command: String, timeoutSeconds: Int) async throws -> DaemonJobData {
        let body: [String: Any] = [
            "command": command,
            "cwd": ".",
            "timeout_seconds": timeoutSeconds
        ]
        return try await request(method: "POST", path: "/v1/run/start", query: [], body: body)
    }

    private func getJob(id: String) async throws -> DaemonJobData {
        try await request(method: "GET", path: "/v1/run/jobs/\(id)", query: [])
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
        body: [String: Any]? = nil
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
        request.timeoutInterval = maxForegroundTimeout
        let token = RemoteRuntimeSecretStore.daemonToken(runtimeID: descriptor.id)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
}

private struct DaemonEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let data: T?
}

private struct DaemonProbeReport: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id, command, cwd, pid
        case exitCode = "exit_code"
    }
}

private struct DaemonJobOutputData: Decodable {
    let output: String
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
