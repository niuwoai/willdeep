//
//  AgentTerminalZModem.swift
//  WillDeep
//
//  Minimal ZMODEM bridge for the WillDeep side-panel terminal. The app
//  detects rz/sz handshakes in the PTY stream, then proxies the remote
//  lrzsz process to a local lrzsz process instead of trying to implement
//  the binary protocol in Swift.
//

import AppKit
import Foundation
import SwiftTerm

enum TerminalZModemDirection: Equatable, Sendable {
    case uploadToRemote
    case downloadFromRemote
}

enum TerminalZModemPathSelection: Equatable {
    case upload(files: [URL])
    case download(directory: URL)

    func matches(_ direction: TerminalZModemDirection) -> Bool {
        switch (self, direction) {
        case (.upload, .uploadToRemote), (.download, .downloadFromRemote):
            return true
        default:
            return false
        }
    }

    var direction: TerminalZModemDirection {
        switch self {
        case .upload:
            return .uploadToRemote
        case .download:
            return .downloadFromRemote
        }
    }
}

struct TerminalZModemTransferOutcome: Equatable, Sendable {
    let direction: TerminalZModemDirection
    let succeeded: Bool
    let message: String
    let transferredByteCount: Int
}

/// Completion gate shared by the terminal bridge and `terminal_send_command`.
///
/// Creating the destination file is not completion: local `rz` opens it near
/// the beginning of a download and keeps appending while the protocol is in
/// flight. The tool therefore waits on this ticket, which is completed only
/// after the local lrzsz process terminates and its final stdout is drained.
final class TerminalZModemTransferTicket: @unchecked Sendable {
    private enum Phase {
        case awaitingHandshake
        case transferring
        case finished(TerminalZModemTransferOutcome)
    }

    let direction: TerminalZModemDirection

    private let lock = NSLock()
    private let handshakeTimeout: TimeInterval
    private var phase: Phase = .awaitingHandshake
    private var waiters: [UUID: CheckedContinuation<TerminalZModemTransferOutcome, Never>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    init(direction: TerminalZModemDirection, handshakeTimeout: TimeInterval = 30) {
        self.direction = direction
        self.handshakeTimeout = handshakeTimeout
        guard handshakeTimeout > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
            self?.finishIfStillAwaitingHandshake()
        }
    }

    @discardableResult
    func markStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingHandshake = phase else { return false }
        phase = .transferring
        return true
    }

    func finish(_ outcome: TerminalZModemTransferOutcome) {
        let pendingWaiters: [CheckedContinuation<TerminalZModemTransferOutcome, Never>]
        lock.lock()
        guard !isFinishedLocked else {
            lock.unlock()
            return
        }
        phase = .finished(outcome)
        pendingWaiters = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        cancelledWaiterIDs.removeAll(keepingCapacity: false)
        lock.unlock()
        pendingWaiters.forEach { $0.resume(returning: outcome) }
    }

    func waitForCompletion() async -> TerminalZModemTransferOutcome {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            cancelWaiter(id: waiterID)
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinishedLocked
    }

    private var isFinishedLocked: Bool {
        if case .finished = phase {
            return true
        }
        return false
    }

    private func finishIfStillAwaitingHandshake() {
        let outcome = TerminalZModemTransferOutcome(
            direction: direction,
            succeeded: false,
            message: "WillDeep ZMODEM did not receive a matching remote handshake within \(Self.timeoutText(handshakeTimeout)); no completed transfer was confirmed.",
            transferredByteCount: 0
        )
        let pendingWaiters: [CheckedContinuation<TerminalZModemTransferOutcome, Never>]
        lock.lock()
        guard case .awaitingHandshake = phase else {
            lock.unlock()
            return
        }
        phase = .finished(outcome)
        pendingWaiters = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        cancelledWaiterIDs.removeAll(keepingCapacity: false)
        lock.unlock()
        pendingWaiters.forEach { $0.resume(returning: outcome) }
    }

    private func registerWaiter(
        id: UUID,
        continuation: CheckedContinuation<TerminalZModemTransferOutcome, Never>
    ) {
        let immediateOutcome: TerminalZModemTransferOutcome?
        lock.lock()
        if case .finished(let outcome) = phase {
            immediateOutcome = outcome
        } else if cancelledWaiterIDs.remove(id) != nil {
            immediateOutcome = cancellationOutcome
        } else {
            waiters[id] = continuation
            immediateOutcome = nil
        }
        lock.unlock()
        if let immediateOutcome {
            continuation.resume(returning: immediateOutcome)
        }
    }

    private func cancelWaiter(id: UUID) {
        let waiter: CheckedContinuation<TerminalZModemTransferOutcome, Never>?
        lock.lock()
        if isFinishedLocked {
            waiter = nil
        } else if let registered = waiters.removeValue(forKey: id) {
            waiter = registered
        } else {
            cancelledWaiterIDs.insert(id)
            waiter = nil
        }
        lock.unlock()
        waiter?.resume(returning: cancellationOutcome)
    }

    private var cancellationOutcome: TerminalZModemTransferOutcome {
        TerminalZModemTransferOutcome(
            direction: direction,
            succeeded: false,
            message: "Waiting for WillDeep ZMODEM completion was cancelled; the transfer was not confirmed complete.",
            transferredByteCount: 0
        )
    }

    private static func timeoutText(_ timeout: TimeInterval) -> String {
        if timeout >= 1 {
            return "\(Int(timeout)) seconds"
        }
        return "\(Int((timeout * 1_000).rounded())) milliseconds"
    }
}

struct TerminalZModemPreparedSelection {
    private var selection: TerminalZModemPathSelection?
    private var expiresAt: Date?
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 60) {
        self.lifetime = lifetime
    }

    mutating func prepare(_ selection: TerminalZModemPathSelection?, now: Date = Date()) {
        self.selection = selection
        expiresAt = selection == nil ? nil : now.addingTimeInterval(lifetime)
    }

    mutating func consume(
        for direction: TerminalZModemDirection,
        now: Date = Date()
    ) -> TerminalZModemPathSelection? {
        defer {
            selection = nil
            expiresAt = nil
        }
        guard let selection,
              let expiresAt,
              now <= expiresAt,
              selection.matches(direction) else {
            return nil
        }
        return selection
    }
}

struct TerminalZModemStart: Equatable {
    var direction: TerminalZModemDirection
    var displayPrefix: [UInt8]
    var protocolBytes: [UInt8]
}

/// What the detector wants done with one incoming PTY chunk.
enum TerminalZModemDetection: Equatable {
    /// No transfer starts here. Render these bytes (usually the chunk
    /// as-is; after a false positive they also include released held bytes).
    case display([UInt8])
    /// A trigger matched but the frame type has not arrived yet. Render the
    /// prefix; the detector holds the tail until the next chunk resolves it.
    case hold(display: [UInt8])
    /// A genuine handshake resolved: start a session.
    case start(TerminalZModemStart)
}

/// Streaming matcher for the ZMODEM handshake. Two properties matter:
///
/// 1. The 4-byte trigger (`**` CAN `B`/`C`) is matched across PTY read
///    boundaries — lrzsz's opening frame routinely arrives split over SSH,
///    and a single-chunk matcher misses it, rendering the frame as garbage
///    and stalling the transfer until a ~10s protocol retry.
/// 2. The direction comes from the frame type that follows the trigger
///    (hex "00" = ZRQINIT, the remote is sending; hex "01" = ZRINIT, the
///    remote is receiving) instead of guessing from nearby prompt text.
///    Any other frame type is treated as a false positive and rendered,
///    which also stops random binary output from hijacking the terminal.
struct TerminalZModemDetector {
    /// Tail of already-rendered bytes (at most `triggerLength - 1`) kept so
    /// a trigger split across reads still matches.
    private var renderedTail: [UInt8] = []
    /// Bytes from a matched trigger onward, held until the frame type
    /// resolves. The first `pendingRenderedCount` of them were already
    /// rendered (they came from `renderedTail`).
    private var pending: [UInt8] = []
    private var pendingRenderedCount = 0

    private static let triggerLength = 4
    private static let hexFrameByte: UInt8 = 0x42 // 'B' — ZHEX frame
    private static let binFrameByte: UInt8 = 0x43 // 'C' — ZBIN32 frame

    /// True while a matched trigger is waiting for its frame type. The
    /// bridge counts this as active so the snapshot mirror skips the held
    /// protocol bytes.
    var isHoldingProtocolTail: Bool {
        !pending.isEmpty
    }

    mutating func detect(in bytes: [UInt8]) -> TerminalZModemDetection {
        guard !bytes.isEmpty else { return .display([]) }
        if !pending.isEmpty {
            pending.append(contentsOf: bytes)
            return resolvePending(displayPrefix: [])
        }
        let combined = renderedTail + bytes
        guard let index = Self.firstTriggerIndex(in: combined) else {
            renderedTail = Array(combined.suffix(Self.triggerLength - 1))
            return .display(bytes)
        }
        let tailCount = combined.count - bytes.count
        let displayPrefix = Array(bytes[..<max(0, index - tailCount)])
        pending = Array(combined[index...])
        pendingRenderedCount = max(0, tailCount - index)
        renderedTail.removeAll(keepingCapacity: true)
        return resolvePending(displayPrefix: displayPrefix)
    }

    private mutating func resolvePending(displayPrefix: [UInt8]) -> TerminalZModemDetection {
        // `pending` always starts with the full 4-byte trigger.
        let frameByte = pending[3]
        let needed = frameByte == Self.hexFrameByte ? 6 : 5
        guard pending.count >= needed else {
            return .hold(display: displayPrefix)
        }
        let direction: TerminalZModemDirection?
        if frameByte == Self.hexFrameByte {
            direction = Self.direction(hexHigh: pending[4], hexLow: pending[5])
        } else {
            direction = Self.direction(binaryType: pending[4])
        }
        guard let direction else {
            return flushPending(displayPrefix: displayPrefix)
        }
        let start = TerminalZModemStart(
            direction: direction,
            displayPrefix: displayPrefix,
            protocolBytes: pending
        )
        pending.removeAll(keepingCapacity: false)
        pendingRenderedCount = 0
        return .start(start)
    }

    /// The held bytes were not a handshake after all — release the part
    /// that has not been rendered yet. (A second, genuine trigger inside
    /// the released junk is not rescanned; lrzsz retries its opening frame,
    /// so the next retry starts the session.)
    private mutating func flushPending(displayPrefix: [UInt8]) -> TerminalZModemDetection {
        let display = displayPrefix + Array(pending.dropFirst(pendingRenderedCount))
        pending.removeAll(keepingCapacity: false)
        pendingRenderedCount = 0
        renderedTail = Array(display.suffix(Self.triggerLength - 1))
        return .display(display)
    }

    private static func direction(hexHigh: UInt8, hexLow: UInt8) -> TerminalZModemDirection? {
        guard hexHigh == 0x30 else { return nil } // '0'
        switch hexLow {
        case 0x30: // "00" ZRQINIT — the remote sz is the sender
            return .downloadFromRemote
        case 0x31: // "01" ZRINIT — the remote rz is the receiver
            return .uploadToRemote
        default:
            return nil
        }
    }

    private static func direction(binaryType: UInt8) -> TerminalZModemDirection? {
        switch binaryType {
        case 0x00:
            return .downloadFromRemote
        case 0x01:
            return .uploadToRemote
        default:
            return nil
        }
    }

    private static func firstTriggerIndex(in bytes: [UInt8]) -> Int? {
        let binaryTriggers: [[UInt8]] = [
            [0x2A, 0x2A, 0x18, hexFrameByte], // ** CAN B
            [0x2A, 0x2A, 0x18, binFrameByte]  // ** CAN C
        ]
        return binaryTriggers.compactMap { index(of: $0, in: bytes) }.min()
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        for offset in 0...lastStart {
            if Array(haystack[offset..<(offset + needle.count)]) == needle {
                return offset
            }
        }
        return nil
    }
}

@MainActor
final class TerminalZModemBridge {
    private enum State {
        case idle
        /// A handshake resolved and the local process is being set up. File
        /// pickers pump the run loop here, so remote retry frames re-enter
        /// `handleRemoteBytes`; they are buffered, never re-detected.
        case starting
        case transferring
    }

    private weak var terminalView: AgentLocalProcessTerminalView?
    private var detector = TerminalZModemDetector()
    private var session: TerminalZModemProcessSession?
    private var sessionToken: UUID?
    private var state: State = .idle
    private var bufferedWhileStarting: [UInt8] = []
    private var preparedSelection = TerminalZModemPreparedSelection()
    private var preparedTicket: TerminalZModemTransferTicket?
    private var activeTicket: TerminalZModemTransferTicket?
    private var progressTimer: DispatchSourceTimer?
    private var sessionDirection: TerminalZModemDirection = .downloadFromRemote
    private var sessionStartedAt = Date()

    /// Handshake retries are tiny; anything past this while a file picker
    /// is open is a runaway stream and gets dropped.
    private static let maxBufferedWhileStarting = 1 << 20

    init(terminalView: AgentLocalProcessTerminalView) {
        self.terminalView = terminalView
    }

    var isActive: Bool {
        state != .idle || detector.isHoldingProtocolTail
    }

    func preparePathSelection(
        _ selection: TerminalZModemPathSelection?
    ) -> TerminalZModemTransferTicket? {
        if let previousTicket = preparedTicket {
            previousTicket.finish(
                TerminalZModemTransferOutcome(
                    direction: previousTicket.direction,
                    succeeded: false,
                    message: "WillDeep ZMODEM path selection was replaced before its transfer started.",
                    transferredByteCount: 0
                )
            )
        }
        preparedSelection.prepare(selection)
        let ticket = selection.map {
            TerminalZModemTransferTicket(direction: $0.direction)
        }
        preparedTicket = ticket
        return ticket
    }

    /// Route one PTY chunk. Returns the bytes the terminal should render,
    /// or nil when the chunk was consumed by the transfer machinery.
    func handleRemoteBytes(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        switch state {
        case .starting:
            if bufferedWhileStarting.count < Self.maxBufferedWhileStarting {
                bufferedWhileStarting.append(contentsOf: bytes)
            }
            return nil
        case .transferring:
            guard let session else {
                state = .idle
                return bytes
            }
            switch session.writeRemoteBytes(bytes) {
            case .accepted:
                return nil
            case .processExited:
                // The local rz/sz process has already completed. Bytes that
                // arrive after that boundary belong to the restored remote
                // shell (normally its prompt); `finishSession` — queued from
                // the termination handler — resets the rest of the state.
                return bytes
            case .failed:
                session.abort(reason: .stalledLocalProcess)
                return nil
            }
        case .idle:
            switch detector.detect(in: bytes) {
            case .display(let display):
                return display
            case .hold(let display):
                return display
            case .start(let start):
                startSession(start)
                return start.displayPrefix
            }
        }
    }

    /// Route user keystrokes while a transfer owns the PTY. Ctrl+C aborts
    /// both sides; everything else is swallowed so stray keys cannot be
    /// injected into the binary protocol stream.
    func handleUserInput(_ bytes: [UInt8]) -> Bool {
        guard state == .transferring, let session else { return false }
        if bytes.contains(0x03) {
            session.abort(reason: .userCancelled)
        }
        return true
    }

    private func startSession(_ start: TerminalZModemStart) {
        guard let terminalView else { return }
        let selectedPath = preparedSelection.consume(for: start.direction)
        let ticket = preparedTicket
        preparedTicket = nil
        if let ticket, selectedPath == nil {
            let message = "WillDeep ZMODEM received a \(Self.directionLabel(start.direction)) handshake that did not match the prepared local path."
            ticket.finish(
                TerminalZModemTransferOutcome(
                    direction: ticket.direction,
                    succeeded: false,
                    message: message,
                    transferredByteCount: 0
                )
            )
            terminalView.cancelRemoteZModem(message: message)
            return
        }
        guard let command = Self.localCommand(for: start.direction) else {
            let message = Self.localInstallHint(for: start.direction)
            ticket?.finish(
                TerminalZModemTransferOutcome(
                    direction: start.direction,
                    succeeded: false,
                    message: message,
                    transferredByteCount: 0
                )
            )
            terminalView.cancelRemoteZModem(message: message)
            return
        }

        sessionDirection = start.direction
        activeTicket = ticket
        _ = ticket?.markStarted()
        state = .starting
        bufferedWhileStarting.removeAll(keepingCapacity: false)
        terminalView.zmodemStateDidChange(active: true)

        switch start.direction {
        case .uploadToRemote:
            let files: [String]?
            if case .some(.upload(let selectedFiles)) = selectedPath {
                files = selectedFiles.map(\.path)
            } else {
                files = Self.chooseUploadFiles()
            }
            guard let files, !files.isEmpty else {
                abandonStart(message: "WillDeep ZMODEM upload cancelled.")
                return
            }
            beginProcess(
                command: command,
                arguments: ["-b"] + files,
                currentDirectory: nil,
                start: start
            )
        case .downloadFromRemote:
            let directory: URL?
            if case .some(.download(let selectedDirectory)) = selectedPath {
                directory = selectedDirectory
            } else {
                directory = Self.chooseDownloadDirectory()
            }
            guard let directory else {
                abandonStart(message: "WillDeep ZMODEM download cancelled.")
                return
            }
            beginProcess(
                command: command,
                // Plain overwrite. The old `-E -y` pair was contradictory
                // (rename-existing vs overwrite); lrzsz let the last flag
                // win, so this is the same behavior made explicit.
                arguments: ["-y", "-b"],
                currentDirectory: directory,
                start: start
            )
        }
    }

    private func abandonStart(message: String) {
        state = .idle
        bufferedWhileStarting.removeAll(keepingCapacity: false)
        finishActiveTicket(succeeded: false, message: message, transferredByteCount: 0)
        terminalView?.zmodemStateDidChange(active: isActive)
        terminalView?.cancelRemoteZModem(message: message)
    }

    private func beginProcess(
        command: String,
        arguments: [String],
        currentDirectory: URL?,
        start: TerminalZModemStart
    ) {
        guard let terminalView else { return }
        let token = UUID()
        do {
            let newSession = try TerminalZModemProcessSession(
                executable: command,
                arguments: arguments,
                currentDirectory: currentDirectory,
                sendToRemote: { [weak terminalView] data in
                    terminalView?.process.send(data: data[...])
                },
                finish: { [weak self] exitCode in
                    Task { @MainActor [weak self] in
                        self?.finishSession(token: token, exitCode: exitCode)
                    }
                }
            )
            session = newSession
            sessionToken = token
            state = .transferring
            sessionStartedAt = Date()
            newSession.start()
            let initialBytes = start.protocolBytes + bufferedWhileStarting
            bufferedWhileStarting.removeAll(keepingCapacity: false)
            // Failures surface asynchronously through `finish`.
            _ = newSession.writeRemoteBytes(initialBytes)
            startProgressTimer()
            let verb = start.direction == .downloadFromRemote ? "receiving" : "sending"
            terminalView.displayZModemStatus(
                "WillDeep ZMODEM \(verb) via local lrzsz… press Ctrl+C to cancel."
            )
        } catch {
            abandonStart(
                message: "WillDeep ZMODEM failed to start local lrzsz: \(error.localizedDescription)"
            )
        }
    }

    private func finishSession(token: UUID, exitCode: Int32?) {
        guard sessionToken == token, let finished = session else { return }
        stopProgressTimer()
        session = nil
        sessionToken = nil
        state = .idle

        let transferred = finished.transferredByteCount(for: sessionDirection)
        let transferredText = ByteCountFormatter.string(
            fromByteCount: Int64(transferred), countStyle: .file
        )
        let elapsed = max(Date().timeIntervalSince(sessionStartedAt), 0.1)
        let message: String
        switch finished.endReason {
        case .userCancelled:
            message = "WillDeep ZMODEM cancelled by Ctrl+C; local lrzsz stopped and remote asked to abort."
        case .timedOut:
            message = "WillDeep ZMODEM timed out after \(Int(finished.idleTimeout))s without data; transfer aborted."
        case .stalledLocalProcess:
            message = "WillDeep ZMODEM aborted: the local lrzsz process stopped consuming data."
        case .none:
            if let exitCode, exitCode != 0 {
                message = "WillDeep ZMODEM finished with exit code \(exitCode) (\(transferredText) transferred)."
            } else {
                message = "WillDeep ZMODEM complete: \(transferredText) in \(String(format: "%.1f", elapsed))s."
            }
        }
        terminalView?.displayZModemStatus(message)
        let succeeded = finished.endReason == nil && (exitCode ?? 0) == 0
        finishActiveTicket(
            succeeded: succeeded,
            message: message,
            transferredByteCount: transferred
        )
        terminalView?.zmodemStateDidChange(active: isActive)
    }

    private func finishActiveTicket(
        succeeded: Bool,
        message: String,
        transferredByteCount: Int
    ) {
        activeTicket?.finish(
            TerminalZModemTransferOutcome(
                direction: sessionDirection,
                succeeded: succeeded,
                message: message,
                transferredByteCount: transferredByteCount
            )
        )
        activeTicket = nil
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tickProgress()
        }
        progressTimer = timer
        timer.resume()
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tickProgress() {
        guard state == .transferring, let session else { return }
        let count = session.transferredByteCount(for: sessionDirection)
        let text = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        let arrow = sessionDirection == .downloadFromRemote ? "⇣" : "⇡"
        terminalView?.displayZModemTransientStatus(
            "\r\u{1B}[2K[WillDeep ZMODEM \(arrow) \(text)]"
        )
    }

    private static func localCommand(for direction: TerminalZModemDirection) -> String? {
        switch direction {
        case .uploadToRemote:
            return findExecutable(named: "sz")
        case .downloadFromRemote:
            return findExecutable(named: "rz")
        }
    }

    private static func localInstallHint(for direction: TerminalZModemDirection) -> String {
        let command: String
        switch direction {
        case .uploadToRemote:
            command = "sz"
        case .downloadFromRemote:
            command = "rz"
        }
        return "WillDeep ZMODEM needs local `\(command)`. Install lrzsz on this Mac, for example: `brew install lrzsz`."
    }

    private static func directionLabel(_ direction: TerminalZModemDirection) -> String {
        switch direction {
        case .uploadToRemote:
            return "upload"
        case .downloadFromRemote:
            return "download"
        }
    }

    private static func findExecutable(named name: String) -> String? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = environmentPath
            .split(separator: ":")
            .map(String.init) + [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
        for directory in pathCandidates {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func chooseUploadFiles() -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to send with ZMODEM."
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.map(\.path)
    }

    private static func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose where to save ZMODEM downloads."
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first
    }
}

enum TerminalZModemRemoteWriteResult {
    case accepted
    case processExited
    case failed
}

enum TerminalZModemSessionEndReason {
    case none
    case timedOut
    case userCancelled
    case stalledLocalProcess
}

final class TerminalZModemProcessSession {
    private let process: Process
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let sendToRemote: ([UInt8]) -> Void
    private let finish: (Int32?) -> Void
    private let outputQueue = DispatchQueue(label: "com.willdeep.terminal.zmodem-output")
    /// Serial queue for stdin writes so the main thread never blocks on a
    /// full pipe buffer (a 64 KB pipe plus a busy rz used to stall the
    /// whole main thread on large downloads).
    private let inputQueue = DispatchQueue(label: "com.willdeep.terminal.zmodem-input")
    private let stateLock = NSLock()
    private var acceptingRemoteBytes = false
    private var didFinish = false
    private var _endReason: TerminalZModemSessionEndReason = .none
    private var bytesWrittenToLocal = 0
    private var bytesReadFromLocal = 0
    private var pendingWriteBytes = 0
    private var lastActivity = Date()
    private var watchdog: DispatchSourceTimer?

    let idleTimeout: TimeInterval
    private let maxPendingWriteBytes: Int

    init(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        idleTimeout: TimeInterval = 30,
        maxPendingWriteBytes: Int = 8 << 20,
        sendToRemote: @escaping ([UInt8]) -> Void,
        finish: @escaping (Int32?) -> Void
    ) throws {
        self.process = Process()
        self.sendToRemote = sendToRemote
        self.finish = finish
        self.idleTimeout = idleTimeout
        self.maxPendingWriteBytes = maxPendingWriteBytes
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = currentDirectory
    }

    var endReason: TerminalZModemSessionEndReason {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _endReason
    }

    /// Approximate payload progress: the payload flows into the local
    /// process on downloads and out of it on uploads.
    func transferredByteCount(for direction: TerminalZModemDirection) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch direction {
        case .downloadFromRemote:
            return bytesWrittenToLocal
        case .uploadToRemote:
            return bytesReadFromLocal
        }
    }

    func start() {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.outputQueue.async { [weak self] in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.stateLock.lock()
                self.bytesReadFromLocal += data.count
                self.lastActivity = Date()
                self.stateLock.unlock()
                self.sendToRemote(Array(data))
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(exitCode: process.terminationStatus)
        }
        setAcceptingRemoteBytes(true)
        do {
            try process.run()
            startWatchdog()
        } catch {
            setAcceptingRemoteBytes(false)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            finishOnce(-1)
        }
    }

    func writeRemoteBytes(_ bytes: [UInt8]) -> TerminalZModemRemoteWriteResult {
        guard !bytes.isEmpty else { return .accepted }
        stateLock.lock()
        guard acceptingRemoteBytes, process.isRunning else {
            acceptingRemoteBytes = false
            stateLock.unlock()
            return .processExited
        }
        guard pendingWriteBytes + bytes.count <= maxPendingWriteBytes else {
            // The local process stopped draining stdin. Refuse instead of
            // buffering the remote stream without bound.
            acceptingRemoteBytes = false
            stateLock.unlock()
            return .failed
        }
        pendingWriteBytes += bytes.count
        stateLock.unlock()

        inputQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingWriteBytes -= bytes.count
                self.stateLock.unlock()
            }
            do {
                try self.inputPipe.fileHandleForWriting.write(contentsOf: Data(bytes))
                self.stateLock.lock()
                self.bytesWrittenToLocal += bytes.count
                self.lastActivity = Date()
                self.stateLock.unlock()
            } catch {
                self.stateLock.lock()
                let wasAccepting = self.acceptingRemoteBytes
                self.acceptingRemoteBytes = false
                self.stateLock.unlock()
                if wasAccepting, self.process.isRunning {
                    self.process.terminate()
                }
            }
        }
        return .accepted
    }

    /// Abort from either side of the bridge: mark why, ask the remote to
    /// stop (ZMODEM cancel burst), and terminate the local process. The
    /// normal termination path then reports through `finish`.
    func abort(reason: TerminalZModemSessionEndReason) {
        stateLock.lock()
        if _endReason == .none {
            _endReason = reason
        }
        acceptingRemoteBytes = false
        stateLock.unlock()
        sendToRemote(TerminalZModemCancel.sequence)
        if process.isRunning {
            process.terminate()
        }
    }

    private func startWatchdog() {
        guard idleTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let interval = max(idleTimeout / 4, 0.25)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkIdle()
        }
        watchdog = timer
        timer.resume()
    }

    /// A ZMODEM session with no bytes moving in either direction is dead —
    /// e.g. the remote died mid-frame, or a stray handshake started a
    /// session no sender ever joins. Without this, the bridge would swallow
    /// every terminal byte forever.
    private func checkIdle() {
        stateLock.lock()
        guard !didFinish, _endReason == .none,
              Date().timeIntervalSince(lastActivity) >= idleTimeout else {
            stateLock.unlock()
            return
        }
        _endReason = .timedOut
        acceptingRemoteBytes = false
        stateLock.unlock()
        sendToRemote(TerminalZModemCancel.sequence)
        if process.isRunning {
            process.terminate()
        }
    }

    private func setAcceptingRemoteBytes(_ accepting: Bool) {
        stateLock.lock()
        acceptingRemoteBytes = accepting
        stateLock.unlock()
    }

    private func processTerminated(exitCode: Int32) {
        setAcceptingRemoteBytes(false)
        watchdog?.cancel()
        watchdog = nil
        try? inputPipe.fileHandleForWriting.close()
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        // Process.terminationHandler may run before FileHandle has delivered
        // the final stdout callback. Drain the pipe on the same serial queue
        // as ordinary reads, then signal completion. ZMODEM's ZFIN/OO tail
        // must reach the remote sz/rz process or its shell never resumes.
        outputQueue.async { [weak self] in
            guard let self else { return }
            let trailingData = outputHandle.readDataToEndOfFile()
            if !trailingData.isEmpty {
                self.stateLock.lock()
                self.bytesReadFromLocal += trailingData.count
                self.stateLock.unlock()
                self.sendToRemote(Array(trailingData))
            }
            self.finishOnce(exitCode)
        }
    }

    private func finishOnce(_ exitCode: Int32?) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        stateLock.unlock()
        finish(exitCode)
    }
}

private extension AgentLocalProcessTerminalView {
    func cancelRemoteZModem(message: String) {
        process.send(data: TerminalZModemCancel.sequence[...])
        displayZModemStatus(message)
    }

    func displayZModemStatus(_ message: String) {
        // Clear any transient progress line before printing.
        feedZModemStatusLine("\r\u{1B}[2K[\(message)]\r\n")
    }

    func displayZModemTransientStatus(_ line: String) {
        feedZModemStatusLine(line)
    }
}

enum TerminalZModemCancel {
    static let sequence: [UInt8] =
        Array(repeating: 0x18, count: 8) + Array(repeating: 0x08, count: 8)
}
