//
//  AgentInteractiveTerminal.swift
//  WillDeep
//
//  Interactive Agent-mode terminal. Rebuilt on SwiftTerm
//  (LocalProcessTerminalView) so each tab is a real VT100/ANSI terminal
//  emulator — colors, cursor addressing, and full-screen TUIs (vim,
//  htop, less) render correctly, and user typing behaves like Terminal /
//  Ghostty. Supports multiple tabs, defaults to a LOCAL login shell (no
//  SSH required), remembers which Agent session opened each tab, and
//  reaps tabs that sit idle for too long.
//
//  Agent tools (terminal_snapshot / terminal_send_command /
//  terminal_send_control) operate on the active tab through the same
//  controller surface as before.
//

import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm

// MARK: - Runtime terminal profile (unchanged surface; used by SSH tabs)

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

struct TerminalShortcutEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var delayMilliseconds: Int
    var bytes: [UInt8]
    var requiresEchoOff: Bool
    var protectedBytesReference: String?
    var transientProtectedBytes: [UInt8]

    init(
        id: UUID = UUID(),
        delayMilliseconds: Int,
        bytes: [UInt8],
        requiresEchoOff: Bool = false,
        protectedBytesReference: String? = nil,
        transientProtectedBytes: [UInt8] = []
    ) {
        self.id = id
        self.delayMilliseconds = max(0, delayMilliseconds)
        self.requiresEchoOff = requiresEchoOff
        self.bytes = requiresEchoOff ? [] : bytes
        self.protectedBytesReference = protectedBytesReference
        self.transientProtectedBytes = requiresEchoOff ? transientProtectedBytes : []
    }

    enum CodingKeys: String, CodingKey {
        case id, delayMilliseconds, bytes, requiresEchoOff, protectedBytesReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        delayMilliseconds = try container.decode(Int.self, forKey: .delayMilliseconds)
        bytes = try container.decodeIfPresent([UInt8].self, forKey: .bytes) ?? []
        requiresEchoOff = try container.decodeIfPresent(Bool.self, forKey: .requiresEchoOff) ?? false
        protectedBytesReference = try container.decodeIfPresent(String.self, forKey: .protectedBytesReference)
        transientProtectedBytes = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try container.encode(requiresEchoOff ? [] : bytes, forKey: .bytes)
        try container.encode(requiresEchoOff, forKey: .requiresEchoOff)
        try container.encodeIfPresent(protectedBytesReference, forKey: .protectedBytesReference)
    }

    var isPlayable: Bool {
        if requiresEchoOff {
            return !transientProtectedBytes.isEmpty || protectedBytesReference?.isEmpty == false
        }
        return !bytes.isEmpty
    }

    func resolvedBytes() -> [UInt8] {
        var cache: [String: [UInt8]] = [:]
        return resolvedBytes(cache: &cache)
    }

    func resolvedBytes(cache: inout [String: [UInt8]]) -> [UInt8] {
        guard requiresEchoOff else { return bytes }
        if !transientProtectedBytes.isEmpty { return transientProtectedBytes }
        guard let protectedBytesReference,
              !protectedBytesReference.isEmpty else { return [] }
        if let cached = cache[protectedBytesReference] {
            return cached
        }
        let encoded = AgentCredentialStore.load(account: protectedBytesReference)
        guard let data = Data(base64Encoded: encoded) else { return [] }
        let resolved = Array(data)
        cache[protectedBytesReference] = resolved
        return resolved
    }
}

struct TerminalShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationMilliseconds: Int
    var events: [TerminalShortcutEvent]
    var hasProtectedInput: Bool

    var eventCount: Int { events.count }
    var isPlayable: Bool { !events.isEmpty }

    var normalized: TerminalShortcut {
        var copy = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = trimmed.isEmpty ? "Terminal Shortcut" : String(trimmed.prefix(80))
        copy.durationMilliseconds = max(0, durationMilliseconds)
        copy.events = events.filter(\.isPlayable)
        return copy
    }
}

final class TerminalShortcutRecorder {
    private let startedAt: Date
    private var lastRecordedInputAt: Date
    private(set) var events: [TerminalShortcutEvent] = []
    private(set) var hasProtectedInput = false
    private var totalRecordedBytes = 0

    private let maxEvents = 4_000
    private let maxRecordedBytes = 64 * 1024

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.lastRecordedInputAt = startedAt
    }

    func record(data: [UInt8], echoEnabled: Bool, now: Date = Date()) {
        guard !data.isEmpty else { return }
        guard events.count < maxEvents, totalRecordedBytes < maxRecordedBytes else { return }

        let remainingBytes = maxRecordedBytes - totalRecordedBytes
        let safeBytes = Array(data.prefix(remainingBytes))
        guard !safeBytes.isEmpty else { return }

        let delay = max(0, Int(now.timeIntervalSince(lastRecordedInputAt) * 1000))
        if !echoEnabled {
            hasProtectedInput = true
        }
        events.append(
            TerminalShortcutEvent(
                delayMilliseconds: min(delay, 300_000),
                bytes: echoEnabled ? safeBytes : [],
                requiresEchoOff: !echoEnabled,
                transientProtectedBytes: echoEnabled ? [] : safeBytes
            )
        )
        totalRecordedBytes += safeBytes.count
        lastRecordedInputAt = now
    }

    func finish(
        title: String,
        id: UUID = UUID(),
        finishedAt: Date = Date()
    ) -> TerminalShortcut? {
        guard !events.isEmpty else { return nil }
        return TerminalShortcut(
            id: id,
            title: title,
            createdAt: startedAt,
            updatedAt: finishedAt,
            durationMilliseconds: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000)),
            events: events,
            hasProtectedInput: hasProtectedInput
        ).normalized
    }
}

enum TerminalShortcutStore {
    private static let key = "com.willdeep.terminalShortcuts.v1"
    private static let maxShortcuts = 24
    private static let fileName = "shortcuts.json"
    private static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("terminal-shortcuts", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> [TerminalShortcut] {
        if let shortcuts = loadFromDisk() {
            return normalized(shortcuts)
        }
        let legacyShortcuts = loadFromUserDefaults()
        if !legacyShortcuts.isEmpty {
            save(legacyShortcuts)
        }
        return normalized(legacyShortcuts)
    }

    static func save(_ shortcuts: [TerminalShortcut]) {
        let prepared = normalized(shortcuts).map { prepareForPersistence($0) }
        do {
            try ensureDirectory()
            let data = try encoder.encode(prepared)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TerminalShortcutStore: failed to save shortcuts: \(error)")
        }
    }

    static func loadEditableShortcuts() throws -> [TerminalShortcut] {
        let data = try Data(contentsOf: fileURL)
        return normalized(try decoder.decode([TerminalShortcut].self, from: data))
    }

    static func isStoreFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path == fileURL.standardizedFileURL.path
    }

    static func lineNumber(for shortcutID: UUID, in text: String) -> Int? {
        let needle = shortcutID.uuidString
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.contains(needle) }) else { return nil }
        return index + 1
    }

    static func deleteProtectedInputs(for shortcut: TerminalShortcut) {
        for event in shortcut.events {
            if let account = event.protectedBytesReference, !account.isEmpty {
                AgentCredentialStore.delete(account: account)
            } else if event.requiresEchoOff {
                AgentCredentialStore.delete(account: protectedInputAccount(shortcutID: shortcut.id, eventID: event.id))
            }
        }
    }

    private static func normalized(_ shortcuts: [TerminalShortcut]) -> [TerminalShortcut] {
        Array(
            shortcuts
                .map(\.normalized)
                .filter(\.isPlayable)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maxShortcuts)
        )
    }

    private static func prepareForPersistence(_ shortcut: TerminalShortcut) -> TerminalShortcut {
        var copy = shortcut.normalized
        copy.events = copy.events.map { event in
            guard event.requiresEchoOff else { return event }
            var prepared = event
            let account = event.protectedBytesReference ?? protectedInputAccount(shortcutID: shortcut.id, eventID: event.id)
            if !event.transientProtectedBytes.isEmpty {
                AgentCredentialStore.save(Data(event.transientProtectedBytes).base64EncodedString(), account: account)
            }
            prepared.protectedBytesReference = account
            prepared.transientProtectedBytes = []
            prepared.bytes = []
            return prepared
        }
        return copy
    }

    private static func protectedInputAccount(shortcutID: UUID, eventID: UUID) -> String {
        "terminal-shortcut/\(shortcutID.uuidString)/\(eventID.uuidString)"
    }

    private static func loadFromDisk() -> [TerminalShortcut]? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([TerminalShortcut].self, from: data)
        } catch {
            print("TerminalShortcutStore: failed to load shortcuts at \(url.path): \(error)")
            return nil
        }
    }

    private static func loadFromUserDefaults() -> [TerminalShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcuts = try? decoder.decode([TerminalShortcut].self, from: data) else {
            return []
        }
        return shortcuts
    }

    private static func ensureDirectory() throws {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    static func _setTestDirectoryOverride(_ directory: URL?) -> URL? {
        let previous = directoryOverride
        directoryOverride = directory
        return previous
    }
}

// MARK: - Tab kind

enum AgentTerminalTabKind: Equatable {
    case localShell
    case ssh(runtimeID: UUID, displayName: String, target: String)

    var isSSH: Bool { if case .ssh = self { return true }; return false }
}

// MARK: - SwiftTerm view subclass that reports user activity

/// LocalProcessTerminalView subclass. `paste` is `open` in SwiftTerm so
/// we hook it for activity; `keyDown` is only `public` (not overridable
/// cross-module), so typed-keystroke activity is instead inferred from
/// echoed output via the controller's buffer-hash sampling — plus the
/// active (visible) tab is always exempt from the idle reaper, which is
/// the only tab the user can actually be typing into.
final class AgentLocalProcessTerminalView: LocalProcessTerminalView {
    var onUserActivity: (() -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Void)?
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048

    override func paste(_ sender: Any) {
        onUserActivity?()
        super.paste(sender)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserActivity?()
        if shouldRecordInput?() == true {
            let bytes = Array(data)
            let echoEnabled = cachedTerminalEchoEnabled()
            onSendToProcess?(bytes, echoEnabled)
            if echoEnabled {
                rememberExpectedEcho(bytes)
            }
        }
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if shouldRecordInput?() == true, !isExpectedEcho(slice) {
            invalidateTerminalEchoCache()
        }
        super.dataReceived(slice: slice)
    }

    var terminalEchoEnabled: Bool {
        guard process.running else { return false }
        var attributes = termios()
        guard tcgetattr(process.childfd, &attributes) == 0 else { return false }
        return (attributes.c_lflag & tcflag_t(ECHO)) != 0
    }

    func invalidateTerminalEchoCache() {
        cachedEchoEnabled = nil
        cachedEchoCheckedAt = 0
        pendingEchoBytes.removeAll(keepingCapacity: true)
    }

    private func cachedTerminalEchoEnabled() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedEchoEnabled, now - cachedEchoCheckedAt <= maxEchoCacheAge {
            return cachedEchoEnabled
        }
        let fresh = terminalEchoEnabled
        cachedEchoEnabled = fresh
        cachedEchoCheckedAt = now
        return fresh
    }

    private func rememberExpectedEcho(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pendingEchoBytes.append(contentsOf: bytes)
        if pendingEchoBytes.count > maxPendingEchoBytes {
            pendingEchoBytes.removeFirst(pendingEchoBytes.count - maxPendingEchoBytes)
        }
    }

    private func isExpectedEcho(_ slice: ArraySlice<UInt8>) -> Bool {
        guard !slice.isEmpty, !pendingEchoBytes.isEmpty else { return false }
        let bytes = Array(slice)
        guard pendingEchoBytes.starts(with: bytes) else { return false }
        pendingEchoBytes.removeFirst(bytes.count)
        return true
    }
}

// MARK: - One terminal tab

@MainActor
final class AgentTerminalTab: ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    /// Which Agent session opened this tab. nil for tabs the user opened
    /// manually with no active session context.
    let originAgentSessionID: UUID?
    let kind: AgentTerminalTabKind
    let terminalView: AgentLocalProcessTerminalView

    @Published var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var recentCommands: [String] = []
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var isPlayingShortcut = false

    /// Last moment the tab saw user input or fresh process output. Drives
    /// the idle reaper. Not @Published — sampled by a timer, not the UI.
    private(set) var lastActivity = Date()
    private var lastBufferHash = 0
    private let maxRecentCommands = 20
    private var recorder: TerminalShortcutRecorder?

    init(
        kind: AgentTerminalTabKind,
        originAgentSessionID: UUID?,
        title: String,
        settings: EditorTerminalSettings
    ) {
        self.kind = kind
        self.originAgentSessionID = originAgentSessionID
        self.title = title
        self.terminalView = AgentLocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        applyAppearance(settings, skin: nil)
        terminalView.processDelegate = self
        terminalView.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
        }
        terminalView.shouldRecordInput = { [weak self] in
            guard let self else { return false }
            return self.recorder != nil && !self.isPlayingShortcut
        }
        terminalView.onSendToProcess = { [weak self] data, echoEnabled in
            self?.recordInputIfNeeded(data: data, echoEnabled: echoEnabled)
        }
    }

    func applyAppearance(_ settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        TerminalAppearance.apply(to: terminalView, settings: settings.normalized(), skin: skin)
    }

    // MARK: Launch

    func start(
        settings: EditorTerminalSettings,
        workingDirectory: String?,
        profile: RuntimeTerminalProfile?,
        skin: TerminalSkinColors?
    ) {
        terminalView.invalidateTerminalEchoCache()
        applyAppearance(settings, skin: skin)
        let env = Self.environmentArray(settings: settings)
        switch kind {
        case .localShell:
            let shell = Self.loginShellPath()
            // No workspace → open the shell in the user's home, never the app
            // process cwd (which is "/" for a bundled app). A fresh terminal
            // should land in the current workspace or ~, not the filesystem root.
            let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-" + (shell as NSString).lastPathComponent,
                currentDirectory: cwd
            )
        case .ssh(_, _, let target):
            guard let descriptor = sshDescriptor() else {
                isRunning = false
                return
            }
            var args = ["-tt", "-p", "\(descriptor.port)"]
            if let identity = descriptor.identityFilePath, !identity.isEmpty {
                args += ["-i", Self.expandedPath(identity)]
            }
            args.append(target)
            terminalView.startProcess(
                executable: "/usr/bin/ssh",
                args: args,
                environment: env,
                currentDirectory: workingDirectory
            )
            if let profile = profile?.normalized, profile.autoRunOnConnect {
                drainConnectCommands(profile.queuedConnectCommands, delayMs: profile.commandDelayMilliseconds)
            }
        }
        isRunning = true
        lastActivity = Date()
    }

    private func sshDescriptor() -> RuntimeDescriptor? {
        guard case .ssh(let runtimeID, _, _) = kind else { return nil }
        return AgentRuntimeStore.descriptor(id: runtimeID)?.normalized
    }

    private func drainConnectCommands(_ commands: [String], delayMs: Int) {
        guard !commands.isEmpty else { return }
        Task { [weak self] in
            let delay = UInt64(max(100, delayMs)) * 1_000_000
            for command in commands {
                try? await Task.sleep(nanoseconds: delay)
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.recordCommand(command)
                    self.terminalView.send(txt: command + "\n")
                }
            }
        }
    }

    func terminate() {
        guard isRunning else { return }
        cancelRecording()
        terminalView.terminate()
        isRunning = false
    }

    var isRecording: Bool { recorder != nil }

    func startRecording() {
        guard recorder == nil else { return }
        let now = Date()
        recorder = TerminalShortcutRecorder(startedAt: now)
        activeRecordingStartedAt = now
    }

    func stopRecording(defaultTitle: String? = nil) -> TerminalShortcut? {
        let finishedAt = Date()
        defer {
            recorder = nil
            activeRecordingStartedAt = nil
        }
        let title = defaultTitle ?? "Terminal Shortcut \(Self.shortcutTitleFormatter.string(from: finishedAt))"
        return recorder?.finish(title: title, finishedAt: finishedAt)
    }

    func cancelRecording() {
        recorder = nil
        activeRecordingStartedAt = nil
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard isRunning, shortcut.isPlayable, !isRecording, !isPlayingShortcut else { return }
        isPlayingShortcut = true
        Task { [weak self] in
            var protectedBytesCache: [String: [UInt8]] = [:]
            for event in shortcut.events {
                if event.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(event.delayMilliseconds) * 1_000_000)
                }
                let shouldContinue = await MainActor.run {
                    guard let self, self.isRunning else { return false }
                    if event.requiresEchoOff, self.terminalView.terminalEchoEnabled {
                        self.isPlayingShortcut = false
                        return false
                    }
                    return true
                }
                if shouldContinue == false {
                    break
                }
                let bytes = event.resolvedBytes(cache: &protectedBytesCache)
                guard !bytes.isEmpty else { continue }
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.terminalView.send(bytes)
                }
            }
            await MainActor.run {
                self?.isPlayingShortcut = false
            }
        }
    }

    // MARK: Agent-tool surface

    func sendApprovedCommand(_ command: String, secretRedactionValues: [String] = []) throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.missingArgument("command") }
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending commands.")
        }
        let visibleCommand = AgentSecretStore.redact(trimmed, secretValues: secretRedactionValues)
        recordCommand(visibleCommand)
        lastActivity = Date()
        terminalView.send(txt: trimmed + "\n")
        let payload = """
        Sent command to Agent Terminal tab \"\(title)\".
        Command: \(visibleCommand)
        """
        return AgentToolResult(summary: "terminal: \(visibleCommand.prefix(80))", payload: payload)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending control input.")
        }
        lastActivity = Date()
        terminalView.send(control.bytes)
        let payload = "Sent \(control.displayName) to Agent Terminal tab \"\(title)\"."
        return AgentToolResult(summary: "terminal: \(control.displayName)", payload: payload)
    }

    /// Latest live viewport text, secrets redacted.
    func snapshotText(maxCharacters: Int) -> String {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return "" }
        let startRow = terminal.buffer.yDisp
        let bottom = startRow + rows - 1
        let raw = terminal.getText(
            start: Position(col: 0, row: startRow),
            end: Position(col: cols - 1, row: bottom)
        )
        let redacted = AgentTerminalRedactor.redact(raw)
        return String(redacted.suffix(max(1, maxCharacters)))
    }

    private func recordCommand(_ command: String) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > maxRecentCommands {
            recentCommands.removeLast(recentCommands.count - maxRecentCommands)
        }
    }

    private func recordInputIfNeeded(data: [UInt8], echoEnabled: Bool) {
        guard !isPlayingShortcut else { return }
        recorder?.record(data: data, echoEnabled: echoEnabled)
    }

    // MARK: Idle bookkeeping

    var runtimeTarget: String {
        if case .ssh(_, _, let target) = kind { return target }
        return "local"
    }

    func idleSeconds(now: Date) -> TimeInterval {
        now.timeIntervalSince(lastActivity)
    }

    /// Sample the visible buffer; if it changed since last sample the tab
    /// produced output → it's active. Returns true if activity bumped.
    @discardableResult
    func refreshActivityFromBuffer(now: Date) -> Bool {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return false }
        let bottom = terminal.buffer.yDisp + rows - 1
        let startRow = max(0, bottom - rows + 1)
        let text = terminal.getText(
            start: Position(col: 0, row: startRow),
            end: Position(col: cols - 1, row: bottom)
        )
        let hash = text.hashValue
        if hash != lastBufferHash {
            lastBufferHash = hash
            lastActivity = now
            return true
        }
        return false
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep the user/origin label as the primary title; the OSC title
        // is noisy. Only adopt it for local tabs that still carry the
        // generic default name.
        if kind == .localShell, self.title.hasPrefix("Shell") {
            self.title = String(trimmed.prefix(40))
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
    }

    // MARK: Helpers

    private static func loginShellPath() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func environmentArray(settings: EditorTerminalSettings) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["WILLDEEP_AGENT_TERMINAL"] = "1"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        for (key, value) in settings.environment {
            environment[key] = value
        }
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private static func expandedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static let shortcutTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Controller: owns tabs + idle reaper + agent-tool surface

@MainActor
final class AgentInteractiveTerminalController: ObservableObject {
    @Published private(set) var tabs: [AgentTerminalTab] = []
    @Published var activeTabID: UUID?
    /// Default runtime for new SSH tabs.
    @Published var selectedRuntimeID: UUID?
    @Published private(set) var shortcuts: [TerminalShortcut] = TerminalShortcutStore.load()

    /// Supplies parameters to open a local shell tab on demand when an
    /// agent tool wants to drive the terminal but the user hasn't opened
    /// one yet. Wired by AppState so the controller can reach live
    /// terminal settings and the active session's workspace. Returns nil
    /// only if there's no AppState to ask.
    var defaultLocalTabProvider: (() -> (settings: EditorTerminalSettings, workingDirectory: String?, originAgentSessionID: UUID?, skin: TerminalSkinColors?)?)?

    /// Tabs idle longer than this are auto-terminated and removed. The
    /// currently-visible tab is exempt so we never close what the user is
    /// looking at.
    private let idleTimeout: TimeInterval = 300
    private var idleTimer: Timer?
    private var localShellCounter = 0
    private var tabChangePublishScheduled = false

    init() {
        startIdleReaper()
    }

    deinit {
        idleTimer?.invalidate()
    }

    var activeTab: AgentTerminalTab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    var recordingTabID: UUID? {
        tabs.first(where: \.isRecording)?.id
    }

    var isRecording: Bool {
        recordingTabID != nil
    }

    var runtimeOptions: [RuntimeDescriptor] {
        AgentRuntimeStore.loadDescriptors().filter { $0.transport == .ssh }
    }

    func selectRuntimeIfNeeded() {
        if selectedRuntimeID == nil {
            selectedRuntimeID = runtimeOptions.first?.id
        }
    }

    // MARK: Tab lifecycle

    @discardableResult
    func openLocalTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) -> AgentTerminalTab {
        localShellCounter += 1
        let tab = AgentTerminalTab(
            kind: .localShell,
            originAgentSessionID: originAgentSessionID,
            title: "Shell \(localShellCounter)",
            settings: settings
        )
        tab.start(settings: settings, workingDirectory: workingDirectory, profile: nil, skin: skin)
        register(tab)
        return tab
    }

    @discardableResult
    func openSSHTab(
        runtime: RuntimeDescriptor,
        originAgentSessionID: UUID?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) -> AgentTerminalTab {
        let normalized = runtime.normalized
        let tab = AgentTerminalTab(
            kind: .ssh(runtimeID: normalized.id, displayName: normalized.displayName, target: normalized.sshTarget),
            originAgentSessionID: originAgentSessionID,
            title: normalized.displayName,
            settings: settings
        )
        tab.start(
            settings: settings,
            workingDirectory: nil,
            profile: normalized.terminalProfile,
            skin: skin
        )
        register(tab)
        return tab
    }

    private func register(_ tab: AgentTerminalTab) {
        // Re-publish each tab's changes so the side panel updates live.
        let cancellable = tab.objectWillChange.sink { [weak self] _ in
            self?.scheduleTabChangePublish()
        }
        tabSubscriptions[tab.id] = cancellable
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func scheduleTabChangePublish() {
        guard !tabChangePublishScheduled else { return }
        tabChangePublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabChangePublishScheduled = false
            self.objectWillChange.send()
        }
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabSubscriptions[id]?.cancel()
        tabSubscriptions[id] = nil
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    func startRecordingActiveTab() {
        guard recordingTabID == nil,
              let tab = activeTab,
              tab.isRunning else { return }
        tab.startRecording()
    }

    func stopRecording() {
        guard let tab = tabs.first(where: \.isRecording),
              let shortcut = tab.stopRecording() else {
            tabs.first(where: \.isRecording)?.cancelRecording()
            return
        }
        upsertShortcut(shortcut)
    }

    func playShortcut(_ shortcut: TerminalShortcut) {
        guard !isRecording else { return }
        activeTab?.playShortcut(shortcut)
    }

    func prepareShortcutsFileForEditing() {
        TerminalShortcutStore.save(shortcuts)
    }

    @discardableResult
    func reloadShortcutsFromDisk() -> Bool {
        do {
            shortcuts = try TerminalShortcutStore.loadEditableShortcuts()
            return true
        } catch {
            print("AgentInteractiveTerminalController: failed to reload edited shortcuts: \(error)")
            return false
        }
    }

    func renameShortcut(id: UUID, title: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var shortcut = shortcuts[index]
        shortcut.title = title
        shortcut.updatedAt = Date()
        shortcuts[index] = shortcut.normalized
        persistShortcuts()
    }

    func deleteShortcut(id: UUID) {
        shortcuts
            .filter { $0.id == id }
            .forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == id }
        persistShortcuts()
    }

    private func upsertShortcut(_ shortcut: TerminalShortcut) {
        shortcuts
            .filter { $0.id == shortcut.id }
            .forEach(TerminalShortcutStore.deleteProtectedInputs)
        shortcuts.removeAll { $0.id == shortcut.id }
        shortcuts.insert(shortcut.normalized, at: 0)
        persistShortcuts()
    }

    private func persistShortcuts() {
        shortcuts = Array(shortcuts.map(\.normalized).filter(\.isPlayable).prefix(24))
        TerminalShortcutStore.save(shortcuts)
    }

    /// Make sure the panel always has at least one live tab to show; opens
    /// a local shell rooted at `workingDirectory` if there are none.
    func ensureAtLeastOneTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) {
        if tabs.isEmpty {
            openLocalTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: workingDirectory,
                settings: settings,
                skin: skin
            )
        }
    }

    func applyAppearanceToAll(_ settings: EditorTerminalSettings, skin: TerminalSkinColors?) {
        for tab in tabs {
            tab.applyAppearance(settings, skin: skin)
        }
    }

    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    // MARK: Idle reaper

    private func startIdleReaper() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func tickIdle() {
        guard !tabs.isEmpty else { return }
        let now = Date()
        var doomed: [UUID] = []
        for tab in tabs {
            tab.refreshActivityFromBuffer(now: now)
            // Never reap the tab the user is currently viewing.
            if tab.id == activeTabID { continue }
            if tab.idleSeconds(now: now) > idleTimeout {
                doomed.append(tab.id)
            }
        }
        for id in doomed {
            closeTab(id: id)
        }
    }

    // MARK: Agent-tool surface (operate on the active tab)

    func snapshot(maxCharacters: Int = 16_000) -> AgentTerminalSnapshot {
        guard let tab = activeTab else {
            return AgentTerminalSnapshot(
                isRunning: false,
                runtimeName: L10n.AgentTerminal.disconnectedRuntime,
                runtimeTarget: "",
                output: "",
                pendingCommands: [],
                recentCommands: []
            )
        }
        return AgentTerminalSnapshot(
            isRunning: tab.isRunning,
            runtimeName: tab.title,
            runtimeTarget: tab.runtimeTarget,
            output: tab.snapshotText(maxCharacters: maxCharacters),
            pendingCommands: [],
            recentCommands: tab.recentCommands
        )
    }

    func sendApprovedCommand(_ command: String, secretRedactionValues: [String] = []) throws -> AgentToolResult {
        let tab = try activeTabForToolUse()
        return try tab.sendApprovedCommand(command, secretRedactionValues: secretRedactionValues)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        let tab = try activeTabForToolUse()
        return try tab.sendApprovedControl(control)
    }

    /// The tab an agent tool should act on: the active one, or — if the
    /// user hasn't opened the terminal yet — a freshly opened local shell
    /// so the agent can drive the terminal without the user first
    /// clicking around. Falls back to a clear error only when there's no
    /// way to open one.
    private func activeTabForToolUse() throws -> AgentTerminalTab {
        if let tab = activeTab { return tab }
        guard let config = defaultLocalTabProvider?() else {
            throw AgentToolError.invalidArgument("Open the Agent Terminal side panel first so a shell is available.")
        }
        return openLocalTab(
            originAgentSessionID: config.originAgentSessionID,
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin
        )
    }
}

// MARK: - Secret redaction (unchanged)

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
