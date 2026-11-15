//
//  AgentForegroundCommandDrain.swift
//  Xedit
//
//  A foreground command owns both pipe readers on one thread. Descendants may
//  retain a pipe after the root shell exits, so EOF is not an unbounded wait.
//

import Darwin
import Foundation

nonisolated enum AgentForegroundCommandDrain {
    enum Completion {
        case finished
        case timedOut
        case cancelled
    }

    private static let readChunkBytes = 64 * 1024
    private static let cancellationPollMilliseconds: Int32 = 50
    private static let millisecondsPerSecond: Double = 1_000

    /// Set this before launching: even a spurious readiness event must never
    /// leave a read blocked beyond cancellation or the command's deadline.
    static func prepare(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw pipeError(operation: "configure nonblocking pipe")
        }
    }

    private static func pipeError(operation: String) -> POSIXError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return POSIXError(code, userInfo: [
            NSLocalizedDescriptionKey: "run_command: \(operation) failed: \(String(cString: strerror(code.rawValue)))"
        ])
    }

    /// No readability handlers or other readers may use these handles. The
    /// caller closes them only after this synchronous loop returns, including
    /// on cancellation; closing a FileHandle around a blocking Foundation read
    /// can otherwise raise an Objective-C exception.
    static func wait(
        for process: Process,
        stdout: FileHandle,
        stderr: FileHandle,
        deadline: TimeInterval,
        receiveStdout: (Data) -> Void,
        receiveStderr: (Data) -> Void
    ) throws -> Completion {
        var descriptors = [
            pollfd(fd: stdout.fileDescriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stderr.fileDescriptor, events: Int16(POLLIN), revents: 0)
        ]
        var buffer = [UInt8](repeating: 0, count: readChunkBytes)
        var exitObservedAt: TimeInterval?
        var idleDeadline: TimeInterval?

        while true {
            if Task.isCancelled { return .cancelled }
            let now = ProcessInfo.processInfo.systemUptime
            let rootExited = !process.isRunning
            // One loop owns the completion decision. There is no independently
            // scheduled timeout that can mark an already finished result late.
            if rootExited, descriptors.allSatisfy({ $0.fd < 0 }) {
                return .finished
            }
            if now >= deadline { return .timedOut }

            if rootExited, exitObservedAt == nil {
                exitObservedAt = now
                idleDeadline = now + AgentPipeReader.defaultDrainGraceSeconds
            }
            var nextDeadline = deadline
            if let exitObservedAt {
                let drainDeadline = exitObservedAt + AgentPipeReader.maximumDrainSeconds
                if now >= drainDeadline { return .finished }
                nextDeadline = min(nextDeadline, drainDeadline, idleDeadline ?? drainDeadline)
            }
            let remainingMilliseconds = max(0, (nextDeadline - now) * millisecondsPerSecond)
            let pollMilliseconds = Int32(min(Double(cancellationPollMilliseconds), remainingMilliseconds.rounded(.up)))
            let ready = descriptors.withUnsafeMutableBufferPointer { descriptors in
                Darwin.poll(descriptors.baseAddress, nfds_t(descriptors.count), pollMilliseconds)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw pipeError(operation: "poll stdout/stderr")
            }
            if ready == 0 {
                // A final zero-time poll still reads buffered tail bytes after
                // an idle deadline, but cannot extend the absolute hard cap.
                if let idleDeadline, ProcessInfo.processInfo.systemUptime >= idleDeadline {
                    if Task.isCancelled { return .cancelled }
                    if ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
                    return .finished
                }
                continue
            }

            // At most one chunk per stream per turn: a descendant continuously
            // writing stdout cannot starve stderr, deadline or cancel checks.
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                if Task.isCancelled { return .cancelled }
                let count = buffer.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptors[index].fd, buffer.baseAddress, buffer.count)
                }
                if count > 0 {
                    let chunk = Data(buffer.prefix(count))
                    if index == 0 {
                        receiveStdout(chunk)
                    } else {
                        receiveStderr(chunk)
                    }
                    if exitObservedAt != nil {
                        idleDeadline = ProcessInfo.processInfo.systemUptime + AgentPipeReader.defaultDrainGraceSeconds
                    }
                } else if count == 0 {
                    // poll ignores negative fds; do not keep polling EOF, which
                    // otherwise remains readable and spins a core.
                    descriptors[index].fd = -1
                } else if errno != EINTR && errno != EAGAIN {
                    throw pipeError(operation: index == 0 ? "read stdout" : "read stderr")
                }
            }
        }
    }
}
