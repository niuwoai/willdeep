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

    private enum PipeReadError: Error { case system(Int32) }

    /// One queue owns read + append + final snapshot. Removing a Foundation
    /// readability handler alone is not an ownership boundary for data already
    /// read by a callback that has not appended it yet.
    private final class PipeCapture: @unchecked Sendable {
        private static let chunkBytes = 16 * 1_024
        private static let maximumChunksPerEvent = 64
        private let queue = DispatchQueue(label: "com.willdeep.agent-subprocess.pipe", qos: .utility)
        private let handle: FileHandle
        private let source: DispatchSourceRead
        private let capture: LockedCapture
        private var ended = false
        private var finished = false
        private var readError: Int32?

        init(handle: FileHandle, limit: Int, keepTail: Bool) throws {
            self.handle = handle
            self.capture = LockedCapture(limit: limit, keepTail: keepTail)
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw PipeReadError.system(errno)
            }
            source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { try? handle.close() }
            source.resume()
        }

        deinit { source.cancel() }

        private func readAvailable() {
            guard !ended, !finished else { return }
            var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
            // Yield to finalization even if a descendant keeps the pipe busy.
            for _ in 0..<Self.maximumChunksPerEvent {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
                if count > 0 { capture.append(Data(buffer.prefix(count))); continue }
                if count == 0 { ended = true; source.cancel(); return }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { readError = errno; ended = true; source.cancel() }
                return
            }
        }

        private func finishOnQueue() throws -> Capture {
            readAvailable()
            finished = true
            source.cancel()
            if let readError { throw PipeReadError.system(readError) }
            return capture.snapshot()
        }

        func finishSynchronously() throws -> Capture {
            try queue.sync { try finishOnQueue() }
        }

        func finish() async throws -> Capture {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.finishOnQueue()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
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
        let stdoutCapture = try PipeCapture(handle: stdoutPipe.fileHandleForReading, limit: stdoutLimit, keepTail: false)
        let stderrCapture = try PipeCapture(handle: stderrPipe.fileHandleForReading, limit: stderrLimit, keepTail: true)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw error
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

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

        let stdout = try stdoutCapture.finishSynchronously()
        let stderr = try stderrCapture.finishSynchronously()
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

        let stdoutCapture = try PipeCapture(handle: stdoutPipe.fileHandleForReading, limit: stdoutLimit, keepTail: false)
        let stderrCapture = try PipeCapture(handle: stderrPipe.fileHandleForReading, limit: stderrLimit, keepTail: true)

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
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

        let stdout = try await stdoutCapture.finish()
        let stderr = try await stderrCapture.finish()
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
