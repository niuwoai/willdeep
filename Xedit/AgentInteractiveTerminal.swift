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

    override func paste(_ sender: Any) {
        onUserActivity?()
        super.paste(sender)
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

    /// Last moment the tab saw user input or fresh process output. Drives
    /// the idle reaper. Not @Published — sampled by a timer, not the UI.
    private(set) var lastActivity = Date()
    private var lastBufferHash = 0
    private let maxRecentCommands = 20

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
        applyAppearance(settings)
        terminalView.processDelegate = self
        terminalView.onUserActivity = { [weak self] in
            self?.lastActivity = Date()
        }
    }

    func applyAppearance(_ settings: EditorTerminalSettings) {
        let scheme = settings.colorScheme
        terminalView.font = settings.font
        terminalView.nativeForegroundColor = scheme.foreground
        terminalView.nativeBackgroundColor = scheme.background
    }

    // MARK: Launch

    func start(
        settings: EditorTerminalSettings,
        workingDirectory: String?,
        profile: RuntimeTerminalProfile?
    ) {
        let env = Self.environmentArray(settings: settings)
        switch kind {
        case .localShell:
            let shell = Self.loginShellPath()
            terminalView.startProcess(
                executable: shell,
                args: ["-l"],
                environment: env,
                execName: "-" + (shell as NSString).lastPathComponent,
                currentDirectory: workingDirectory
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
        terminalView.terminate()
        isRunning = false
    }

    // MARK: Agent-tool surface

    func sendApprovedCommand(_ command: String) throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.missingArgument("command") }
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending commands.")
        }
        recordCommand(trimmed)
        lastActivity = Date()
        terminalView.send(txt: trimmed + "\n")
        let payload = """
        Sent command to Agent Terminal tab \"\(title)\".
        Command: \(trimmed)
        """
        return AgentToolResult(summary: "terminal: \(trimmed.prefix(80))", payload: payload)
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

    /// Visible-screen-plus-recent-scrollback text, secrets redacted.
    func snapshotText(maxCharacters: Int) -> String {
        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return "" }
        let bottom = terminal.buffer.yDisp + rows - 1
        let wantRows = min(400, bottom + 1)
        let startRow = max(0, bottom - wantRows + 1)
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
}

// MARK: - Controller: owns tabs + idle reaper + agent-tool surface

@MainActor
final class AgentInteractiveTerminalController: ObservableObject {
    @Published private(set) var tabs: [AgentTerminalTab] = []
    @Published var activeTabID: UUID?
    /// Default runtime for new SSH tabs.
    @Published var selectedRuntimeID: UUID?

    /// Tabs idle longer than this are auto-terminated and removed. The
    /// currently-visible tab is exempt so we never close what the user is
    /// looking at.
    private let idleTimeout: TimeInterval = 300
    private var idleTimer: Timer?
    private var localShellCounter = 0

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
        settings: EditorTerminalSettings
    ) -> AgentTerminalTab {
        localShellCounter += 1
        let tab = AgentTerminalTab(
            kind: .localShell,
            originAgentSessionID: originAgentSessionID,
            title: "Shell \(localShellCounter)",
            settings: settings
        )
        tab.start(settings: settings, workingDirectory: workingDirectory, profile: nil)
        register(tab)
        return tab
    }

    @discardableResult
    func openSSHTab(
        runtime: RuntimeDescriptor,
        originAgentSessionID: UUID?,
        settings: EditorTerminalSettings
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
            profile: normalized.terminalProfile
        )
        register(tab)
        return tab
    }

    private func register(_ tab: AgentTerminalTab) {
        // Re-publish each tab's changes so the side panel updates live.
        let cancellable = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tabSubscriptions[tab.id] = cancellable
        tabs.append(tab)
        activeTabID = tab.id
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

    /// Make sure the panel always has at least one live tab to show; opens
    /// a local shell rooted at `workingDirectory` if there are none.
    func ensureAtLeastOneTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings
    ) {
        if tabs.isEmpty {
            openLocalTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: workingDirectory,
                settings: settings
            )
        }
    }

    func applyAppearanceToAll(_ settings: EditorTerminalSettings) {
        for tab in tabs {
            tab.applyAppearance(settings)
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

    func sendApprovedCommand(_ command: String) throws -> AgentToolResult {
        guard let tab = activeTab else {
            throw AgentToolError.invalidArgument("Open the Agent Terminal side panel and start a tab before sending commands.")
        }
        return try tab.sendApprovedCommand(command)
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        guard let tab = activeTab else {
            throw AgentToolError.invalidArgument("Open the Agent Terminal side panel and start a tab before sending control input.")
        }
        return try tab.sendApprovedControl(control)
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
