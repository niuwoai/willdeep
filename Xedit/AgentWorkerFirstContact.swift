//
//  AgentWorkerFirstContact.swift
//  WillDeep
//
//  A spawned Worker that never reaches its provider used to take ten
//  minutes to die: the default URLSession keeps re-handshaking inside its
//  600-second resource budget, the Worker has no retry ladder of its own,
//  and its first heartbeat is "round 1, thinking" — published before the
//  request goes out, so the strip looked alive the whole time. Meanwhile the
//  parent was fenced behind the delegate-first route with nothing to do.
//
//  This races the Worker's first request against a short clock. "Contact" is
//  the first streamed event of any kind; once one arrives the clock is
//  dropped and the request runs to whatever its normal limits are. Only the
//  first round is guarded — later rounds have already proven the link.
//
//  The loser is an explicit error, not a cancellation: the runner treats
//  `CancellationError` as the user pressing Stop and would never reach the
//  spawn failure branch that lifts the route fence.
//

import Foundation

nonisolated enum AgentWorkerFirstContact {
    /// Seconds a Worker may spend on its first request without a single
    /// streamed event. Twenty seconds is several TLS handshakes plus a
    /// provider's time-to-first-token at the slow end; a provider that
    /// cannot answer in that time is not going to.
    static let timeout: TimeInterval = 20

    /// Run `operation`, failing with `AgentSubagentError.firstContactTimeout`
    /// if `hasMadeContact()` is still false after `timeout` seconds.
    ///
    /// `hasMadeContact` is polled once, when the clock runs out, so the
    /// operation pays nothing for the guard on the happy path.
    static func race<T: Sendable>(
        timeout: TimeInterval = timeout,
        hasMadeContact: @escaping @Sendable () async -> Bool,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
            group.addTask { .finished(try await operation()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if await hasMadeContact() {
                    return .contactMade
                }
                throw AgentSubagentError.firstContactTimeout(timeout)
            }
            // The first task to finish decides. If the clock expired and no
            // contact was made it threw here and the operation is cancelled
            // with the group. If the clock expired *with* contact, keep
            // waiting for the operation.
            while let outcome = try await group.next() {
                if case .finished(let value) = outcome {
                    group.cancelAll()
                    return value
                }
            }
            throw CancellationError()
        }
    }

    private enum Outcome<T: Sendable>: Sendable {
        case finished(T)
        case contactMade
    }
}
