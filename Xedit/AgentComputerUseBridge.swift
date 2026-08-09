//
//  AgentComputerUseBridge.swift
//  WillDeep
//
//  Process bridge to the separately signed WillDeep Computer Use helper.
//  The helper owns Accessibility and Screen Recording TCC grants; restarting
//  it never requires restarting the editor.
//

import Foundation

nonisolated struct AgentComputerUseUserInputInterruptionError: LocalizedError, Sendable {
    let errorDescription: String? =
        "Computer Use yielded immediately to physical user input. The interrupted result was discarded."
}

actor AgentComputerUseBridge {
    static let shared = AgentComputerUseBridge()
    nonisolated static let expectedProtocolVersion = "willdeep-computer-use.v6"
    nonisolated static let userInputNotification = Notification.Name(
        "WillDeepComputerUseUserInput"
    )
    private static let expectedHelperBundleIdentifier = "com.willdeep.computer-use-helper"
    private static let defaultTimeout: TimeInterval = 20

    private struct PendingRequest {
        let generation: UUID
        let action: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var outputBuffer = Data()
    private var generation: UUID?
    private var validatedGeneration: UUID?
    private var pending: [String: PendingRequest] = [:]

    /// Sticky "computer-use has worked at least once" marker. Accessibility
    /// is granted to the helper process, so the main app cannot probe TCC
    /// directly and cheaply; the system prompt's capability gating reads
    /// this flag instead. Once true it stays true — revocation merely means
    /// the appended guidance goes unused until the user re-grants.
    private static let accessibilityEverGrantedKey = "com.willdeep.computerUse.accessibilityEverGranted"

    nonisolated static var accessibilityEverGranted: Bool {
        UserDefaults.standard.bool(forKey: accessibilityEverGrantedKey)
    }

    nonisolated static func recordAccessibilityGranted() {
        UserDefaults.standard.set(true, forKey: accessibilityEverGrantedKey)
    }

    /// Invoke one Computer Use helper action.
    ///
    /// `controlLeaseID` is required by protocol v6 for control-session
    /// lifecycle calls, app-state snapshots, waits, and app/input mutations.
    /// Permission/list/display reads intentionally leave it nil.
    func invoke(
        action: String,
        arguments: [String: AgentJSONValue] = [:],
        controlLeaseID: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        let currentGeneration = try startIfNeeded()
        if action == "permissions" {
            let result = try await invokeRaw(
                action: action,
                arguments: arguments,
                controlLeaseID: controlLeaseID,
                timeout: timeout,
                generation: currentGeneration
            )
            try validateProtocolVersion(in: result, generation: currentGeneration)
            if (result["accessibility_granted"] as? Bool) == true {
                Self.recordAccessibilityGranted()
            }
            return result
        }

        try await ensureProtocolVersion(generation: currentGeneration)
        guard generation == currentGeneration else {
            throw AgentToolError.commandFailed(
                1,
                "Computer Use helper restarted while validating its protocol."
            )
        }
        return try await invokeRaw(
            action: action,
            arguments: arguments,
            controlLeaseID: controlLeaseID,
            timeout: timeout,
            generation: currentGeneration
        )
    }

    /// Acquire the helper's single global control lease and bind it to an app.
    ///
    /// Pass exactly one of `targetPID` or `targetApp`. `targetApp` may be a
    /// bundle identifier for an app that will be launched after the lease is
    /// acquired. Repeating the same lease/target is idempotent.
    func startControlSession(
        controlLeaseID: String,
        targetPID: Int? = nil,
        targetApp: String? = nil
    ) async throws -> [String: Any] {
        let leaseID = try normalizedLeaseID(controlLeaseID)
        guard targetPID != nil || !(targetApp ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArgument(
                "Starting Computer Use control requires targetPID or targetApp."
            )
        }
        var arguments: [String: AgentJSONValue] = [:]
        if let targetPID {
            arguments["pid"] = .number(Double(targetPID))
        }
        if let targetApp {
            arguments["app"] = .string(targetApp)
        }
        return try await invoke(
            action: "start_control_session",
            arguments: arguments,
            controlLeaseID: leaseID
        )
    }

    func pauseControlSession(controlLeaseID: String) async throws -> [String: Any] {
        try await invoke(
            action: "pause_control_session",
            controlLeaseID: try normalizedLeaseID(controlLeaseID)
        )
    }

    func resumeControlSession(controlLeaseID: String) async throws -> [String: Any] {
        try await invoke(
            action: "resume_control_session",
            controlLeaseID: try normalizedLeaseID(controlLeaseID)
        )
    }

    func endControlSession(controlLeaseID: String) async throws -> [String: Any] {
        let leaseID = try normalizedLeaseID(controlLeaseID)
        guard process?.isRunning == true else {
            if let generation {
                abortGeneration(
                    generation,
                    primaryRequestID: nil,
                    primaryError: AgentToolError.commandFailed(
                        1,
                        "Computer Use helper stopped before its control session could be ended."
                    ),
                    otherError: AgentToolError.commandFailed(
                        1,
                        "Computer Use helper stopped before its control session could be ended."
                    ),
                    terminateProcess: false
                )
            } else {
                resetTransport()
            }
            return [
                "control_lease_id": leaseID,
                "ended": true,
                "helper_running": false,
            ]
        }
        return try await invoke(
            action: "end_control_session",
            controlLeaseID: leaseID
        )
    }

    private func invokeRaw(
        action: String,
        arguments: [String: AgentJSONValue],
        controlLeaseID: String?,
        timeout: TimeInterval,
        generation requestGeneration: UUID
    ) async throws -> [String: Any] {
        let id = UUID().uuidString.lowercased()
        var object: [String: Any] = [
            "id": id,
            "action": action,
            "arguments": arguments.mapValues(\.rawAny)
        ]
        if let controlLeaseID {
            object["control_lease_id"] = controlLeaseID
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard generation == requestGeneration, let input else {
            throw AgentToolError.commandFailed(
                1,
                "Computer Use helper restarted before the request could be written."
            )
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeoutNanoseconds = UInt64(
                    max(0.1, min(timeout, 300)) * 1_000_000_000
                )
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id: id, generation: requestGeneration)
                }
                pending[id] = PendingRequest(
                    generation: requestGeneration,
                    action: action,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                // Legacy `write(_:)` raises an uncatchable ObjC exception if
                // the helper died after startIfNeeded()'s isRunning check.
                // `write(contentsOf:)` throws and lets this generation fail
                // atomically instead.
                do {
                    try input.write(contentsOf: data)
                    try input.write(contentsOf: Data([0x0A]))
                } catch {
                    abortGeneration(
                        requestGeneration,
                        primaryRequestID: id,
                        primaryError: AgentToolError.commandFailed(
                            1,
                            "Computer Use helper stdin write failed (helper likely exited): \(error.localizedDescription)"
                        ),
                        otherError: AgentToolError.commandFailed(
                            1,
                            "Computer Use helper stopped while writing another request."
                        )
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id: id, generation: requestGeneration)
            }
        }
    }

    func restart() {
        guard let generation else {
            resetTransport()
            return
        }
        abortGeneration(
            generation,
            primaryRequestID: nil,
            primaryError: AgentToolError.commandFailed(
                1,
                "Computer Use helper restarted."
            ),
            otherError: AgentToolError.commandFailed(
                1,
                "Computer Use helper restarted."
            )
        )
    }

    @discardableResult
    private func startIfNeeded() throws -> UUID {
        if process?.isRunning == true, let generation {
            return generation
        }

        if let staleGeneration = generation {
            abortGeneration(
                staleGeneration,
                primaryRequestID: nil,
                primaryError: AgentToolError.commandFailed(
                    1,
                    "Computer Use helper stopped before a new request started."
                ),
                otherError: AgentToolError.commandFailed(
                    1,
                    "Computer Use helper stopped before a new request started."
                ),
                terminateProcess: false
            )
        } else {
            resetTransport()
        }
        let executable = try helperExecutableURL()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let newGeneration = UUID()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: without nil-ing the handler here it keeps firing
                // with empty data in a tight loop, pinning a core.
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.consume(data, generation: newGeneration) }
        }
        // Drain and discard helper stderr — with no reader its 64KB pipe
        // buffer fills up and the helper blocks mid-write, after which
        // every invoke() dies on the 20s timeout until a manual restart.
        stderrHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.didTerminate(generation: newGeneration) }
        }
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw AgentToolError.commandFailed(127, "Could not start WillDeep Computer Use helper: \(error.localizedDescription)")
        }
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdoutHandle
        self.errorOutput = stderrHandle
        self.outputBuffer.removeAll(keepingCapacity: true)
        self.generation = newGeneration
        self.validatedGeneration = nil
        return newGeneration
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

    private func consume(_ data: Data, generation responseGeneration: UUID) {
        guard generation == responseGeneration else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 16 * 1_024 * 1_024 else {
            abortGeneration(
                responseGeneration,
                primaryRequestID: nil,
                primaryError: AgentToolError.commandFailed(
                    1,
                    "Computer Use helper returned an oversized protocol response."
                ),
                otherError: AgentToolError.commandFailed(
                    1,
                    "Computer Use helper returned an oversized protocol response."
                )
            )
            return
        }
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            resolveLine(Data(line), generation: responseGeneration)
        }
    }

    private func resolveLine(_ data: Data, generation responseGeneration: UUID) {
        guard generation == responseGeneration else { return }
        guard let response = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            return
        }
        if response["event"] != nil {
            handleUnsolicitedEvent(
                response,
                generation: responseGeneration
            )
            return
        }
        guard
              let id = response["id"] as? String,
              let request = pending.removeValue(forKey: id),
              request.generation == responseGeneration else { return }
        request.timeoutTask.cancel()
        if response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] {
            request.continuation.resume(returning: result)
        } else {
            request.continuation.resume(
                throwing: AgentToolError.commandFailed(
                    1,
                    response["error"] as? String
                        ?? "Computer Use helper request failed during \(request.action)."
                )
            )
        }
    }

    private func handleUnsolicitedEvent(
        _ event: [String: Any],
        generation responseGeneration: UUID
    ) {
        guard generation == responseGeneration else { return }
        guard event["protocol_version"] as? String
                == Self.expectedProtocolVersion else {
            let error = AgentToolError.commandFailed(
                1,
                "Computer Use helper sent an event with an incompatible protocol version."
            )
            abortGeneration(
                responseGeneration,
                primaryRequestID: nil,
                primaryError: error,
                otherError: error
            )
            return
        }
        guard event["event"] as? String == "user_input",
              let leaseID = event["control_lease_id"] as? String,
              !leaseID.isEmpty else {
            return
        }
        var userInfo: [String: Any] = [
            "control_lease_id": leaseID,
            "paused": true
        ]
        if let inputKind = event["input_kind"] as? String {
            userInfo["input_kind"] = inputKind
        }
        // Physical user input is a hard generation boundary. Merely notifying
        // the UI leaves an in-flight AX action or screenshot free to complete
        // and leak its result into the transcript before the main actor updates
        // the takeover card. Tear down this exact helper generation now; every
        // pending continuation fails and any later response line is stale.
        let handoffError = AgentComputerUseUserInputInterruptionError()
        abortGeneration(
            responseGeneration,
            primaryRequestID: nil,
            primaryError: handoffError,
            otherError: handoffError
        )
        NotificationCenter.default.post(
            name: Self.userInputNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    private func didTerminate(generation terminatedGeneration: UUID) {
        // A stale termination callback must never clear a replacement helper.
        guard generation == terminatedGeneration else { return }
        abortGeneration(
            terminatedGeneration,
            primaryRequestID: nil,
            primaryError: AgentToolError.commandFailed(
                1,
                "Computer Use helper stopped unexpectedly."
            ),
            otherError: AgentToolError.commandFailed(
                1,
                "Computer Use helper stopped unexpectedly."
            ),
            terminateProcess: false
        )
    }

    private func timeoutRequest(id: String, generation requestGeneration: UUID) {
        guard pending[id]?.generation == requestGeneration else { return }
        abortGeneration(
            requestGeneration,
            primaryRequestID: id,
            primaryError: AgentToolError.commandTimeout,
            otherError: AgentToolError.commandFailed(
                1,
                "Computer Use helper was restarted after another request timed out."
            )
        )
    }

    private func cancelRequest(id: String, generation requestGeneration: UUID) {
        guard pending[id]?.generation == requestGeneration else { return }
        abortGeneration(
            requestGeneration,
            primaryRequestID: id,
            primaryError: CancellationError(),
            otherError: AgentToolError.commandFailed(
                1,
                "Computer Use helper was restarted because another request was cancelled."
            )
        )
    }

    private func abortGeneration(
        _ abortedGeneration: UUID,
        primaryRequestID: String?,
        primaryError: Error,
        otherError: Error,
        terminateProcess: Bool = true
    ) {
        guard generation == abortedGeneration else { return }
        let oldProcess = process
        oldProcess?.terminationHandler = nil
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if terminateProcess, oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }

        let requests = pending
        pending.removeAll()
        resetTransport()
        for (id, request) in requests where request.generation == abortedGeneration {
            request.timeoutTask.cancel()
            request.continuation.resume(
                throwing: id == primaryRequestID ? primaryError : otherError
            )
        }
    }

    private func resetTransport() {
        process?.terminationHandler = nil
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        outputBuffer.removeAll(keepingCapacity: true)
        generation = nil
        validatedGeneration = nil
    }

    private func ensureProtocolVersion(generation requestGeneration: UUID) async throws {
        guard validatedGeneration != requestGeneration else { return }
        let status = try await invokeRaw(
            action: "permissions",
            arguments: [:],
            controlLeaseID: nil,
            timeout: Self.defaultTimeout,
            generation: requestGeneration
        )
        try validateProtocolVersion(in: status, generation: requestGeneration)
    }

    private func validateProtocolVersion(
        in status: [String: Any],
        generation requestGeneration: UUID
    ) throws {
        guard generation == requestGeneration else {
            throw AgentToolError.commandFailed(
                1,
                "Computer Use helper restarted during protocol validation."
            )
        }
        guard status["protocol_version"] as? String == Self.expectedProtocolVersion else {
            let actual = status["protocol_version"] as? String ?? "missing"
            let error = AgentToolError.commandFailed(
                1,
                "Computer Use helper protocol mismatch: expected \(Self.expectedProtocolVersion), got \(actual). Rebuild or reinstall WillDeep."
            )
            abortGeneration(
                requestGeneration,
                primaryRequestID: nil,
                primaryError: error,
                otherError: error
            )
            throw error
        }
        validatedGeneration = requestGeneration
    }

    private func normalizedLeaseID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AgentToolError.invalidArgument(
                "Computer Use controlLeaseID cannot be empty."
            )
        }
        return normalized
    }
}
