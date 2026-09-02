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
//  terminal_send_control) follow the ACTIVE side-panel tab — the one the
//  user currently sees — unless an explicit terminal_tab_id targets another
//  tab. terminal_select_tab switches the active tab. Tabs remember which
//  Agent session opened them (originAgentSessionID) for grouping and
//  cleanup, but routing is driven by tab visibility, not session binding.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
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

/// Cheap main-actor metadata handed to the agent-tool layer. The actual
/// screen text is read OFF the main actor from `mirror` — a head-less
/// `Terminal` fed on a background queue — so `terminal_snapshot` no longer
/// depends on the (possibly starved) visible model being current. Redaction
/// and trimming also run off the main actor (see `AgentTerminalTools.snapshot`).
struct AgentTerminalRawSnapshot: Sendable {
    let tabID: UUID
    let isRunning: Bool
    let inputState: AgentTerminalInputState
    let isZModemTransferActive: Bool
    let runtimeName: String
    let runtimeTarget: String
    let recentCommands: [String]
    /// Off-main source of the visible screen text.
    let mirror: AgentTerminalSnapshotMirror
    /// Live geometry of the visible terminal, so the mirror can be squared
    /// up before capture even if a resize hasn't reflowed it yet.
    let cols: Int
    let rows: Int
}

/// What currently owns keyboard input on a terminal PTY. The distinction is
/// intentionally narrower than "the root process is alive": a login shell can
/// remain alive while a quiet foreground child owns the terminal for minutes.
nonisolated enum AgentTerminalInputState: String, Equatable, Sendable {
    case starting
    case shellReady = "shell_ready"
    case foregroundTask = "foreground_task"
    case interactiveProgram = "interactive_program"
    case unknown
    case exited

    static func classify(
        processIsRunning: Bool,
        shellProcessGroupID: pid_t?,
        foregroundProcessGroupID: pid_t?,
        echoEnabled: Bool?,
        canonicalInputEnabled: Bool?
    ) -> AgentTerminalInputState {
        guard processIsRunning else { return .exited }
        guard let shellProcessGroupID,
              let foregroundProcessGroupID,
              shellProcessGroupID > 0,
              foregroundProcessGroupID > 0 else {
            return .unknown
        }
        if shellProcessGroupID == foregroundProcessGroupID {
            return .shellReady
        }
        guard let echoEnabled, let canonicalInputEnabled else {
            return .unknown
        }
        // A foreground child that deliberately owns an interactive terminal
        // (SSH, vim, tmux, a REPL) normally switches the PTY to raw/no-echo.
        // Canonical + echo is the characteristic state of a non-interactive
        // foreground job such as sleep/load-test runners. Arrow keys in this
        // state are echoed as ^[[A instead of reaching shell history.
        return echoEnabled && canonicalInputEnabled ? .foregroundTask : .interactiveProgram
    }
}

nonisolated struct AgentTerminalStateEvent: Equatable, Sendable {
    enum Transition: String, Equatable, Sendable {
        case commandCompleted = "command_completed"
        case exited
    }

    let tabID: UUID
    let runtimeID: UUID?
    let transition: Transition
    let title: String
    let summary: String
}

nonisolated enum AgentTerminalCommandDispatchPolicy {
    static func refusalMessage(for inputState: AgentTerminalInputState) -> String? {
        guard inputState == .foregroundTask else { return nil }
        return "A non-interactive foreground task currently owns this terminal. Nothing was sent. Wait for it to finish, interrupt it with terminal_send_control ctrl_c, or open a new local terminal tab. For long-running work that does not need the visible terminal, use run_command with run_in_background=true."
    }
}

struct AgentTerminalCommandDispatch: Sendable {
    let result: AgentToolResult
    /// Exact tab that received the command. The tool layer uses this for its
    /// bounded follow-up snapshot even if the user switches the active tab
    /// while output is arriving.
    let terminalTabID: UUID
    let zmodemTicket: TerminalZModemTransferTicket?
}

/// Result of the "提取主机标识" probe: what machine the tab's shell is
/// actually talking to right now (a local tab may contain a manual SSH
/// session, so this is read from the live shell, not from tab metadata).
struct AgentTerminalHostIdentity: Equatable {
    var hostname: String
    var ipAddress: String
    var operatingSystem: String
    var capturedAt: Date
}

enum AgentTerminalControl: String, CaseIterable {
    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case ctrlRightBracket = "ctrl_right_bracket"
    case enter
    case escape

    var bytes: [UInt8] {
        switch self {
        case .ctrlC: return [3]
        case .ctrlD: return [4]
        case .ctrlRightBracket: return [29]
        case .enter: return [13]
        case .escape: return [27]
        }
    }

    var displayName: String {
        switch self {
        case .ctrlC: return "Ctrl-C"
        case .ctrlD: return "Ctrl-D"
        case .ctrlRightBracket: return "Ctrl-]"
        case .enter: return "Enter"
        case .escape: return "Esc"
        }
    }
}

// MARK: - Tab kind

enum AgentTerminalTabKind: Equatable {
    case localShell
    /// Reusable app-managed `/bin/sh` tab for visible external CLI delegation.
    case delegatedShell
    case ssh(runtimeID: UUID, displayName: String, target: String)

    var isSSH: Bool { if case .ssh = self { return true }; return false }
    var isDelegatedShell: Bool { self == .delegatedShell }
}

// MARK: - SwiftTerm view subclass that reports user activity

/// Callbacks the owning `AgentTerminalTab` needs from the terminal view.
/// Replaces SwiftTerm's `LocalProcessTerminalViewDelegate` because the view
/// is no longer a `LocalProcessTerminalView` (see the class note below), so
/// its `source:` type would no longer fit.
protocol AgentTerminalProcessDelegate: AnyObject {
    func sizeChanged(source: AgentLocalProcessTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: AgentLocalProcessTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: AgentLocalProcessTerminalView, directory: String?)
    func processTerminated(source: AgentLocalProcessTerminalView, exitCode: Int32?)
}

/// A `TerminalView` that owns its own `LocalProcess` — deliberately NOT a
/// `LocalProcessTerminalView`.
///
/// Why not the stock subclass: `LocalProcessTerminalView` hard-wires its
/// `LocalProcess` to `DispatchQueue.main`, and its `process` is
/// `internal(set)`, so a subclass cannot swap in a background delivery
/// queue. That main-thread delivery is exactly what makes
/// `terminal_snapshot` return stale content: when the main thread is busy
/// (mid-render while streaming a reply) the PTY→model parse is starved.
///
/// So we hand-roll the ~thin process glue `LocalProcessTerminalView` gave
/// us, but point the `LocalProcess` at a private background serial queue
/// (`snapshotMirror.queue`). On that queue `dataReceived`:
///   1. feeds a head-less mirror `Terminal` (fresh, snapshot reads this), and
///   2. marshals the *visible* terminal's model+display feed back to the
///      main thread — because the visible NSView reads its model on the main
///      thread when it draws, so feeding it off-main would race the drawing.
/// The visible terminal therefore behaves exactly as before; only the
/// snapshot path is decoupled from main-thread starvation.
///
/// `paste` is `open` in SwiftTerm so we hook it for activity; `keyDown` is
/// only `public` (not overridable cross-module), so typed-keystroke activity
/// is instead inferred from echoed output via the controller's buffer-hash
/// sampling — plus the active (visible) tab is always exempt from the idle
/// reaper, which is the only tab the user can actually be typing into.
final class AgentLocalProcessTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    /// Owned PTY process, delivering bytes on `snapshotMirror.queue`.
    private(set) var process: LocalProcess!
    /// Head-less model fed off the main thread; the source of truth for
    /// `terminal_snapshot`.
    let snapshotMirror: AgentTerminalSnapshotMirror
    weak var processDelegate: AgentTerminalProcessDelegate?

    var onUserActivity: (() -> Void)?
    var shouldRecordInput: (() -> Bool)?
    var onSendToProcess: ((_ data: [UInt8], _ echoEnabled: Bool) -> Void)?
    private lazy var zmodemBridge = TerminalZModemBridge(terminalView: self)
    private var cachedEchoEnabled: Bool?
    private var cachedEchoCheckedAt: TimeInterval = 0
    private var pendingEchoBytes: [UInt8] = []
    private let maxEchoCacheAge: TimeInterval = 1.0
    private let maxPendingEchoBytes = 2_048
    /// True while a ZMODEM transfer is in flight. Written on main (from the
    /// bridge decision), read on the delivery queue (in `dataReceived`) to
    /// pause mirror feeding — the raw protocol bytes would otherwise corrupt
    /// the mirror screen, and a snapshot mid-transfer is meaningless anyway.
    /// Lock-guarded because the two accessors run on different threads.
    private let zmodemLock = NSLock()
    private var _zmodemActive = false
    private var zmodemActive: Bool {
        get { zmodemLock.lock(); defer { zmodemLock.unlock() }; return _zmodemActive }
        set { zmodemLock.lock(); _zmodemActive = newValue; zmodemLock.unlock() }
    }

    /// Scrollback kept by the mirror. Matches SwiftTerm's default so the
    /// mirror and the visible terminal reflow identically.
    private static let mirrorScrollback = 500

    override init(frame: CGRect) {
        let seed = AgentLocalProcessTerminalView.seedGeometry(for: frame)
        snapshotMirror = AgentTerminalSnapshotMirror(
            cols: seed.cols,
            rows: seed.rows,
            scrollback: AgentLocalProcessTerminalView.mirrorScrollback,
            label: "com.willdeep.agent.terminal.snapshot-mirror"
        )
        super.init(frame: frame)
        terminalDelegate = self
        // Deliver PTY bytes on the mirror's queue, NOT the main thread.
        process = LocalProcess(delegate: self, dispatchQueue: snapshotMirror.queue)
        // Match the mirror to the visible terminal's real geometry once the
        // view has computed it from the frame + font.
        let live = getTerminal()
        snapshotMirror.resize(cols: live.cols, rows: live.rows)
        isGridClampArmed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func seedGeometry(for frame: CGRect) -> (cols: Int, rows: Int) {
        // Pre-`super.init` we can't ask the view for its cell grid, so seed
        // with a sane default; the init tail resizes the mirror to the real
        // geometry, and every `sizeChanged` keeps it in step thereafter.
        (cols: 80, rows: 24)
    }

    override func paste(_ sender: Any) {
        onUserActivity?()
        super.paste(sender)
    }

    /// Smallest grid the emulator may ever be driven to. SwiftTerm's own
    /// floor is 2 cols x 1 row, and it reflows the whole buffer on the way
    /// down: a populated scrollback rewrapped through two columns explodes
    /// far past `rows + scrollback`, so the buffer trims from the top — and
    /// widening back cannot undo it. The tab then comes back blank or with
    /// mangled rows while the scroller still advertises scrollback, which is
    /// the "side panel has no characters but still has a scrollbar" report.
    /// The side panel is clamped to 240pt (~24 cols), so this floor only
    /// ever rejects frames no real layout asks for.
    private static let minimumUsableGrid = (cols: 20, rows: 3)

    /// Armed at the end of `init`. Before that SwiftTerm is still wiring up
    /// its font metrics and terminal — asking for the optimal frame size
    /// would touch them — and there is no buffer content worth protecting.
    private var isGridClampArmed = false

    override func setFrameSize(_ newSize: NSSize) {
        // A frame too small to host a usable grid is never a real layout: it
        // is SwiftUI mounting, unmounting, or collapsing the host (panel
        // switch, detach-to-window, window restore). Dropping it keeps the
        // last real geometry — the view is off screen at that moment anyway
        // and the panel host clips, so nothing can overflow.
        guard acceptsFrameSize(newSize) else { return }
        super.setFrameSize(newSize)
        refreshVisibleTerminalDisplay()
    }

    /// Visible for testing: the grid floor as a pixel size, given the view's
    /// current font metrics.
    func acceptsFrameSize(_ size: NSSize) -> Bool {
        guard isGridClampArmed else { return true }
        let cell = currentCellSize()
        guard cell.width > 0, cell.height > 0 else { return true }
        let minWidth = cell.width * CGFloat(Self.minimumUsableGrid.cols) + Self.scrollerWidth
        let minHeight = cell.height * CGFloat(Self.minimumUsableGrid.rows)
        return size.width >= minWidth && size.height >= minHeight
    }

    /// SwiftTerm keeps `cellDimension` internal to the package, so the cell
    /// metrics are read back out of its own optimal-frame math instead.
    private func currentCellSize() -> CGSize {
        let live = getTerminal()
        guard live.cols > 0, live.rows > 0 else { return .zero }
        let optimal = getOptimalFrameSize()
        return CGSize(
            width: (optimal.width - Self.scrollerWidth) / CGFloat(live.cols),
            height: optimal.height / CGFloat(live.rows)
        )
    }

    /// Matches the scroller style SwiftTerm hardcodes for its own layout.
    private static var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Only a remount warrants the forced layout below. Running it while
        // detached is how a degenerate frame gets computed and pushed into
        // the emulator in the first place.
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Remount is the one place a forced layout is warranted: the
            // SwiftUI representable may have handed us a stale frame while
            // detached. Everywhere else (per-chunk refresh) forcing layout
            // is actively harmful — see refreshVisibleTerminalDisplay.
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            self.refreshVisibleTerminalDisplay()
        }
    }

    func refreshVisibleTerminalDisplay() {
        // No forced layout here. This runs after EVERY PTY chunk; a
        // synchronous layoutSubtreeIfNeeded on that hot path let any
        // transient SwiftUI geometry wobble (panel animation, recording bar,
        // divider drag) reach setFrameSize → terminal.resize → SIGWINCH
        // mid-stream. The local reflow plus the remote shell's redraw-on-
        // WINCH then bake mixed-generation rows and a mid-screen cursor into
        // the buffer — the "stale content below the cursor" bug.
        needsDisplay = true
        setNeedsDisplay(bounds)

        // SwiftTerm renders its caret in a separate child view. AppKit
        // invalidation redraws terminal cells but does not reposition that
        // child, which can leave the cursor on an old prompt after remounting
        // the terminal. An empty feed is side-effect free and schedules
        // SwiftTerm's own display pass, including its cursor-position update.
        feed(text: "")
    }

    var isZModemTransferActive: Bool {
        zmodemActive
    }

    func prepareZModemPathSelection(
        _ selection: TerminalZModemPathSelection?
    ) -> TerminalZModemTransferTicket? {
        zmodemBridge.preparePathSelection(selection)
    }

    /// Called by the ZMODEM bridge at session boundaries so the mirror
    /// gate reacts immediately instead of one PTY chunk late.
    func zmodemStateDidChange(active: Bool) {
        zmodemActive = active
    }

    /// Feed a ZMODEM status line to BOTH the visible terminal and the
    /// snapshot mirror. During a transfer the raw PTY stream bypasses the
    /// mirror, so status lines are the only thing keeping the agent's
    /// `terminal_snapshot` truthful about what the terminal is doing.
    func feedZModemStatusLine(_ text: String) {
        let bytes = Array(text.utf8)
        feed(byteArray: bytes[...])
        snapshotMirror.queue.async { [snapshotMirror] in
            snapshotMirror.feedOnQueue(bytes)
        }
        refreshVisibleTerminalDisplay()
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserActivity?()
        // While a ZMODEM transfer owns the PTY, keystrokes must not reach
        // the remote — they would be injected into the protocol stream and
        // corrupt frames. The bridge swallows them; Ctrl+C aborts the
        // transfer on both ends.
        if zmodemActive, zmodemBridge.handleUserInput(Array(data)) {
            return
        }
        let bytes = Array(data)
        if currentInputState == .foregroundTask,
           Self.isNavigationEscapeSequence(bytes) {
            // The shell line editor is not active while a canonical foreground
            // task owns the PTY. Passing arrows through only paints ^[[A/^[[B
            // into the screen (and may leave them queued as later shell input).
            NSSound.beep()
            return
        }
        if shouldRecordInput?() == true {
            let echoEnabled = cachedTerminalEchoEnabled()
            onSendToProcess?(bytes, echoEnabled)
            if echoEnabled {
                rememberExpectedEcho(bytes)
            }
        }
        process.send(data: data)
    }

    nonisolated static func isNavigationEscapeSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
        if bytes[1] == 0x4F, bytes.count == 3 { // ESC O A-D/H/F
            return [0x41, 0x42, 0x43, 0x44, 0x48, 0x46].contains(bytes[2])
        }
        guard bytes[1] == 0x5B,
              let final = bytes.last,
              [0x41, 0x42, 0x43, 0x44, 0x48, 0x46].contains(final) else {
            return false
        }
        // CSI arrows may carry numeric modifier parameters, e.g. ESC[1;5A.
        return bytes.dropFirst(2).dropLast().allSatisfy {
            (0x30...0x39).contains($0) || $0 == 0x3B
        }
    }

    /// Debounce window for geometry propagation. SwiftUI mount animations
    /// and divider drags emit a burst of transient sizes; every one used to
    /// go straight to the PTY as a SIGWINCH, and interactive remotes (bash /
    /// readline) redraw their prompt on each — against a locally reflowed
    /// buffer whose row mapping no longer matches, leaving mixed-generation
    /// rows behind. Only the settled size is worth telling the child about.
    private static let winsizeDebounce: TimeInterval = 0.12
    private var pendingWinsizeItem: DispatchWorkItem?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Transitional degenerate sizes (collapsing panes, zero frames
        // during remount) must never reach the child process or the mirror.
        guard newCols >= 2, newRows >= 2 else { return }
        pendingWinsizeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWinsizeItem = nil
            self.commitWindowSize()
        }
        pendingWinsizeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.winsizeDebounce, execute: item)
    }

    /// Push the CURRENT settled geometry (not the possibly stale values a
    /// debounced call captured) to the PTY, the snapshot mirror, and the
    /// process delegate.
    private func commitWindowSize() {
        let live = getTerminal()
        let cols = live.cols
        let rows = live.rows
        guard cols >= 2, rows >= 2 else { return }
        if process.running {
            var size = getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        }
        // Keep the mirror's wrapping in step with what the user sees.
        snapshotMirror.resize(cols: cols, rows: rows)
        processDelegate?.sizeChanged(source: self, newCols: cols, newRows: rows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: self, directory: directory)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let str = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([str as NSString])
    }

    // MARK: LocalProcessDelegate

    /// Runs on `snapshotMirror.queue` — NOT the main thread. Feeding the
    /// mirror here is the whole fix: it can never be starved by main-thread
    /// rendering, so the snapshot stays fresh. Everything main-affine (the
    /// @MainActor ZMODEM bridge, echo bookkeeping shared with `send`, and the
    /// visible terminal's model+display) is marshaled back to main, ordered.
    func dataReceived(slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        if !zmodemActive {
            snapshotMirror.feedOnQueue(bytes)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The bridge returns the bytes the terminal should render:
            // usually the chunk unchanged, nil while a transfer consumes the
            // stream, or a substitute chunk when the detector releases bytes
            // it had held across a read boundary.
            let renderable = self.zmodemBridge.handleRemoteBytes(bytes)
            self.zmodemActive = self.zmodemBridge.isActive
            guard let renderable, !renderable.isEmpty else { return }
            if self.shouldRecordInput?() == true, !self.isExpectedEcho(renderable[...]) {
                self.invalidateTerminalEchoCache()
            }
            self.feed(byteArray: renderable[...])
            self.refreshVisibleTerminalDisplay()
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processDelegate?.processTerminated(source: self, exitCode: exitCode)
        }
    }

    func getWindowSize() -> winsize {
        let f = self.frame
        let live = getTerminal()
        return winsize(
            ws_row: UInt16(live.rows),
            ws_col: UInt16(live.cols),
            ws_xpixel: UInt16(f.width),
            ws_ypixel: UInt16(f.height)
        )
    }

    // MARK: Process control (mirrors the old LocalProcessTerminalView surface)

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        process.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    func terminate() {
        let rootPID = process.shellPid
        if rootPID > 0 {
            // SwiftTerm only SIGTERMs its immediate child. Capture and signal
            // the complete tree first, then let SwiftTerm close the PTY so an
            // SSH peer receives hangup. Survivors are SIGKILLed after the
            // shared grace period with PID-reuse protection.
            AgentProcessSupport.terminateProcessTree(rootPID: rootPID)
        }
        // `LocalProcess.terminate()` and its exit-source handler both run
        // `childStopped()`, which cancels and nils the same `DispatchSourceProcess`.
        // Upstream is safe from that because it delivers on `DispatchQueue.main`;
        // we deliberately hand it `snapshotMirror.queue` instead (see init), so
        // the two would otherwise run concurrently — main tearing down while the
        // mirror queue handles the exit we just triggered by killing the tree.
        // That over-releases the dispatch source and traps in `_os_object_retain`.
        // Running the teardown on the delivery queue restores the serialization
        // upstream gets for free. Synchronous on purpose: callers read
        // `process.running` right after this returns.
        let localProcess = process
        snapshotMirror.queue.sync {
            localProcess?.terminate()
        }
    }

    var terminalEchoEnabled: Bool {
        guard process.running else { return false }
        var attributes = termios()
        guard tcgetattr(process.childfd, &attributes) == 0 else { return false }
        return (attributes.c_lflag & tcflag_t(ECHO)) != 0
    }

    var currentInputState: AgentTerminalInputState {
        guard process.running else {
            return process.shellPid > 0 ? .exited : .starting
        }
        let shellPID = pid_t(process.shellPid)
        guard shellPID > 0 else { return .starting }
        let rawShellGroup = getpgid(shellPID)
        let rawForegroundGroup = tcgetpgrp(process.childfd)
        var attributes = termios()
        let hasAttributes = tcgetattr(process.childfd, &attributes) == 0
        return AgentTerminalInputState.classify(
            processIsRunning: true,
            shellProcessGroupID: rawShellGroup > 0 ? rawShellGroup : nil,
            foregroundProcessGroupID: rawForegroundGroup > 0 ? rawForegroundGroup : nil,
            echoEnabled: hasAttributes ? (attributes.c_lflag & tcflag_t(ECHO)) != 0 : nil,
            canonicalInputEnabled: hasAttributes ? (attributes.c_lflag & tcflag_t(ICANON)) != 0 : nil
        )
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
final class AgentTerminalTab: ObservableObject, Identifiable, AgentTerminalProcessDelegate {
    nonisolated static let delegatedShellExecutable = "/bin/sh"

    /// Hard ceiling on a single automation command typed into the pty. The
    /// tty input queue (MAX_INPUT, 1024 bytes on Darwin) drops the tail of
    /// anything larger once the interactive shell's echo backs up the output
    /// queue. Delegated invocations are `/bin/sh <runner path>` — ~100 bytes —
    /// so this only fires if someone reintroduces an inline wrapper.
    nonisolated static let maximumAutomationCommandBytes = 512

    let id: UUID
    /// Which Agent session opened this tab. nil for tabs the user opened
    /// manually with no active session context.
    let originAgentSessionID: UUID?
    let kind: AgentTerminalTabKind
    let terminalView: AgentLocalProcessTerminalView

    @Published var title: String
    @Published private(set) var isRunning = false
    @Published private(set) var inputState: AgentTerminalInputState = .starting
    @Published private(set) var recentCommands: [String] = []
    @Published private(set) var activeRecordingStartedAt: Date?
    @Published private(set) var isPlayingShortcut = false
    @Published private(set) var shortcutPlaybackState: TerminalShortcutPlaybackState?
    @Published private(set) var shortcutBadgeTitle: String?
    @Published private(set) var isAutomationBusy = false
    @Published private(set) var hostIdentity: AgentTerminalHostIdentity?
    @Published private(set) var isExtractingHostIdentity = false

    /// Last moment the tab saw user input or fresh process output. Drives
    /// the idle reaper. Not @Published — sampled by a timer, not the UI.
    private(set) var lastActivity = Date()
    private var lastBufferHash = 0
    private let maxRecentCommands = 20
    private var recorder: TerminalShortcutRecorder?
    private var shortcutPlaybackTask: Task<Void, Never>?
    private var hostIdentityTask: Task<Void, Never>?

    init(
        id: UUID = UUID(),
        kind: AgentTerminalTabKind,
        originAgentSessionID: UUID?,
        title: String,
        settings: EditorTerminalSettings
    ) {
        self.id = id
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
        let env = EditorTerminalLaunchEnvironment.array(
            settings: settings,
            injectClaudeCodeCompatibility: kind == .localShell,
            markAsAgentTerminal: true
        )
        switch kind {
        case .localShell:
            let shell = Self.loginShellPath(settings.shellPath)
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
        case .delegatedShell:
            let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            terminalView.startProcess(
                executable: Self.delegatedShellExecutable,
                args: ["-i"],
                environment: env,
                execName: "sh",
                currentDirectory: cwd
            )
        case .ssh(_, _, let target):
            guard let descriptor = sshDescriptor() else {
                isRunning = false
                inputState = .exited
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
        refreshInputState()
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
        shortcutPlaybackTask?.cancel()
        shortcutPlaybackTask = nil
        hostIdentityTask?.cancel()
        hostIdentityTask = nil
        isExtractingHostIdentity = false
        finishShortcutPlayback(status: .cancelled(reason: "terminal_stopped"))
        terminalView.terminate()
        isRunning = false
        inputState = .exited
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
        refreshInputState()
        guard isRunning,
              shortcut.isPlayable,
              !shortcut.hasPendingProtectedInput,
              !isRecording,
              !isPlayingShortcut,
              inputState != .foregroundTask else { return }
        isPlayingShortcut = true
        let startedAt = Date()
        let totalDelay = shortcut.playbackDurationMilliseconds
        shortcutBadgeTitle = Self.shortcutBadgeTitle(for: shortcut.title)
        shortcutPlaybackTask?.cancel()
        shortcutPlaybackState = TerminalShortcutPlaybackState(
            shortcutID: shortcut.id,
            title: shortcut.title,
            currentEventIndex: 0,
            totalEvents: shortcut.eventCount,
            startedAt: startedAt,
            estimatedFinishedAt: startedAt.addingTimeInterval(Double(totalDelay) / 1000),
            totalDelayMilliseconds: totalDelay,
            status: .running
        )
        shortcutPlaybackTask = Task { [weak self] in
            var protectedBytesCache: [String: [UInt8]] = [:]
            var completedNormally = true
            for (index, event) in shortcut.events.enumerated() {
                guard !Task.isCancelled else {
                    completedNormally = false
                    break
                }
                await MainActor.run {
                    guard let self, self.isRunning else { return }
                    self.shortcutPlaybackState?.currentEventIndex = index + 1
                }
                if event.delayMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(event.delayMilliseconds) * 1_000_000)
                }
                guard !Task.isCancelled else {
                    completedNormally = false
                    break
                }
                let shouldContinue = await MainActor.run {
                    guard let self, self.isRunning else { return false }
                    if event.requiresEchoOff, self.terminalView.terminalEchoEnabled {
                        self.finishShortcutPlayback(status: .cancelled(reason: "echo_enabled"))
                        return false
                    }
                    return true
                }
                if shouldContinue == false {
                    completedNormally = false
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
                guard let self else { return }
                if completedNormally {
                    self.finishShortcutPlayback(status: .finished)
                } else if self.isPlayingShortcut {
                    self.finishShortcutPlayback(status: .cancelled(reason: "interrupted"))
                }
            }
        }
    }

    func cancelShortcutPlayback() {
        guard isPlayingShortcut else { return }
        shortcutPlaybackTask?.cancel()
        shortcutPlaybackTask = nil
        finishShortcutPlayback(status: .cancelled(reason: "user_cancelled"))
    }

    private func finishShortcutPlayback(status: TerminalShortcutPlaybackState.Status) {
        isPlayingShortcut = false
        shortcutPlaybackTask = nil
        guard shortcutPlaybackState != nil else { return }
        shortcutPlaybackState?.status = status
        shortcutPlaybackState?.currentEventIndex = shortcutPlaybackState?.totalEvents ?? 0
    }

    nonisolated static func shortcutBadgeTitle(for title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(24))
    }

    // MARK: Host identity extraction ("提取主机标识")

    /// Output marker assembled at runtime so the echoed probe command line
    /// never contains the literal string the parser scans for.
    nonisolated static let hostIdentityMarker = "WD_HOST" + "IDENT"

    /// One POSIX-compatible line that prints marker|hostname|ip|os on
    /// Debian/Ubuntu (and most Linuxes) as well as macOS. Runs in whatever
    /// shell the tab currently talks to — including a manual SSH session —
    /// which is exactly the point: identify the real host behind the tab.
    nonisolated static let hostIdentityProbeCommand =
        #"printf '%s|%s|%s|%s\n' "WD_HOST""IDENT" "$(hostname)" "$( (hostname -I 2>/dev/null || ipconfig getifaddr en0 2>/dev/null) | awk '{print $1; exit}' )" "$( (. /etc/os-release 2>/dev/null && printf %s "$PRETTY_NAME") || sw_vers -productName 2>/dev/null || uname -s )""#

    /// Send the identity probe into the tab's live shell, poll the snapshot
    /// mirror for the marker line, then adopt the hostname as the tab title.
    func extractHostIdentity() {
        refreshInputState()
        guard canExtractHostIdentity else { return }
        isExtractingHostIdentity = true
        recordCommand(Self.hostIdentityProbeCommand)
        lastActivity = Date()
        terminalView.send(txt: Self.hostIdentityProbeCommand + "\n")
        hostIdentityTask?.cancel()
        hostIdentityTask = Task { [weak self] in
            // Up to ~8s to cover slow remote shells inside the tab.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self, self.isExtractingHostIdentity else { return }
                guard let identity = self.parseHostIdentityFromScreen() else { continue }
                self.hostIdentity = identity
                if !identity.hostname.isEmpty {
                    self.title = String(identity.hostname.prefix(40))
                }
                self.isExtractingHostIdentity = false
                return
            }
            self?.isExtractingHostIdentity = false
        }
    }

    private func parseHostIdentityFromScreen() -> AgentTerminalHostIdentity? {
        let source = snapshotSource()
        source.mirror.resize(cols: source.cols, rows: source.rows)
        let viewport = source.mirror.captureViewport()
        let markerPrefix = Self.hostIdentityMarker + "|"
        for line in viewport.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(markerPrefix) else { continue }
            let fields = trimmed.dropFirst(markerPrefix.count).components(separatedBy: "|")
            guard let hostname = fields.first?.trimmingCharacters(in: .whitespaces),
                  !hostname.isEmpty else { continue }
            return AgentTerminalHostIdentity(
                hostname: hostname,
                ipAddress: fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : "",
                operatingSystem: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : "",
                capturedAt: Date()
            )
        }
        return nil
    }

    // MARK: Agent-tool surface

    func sendApprovedCommand(
        _ command: String,
        zmodemPathSelection: TerminalZModemPathSelection? = nil,
        secretRedactionValues: [String] = []
    ) throws -> AgentToolResult {
        try sendApprovedCommandDispatch(
            command,
            zmodemPathSelection: zmodemPathSelection,
            secretRedactionValues: secretRedactionValues
        ).result
    }

    func sendApprovedCommandDispatch(
        _ command: String,
        zmodemPathSelection: TerminalZModemPathSelection? = nil,
        secretRedactionValues: [String] = []
    ) throws -> AgentTerminalCommandDispatch {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentToolError.missingArgument("command") }
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending commands.")
        }
        refreshInputState()
        if let refusal = AgentTerminalCommandDispatchPolicy.refusalMessage(for: inputState) {
            throw AgentToolError.invalidArgument(refusal)
        }
        let visibleCommand = AgentSecretStore.redact(trimmed, secretValues: secretRedactionValues)
        recordCommand(visibleCommand)
        lastActivity = Date()
        let zmodemTicket = terminalView.prepareZModemPathSelection(zmodemPathSelection)
        terminalView.send(txt: trimmed + "\n")
        var payload = """
        Command dispatch confirmed for Agent Terminal tab \"\(title)\".
        Command: \(visibleCommand)

        This dispatch confirmation does not contain command output.
        """
        switch zmodemPathSelection {
        case .upload(let files):
            payload += "\nPrepared ZMODEM upload files:\n" + files.map(\.path).joined(separator: "\n")
        case .download(let directory):
            payload += "\nPrepared ZMODEM download directory: \(directory.path)"
        case nil:
            break
        }
        return AgentTerminalCommandDispatch(
            result: AgentToolResult(summary: "terminal: \(visibleCommand.prefix(80))", payload: payload),
            terminalTabID: id,
            zmodemTicket: zmodemTicket
        )
    }

    func sendApprovedControl(_ control: AgentTerminalControl) throws -> AgentToolResult {
        guard isRunning else {
            throw AgentToolError.invalidArgument("Open and start an Agent Terminal tab before sending control input.")
        }
        sendUserControl(control)
        let payload = "Sent \(control.displayName) to Agent Terminal tab \"\(title)\"."
        return AgentToolResult(summary: "terminal: \(control.displayName)", payload: payload)
    }

    func sendUserControl(_ control: AgentTerminalControl) {
        guard isRunning else { return }
        lastActivity = Date()
        terminalView.send(control.bytes)
    }

    func sendAutomationCommand(_ command: String, displayCommand: String) throws {
        guard isRunning else {
            throw AgentToolError.invalidArgument("The bound Agent Terminal tab is not running.")
        }
        guard !isAutomationBusy else {
            throw AgentToolError.invalidArgument("The bound Agent Terminal tab is already running another delegated task.")
        }
        refreshInputState()
        guard inputState != .foregroundTask, inputState != .interactiveProgram else {
            throw AgentToolError.invalidArgument(
                "The delegated terminal is still owned by a foreground or interactive program. Nothing was sent; wait for the shell prompt, interrupt that program, or use another delegated tab."
            )
        }
        // Typed into the pty as input, so it is bound by the tty input queue —
        // see AgentDelegatedTerminalRunner for the full failure mode. Anything
        // large must be staged in a runner file and invoked by path.
        guard command.utf8.count <= Self.maximumAutomationCommandBytes else {
            throw AgentToolError.invalidArgument(
                "Automation command is \(command.utf8.count) bytes; the pty input queue truncates past \(Self.maximumAutomationCommandBytes). Stage it in a runner file and send `/bin/sh <path>` instead."
            )
        }
        isAutomationBusy = true
        title = "\(displayCommand) · sh"
        recordCommand(displayCommand)
        lastActivity = Date()
        terminalView.send(txt: command + "\n")
    }

    func finishAutomationCommand() {
        isAutomationBusy = false
        lastActivity = Date()
    }

    /// The off-main snapshot mirror plus the visible terminal's live grid
    /// size. The screen text itself is read from the mirror off the main
    /// actor by `AgentTerminalTools.snapshot`, so a busy main thread can no
    /// longer make the snapshot stale.
    func snapshotSource() -> (mirror: AgentTerminalSnapshotMirror, cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminalView.snapshotMirror, terminal.cols, terminal.rows)
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
        if kind.isDelegatedShell { return "/bin/sh automation tab" }
        return "local tab (may contain nested manual SSH)"
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

    func refreshInputState() {
        let next = isRunning ? terminalView.currentInputState : .exited
        guard next != inputState else { return }
        inputState = next
    }

    var canExtractHostIdentity: Bool {
        guard isRunning, !isAutomationBusy, !isExtractingHostIdentity else { return false }
        return inputState != .foregroundTask
    }

    // MARK: AgentTerminalProcessDelegate

    func sizeChanged(source: AgentLocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: AgentLocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep the user/origin label as the primary title; the OSC title
        // is noisy. Only adopt it for local tabs that still carry the
        // generic default name.
        if kind == .localShell, self.title.hasPrefix("Shell") {
            self.title = String(trimmed.prefix(40))
        }
    }

    func hostCurrentDirectoryUpdate(source: AgentLocalProcessTerminalView, directory: String?) {}

    func processTerminated(source: AgentLocalProcessTerminalView, exitCode: Int32?) {
        isRunning = false
        inputState = .exited
        finishShortcutPlayback(status: .cancelled(reason: "terminal_exited"))
    }

    // MARK: Helpers

    private static func loginShellPath(_ configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
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
    /// Keep the visible delegated-executor pool small. Finished tabs are
    /// reused; additional tasks wait for a free slot instead of opening tabs
    /// without bound.
    nonisolated static let maximumDelegatedShellTabs = 3

    nonisolated static func canCreateDelegatedShellTab(existingCount: Int) -> Bool {
        max(existingCount, 0) < maximumDelegatedShellTabs
    }

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
    var defaultLocalTabProvider: ((UUID?) -> (settings: EditorTerminalSettings, workingDirectory: String?, originAgentSessionID: UUID?, skin: TerminalSkinColors?)?)?
    /// Low-frequency semantic transitions for the runtime event kernel. Raw
    /// PTY bytes never cross this boundary: a repaint or prompt echo must not
    /// become an interrupt storm.
    var onStateEvent: ((AgentTerminalStateEvent) -> Void)?

    /// Tabs idle longer than this are auto-terminated and removed. The
    /// currently-visible tab is exempt so we never close what the user is
    /// looking at.
    private let idleTimeout: TimeInterval = 300
    private var idleTimer: Timer?
    private var inputStateTimer: Timer?
    private var localShellCounter = 0
    private var tabChangePublishScheduled = false
    private var lastReportedInputStates: [UUID: AgentTerminalInputState] = [:]
    /// A ready-shell transition is meaningful to the Agent only when an
    /// Agent tool actually dispatched the foreground command. User typing in
    /// a tab that merely belongs to the same session must stay UI-local.
    private var pendingAgentCommandTabIDs: Set<UUID> = []
    /// Only tabs created by Agent automation may publish an exit event. A
    /// user-created side-panel tab keeps its lifecycle in the terminal UI.
    private var agentCreatedTabIDs: Set<UUID> = []
    /// Closing the visible SSH tab must not silently retarget a later,
    /// unqualified agent command to a local shell. Keep a short-lived routing
    /// tombstone until the user or agent explicitly chooses another tab.
    private var closedRemoteRoute: (title: String, target: String)?

    init() {
        startIdleReaper()
    }

    deinit {
        idleTimer?.invalidate()
        inputStateTimer?.invalidate()
    }

    var activeTab: AgentTerminalTab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    func tab(id: UUID) -> AgentTerminalTab? {
        tabs.first { $0.id == id }
    }

    /// The most recent tab this session opened. Ownership only groups tabs
    /// per conversation for bootstrap/cleanup; command routing follows the
    /// active tab instead.
    func ownedTabID(for sessionID: UUID?) -> UUID? {
        guard let sessionID else { return nil }
        return tabs.last(where: { $0.originAgentSessionID == sessionID })?.id
    }

    var recordingTabID: UUID? {
        tabs.first(where: \.isRecording)?.id
    }

    var isRecording: Bool {
        recordingTabID != nil
    }

    var recordingStartedAt: Date? {
        tabs.first(where: \.isRecording)?.activeRecordingStartedAt
    }

    var activeShortcutPlaybackState: TerminalShortcutPlaybackState? {
        activeTab?.shortcutPlaybackState
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
        skin: TerminalSkinColors?,
        clearsClosedRemoteRoute: Bool = true
    ) -> AgentTerminalTab {
        if clearsClosedRemoteRoute {
            closedRemoteRoute = nil
        }
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
    func openDelegatedShellTab(
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) -> AgentTerminalTab {
        let tab = AgentTerminalTab(
            kind: .delegatedShell,
            originAgentSessionID: nil,
            title: L10n.AgentTerminal.delegatedShellTitle,
            settings: settings
        )
        tab.start(settings: settings, workingDirectory: workingDirectory, profile: nil, skin: skin)
        agentCreatedTabIDs.insert(tab.id)
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
        closedRemoteRoute = nil
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
        lastReportedInputStates[tab.id] = tab.inputState
        activeTabID = tab.id
        startInputStateMonitorIfNeeded()
    }

    func activateTab(id: UUID) {
        guard tab(id: id) != nil else { return }
        closedRemoteRoute = nil
        activeTabID = id
    }

    func activateOwnedTab(for sessionID: UUID?) {
        guard let tabID = ownedTabID(for: sessionID) else { return }
        activeTabID = tabID
    }

    private func scheduleTabChangePublish() {
        guard !tabChangePublishScheduled else { return }
        tabChangePublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabChangePublishScheduled = false
            self.publishSemanticTerminalTransitions()
            self.objectWillChange.send()
        }
    }

    private func publishSemanticTerminalTransitions() {
        for tab in tabs {
            let previous = lastReportedInputStates[tab.id] ?? .starting
            let current = tab.inputState
            guard previous != current else { continue }
            lastReportedInputStates[tab.id] = current
            let transition = Self.semanticTransition(
                from: previous,
                to: current,
                hasPendingAgentCommand: pendingAgentCommandTabIDs.contains(tab.id),
                isAgentCreatedTab: agentCreatedTabIDs.contains(tab.id)
            )
            if transition == .exited {
                pendingAgentCommandTabIDs.remove(tab.id)
            } else if transition == .commandCompleted {
                pendingAgentCommandTabIDs.remove(tab.id)
            }
            guard let transition else { continue }
            let summary: String
            switch transition {
            case .commandCompleted:
                summary = "Terminal \(tab.title) returned to a ready shell."
            case .exited:
                summary = "Terminal \(tab.title) exited."
            }
            onStateEvent?(
                AgentTerminalStateEvent(
                    tabID: tab.id,
                    runtimeID: tab.originAgentSessionID,
                    transition: transition,
                    title: tab.title,
                    summary: summary
                )
            )
        }
    }

    nonisolated static func semanticTransition(
        from previous: AgentTerminalInputState,
        to current: AgentTerminalInputState,
        hasPendingAgentCommand: Bool,
        isAgentCreatedTab: Bool
    ) -> AgentTerminalStateEvent.Transition? {
        if current == .exited, isAgentCreatedTab {
            return .exited
        }
        if current == .shellReady,
           previous == .foregroundTask || previous == .interactiveProgram,
           hasPendingAgentCommand {
            return .commandCompleted
        }
        return nil
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // A delegated Claude/Codex task owns this tab until its wrapper reports
        // a final status. Closing it early would detach the visible execution
        // from the conversation and make a later tool call appear to "jump"
        // to another tab.
        guard !tabs[index].isAutomationBusy else { return }
        let closingTab = tabs[index]
        if activeTabID == id, closingTab.kind.isSSH {
            closedRemoteRoute = (closingTab.title, closingTab.runtimeTarget)
        }
        closingTab.terminate()
        tabSubscriptions[id]?.cancel()
        tabSubscriptions[id] = nil
        lastReportedInputStates[id] = nil
        pendingAgentCommandTabIDs.remove(id)
        agentCreatedTabIDs.remove(id)
        tabs.remove(at: index)
        stopInputStateMonitorIfIdle()
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    func stopTab(id: UUID) {
        guard let target = tab(id: id), !target.isAutomationBusy else { return }
        target.terminate()
    }

    func sendUserControl(_ control: AgentTerminalControl, toTabID id: UUID) {
        guard let target = tab(id: id), !target.isAutomationBusy else { return }
        target.sendUserControl(control)
    }

    func closeTabs(openedBy sessionID: UUID) {
        let ids = tabs
            .filter { $0.originAgentSessionID == sessionID }
            .map(\.id)
        ids.forEach(closeTab)
    }

    /// Start recording in the active tab. Without a usable active tab this
    /// falls back to a running local shell — activating it — or opens a
    /// fresh local shell tab, so the record button never dead-ends on an
    /// empty or exited panel.
    func startRecordingActiveTab() {
        guard recordingTabID == nil else { return }
        if let tab = activeTab, tab.isRunning, !tab.kind.isDelegatedShell, !tab.isAutomationBusy {
            tab.startRecording()
            return
        }
        if let localTab = tabs.last(where: { $0.kind == .localShell && $0.isRunning && !$0.isAutomationBusy }) {
            activeTabID = localTab.id
            localTab.startRecording()
            return
        }
        guard let config = defaultLocalTabProvider?(nil) else { return }
        let created = openLocalTab(
            originAgentSessionID: config.originAgentSessionID,
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin
        )
        created.startRecording()
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
        guard let target = shortcutPlaybackTab() else { return }
        target.playShortcut(shortcut)
    }

    /// Pick a safe local tab for a saved shortcut, creating one when the
    /// terminal is empty. Playback used to be a silent no-op when every tab
    /// was closed, while recording already had this fallback.
    private func shortcutPlaybackTab() -> AgentTerminalTab? {
        if let active = activeTab,
           active.isRunning,
           !active.kind.isDelegatedShell,
           !active.isAutomationBusy {
            return active
        }
        if let local = tabs.last(where: {
            $0.kind == .localShell && $0.isRunning && !$0.isAutomationBusy
        }) {
            activeTabID = local.id
            return local
        }
        guard let config = defaultLocalTabProvider?(nil) else { return nil }
        return openLocalTab(
            originAgentSessionID: config.originAgentSessionID,
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin
        )
    }

    func cancelActiveShortcutPlayback() {
        activeTab?.cancelShortcutPlayback()
    }

    func prepareShortcutFileForEditing(id: UUID) -> URL? {
        do {
            // AppState instances each own an independent terminal controller.
            // Saving an edit in an Editor window can therefore update the
            // shared store while a retained/headless Agent AppState still has
            // the pre-edit snapshot in memory. Always refresh from the
            // canonical store before regenerating the per-item edit file, or
            // that stale controller would overwrite the edit file with old
            // content the next time the user chooses Edit.
            let persistedShortcuts = try TerminalShortcutStore.loadEditableShortcuts()
            guard let shortcut = persistedShortcuts.first(where: { $0.id == id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            shortcuts = persistedShortcuts
            return try TerminalShortcutStore.prepareEditableFile(for: shortcut)
        } catch {
            print("AgentInteractiveTerminalController: failed to prepare shortcut edit file: \(error)")
            return nil
        }
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

    @discardableResult
    func reloadShortcutFromEditFile(id: UUID, url: URL) -> Bool {
        do {
            guard let index = shortcuts.firstIndex(where: { $0.id == id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            var edited = try TerminalShortcutStore.loadEditableShortcut(from: url, expectedID: id)
            edited.updatedAt = Date()
            shortcuts[index] = edited
            persistShortcuts()
            return true
        } catch {
            print("AgentInteractiveTerminalController: failed to reload edited shortcut: \(error)")
            return false
        }
    }

    func saveShortcutEdit(
        id: UUID,
        json: String,
        protectedValues: [UUID: String]
    ) throws {
        var persisted = try TerminalShortcutStore.loadEditableShortcuts()
        guard let index = persisted.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var edited = try TerminalShortcutStore.decodeEditableShortcut(json, expectedID: id)
        edited.updatedAt = Date()

        for eventIndex in edited.events.indices where edited.events[eventIndex].requiresEchoOff {
            let eventID = edited.events[eventIndex].id
            let account = edited.events[eventIndex].protectedBytesReference
                ?? TerminalShortcutStore.protectedInputAccount(shortcutID: id, eventID: eventID)
            edited.events[eventIndex].protectedBytesReference = account
            guard let value = protectedValues[eventID], !value.isEmpty else { continue }
            TerminalShortcutProtectedVault.save(Array(value.utf8), account: account)
        }

        persisted[index] = edited
        TerminalShortcutStore.save(persisted)
        shortcuts = TerminalShortcutStore.load()
    }

    func renameShortcut(id: UUID, title: String) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        var shortcut = shortcuts[index]
        shortcut.title = title
        shortcut.updatedAt = Date()
        shortcuts[index] = shortcut.normalized
        persistShortcuts()
    }

    @discardableResult
    func cloneShortcut(id: UUID, title: String, now: Date = Date()) -> TerminalShortcut? {
        guard let source = shortcuts.first(where: { $0.id == id }) else { return nil }
        let clonedEvents = source.events.map { sourceEvent in
            var event = sourceEvent
            event.id = UUID()
            guard event.requiresEchoOff else { return event }
            event.transientProtectedBytes = sourceEvent.resolvedBytes()
            event.protectedBytesReference = nil
            return event
        }
        let clone = TerminalShortcut(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            durationMilliseconds: source.durationMilliseconds,
            events: clonedEvents,
            hasProtectedInput: clonedEvents.contains(where: \.requiresEchoOff)
        ).normalized
        shortcuts.insert(clone, at: 0)
        persistShortcuts()
        return shortcuts.first(where: { $0.id == clone.id })
    }

    @discardableResult
    func createShortcut(
        title: String,
        events createEvents: [TerminalShortcutCreateEvent],
        now: Date = Date()
    ) throws -> TerminalShortcut {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        guard !createEvents.isEmpty else {
            throw AgentToolError.invalidArgument("Terminal shortcut creation requires at least one event.")
        }

        let events = try createEvents.map { createEvent in
            let delay = min(max(createEvent.delayMilliseconds, 0), 300_000)
            if createEvent.kind == .protectedPlaceholder {
                let placeholder = createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !placeholder.isEmpty else {
                    throw AgentToolError.invalidArgument("Terminal shortcut protected placeholders cannot be empty.")
                }
                return TerminalShortcutEvent(
                    delayMilliseconds: delay,
                    bytes: [],
                    requiresEchoOff: true,
                    protectedPlaceholder: String(placeholder.prefix(80))
                )
            }
            let bytes = try Self.shortcutBytes(for: createEvent)
            guard !bytes.isEmpty else {
                throw AgentToolError.invalidArgument("Terminal shortcut events cannot be empty.")
            }
            return TerminalShortcutEvent(
                delayMilliseconds: delay,
                bytes: bytes
            )
        }
        let duration = events.reduce(0) { $0 + max(0, $1.delayMilliseconds) }
        let shortcut = TerminalShortcut(
            id: UUID(),
            title: trimmed,
            createdAt: now,
            updatedAt: now,
            durationMilliseconds: duration,
            events: events,
            hasProtectedInput: events.contains { $0.requiresEchoOff }
        ).normalized
        shortcuts.insert(shortcut, at: 0)
        persistShortcuts()
        return shortcut
    }

    @discardableResult
    func editShortcut(
        id: UUID,
        title: String?,
        operations: [TerminalShortcutEditOperation]
    ) throws -> TerminalShortcut {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else {
            throw AgentToolError.invalidArgument("Unknown terminal shortcut id: \(id.uuidString).")
        }

        var shortcut = shortcuts[index]
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                shortcut.title = trimmed
            }
        }

        for operation in operations {
            guard shortcut.events.indices.contains(operation.eventIndex) else {
                throw AgentToolError.invalidArgument("Terminal shortcut event index \(operation.eventIndex) is out of range.")
            }

            switch operation.kind {
            case .setDelay:
                guard let delay = operation.delayMilliseconds else {
                    throw AgentToolError.missingArgument("delay_ms")
                }
                shortcut.events[operation.eventIndex].delayMilliseconds = min(max(delay, 0), 300_000)
            case .deleteEvent:
                shortcut.events.remove(at: operation.eventIndex)
            case .replaceVisibleText:
                try editVisibleEventText(
                    shortcut: &shortcut,
                    eventIndex: operation.eventIndex,
                    find: operation.find,
                    replacement: operation.replacement ?? ""
                )
            case .setVisibleText:
                guard let text = operation.text else {
                    throw AgentToolError.missingArgument("text")
                }
                try setVisibleEventText(shortcut: &shortcut, eventIndex: operation.eventIndex, text: text)
            case .deleteVisibleText:
                try editVisibleEventText(
                    shortcut: &shortcut,
                    eventIndex: operation.eventIndex,
                    find: operation.find,
                    replacement: ""
                )
            }
        }

        shortcut.updatedAt = Date()
        shortcut.hasProtectedInput = shortcut.events.contains { $0.requiresEchoOff }
        let normalized = shortcut.normalized
        guard normalized.isPlayable else {
            throw AgentToolError.invalidArgument("Terminal shortcut edits removed all playable events.")
        }
        shortcuts[index] = normalized
        persistShortcuts()
        return normalized
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
        let normalized = Array(shortcuts.map(\.normalized).filter(\.isPlayable).prefix(24))
        TerminalShortcutStore.save(normalized)
        shortcuts = TerminalShortcutStore.load()
    }

    @discardableResult
    func fillProtectedInputs(
        shortcutID: UUID,
        valuesByEventIndex: [Int: String]
    ) throws -> TerminalShortcut {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else {
            throw AgentToolError.invalidArgument("Unknown terminal shortcut id: \(shortcutID.uuidString).")
        }
        guard !valuesByEventIndex.isEmpty else {
            throw AgentToolError.missingArgument("protected input values")
        }

        var shortcut = shortcuts[index]
        for (eventIndex, value) in valuesByEventIndex {
            guard shortcut.events.indices.contains(eventIndex) else {
                throw AgentToolError.invalidArgument("Terminal shortcut event index \(eventIndex) is out of range.")
            }
            guard shortcut.events[eventIndex].requiresEchoOff else {
                throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) is not a protected input placeholder.")
            }
            guard !value.isEmpty else {
                throw AgentToolError.invalidArgument("Protected input for event \(eventIndex) cannot be empty.")
            }
            shortcut.events[eventIndex].transientProtectedBytes = Array(value.utf8)
        }

        shortcut.updatedAt = Date()
        shortcut.hasProtectedInput = shortcut.events.contains { $0.requiresEchoOff }
        shortcuts[index] = shortcut.normalized
        persistShortcuts()

        guard let updated = shortcuts.first(where: { $0.id == shortcutID }) else {
            throw AgentToolError.notFound(shortcutID.uuidString)
        }
        return updated
    }

    private static func shortcutBytes(for createEvent: TerminalShortcutCreateEvent) throws -> [UInt8] {
        switch createEvent.kind {
        case .command:
            let command = createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                throw AgentToolError.invalidArgument("Terminal shortcut command events cannot be empty.")
            }
            return Array((command + "\n").utf8)
        case .text:
            return TerminalShortcutTextCodec.bytes(fromEscapedText: createEvent.value)
        case .control:
            switch createEvent.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "enter":
                return [13]
            case "tab":
                return [9]
            case "escape", "esc":
                return [27]
            case "backspace":
                return [127]
            case "ctrl_c", "ctrl-c":
                return [3]
            default:
                throw AgentToolError.invalidArgument("control must be one of: enter, tab, escape, backspace, ctrl_c.")
            }
        case .protectedPlaceholder:
            throw AgentToolError.invalidArgument("Protected placeholders are not visible byte events.")
        }
    }

    private func editVisibleEventText(
        shortcut: inout TerminalShortcut,
        eventIndex: Int,
        find: String?,
        replacement: String
    ) throws {
        guard let find, !find.isEmpty else {
            throw AgentToolError.missingArgument("find")
        }
        var text = try visibleEventText(shortcut.events[eventIndex], eventIndex: eventIndex)
        guard text.contains(find) else {
            throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) does not contain the requested visible text.")
        }
        text = text.replacingOccurrences(of: find, with: replacement)
        try setVisibleEventText(shortcut: &shortcut, eventIndex: eventIndex, text: text)
    }

    private func setVisibleEventText(
        shortcut: inout TerminalShortcut,
        eventIndex: Int,
        text: String
    ) throws {
        _ = try visibleEventText(shortcut.events[eventIndex], eventIndex: eventIndex)
        shortcut.events[eventIndex].bytes = TerminalShortcutTextCodec.bytes(fromEscapedText: text)
    }

    private func visibleEventText(_ event: TerminalShortcutEvent, eventIndex: Int) throws -> String {
        guard !event.requiresEchoOff else {
            throw AgentToolError.invalidArgument("Terminal shortcut event \(eventIndex) is protected echo-off input and cannot expose or rewrite secret bytes.")
        }
        return String(decoding: event.bytes, as: UTF8.self)
    }

    /// Make sure the current conversation owns a terminal tab. A different
    /// conversation's existing tab must not become the implicit default,
    /// otherwise opening the panel leaks that tab's screen and SSH state
    /// into a fresh conversation.
    func ensureAtLeastOneTab(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) {
        if let originAgentSessionID {
            if ownedTabID(for: originAgentSessionID) != nil {
                return
            }
        } else if !tabs.isEmpty {
            return
        }

        openLocalTab(
            originAgentSessionID: originAgentSessionID,
            workingDirectory: workingDirectory,
            settings: settings,
            skin: skin,
            clearsClosedRemoteRoute: false
        )
    }

    /// Prepare the terminal side panel for the active conversation without
    /// stealing visibility from a delegated CLI task that just opened its own
    /// tab. The panel appears asynchronously, so its delayed bootstrap can
    /// otherwise reactivate the conversation's older bound shell after the
    /// delegated tab has already been selected.
    func bootstrapSidePanel(
        originAgentSessionID: UUID?,
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?
    ) {
        selectRuntimeIfNeeded()
        if activeTab?.kind.isDelegatedShell != true || activeTab?.isAutomationBusy != true {
            ensureAtLeastOneTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: workingDirectory,
                settings: settings,
                skin: skin
            )
            activateOwnedTab(for: originAgentSessionID)
        }
        applyAppearanceToAll(settings, skin: skin)
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

    private func startInputStateMonitorIfNeeded() {
        guard inputStateTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tabs.forEach { $0.refreshInputState() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inputStateTimer = timer
    }

    private func stopInputStateMonitorIfIdle() {
        guard tabs.isEmpty else { return }
        inputStateTimer?.invalidate()
        inputStateTimer = nil
    }

    private func tickIdle() {
        guard !tabs.isEmpty else { return }
        let now = Date()
        var doomed: [UUID] = []
        for tab in tabs {
            tab.refreshActivityFromBuffer(now: now)
            // Never reap the tab the user is currently viewing or a tab owned
            // by a visible delegated execution. The latter can be quiet for
            // several minutes while a coding agent is thinking.
            if tab.id == activeTabID || tab.isAutomationBusy { continue }
            if tab.idleSeconds(now: now) > idleTimeout {
                doomed.append(tab.id)
            }
        }
        for id in doomed {
            closeTab(id: id)
        }
    }

    // MARK: Agent-tool surface (explicit tab id, else the active tab)

    /// Cheap main-actor metadata for the `terminal_snapshot` tool, plus the
    /// off-main mirror the tool reads the actual screen from. Throws a clear,
    /// actionable error when there is no terminal to read — instead of
    /// silently returning an empty "disconnected" snapshot the agent can't
    /// tell apart from a terminal that simply produced no output. The screen
    /// text, redaction and trimming all run off the main actor in
    /// `AgentTerminalTools.snapshot`.
    func rawSnapshot(targetTabID: UUID? = nil, sessionID: UUID? = nil) throws -> AgentTerminalRawSnapshot {
        let tab = try tabForToolUse(
            targetTabID: targetTabID,
            sessionID: sessionID,
            opensLocalTabIfNeeded: false
        )
        tab.refreshInputState()
        let source = tab.snapshotSource()
        return AgentTerminalRawSnapshot(
            tabID: tab.id,
            isRunning: tab.isRunning,
            inputState: tab.inputState,
            isZModemTransferActive: tab.terminalView.isZModemTransferActive,
            runtimeName: tab.title,
            runtimeTarget: tab.runtimeTarget,
            recentCommands: tab.recentCommands,
            mirror: source.mirror,
            cols: source.cols,
            rows: source.rows
        )
    }

    func sendApprovedCommand(
        _ command: String,
        targetTabID: UUID? = nil,
        sessionID: UUID? = nil,
        zmodemPathSelection: TerminalZModemPathSelection? = nil,
        secretRedactionValues: [String] = []
    ) throws -> AgentToolResult {
        let tab = try tabForToolUse(
            targetTabID: targetTabID,
            sessionID: sessionID,
            opensLocalTabIfNeeded: true
        )
        return try tab.sendApprovedCommand(
            command,
            zmodemPathSelection: zmodemPathSelection,
            secretRedactionValues: secretRedactionValues
        )
    }

    func sendApprovedCommandDispatch(
        _ command: String,
        targetTabID: UUID? = nil,
        sessionID: UUID? = nil,
        zmodemPathSelection: TerminalZModemPathSelection? = nil,
        secretRedactionValues: [String] = []
    ) throws -> AgentTerminalCommandDispatch {
        let tab = try tabForToolUse(
            targetTabID: targetTabID,
            sessionID: sessionID,
            opensLocalTabIfNeeded: true
        )
        let dispatch = try tab.sendApprovedCommandDispatch(
            command,
            zmodemPathSelection: zmodemPathSelection,
            secretRedactionValues: secretRedactionValues
        )
        pendingAgentCommandTabIDs.insert(tab.id)
        return dispatch
    }

    func sendApprovedControl(
        _ control: AgentTerminalControl,
        targetTabID: UUID? = nil,
        sessionID: UUID? = nil
    ) throws -> AgentToolResult {
        let tab = try tabForToolUse(
            targetTabID: targetTabID,
            sessionID: sessionID,
            opensLocalTabIfNeeded: true
        )
        return try tab.sendApprovedControl(control)
    }

    /// Routing: an explicit terminal_tab_id wins; otherwise terminal tools
    /// follow the ACTIVE side-panel tab — the one the user currently sees.
    /// Delegated /bin/sh pool tabs and automation-busy tabs are never
    /// implicit targets; explicitly targeting one is still allowed for
    /// reads. An explicit one-off target does not change the active tab —
    /// terminal_select_tab is the intentional way to switch it.
    private func tabForToolUse(
        targetTabID: UUID?,
        sessionID: UUID?,
        opensLocalTabIfNeeded: Bool
    ) throws -> AgentTerminalTab {
        if let targetTabID {
            guard let exact = tab(id: targetTabID) else {
                throw AgentToolError.invalidArgument(
                    "Agent Terminal tab \(targetTabID.uuidString) is no longer open. "
                        + "The tab list may have changed while approval was pending. "
                        + "Nothing was executed. "
                        + "Call terminal_list_tabs, read the active tab with terminal_snapshot, "
                        + "then retry without terminal_tab_id when continuing in the visible tab."
                )
            }
            if opensLocalTabIfNeeded, !exact.isRunning {
                throw AgentToolError.invalidArgument(
                    "Agent Terminal tab \"\(exact.title)\" exited before the command could be sent. "
                        + "Nothing was executed. Restart or switch the visible terminal, call "
                        + "terminal_snapshot again, then retry without a stale terminal_tab_id."
                )
            }
            closedRemoteRoute = nil
            return exact
        }
        if opensLocalTabIfNeeded, let closedRemoteRoute {
            throw AgentToolError.invalidArgument(
                "The previously active SSH terminal \"\(closedRemoteRoute.title)\" "
                    + "(\(closedRemoteRoute.target)) was closed. Nothing was executed, and "
                    + "WillDeep did not fall back to a local shell. Open or explicitly select "
                    + "the intended terminal tab, call terminal_snapshot to verify its host, "
                    + "then retry."
            )
        }
        if let active = activeTab, isImplicitlyRoutable(active) {
            if opensLocalTabIfNeeded, !active.isRunning {
                throw AgentToolError.invalidArgument(
                    "The active Agent Terminal tab \"\(active.title)\" exited before the command "
                        + "could be sent. Nothing was executed. Restart or switch the visible "
                        + "terminal, then call terminal_snapshot and retry."
                )
            }
            return active
        }
        if let fallback = tabs.last(where: { tab in
            isImplicitlyRoutable(tab) && (!opensLocalTabIfNeeded || tab.isRunning)
        }) {
            return fallback
        }
        guard opensLocalTabIfNeeded,
              let config = defaultLocalTabProvider?(sessionID) else {
            throw AgentToolError.invalidArgument(noRoutableTabGuidance())
        }
        let tab = openLocalTab(
            originAgentSessionID: config.originAgentSessionID,
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin,
            clearsClosedRemoteRoute: false
        )
        agentCreatedTabIDs.insert(tab.id)
        return tab
    }

    private func isImplicitlyRoutable(_ tab: AgentTerminalTab) -> Bool {
        !tab.kind.isDelegatedShell && !tab.isAutomationBusy
    }

    /// Make the given tab the active side-panel tab so subsequent terminal
    /// tools (and the user's own typing) target it. Surface for the
    /// terminal_select_tab tool.
    @discardableResult
    func selectTab(id: UUID) throws -> AgentTerminalTab {
        guard let selected = tab(id: id) else {
            throw AgentToolError.invalidArgument("Unknown Agent Terminal tab id: \(id.uuidString).")
        }
        closedRemoteRoute = nil
        activeTabID = selected.id
        return selected
    }

    /// Guidance for the model when no tab can be routed to implicitly. A
    /// bare error used to be relayed as "the side panel is not open" —
    /// gaslighting users who could see it right there. Enumerate what is
    /// actually open so the agent can retry with terminal_tab_id.
    private func noRoutableTabGuidance() -> String {
        guard !tabs.isEmpty else {
            return "The Agent Terminal side panel has no open tabs. Open one in the side panel, or use terminal_send_command which opens a local shell automatically."
        }
        let tabLines = tabs.map { tab -> String in
            let visibleMark = tab.id == activeTabID ? " [currently visible to the user]" : ""
            return "- terminal_tab_id \(tab.id.uuidString): \"\(tab.title)\", \(tab.runtimeTarget)\(visibleMark)"
        }
        return """
        Only delegated automation tabs are currently open in the Agent Terminal side panel, so there is no implicit target:
        \(tabLines.joined(separator: "\n"))
        Do NOT tell the user the side panel or terminal is closed. Use terminal_send_command to open a local shell, or explicitly target one of the tabs above with terminal_tab_id.
        """
    }

    func runCommandInDelegatedShellTab(
        _ command: String,
        sessionID: UUID,
        displayCommand: String,
        timeout: TimeInterval,
        secretRedactionValues: [String],
        progressSink: (@MainActor (AgentDelegatedTerminalProgressUpdate) -> Void)? = nil
    ) async throws -> AgentToolResult {
        guard let config = defaultLocalTabProvider?(sessionID) else {
            throw AgentToolError.invalidArgument(
                "Could not prepare a visible /bin/sh terminal for this delegated task."
            )
        }

        let deadline = Date().addingTimeInterval(max(timeout, 1))
        let tab = try await acquireDelegatedShellTab(
            workingDirectory: config.workingDirectory,
            settings: config.settings,
            skin: config.skin,
            deadline: deadline
        )
        activeTabID = tab.id
        let artifacts: AgentDelegatedTerminalArtifacts
        do {
            artifacts = try AgentDelegatedTerminalRunner.create(
                command: command,
                workingDirectory: config.workingDirectory
            )
        } catch {
            throw AgentToolError.commandFailed(
                1,
                "Failed to prepare the visible delegated-agent command: \(error.localizedDescription)"
            )
        }

        var ownsAutomation = false
        defer {
            if ownsAutomation {
                tab.finishAutomationCommand()
            }
            artifacts.removeAll()
        }
        try tab.sendAutomationCommand(artifacts.invocation, displayCommand: displayCommand)
        pendingAgentCommandTabIDs.insert(tab.id)
        ownsAutomation = true

        let startupDeadline = Date().addingTimeInterval(15)
        var didStart = false
        var nextProgressReadAt = Date()
        var lastProgressSnapshot: AgentDelegatedLiveOutputSnapshot?

        func publishProgress(force: Bool = false) {
            let rawOutput = AgentDelegatedTerminalRunner.readOutputTail(
                from: artifacts.outputURL
            )
            let redacted = AgentSecretStore.redact(
                rawOutput,
                secretValues: secretRedactionValues
            )
            let snapshot = AgentDelegatedLiveOutputSnapshot.make(from: redacted)
            guard force || snapshot != lastProgressSnapshot else { return }
            lastProgressSnapshot = snapshot
            progressSink?(
                AgentDelegatedTerminalProgressUpdate(
                    terminalTabID: tab.id,
                    currentActivity: snapshot.currentActivity,
                    recentOutput: snapshot.recentOutput
                )
            )
        }

        progressSink?(
            AgentDelegatedTerminalProgressUpdate(
                terminalTabID: tab.id,
                currentActivity: nil,
                recentOutput: nil
            )
        )
        while Date() < deadline {
            if Task.isCancelled {
                _ = try? tab.sendApprovedControl(.ctrlC)
                throw CancellationError()
            }
            if !didStart {
                didStart = FileManager.default.fileExists(atPath: artifacts.startedURL.path)
                if !didStart, Date() >= startupDeadline {
                    _ = try? tab.sendApprovedControl(.ctrlC)
                    throw AgentToolError.invalidArgument(
                        "The delegated command did not start within 15 seconds. Make sure the dedicated /bin/sh terminal is still running, then retry."
                    )
                }
            }
            if didStart, Date() >= nextProgressReadAt {
                publishProgress()
                nextProgressReadAt = Date().addingTimeInterval(1)
            }
            if FileManager.default.fileExists(atPath: artifacts.statusURL.path) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                publishProgress(force: true)
                let statusText = (try? String(contentsOf: artifacts.statusURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                let exitCode = Int(statusText) ?? 1
                let output = (try? String(contentsOf: artifacts.outputURL, encoding: .utf8)) ?? ""
                let redacted = AgentSecretStore.redact(output, secretValues: secretRedactionValues)
                let payload = """
                exit=\(exitCode)
                terminal_tab_id=\(tab.id.uuidString)
                --- stdout ---
                \(redacted)
                --- stderr ---

                """
                if exitCode != 0 {
                    throw AgentToolError.commandFailed(Int32(exitCode), payload)
                }
                return AgentToolResult(summary: "terminal exit \(exitCode)", payload: payload)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        _ = try? tab.sendApprovedControl(.ctrlC)
        throw AgentToolError.invalidArgument(
            "Command in Agent Terminal tab \(tab.id.uuidString) timed out after \(Int(timeout)) seconds."
        )
    }

    private func acquireDelegatedShellTab(
        workingDirectory: String?,
        settings: EditorTerminalSettings,
        skin: TerminalSkinColors?,
        deadline: Date
    ) async throws -> AgentTerminalTab {
        while Date() < deadline {
            let exited = tabs.filter {
                $0.kind.isDelegatedShell && !$0.isRunning && !$0.isAutomationBusy
            }
            for tab in exited {
                closeTab(id: tab.id)
            }

            let pool = tabs.filter { $0.kind.isDelegatedShell }
            pool.forEach { $0.refreshInputState() }
            if let reusable = pool
                .filter({ $0.isRunning && !$0.isAutomationBusy && $0.inputState == .shellReady })
                .min(by: { $0.lastActivity < $1.lastActivity }) {
                return reusable
            }
            if Self.canCreateDelegatedShellTab(existingCount: pool.count) {
                return openDelegatedShellTab(
                    workingDirectory: workingDirectory,
                    settings: settings,
                    skin: skin
                )
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AgentToolError.invalidArgument(
            "All \(Self.maximumDelegatedShellTabs) delegated /bin/sh terminal tabs stayed busy until this task timed out."
        )
    }
}

// MARK: - Secret redaction (unchanged)

enum AgentTerminalRedactor {
    private static let patterns: [String] = [
        #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{12,}"#,
        // Credential markers embedded in environment/config keys must be
        // separated as their own snake_case or kebab-case segment. The old
        // unrestricted prefix/suffix matched ordinary business identifiers
        // such as `tokenhub:0.196.0-rc2`, redacting the repository/image name
        // and version together even though neither is a secret.
        #"(?i)\b(?:[A-Z0-9]+[_-])*(api[_-]?key|token|secret|password|jwt)(?:[_-][A-Z0-9]+)*\s*[:=]\s*['"]?[^'"\s]{3,}"#,
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
