//
//  AgentRemoteRuntime.swift
//  WillDeep
//
//  Runtime backends let Agent tools execute against either the local
//  workspace or a configured remote host. The first remote transport is
//  intentionally SSH-only: it relies on the user's existing OpenSSH
//  config and BatchMode authentication, so WillDeep never stores private
//  key material.
//

import Foundation
import Darwin

enum RuntimePlatform: String, Codable, CaseIterable, Identifiable {
    case macOS
    case linux
    case unknown

    var id: String { rawValue }

    static func parse(_ value: String) -> RuntimePlatform {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "darwin": return .macOS
        case "linux": return .linux
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .unknown: return "Unknown"
        }
    }
}

enum RuntimeArch: String, Codable, CaseIterable, Identifiable {
    case arm64
    case x86_64
    case unknown

    var id: String { rawValue }

    static func parse(_ value: String) -> RuntimeArch {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arm64", "aarch64": return .arm64
        case "x86_64", "amd64": return .x86_64
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .arm64: return "arm64"
        case .x86_64: return "x86_64"
        case .unknown: return "unknown"
        }
    }
}

enum RuntimeTransport: String, Codable, CaseIterable, Identifiable {
    case local
    case ssh
    case daemon

    var id: String { rawValue }
}

struct RuntimeCapabilities: Codable, Equatable {
    var hasGit: Bool
    var hasRipgrep: Bool
    var shellPath: String?
    var nodeVersion: String?
    var npmVersion: String?
    var yarnVersion: String?
    var pythonVersion: String?
    var pipVersion: String?
    var rubyVersion: String?
    var goVersion: String?
    var javaVersion: String?
    var ghVersion: String?
    var ghAuthStatus: String?
    var npmRegistry: String?
    var yarnRegistry: String?
    var npmProxy: String?
    var npmHTTPSProxy: String?
    var pipProxy: String?
    var proxyEnvironment: [String: String]

    static let empty = RuntimeCapabilities(
        hasGit: false,
        hasRipgrep: false,
        shellPath: nil,
        nodeVersion: nil,
        npmVersion: nil,
        yarnVersion: nil,
        pythonVersion: nil,
        pipVersion: nil,
        rubyVersion: nil,
        goVersion: nil,
        javaVersion: nil,
        ghVersion: nil,
        ghAuthStatus: nil,
        npmRegistry: nil,
        yarnRegistry: nil,
        npmProxy: nil,
        npmHTTPSProxy: nil,
        pipProxy: nil,
        proxyEnvironment: [:]
    )

    enum CodingKeys: String, CodingKey {
        case hasGit, hasRipgrep, shellPath
        case nodeVersion, npmVersion, yarnVersion, pythonVersion, pipVersion
        case rubyVersion, goVersion, javaVersion, ghVersion, ghAuthStatus
        case npmRegistry, yarnRegistry, npmProxy, npmHTTPSProxy, pipProxy, proxyEnvironment
    }

    init(
        hasGit: Bool,
        hasRipgrep: Bool,
        shellPath: String?,
        nodeVersion: String? = nil,
        npmVersion: String? = nil,
        yarnVersion: String? = nil,
        pythonVersion: String? = nil,
        pipVersion: String? = nil,
        rubyVersion: String? = nil,
        goVersion: String? = nil,
        javaVersion: String? = nil,
        ghVersion: String? = nil,
        ghAuthStatus: String? = nil,
        npmRegistry: String? = nil,
        yarnRegistry: String? = nil,
        npmProxy: String? = nil,
        npmHTTPSProxy: String? = nil,
        pipProxy: String? = nil,
        proxyEnvironment: [String: String] = [:]
    ) {
        self.hasGit = hasGit
        self.hasRipgrep = hasRipgrep
        self.shellPath = shellPath
        self.nodeVersion = nodeVersion
        self.npmVersion = npmVersion
        self.yarnVersion = yarnVersion
        self.pythonVersion = pythonVersion
        self.pipVersion = pipVersion
        self.rubyVersion = rubyVersion
        self.goVersion = goVersion
        self.javaVersion = javaVersion
        self.ghVersion = ghVersion
        self.ghAuthStatus = ghAuthStatus
        self.npmRegistry = npmRegistry
        self.yarnRegistry = yarnRegistry
        self.npmProxy = npmProxy
        self.npmHTTPSProxy = npmHTTPSProxy
        self.pipProxy = pipProxy
        self.proxyEnvironment = proxyEnvironment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hasGit = try c.decodeIfPresent(Bool.self, forKey: .hasGit) ?? false
        self.hasRipgrep = try c.decodeIfPresent(Bool.self, forKey: .hasRipgrep) ?? false
        self.shellPath = try c.decodeIfPresent(String.self, forKey: .shellPath)
        self.nodeVersion = try c.decodeIfPresent(String.self, forKey: .nodeVersion)
        self.npmVersion = try c.decodeIfPresent(String.self, forKey: .npmVersion)
        self.yarnVersion = try c.decodeIfPresent(String.self, forKey: .yarnVersion)
        self.pythonVersion = try c.decodeIfPresent(String.self, forKey: .pythonVersion)
        self.pipVersion = try c.decodeIfPresent(String.self, forKey: .pipVersion)
        self.rubyVersion = try c.decodeIfPresent(String.self, forKey: .rubyVersion)
        self.goVersion = try c.decodeIfPresent(String.self, forKey: .goVersion)
        self.javaVersion = try c.decodeIfPresent(String.self, forKey: .javaVersion)
        self.ghVersion = try c.decodeIfPresent(String.self, forKey: .ghVersion)
        self.ghAuthStatus = try c.decodeIfPresent(String.self, forKey: .ghAuthStatus)
        self.npmRegistry = try c.decodeIfPresent(String.self, forKey: .npmRegistry)
        self.yarnRegistry = try c.decodeIfPresent(String.self, forKey: .yarnRegistry)
        self.npmProxy = try c.decodeIfPresent(String.self, forKey: .npmProxy)
        self.npmHTTPSProxy = try c.decodeIfPresent(String.self, forKey: .npmHTTPSProxy)
        self.pipProxy = try c.decodeIfPresent(String.self, forKey: .pipProxy)
        self.proxyEnvironment = try c.decodeIfPresent([String: String].self, forKey: .proxyEnvironment) ?? [:]
    }
}

struct RuntimeDescriptor: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var transport: RuntimeTransport
    var host: String
    var port: Int
    var username: String
    var identityFilePath: String?
    var defaultWorkspacePath: String
    var platform: RuntimePlatform
    var arch: RuntimeArch
    var lastProbeAt: Date?
    var capabilities: RuntimeCapabilities

    init(
        id: UUID = UUID(),
        displayName: String,
        transport: RuntimeTransport = .ssh,
        host: String,
        port: Int = 22,
        username: String,
        identityFilePath: String? = nil,
        defaultWorkspacePath: String,
        platform: RuntimePlatform = .unknown,
        arch: RuntimeArch = .unknown,
        lastProbeAt: Date? = nil,
        capabilities: RuntimeCapabilities = .empty
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.host = host
        self.port = port
        self.username = username
        self.identityFilePath = identityFilePath
        self.defaultWorkspacePath = defaultWorkspacePath
        self.platform = platform
        self.arch = arch
        self.lastProbeAt = lastProbeAt
        self.capabilities = capabilities
    }

    var normalized: RuntimeDescriptor {
        var copy = self
        copy.displayName = copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = copy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFilePath = copy.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.identityFilePath?.isEmpty == true {
            copy.identityFilePath = nil
        }
        copy.defaultWorkspacePath = RemotePathValidator.normalizedWorkspaceRoot(copy.defaultWorkspacePath)
        copy.port = min(max(copy.port, 1), 65535)
        if copy.displayName.isEmpty {
            copy.displayName = copy.host.isEmpty ? "Remote Runtime" : copy.host
        }
        return copy
    }

    var sshTarget: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }
}

enum WorkspaceLocation: Codable, Equatable {
    case local(path: String)
    case remote(runtimeID: UUID, path: String)

    enum Kind: String, Codable {
        case local
        case remote
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case path
        case runtimeID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let path = try c.decode(String.self, forKey: .path)
        switch kind {
        case .local:
            self = .local(path: path)
        case .remote:
            let runtimeID = try c.decode(UUID.self, forKey: .runtimeID)
            self = .remote(runtimeID: runtimeID, path: path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let path):
            try c.encode(Kind.local, forKey: .kind)
            try c.encode(path, forKey: .path)
        case .remote(let runtimeID, let path):
            try c.encode(Kind.remote, forKey: .kind)
            try c.encode(runtimeID, forKey: .runtimeID)
            try c.encode(path, forKey: .path)
        }
    }

    var localPath: String? {
        if case .local(let path) = self { return path }
        return nil
    }

    var remoteRuntimeID: UUID? {
        if case .remote(let runtimeID, _) = self { return runtimeID }
        return nil
    }

    var path: String {
        switch self {
        case .local(let path), .remote(_, let path): return path
        }
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }
}

enum RemotePathError: LocalizedError {
    case emptyWorkspace
    case emptyPath
    case pathEscapesWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .emptyWorkspace:
            return "Remote workspace path is empty."
        case .emptyPath:
            return "Remote path is empty."
        case .pathEscapesWorkspace(let path):
            return "Remote path escapes the workspace: \(path)"
        }
    }
}

enum RemotePathValidator {
    static func normalizedWorkspaceRoot(_ path: String) -> String {
        var cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.count > 1 && cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        return cleaned
    }

    static func resolve(_ rawPath: String?, workspaceRoot: String) throws -> String {
        let root = normalizedWorkspaceRoot(workspaceRoot)
        guard !root.isEmpty else { throw RemotePathError.emptyWorkspace }
        let raw = (rawPath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw RemotePathError.emptyPath }

        let combined: String
        if raw == "." {
            combined = root
        } else if raw.hasPrefix("/") {
            combined = raw
        } else {
            combined = root + "/" + raw
        }

        let normalized = normalizeLexically(combined)
        guard normalized == root || normalized.hasPrefix(root + "/") else {
            throw RemotePathError.pathEscapesWorkspace(raw)
        }
        return normalized
    }

    static func relativePath(_ rawPath: String?, workspaceRoot: String) throws -> String {
        let root = normalizedWorkspaceRoot(workspaceRoot)
        let resolved = try resolve(rawPath, workspaceRoot: root)
        if resolved == root { return "." }
        return String(resolved.dropFirst(root.count + 1))
    }

    private static func normalizeLexically(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }
}

enum AgentRuntimeStore {
    private static let defaultsKey = "com.willdeep.agentRuntime.descriptors.v1"
    private static var defaults: UserDefaults { .standard }

    static func loadDescriptors() -> [RuntimeDescriptor] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RuntimeDescriptor].self, from: data) else {
            return []
        }
        return decoded
            .filter { $0.transport != .local }
            .map(\.normalized)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func saveDescriptors(_ descriptors: [RuntimeDescriptor]) {
        let cleaned = descriptors
            .filter { $0.transport != .local }
            .map(\.normalized)
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func descriptor(id: UUID) -> RuntimeDescriptor? {
        loadDescriptors().first { $0.id == id }
    }

    static func upsert(_ descriptor: RuntimeDescriptor) {
        var all = loadDescriptors()
        let normalized = descriptor.normalized
        if let index = all.firstIndex(where: { $0.id == normalized.id }) {
            all[index] = normalized
        } else {
            all.append(normalized)
        }
        saveDescriptors(all)
    }

    static func delete(id: UUID) {
        saveDescriptors(loadDescriptors().filter { $0.id != id })
    }
}

struct SSHRuntimeBackend {
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

    func runCommand(arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        let command = try requiredString("command", in: arguments)
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultTimeout
        let timeout = min(max(timeoutArg, 1), maxForegroundTimeout)
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
            stdoutCollector.append(stdoutPipe.fileHandleForReading.availableData)
            stderrCollector.append(stderrPipe.fileHandleForReading.availableData)

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

    private func sshArguments(remoteCommand: String) -> [String] {
        var args = ["-o", "BatchMode=yes", "-p", "\(descriptor.port)"]
        if let identityFilePath = descriptor.identityFilePath, !identityFilePath.isEmpty {
            args += ["-i", identityFilePath]
        }
        args += [descriptor.sshTarget, remoteCommand]
        return args
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
