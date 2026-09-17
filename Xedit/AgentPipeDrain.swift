//
//  AgentPipeDrain.swift
//  Xedit
//
//  Reading a child's stdout/stderr to the end when it terminates.
//
//  `terminationHandler` used to take one `availableData` from each pipe and
//  then mark the job finished. Under load the `readabilityHandler` falls
//  behind, so more than one read's worth is still buffered when the process
//  exits: the rest — typically the verdict line (`RESULT=…`, `PASS`) — was
//  dropped from memory, the on-disk log and the completion notice. A read
//  already in flight in the handler could also land after the job was marked
//  finished. `AgentPipeReader` serialises handler reads with the final drain,
//  and the drain reads until EOF, bounded by a grace period in case a
//  descendant that escaped process-group cleanup still holds the write end.
//

import Darwin
import Foundation

nonisolated final class AgentPipeReader: @unchecked Sendable {
    /// Upper bound on how long the final drain waits for EOF once nothing
    /// more is readable. Long enough for a loaded host to deliver what the
    /// child already wrote, short enough that a leaked writer cannot hold a
    /// job in "running" noticeably.
    static let defaultDrainGraceSeconds: Double = 2
    /// Hard cap on the whole drain, for an escaped descendant that keeps
    /// writing: the grace period alone would then never elapse.
    static let maximumDrainSeconds: Double = 10
    private static let readChunkBytes = 64 * 1024

    private let lock = NSLock()
    private let handle: FileHandle
    private let sink: (Data) -> Void
    private var drained = false

    init(handle: FileHandle, sink: @escaping (Data) -> Void) {
        self.handle = handle
        self.sink = sink
    }

    /// Installs the readability handler. Every chunk goes through the same
    /// lock as `drainToEnd`, so no read can land after the drain returns.
    func startReading() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.drained else { return }
            let data = handle.availableData
            if !data.isEmpty { self.sink(data) }
        }
    }

    func stopReading() {
        handle.readabilityHandler = nil
    }

    /// Stops the handler, waits for any read in flight, then reads until EOF
    /// or until nothing arrives for `graceSeconds`.
    func drainToEnd(graceSeconds: Double = AgentPipeReader.defaultDrainGraceSeconds) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !drained else { return }
        drained = true
        Self.readUntilEOF(fileDescriptor: handle.fileDescriptor, graceSeconds: graceSeconds) { sink($0) }
    }

    /// Reads `fileDescriptor` until EOF. Returns early when no byte becomes
    /// readable within `graceSeconds` of the last one, or once
    /// `maximumSeconds` have passed in total.
    static func readUntilEOF(
        fileDescriptor: Int32,
        graceSeconds: Double,
        maximumSeconds: Double = AgentPipeReader.maximumDrainSeconds,
        sink: (Data) -> Void
    ) {
        var buffer = [UInt8](repeating: 0, count: readChunkBytes)
        let deadline = Date().addingTimeInterval(maximumSeconds)
        while true {
            let remaining = min(max(0, graceSeconds), deadline.timeIntervalSinceNow)
            if remaining <= 0 { return }
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { return }
            let count = buffer.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                sink(Data(buffer[0..<count]))
            } else if count == 0 {
                return
            } else if errno != EINTR && errno != EAGAIN {
                return
            }
        }
    }
}
