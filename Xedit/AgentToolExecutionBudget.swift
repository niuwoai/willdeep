import Foundation

/// Host-only execution envelope. Model arguments cannot extend the deadline
/// or reopen a segment that is already in its ordered wrap-up phase.
nonisolated struct AgentToolExecutionBudget: Equatable, Sendable {
    let deadline: Date?
    let wrapUpOnly: Bool
    let requestLedger: AgentModelRequestLedger?
    let ownerGate: AgentRequestOwnerGate?

    init(budget: AgentGoalContinuationBudget, requestLedger: AgentModelRequestLedger? = nil,
         ownerGate: AgentRequestOwnerGate? = nil) {
        self.requestLedger = requestLedger
        self.ownerGate = ownerGate
        deadline = budget.segmentStartedAt.flatMap { start in
            budget.wallClockLimit.map { start.addingTimeInterval($0) }
        }
        wrapUpOnly = budget.wrapUpDispatched
    }

    func check(now: Date = Date()) throws {
        guard !wrapUpOnly, deadline.map({ now < $0 }) ?? true else {
            throw AgentToolExecutionBudgetError.exhausted
        }
    }

    @MainActor func checkCurrentOwner() throws {
        try Task.checkCancellation()
        // Stale ownership wins over a deadline: it must not pause a new Goal.
        try ownerGate?.check()
        try check()
    }

    /// One deadline covers the provider request AND its empty-response
    /// retries. Structured cancellation waits for the losing operation to
    /// unwind; it does not promise to reverse provider-side billing.
    @MainActor
    func runModelRequest(
        waitUntilDeadline: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        },
        _ operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try checkCurrentOwner()
        do {
            if let deadline {
                try await runUntilDeadline(deadline, waitUntilDeadline: waitUntilDeadline, operation: operation)
            } else {
                try await operation()
                try Task.checkCancellation()
                try checkCurrentOwner()
            }
        } catch {
            // Stop wins even if the timer's error was already queued while
            // the provider was unwinding. Never turn cancellation into a new
            // host continuation or a fresh approval request.
            try Task.checkCancellation()
            try ownerGate?.check()
            throw error
        }
    }

    @MainActor
    private func runUntilDeadline(
        _ deadline: Date,
        waitUntilDeadline: @escaping @Sendable (Date) async throws -> Void,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask { @MainActor in
                try Task.checkCancellation()
                try checkCurrentOwner()
                try await operation()
                try Task.checkCancellation()
                try ownerGate?.check()
                guard Date() < deadline else { throw AgentToolExecutionBudgetError.deadlineReached }
            }
            group.addTask {
                try await waitUntilDeadline(deadline)
                try Task.checkCancellation()
                throw AgentToolExecutionBudgetError.deadlineReached
            }
            _ = try await group.next()
            try Task.checkCancellation()
        }
    }
}

nonisolated enum AgentToolExecutionBudgetError: Error, LocalizedError, Equatable {
    case exhausted
    case deadlineReached

    var errorDescription: String? {
        switch self {
        case .exhausted:
            "The Goal execution budget is exhausted. This tool did not run. Do not retry or request broader permissions; provide the remaining-work handover."
        case .deadlineReached:
            "The Goal deadline was reached and the in-flight model request was cancelled. Partial output is not completion evidence. Do not retry or request broader permissions; provide the remaining-work handover."
        }
    }
}
