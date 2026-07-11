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
            input.write(data)
            input.write(Data([0x0A]))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.timeout(id: id)
            }
        }
    }

    func restart() {
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
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.didTerminate() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw AgentToolError.commandFailed(127, "Could not start WillDeep Computer Use helper: \(error.localizedDescription)")
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    private func helperExecutableURL() throws -> URL {
        guard let helperApp = Bundle.main.url(forResource: "WillDeepComputerUseHelper", withExtension: "app"),
              let executable = Bundle(url: helperApp)?.executableURL else {
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
