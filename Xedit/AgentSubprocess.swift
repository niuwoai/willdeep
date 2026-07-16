import Foundation
import Darwin

/// A bounded, cancellation-aware subprocess runner.
///
/// Both output pipes are drained concurrently so a noisy child cannot block on
/// a full pipe. Captured output is bounded independently from draining: bytes
/// beyond the budget are discarded while the pipe continues to be consumed.
nonisolated enum AgentSubprocess {
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

    private enum WaitEvent: Sendable {
        case exited
        case timedOut
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }

        func terminateAndEscalate() {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                if self.process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private final class FileHandleBox: @unchecked Sendable {
        let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
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
            timedOut.mark()
            processBox.terminateAndEscalate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
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

        let stdoutReader = FileHandleBox(stdoutPipe.fileHandleForReading)
        let stderrReader = FileHandleBox(stderrPipe.fileHandleForReading)
        let stdoutTask = Task.detached(priority: .utility) {
            drain(stdoutReader.handle, limit: stdoutLimit, keepTail: false)
        }
        let stderrTask = Task.detached(priority: .utility) {
            drain(stderrReader.handle, limit: stderrLimit, keepTail: true)
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        // The child inherited its own write descriptors. Closing the parent's
        // copies lets the drain tasks observe EOF as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let processBox = ProcessBox(process)
        let waitEvent = await withTaskCancellationHandler {
            await withTaskGroup(of: WaitEvent.self) { group in
                group.addTask {
                    await AgentProcessSupport.waitUntilExit(processBox.process)
                    return .exited
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        return .timedOut
                    } catch {
                        return .exited
                    }
                }

                let first = await group.next() ?? .exited
                if case .timedOut = first {
                    processBox.terminateAndEscalate()
                }
                group.cancelAll()
                while await group.next() != nil {}
                return first
            }
        } onCancel: {
            processBox.terminateAndEscalate()
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        try Task.checkCancellation()
        let timedOut: Bool
        if case .timedOut = waitEvent {
            timedOut = true
        } else {
            timedOut = false
        }
        return Output(
            exitStatus: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutWasTruncated: stdout.wasTruncated,
            stderrWasTruncated: stderr.wasTruncated,
            timedOut: timedOut
        )
    }

    private static func drain(_ handle: FileHandle, limit: Int, keepTail: Bool) -> Capture {
        var captured = Data()
        captured.reserveCapacity(min(limit, 64 * 1_024))
        var wasTruncated = false

        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1_024), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }

            guard limit > 0 else {
                wasTruncated = true
                continue
            }
            if keepTail {
                captured.append(chunk)
                if captured.count > limit {
                    captured.removeFirst(captured.count - limit)
                    wasTruncated = true
                }
            } else {
                let remaining = limit - captured.count
                if remaining > 0 {
                    captured.append(chunk.prefix(remaining))
                }
                if chunk.count > remaining {
                    wasTruncated = true
                }
            }
        }
        return Capture(data: captured, wasTruncated: wasTruncated)
    }
}
