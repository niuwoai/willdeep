//
//  AgentStreamIdleGuard.swift
//  WillDeep
//
//  Idle detection for streaming provider responses.
//
//  `timeoutIntervalForRequest` is "no bytes for this long", and SSE
//  keepalives are bytes: a gateway that pings every fifteen seconds while
//  the upstream sits dead can hold a request open forever. The four
//  adapters iterate `bytes.lines` bare. This wraps that iteration and runs
//  a clock that only payload lines reset — comment lines (`: ping`) and
//  blank separators keep the connection alive at the socket but do not
//  count as progress here. When the clock runs out the stream fails with
//  `AgentClientError.streamStalled`, which the transient-error ladder in
//  the turn loop treats like any other dropped connection.
//

import Foundation

nonisolated enum AgentStreamIdleGuard {
    /// Seconds without a payload line before the stream is declared
    /// stalled. Matches the request timeout: reasoning models really can
    /// spend that long before the first visible delta.
    static let streamIdleTimeout: TimeInterval = AgentNetworkSupport.requestTimeout

    /// An SSE line that carries content, as opposed to a keepalive comment
    /// or the blank line between events.
    static func isPayloadLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first != ":"
    }

    /// Yield `lines` unchanged, failing with `streamStalled` if no payload
    /// line arrives within `idleTimeout`.
    static func lines<Lines: AsyncSequence & Sendable>(
        _ lines: Lines,
        idleTimeout: TimeInterval = streamIdleTimeout
    ) -> AsyncThrowingStream<String, Error> where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                let lastPayloadAt = IdleClock()
                await lastPayloadAt.touch()
                let watchdog = Task {
                    let interval = UInt64(min(idleTimeout, 5) * 1_000_000_000)
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: interval)
                        if await lastPayloadAt.idleSeconds() >= idleTimeout {
                            throw AgentClientError.streamStalled(idleSeconds: idleTimeout)
                        }
                    }
                }
                defer { watchdog.cancel() }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in lines {
                                if isPayloadLine(line) { await lastPayloadAt.touch() }
                                continuation.yield(line)
                            }
                        }
                        group.addTask {
                            try await watchdog.value
                        }
                        // Whichever finishes first: the reader on end of
                        // stream, or the watchdog by throwing.
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor IdleClock {
        private var last = Date()
        func touch() { last = Date() }
        func idleSeconds() -> TimeInterval { Date().timeIntervalSince(last) }
    }
}
