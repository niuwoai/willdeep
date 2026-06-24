//
//  AgentInteractiveTerminal.swift
//  WillDeep
//
//  Interactive Agent-mode terminal sessions. Kept separate from the editor
//  bottom terminal so Agent tools can read/send through one audited surface.
//

import Combine
import Darwin
import Foundation

struct RuntimeTerminalProfile: Codable, Equatable {
    var startupDirectory: String
    var startupCommands: [String]
    var jumpCommands: [String]
    var autoRunOnConnect: Bool
    var commandDelayMilliseconds: Int
    var idleTimeoutSeconds: Int
    var serviceNames: [String]

    static let `default` = RuntimeTerminalProfile(
        startupDirectory: "",
        startupCommands: [],
        jumpCommands: [],
        autoRunOnConnect: false,
        commandDelayMilliseconds: 450,
        idleTimeoutSeconds: 5,
        serviceNames: ["nginx", "mysql", "postgresql", "redis", "docker"]
    )

    var normalized: RuntimeTerminalProfile {
        var copy = self
        copy.startupDirectory = copy.startupDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.startupCommands = Self.cleanedCommands(copy.startupCommands)
        copy.jumpCommands = Self.cleanedCommands(copy.jumpCommands)
        copy.commandDelayMilliseconds = min(max(copy.commandDelayMilliseconds, 100), 10_000)
        copy.idleTimeoutSeconds = min(max(copy.idleTimeoutSeconds, 1), 120)
        copy.serviceNames = Array(Set(copy.serviceNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        return copy
    }

    var queuedConnectCommands: [String] {
        var commands: [String] = []
        if !startupDirectory.isEmpty {
            commands.append("cd \(AgentToolRunner.shellQuoted(startupDirectory))")
        }
        commands.append(contentsOf: startupCommands)
        commands.append(contentsOf: jumpCommands)
        return commands
    }

    private static func cleanedCommands(_ commands: [String]) -> [String] {
        commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct AgentTerminalSnapshot: Equatable {
    let isRunning: Bool
    let runtimeName: String
    let runtimeTarget: String
    let output: String
    let pendingCommands: [String]
    let recentCommands: [String]
}

@MainActor
final class AgentInteractiveTerminalController: ObservableObject {
    @Published private(set) var session = AgentInteractiveTerminalSession()
    @Published var selectedRuntimeID: UUID?

    private var sessionSubscription: AnyCancellable?

    init() {
        subscribeToSession()
    }

    var selectedRuntime: RuntimeDescriptor? {
        guard let selectedRuntimeID else { return nil }
        return AgentRuntimeStore.descriptor(id: selectedRuntimeID)
    }

    var runtimeOptions: [RuntimeDescriptor] {
        AgentRuntimeStore.loadDescriptors().filter { $0.transport == .ssh }
    }

    func selectRuntimeIfNeeded() {
        if selectedRuntime != nil { return }
        selectedRuntimeID = runtimeOptions.first?.id
    }

    func connect(settings: EditorTerminalSettings) {
        guard let runtime = selectedRuntime?.normalized else {
            session.appendHostNotice(L10n.AgentTerminal.noRuntime)
            return
        }
        session.connect(runtime: runtime, settings: settings.normalized())
    }

    func disconnect() {
        session.terminate()
    }

    func clear() {
        session.clear()
    }

    func sendUserInput(_ data: Data) {
        session.send(data)
    }

    func sendUserText(_ text: String) {
        session.send(text)
    }

    func sendApprovedCommand(_ command: String) throws -> AgentToolResult {
        try session.sendApprovedCommand(command)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        try session.sendApprovedControl(control)
    }

    func snapshot(maxCharacters: Int = 16_000) -> AgentTerminalSnapshot {
        session.snapshot(maxCharacters: maxCharacters)
    }

    private func subscribeToSession() {
        sessionSubscription = session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

enum AgentTerminalControl: String, CaseIterable {
    case ctrlC = "ctrl_c"
    case enter
    case escape

    var bytes: [UInt8] {
        switch self {
        case .ctrlC: return [3]
        case .enter: return [13]
        case .escape: return [27]
        }
    }

    var displayName: String {
        switch self {
        case .ctrlC: return "Ctrl-C"
        case .enter: return "Enter"
        case .escape: return "Esc"
        }
    }
}

@MainActor
final class AgentInteractiveTerminalSession: ObservableObject {
    @Published private(set) var output: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var runtimeName = L10n.AgentTerminal.disconnectedRuntime
    @Published private(set) var runtimeTarget = ""
    @Published private(set) var pendingAutoCommands: [String] = []
    @Published private(set) var recentCommands: [String] = []
    @Published private(set) var isAutoQueuePaused = false

    private var childPID: pid_t?
    private var masterFileHandle: FileHandle?
    private var processSource: DispatchSourceProcess?
    private var autoQueueTask: Task<Void, Never>?
    private let maxOutputCharacters = 120_000
    private let maxRecentCommands = 20

    func connect(runtime: RuntimeDescriptor, settings: EditorTerminalSettings) {
        terminate()
        let profile = (runtime.terminalProfile ?? .default).normalized
        runtimeName = runtime.displayName
        runtimeTarget = runtime.sshTarget
        appendHostNotice(L10n.AgentTerminal.connecting(runtime.displayName, runtime.sshTarget))
        startSSHPTY(runtime: runtime, settings: settings)
        if isRunning, profile.autoRunOnConnect {
            pendingAutoCommands = profile.queuedConnectCommands
            drainAutoQueue(profile: profile)
        }
    }

    func terminate() {
        autoQueueTask?.cancel()
        autoQueueTask = nil
        pendingAutoCommands = []
        isAutoQueuePaused = false
        if let childPID {
            kill(childPID, SIGTERM)
        }
        cleanup()
    }

    func clear() {
        output = ""
    }

    func appendHostNotice(_ text: String) {
        append("\n[\(text)]\n")
    }

    func send(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        send(data)
    }

    func send(_ data: Data) {
        guard let masterFileHandle, isRunning else { return }
        do {
            try masterFileHandle.write(contentsOf: data)
        } catch {
            appendHostNotice(L10n.AgentTerminal.writeFailed(error.localizedDescription))
        }
    }

    func sendApprovedCommand(_ command: String) throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and connect the Agent Terminal side panel before sending commands.")
        }
        recordCommand(trimmed)
        send(trimmed + "\n")
        let payload = """
        Sent command to Agent Terminal.
        Runtime: \(runtimeName) \(runtimeTarget.isEmpty ? "" : "(\(runtimeTarget))")
        Command: \(trimmed)
        """
        return AgentToolResult(summary: "terminal: \(trimmed.prefix(80))", payload: payload)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and connect the Agent Terminal side panel before sending control input.")
        }
        send(Data(control.bytes))
        let payload = "Sent \(control.displayName) to Agent Terminal on \(runtimeName)."
        return AgentToolResult(summary: "terminal: \(control.displayName)", payload: payload)
    }

    func snapshot(maxCharacters: Int) -> AgentTerminalSnapshot {
        let redacted = AgentTerminalRedactor.redact(output)
        let suffix = String(redacted.suffix(max(1, maxCharacters)))
        return AgentTerminalSnapshot(
            isRunning: isRunning,
            runtimeName: runtimeName,
            runtimeTarget: runtimeTarget,
            output: suffix,
            pendingCommands: pendingAutoCommands,
            recentCommands: recentCommands
        )
    }

    deinit {
        if let childPID {
            kill(childPID, SIGTERM)
        }
        autoQueueTask?.cancel()
        processSource?.cancel()
        masterFileHandle?.readabilityHandler = nil
        try? masterFileHandle?.close()
    }

    private func startSSHPTY(runtime: RuntimeDescriptor, settings: EditorTerminalSettings) {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            appendHostNotice(L10n.AgentTerminal.ptyFailed(String(cString: strerror(errno))))
            return
        }
        guard let slavePathPointer = ttyname(slaveFD) else {
            appendHostNotice(L10n.AgentTerminal.ptyFailed(String(cString: strerror(errno))))
            close(masterFD)
            close(slaveFD)
            return
        }
        let slavePath = String(cString: slavePathPointer)
        let launch = Self.sshLaunch(runtime: runtime, settings: settings)
        guard let pid = Self.spawnPTYProcess(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            environment: launch.environment,
            masterFD: masterFD,
            slaveFD: slaveFD,
            slavePath: slavePath
        ) else {
            appendHostNotice(L10n.AgentTerminal.spawnFailed(String(cString: strerror(errno))))
            close(masterFD)
            close(slaveFD)
            return
        }

        close(slaveFD)
        let handle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        masterFileHandle = handle
        childPID = pid
        isRunning = true

        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self, text] in
                self?.append(text)
            }
        }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let code = Self.exitCode(fromWaitStatus: status)
            appendHostNotice(L10n.AgentTerminal.exited(code))
            cleanup()
        }
        processSource = source
        source.resume()
    }

    private func drainAutoQueue(profile: RuntimeTerminalProfile) {
        autoQueueTask?.cancel()
        autoQueueTask = Task { [weak self] in
            let delay = UInt64(profile.commandDelayMilliseconds) * 1_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                await MainActor.run {
                    guard let self, self.isRunning, !self.pendingAutoCommands.isEmpty else { return }
                    let command = self.pendingAutoCommands.removeFirst()
                    self.recordCommand(command)
                    self.send(command + "\n")
                }
                await MainActor.run {
                    guard let self else { return }
                    if self.pendingAutoCommands.isEmpty {
                        self.autoQueueTask?.cancel()
                        self.autoQueueTask = nil
                    }
                }
                if await MainActor.run(body: { self?.pendingAutoCommands.isEmpty ?? true }) {
                    return
                }
            }
        }
    }

    private func recordCommand(_ command: String) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > maxRecentCommands {
            recentCommands.removeLast(recentCommands.count - maxRecentCommands)
        }
    }

    private func append(_ text: String) {
        output += normalizedTerminalOutput(text)
        if output.count > maxOutputCharacters {
            output.removeFirst(output.count - maxOutputCharacters)
        }
    }

    private func normalizedTerminalOutput(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func cleanup() {
        masterFileHandle?.readabilityHandler = nil
        try? masterFileHandle?.close()
        masterFileHandle = nil
        processSource?.cancel()
        processSource = nil
        childPID = nil
        isRunning = false
        pendingAutoCommands = []
        autoQueueTask?.cancel()
        autoQueueTask = nil
    }

    private static func sshLaunch(
        runtime: RuntimeDescriptor,
        settings: EditorTerminalSettings
    ) -> (executablePath: String, arguments: [String], environment: [String: String]) {
        var args = ["-tt", "-p", "\(runtime.port)"]
        if let identityFilePath = runtime.identityFilePath, !identityFilePath.isEmpty {
            args += ["-i", expandedIdentityFilePath(identityFilePath)]
        }
        args.append(runtime.sshTarget)

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["WILLDEEP_AGENT_TERMINAL"] = "1"
        for (key, value) in settings.environment {
            environment[key] = value
        }
        return ("/usr/bin/ssh", args, environment)
    }

    private static func spawnPTYProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        masterFD: Int32,
        slaveFD: Int32,
        slavePath: String
    ) -> pid_t? {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, slavePath, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, masterFD) == 0,
              posix_spawn_file_actions_addclose(&fileActions, slaveFD) == 0 else {
            return nil
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv = [URL(fileURLWithPath: executablePath).lastPathComponent] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStringArray(argv) { argvPointer in
            withCStringArray(envp) { envPointer in
                executablePath.withCString { executableCString in
                    posix_spawn(&pid, executableCString, &fileActions, &attributes, argvPointer, envPointer)
                }
            }
        }
        guard result == 0 else {
            errno = result
            return nil
        }
        return pid
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        }
        return status
    }

    private static func expandedIdentityFilePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let cStrings = strings.map { strdup($0) }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        var pointers: [UnsafeMutablePointer<CChar>?] = cStrings.map { $0 }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

enum AgentTerminalRedactor {
    private static let patterns: [String] = [
        #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{12,}"#,
        #"(?i)\b[A-Z0-9_]*(api[_-]?key|token|secret|password|jwt)[A-Z0-9_]*\s*[:=]\s*['"]?[^'"\s]{3,}"#,
        #"(?i)\b(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{3,}"#,
        #"(?i)\b(sk-[A-Za-z0-9_-]{16,})\b"#,
        #"(?i)\b([A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b"#
    ]

    static func redact(_ text: String) -> String {
        var output = text
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: [.regularExpression]
            )
        }
        return output
    }
}
