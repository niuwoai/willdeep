import Foundation

/// The server's monotonic clock is instance-relative, never a Unix timestamp.
/// Add the remaining local budget only after receiving identity. Response
/// latency makes this conservative; clock skew cannot extend the budget.
nonisolated enum AgentDaemonRunDeadline {
    static let maximumMilliseconds = Int64.max / 1_000_000
    static let maximumCommandSeconds = 6 * 3600

    static func commandTimeout(requestedSeconds: Int?, foregroundMaximum: TimeInterval,
        background: Bool) -> Int {
        let requested = requestedSeconds ?? Int(foregroundMaximum)
        let maximum = background ? maximumCommandSeconds
            : min(maximumCommandSeconds, max(1, Int(foregroundMaximum)))
        return min(max(requested, 1), maximum)
    }

    static func resolve(localDeadline: Date?, serverElapsedMilliseconds: Int64?,
        timeoutSeconds: Int, now: Date = Date()) throws -> Int64? {
        guard let localDeadline else { return nil }
        guard let elapsed = serverElapsedMilliseconds, elapsed >= 0,
              elapsed < maximumMilliseconds else {
            throw AgentToolError.invalidArgument("Daemon returned an invalid monotonic clock.")
        }
        let remaining = min(localDeadline.timeIntervalSince(now), Double(timeoutSeconds))
        guard remaining.isFinite, remaining >= 0.001 else {
            throw AgentToolExecutionBudgetError.exhausted
        }
        let milliseconds = Int64((min(remaining, Double(maximumCommandSeconds)) * 1000).rounded(.down))
        guard elapsed <= maximumMilliseconds - milliseconds else {
            throw AgentToolError.invalidArgument("Daemon deadline exceeds the monotonic clock range.")
        }
        return elapsed + milliseconds
    }
}
