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

enum TerminalZModemDirection {
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

struct TerminalZModemStart {
    var direction: TerminalZModemDirection
    var displayPrefix: [UInt8]
    var protocolBytes: [UInt8]
}

struct TerminalZModemDetector {
    private var recentOutput: [UInt8] = []
    private let maxRecentOutput = 4_096

    mutating func detect(in bytes: [UInt8]) -> TerminalZModemStart? {
        guard !bytes.isEmpty else { return nil }
        guard let triggerIndex = Self.firstTriggerIndex(in: bytes) else {
            remember(bytes)
            return nil
        }

        let displayPrefix = Array(bytes[..<triggerIndex])
        let protocolBytes = Array(bytes[triggerIndex...])
        let contextBytes = recentOutput + displayPrefix
        let context = String(decoding: contextBytes.suffix(maxRecentOutput), as: UTF8.self).lowercased()
        let direction: TerminalZModemDirection = Self.looksLikeRemoteRzPrompt(context)
            ? .uploadToRemote
            : .downloadFromRemote
        recentOutput.removeAll(keepingCapacity: true)
        return TerminalZModemStart(
            direction: direction,
            displayPrefix: displayPrefix,
            protocolBytes: protocolBytes
        )
    }

    private mutating func remember(_ bytes: [UInt8]) {
        recentOutput.append(contentsOf: bytes)
        if recentOutput.count > maxRecentOutput {
            recentOutput.removeFirst(recentOutput.count - maxRecentOutput)
        }
    }

    private static func firstTriggerIndex(in bytes: [UInt8]) -> Int? {
        let binaryTriggers: [[UInt8]] = [
            [0x2A, 0x2A, 0x18, 0x42], // ** CAN B
            [0x2A, 0x2A, 0x18, 0x43]  // ** CAN C
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

    private static func looksLikeRemoteRzPrompt(_ context: String) -> Bool {
        context.contains("rz waiting to receive") ||
            context.contains("ready to receive") ||
            context.contains("zmodem receive") ||
            context.contains("start your local zmodem")
    }
}

@MainActor
final class TerminalZModemBridge {
    private weak var terminalView: AgentLocalProcessTerminalView?
    private var detector = TerminalZModemDetector()
    private var session: TerminalZModemProcessSession?
    private var sessionToken: UUID?
    private var preparedSelection = TerminalZModemPreparedSelection()

    init(terminalView: AgentLocalProcessTerminalView) {
        self.terminalView = terminalView
    }

    var isActive: Bool {
        session != nil
    }

    func preparePathSelection(_ selection: TerminalZModemPathSelection?) {
        preparedSelection.prepare(selection)
    }

    func handleRemoteBytes(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        if let session {
            switch session.writeRemoteBytes(bytes) {
            case .accepted:
                return true
            case .processExited:
                // The local rz/sz process has already completed. Bytes that
                // arrive after that boundary belong to the restored remote
                // shell (normally its prompt), so let the terminal render
                // them instead of swallowing them into a closed pipe.
                self.session = nil
                return false
            case .failed:
                self.session = nil
                sessionToken = nil
                terminalView?.cancelRemoteZModem(
                    message: "WillDeep ZMODEM connection to the local lrzsz process failed."
                )
                return true
            }
        }
        guard let start = detector.detect(in: bytes) else { return false }
        if !start.displayPrefix.isEmpty {
            terminalView?.feed(byteArray: start.displayPrefix[...])
        }
        startSession(start)
        return true
    }

    private func startSession(_ start: TerminalZModemStart) {
        guard let terminalView else { return }
        let selectedPath = preparedSelection.consume(for: start.direction)
        guard let command = Self.localCommand(for: start.direction) else {
            terminalView.cancelRemoteZModem(message: Self.localInstallHint(for: start.direction))
            return
        }

        switch start.direction {
        case .uploadToRemote:
            let files: [String]?
            if case .some(.upload(let selectedFiles)) = selectedPath {
                files = selectedFiles.map(\.path)
            } else {
                files = Self.chooseUploadFiles()
            }
            guard let files, !files.isEmpty else {
                terminalView.cancelRemoteZModem(message: "WillDeep ZMODEM upload cancelled.")
                return
            }
            beginProcess(
                command: command,
                arguments: ["-b"] + files,
                currentDirectory: nil,
                initialBytes: start.protocolBytes
            )
        case .downloadFromRemote:
            let directory: URL?
            if case .some(.download(let selectedDirectory)) = selectedPath {
                directory = selectedDirectory
            } else {
                directory = Self.chooseDownloadDirectory()
            }
            guard let directory else {
                terminalView.cancelRemoteZModem(message: "WillDeep ZMODEM download cancelled.")
                return
            }
            beginProcess(
                command: command,
                arguments: ["-E", "-y", "-b"],
                currentDirectory: directory,
                initialBytes: start.protocolBytes
            )
        }
    }

    private func beginProcess(
        command: String,
        arguments: [String],
        currentDirectory: URL?,
        initialBytes: [UInt8]
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
            newSession.start()
            if !initialBytes.isEmpty {
                switch newSession.writeRemoteBytes(initialBytes) {
                case .accepted:
                    break
                case .processExited, .failed:
                    session = nil
                    sessionToken = nil
                    terminalView.cancelRemoteZModem(
                        message: "WillDeep ZMODEM local lrzsz process ended before the transfer started."
                    )
                }
            }
        } catch {
            terminalView.cancelRemoteZModem(message: "WillDeep ZMODEM failed to start local lrzsz: \(error.localizedDescription)")
        }
    }

    private func finishSession(token: UUID, exitCode: Int32?) {
        guard sessionToken == token else { return }
        session = nil
        sessionToken = nil
        if let exitCode, exitCode != 0 {
            terminalView?.displayZModemStatus("WillDeep ZMODEM finished with exit code \(exitCode).")
        }
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

final class TerminalZModemProcessSession {
    private let process: Process
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let sendToRemote: ([UInt8]) -> Void
    private let finish: (Int32?) -> Void
    private let outputQueue = DispatchQueue(label: "com.willdeep.terminal.zmodem-output")
    private let stateLock = NSLock()
    private var acceptingRemoteBytes = false
    private var didFinish = false

    init(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        sendToRemote: @escaping ([UInt8]) -> Void,
        finish: @escaping (Int32?) -> Void
    ) throws {
        self.process = Process()
        self.sendToRemote = sendToRemote
        self.finish = finish
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.currentDirectoryURL = currentDirectory
    }

    func start() {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.outputQueue.async { [weak self] in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
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
        } catch {
            setAcceptingRemoteBytes(false)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            finishOnce(-1)
        }
    }

    func writeRemoteBytes(_ bytes: [UInt8]) -> TerminalZModemRemoteWriteResult {
        guard !bytes.isEmpty else { return .accepted }
        guard isAcceptingRemoteBytes, process.isRunning else {
            setAcceptingRemoteBytes(false)
            return .processExited
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(bytes))
            return .accepted
        } catch {
            let wasRunning = process.isRunning
            setAcceptingRemoteBytes(false)
            if wasRunning {
                process.terminate()
                return .failed
            }
            return .processExited
        }
    }

    private var isAcceptingRemoteBytes: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptingRemoteBytes
    }

    private func setAcceptingRemoteBytes(_ accepting: Bool) {
        stateLock.lock()
        acceptingRemoteBytes = accepting
        stateLock.unlock()
    }

    private func processTerminated(exitCode: Int32) {
        setAcceptingRemoteBytes(false)
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
        let line = "\r\n[\(message)]\r\n"
        let bytes = Array(line.utf8)
        feed(byteArray: bytes[...])
    }
}

private enum TerminalZModemCancel {
    static let sequence: [UInt8] =
        Array(repeating: 0x18, count: 8) + Array(repeating: 0x08, count: 8)
}
