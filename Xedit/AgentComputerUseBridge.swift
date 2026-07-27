//
//  AgentComputerUseBridge.swift
//  WillDeep
//
//  Process bridge to the separately signed WillDeep Computer Use helper.
//  The helper owns Accessibility and Screen Recording TCC grants; restarting
//  it never requires restarting the editor.
//

import Foundation

actor AgentComputerUseBridge {
    static let shared = AgentComputerUseBridge()
    private static let expectedHelperBundleIdentifier = "com.willdeep.computer-use-helper"

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func invoke(action: String, arguments: [String: AgentJSONValue] = [:]) async throws -> [String: Any] {
        try startIfNeeded()
        let id = UUID().uuidString.lowercased()
        let object: [String: Any] = [
            "id": id,
            "action": action,
            "arguments": arguments.mapValues(\.rawAny)
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw AgentToolError.commandFailed(1, "Computer Use helper stdin is unavailable.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            // Legacy `write(_:)` raises an uncatchable ObjC exception if the
            // helper died after startIfNeeded()'s isRunning check (broken
            // pipe); `write(contentsOf:)` throws so we can fail the request.
            do {
                try input.write(contentsOf: data)
                try input.write(contentsOf: Data([0x0A]))
            } catch {
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(throwing: AgentToolError.commandFailed(1, "Computer Use helper stdin write failed (helper likely exited): \(error.localizedDescription)"))
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.timeout(id: id)
            }
        }
    }

    func restart() {
        // The old process may report termination after startIfNeeded() has
        // already installed a replacement. Detach its callback first so that
        // stale EOF cannot clear the new helper's stdin/process references.
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        input = nil
        failPending(with: AgentToolError.commandFailed(1, "Computer Use helper restarted."))
    }

    private func startIfNeeded() throws {
        guard process?.isRunning != true else { return }
        let executable = try helperExecutableURL()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: without nil-ing the handler here it keeps firing
                // with empty data in a tight loop, pinning a core.
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.consume(data) }
        }
        // Drain and discard helper stderr — with no reader its 64KB pipe
        // buffer fills up and the helper blocks mid-write, after which
        // every invoke() dies on the 20s timeout until a manual restart.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.didTerminate() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw AgentToolError.commandFailed(127, "Could not start WillDeep Computer Use helper: \(error.localizedDescription)")
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    private func helperExecutableURL() throws -> URL {
        guard let helperApp = Bundle.main.url(forResource: "WillDeepComputerUseHelper", withExtension: "app"),
              let helperBundle = Bundle(url: helperApp),
              helperBundle.bundleIdentifier == Self.expectedHelperBundleIdentifier,
              let executable = helperBundle.executableURL else {
            throw AgentToolError.commandFailed(127, "WillDeep Computer Use helper is not bundled. Rebuild or reinstall WillDeep.")
        }
        return executable
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            resolveLine(Data(line))
        }
    }

    private func resolveLine(_ data: Data) {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = response["id"] as? String,
              let continuation = pending.removeValue(forKey: id) else { return }
        if response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: AgentToolError.commandFailed(1, response["error"] as? String ?? "Computer Use helper request failed."))
        }
    }

    private func didTerminate() {
        process = nil
        input = nil
        failPending(with: AgentToolError.commandFailed(1, "Computer Use helper stopped unexpectedly."))
    }

    private func timeout(id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: AgentToolError.commandTimeout)
    }

    private func failPending(with error: Error) {
        let calls = pending
        pending.removeAll()
        for continuation in calls.values { continuation.resume(throwing: error) }
    }
}
