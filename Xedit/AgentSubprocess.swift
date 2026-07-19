import Foundation
import Darwin

/// A bounded, cancellation-aware subprocess runner.
///
/// Both output pipes are drained concurrently so a noisy child cannot block on
/// a full pipe. Captured output is bounded independently from draining: bytes
/// beyond the budget are discarded while the pipe continues to be consumed.
nonisolated enum AgentSubprocess {
    private static let timeoutQueue = DispatchQueue(
        label: "com.willdeep.agent-subprocess.timeout",
        qos: .userInitiated
    )

    struct Output: Sendable {
        let exitStatus: Int32
        let stdout: Data
        let stderr: Data
        let stdoutWasTruncated: Bool
        let stderrWasTruncated: Bool
        let timedOut: Bool

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }

        @discardableResult
        func terminateAndEscalate() -> Bool {
            guard process.isRunning else { return false }
            process.terminate()
            let pid = process.processIdentifier
            AgentSubprocess.timeoutQueue.asyncAfter(deadline: .now() + 2) { [self] in
                if self.process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
            return true
        }
    }

    private struct Capture: Sendable {
        let data: Data
        let wasTruncated: Bool
    }

    private final class LockedCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private let keepTail: Bool
        private var data = Data()
        private var truncated = false

        init(limit: Int, keepTail: Bool) {
            self.limit = limit
            self.keepTail = keepTail
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard limit > 0 else { truncated = true; return }
            if keepTail {
                data.append(chunk)
                if data.count > limit {
                    data.removeFirst(data.count - limit)
                    truncated = true
                }
            } else {
                let remaining = limit - data.count
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            }
        }

        func snapshot() -> Capture {
            lock.lock()
            defer { lock.unlock() }
            return Capture(data: data, wasTruncated: truncated)
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func mark() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Bounded synchronous variant for legacy preflight/install call sites.
    /// It may block its caller until timeout, but it cannot deadlock on pipes.
    static func runSynchronously(
        _ process: Process,
        timeout: TimeInterval = 30,
        stdoutLimit: Int = 256 * 1_024,
        stderrLimit: Int = 256 * 1_024
    ) throws -> Output {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCapture = LockedCapture(limit: stdoutLimit, keepTail: false)
        let stderrCapture = LockedCapture(limit: stderrLimit, keepTail: true)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCapture.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCapture.append(handle.availableData)
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let processBox = ProcessBox(process)
        let timedOut = TimeoutFlag()
        let timeoutWorkItem = DispatchWorkItem {
            if processBox.terminateAndEscalate() {
                timedOut.mark()
            }
        }
        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() { stdoutCapture.append(tail) }
        if let tail = try? stderrPipe.fileHandleForReading.readToEnd() { stderrCapture.append(tail) }
        let stdout = stdoutCapture.snapshot()
        let stderr = stderrCapture.snapshot()
        return Output(
            exitStatus: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutWasTruncated: stdout.wasTruncated,
            stderrWasTruncated: stderr.wasTruncated,
            timedOut: timedOut.isSet
        )
    }

    static func run(
        _ process: Process,
        timeout: TimeInterval = 30 * 60,
        stdoutLimit: Int = 8 * 1_024 * 1_024,
        stderrLimit: Int = 256 * 1_024
    ) async throws -> Output {
        precondition(timeout > 0)
        precondition(stdoutLimit >= 0 && stderrLimit >= 0)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCapture = LockedCapture(limit: stdoutLimit, keepTail: false)
        let stderrCapture = LockedCapture(limit: stderrLimit, keepTail: true)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCapture.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCapture.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // The child inherited its own write descriptors. Closing the parent's
        // copies lets the drain tasks observe EOF as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let processBox = ProcessBox(process)
        let timedOut = TimeoutFlag()
        let timeoutWorkItem = DispatchWorkItem {
            if processBox.terminateAndEscalate() {
                timedOut.mark()
            }
        }
        // A Dispatch deadline is intentional here. Blocking pipe readers must
        // not occupy Swift's cooperative executor and delay a sub-second
        // timeout until the child exits naturally under a busy test/app load.
        timeoutQueue.asyncAfter(
            deadline: .now() + timeout,
            execute: timeoutWorkItem
        )

        await withTaskCancellationHandler {
            await AgentProcessSupport.waitUntilExit(processBox.process)
        } onCancel: {
            processBox.terminateAndEscalate()
        }
        timeoutWorkItem.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe.fileHandleForReading.readToEnd() { stdoutCapture.append(tail) }
        if let tail = try? stderrPipe.fileHandleForReading.readToEnd() { stderrCapture.append(tail) }
        let stdout = stdoutCapture.snapshot()
        let stderr = stderrCapture.snapshot()
        try Task.checkCancellation()
        return Output(
            exitStatus: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutWasTruncated: stdout.wasTruncated,
            stderrWasTruncated: stderr.wasTruncated,
            timedOut: timedOut.isSet
        )
    }
}
