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

    init(terminalView: AgentLocalProcessTerminalView) {
        self.terminalView = terminalView
    }

    var isActive: Bool {
        session != nil
    }

    func handleRemoteBytes(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        if let session {
            session.writeRemoteBytes(bytes)
            return true
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
        guard let command = Self.localCommand(for: start.direction) else {
            terminalView.cancelRemoteZModem(message: Self.localInstallHint(for: start.direction))
            return
        }

        switch start.direction {
        case .uploadToRemote:
            guard let files = Self.chooseUploadFiles(), !files.isEmpty else {
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
            guard let directory = Self.chooseDownloadDirectory() else {
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
                        self?.finishSession(exitCode: exitCode)
                    }
                }
            )
            session = newSession
            newSession.start()
            if !initialBytes.isEmpty {
                newSession.writeRemoteBytes(initialBytes)
            }
        } catch {
            terminalView.cancelRemoteZModem(message: "WillDeep ZMODEM failed to start local lrzsz: \(error.localizedDescription)")
        }
    }

    private func finishSession(exitCode: Int32?) {
        session = nil
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

private final class TerminalZModemProcessSession {
    private let process: Process
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let sendToRemote: ([UInt8]) -> Void
    private let finish: (Int32?) -> Void

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
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.sendToRemote(Array(data))
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            self?.outputPipe.fileHandleForReading.readabilityHandler = nil
            self?.errorPipe.fileHandleForReading.readabilityHandler = nil
            self?.finish(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            finish(-1)
        }
    }

    func writeRemoteBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(bytes))
        } catch {
            process.terminate()
        }
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
