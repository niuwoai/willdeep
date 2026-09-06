import Combine
import Foundation

extension AgentJobRegistry {
    /// Observe registry receipts, including deliberately quiet completions.
    /// Waiting never consumes notifications or cancels someone else's job.
    func waitForTerminal(id: UUID, forRuntime runtimeID: UUID) async throws -> AgentBackgroundJob {
        try Task.checkCancellation()
        terminalWaiterCount += 1
        defer { terminalWaiterCount -= 1 }
        let waiter = AgentJobTerminalWaiter(id: id, runtimeID: runtimeID)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(registry: self, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in waiter.cancel() }
        }
        // Cancellation takes priority even when a receipt raced its handler.
        try Task.checkCancellation()
        return result
    }
}

@MainActor
private final class AgentJobTerminalWaiter {
    private let id: UUID
    private let runtimeID: UUID
    private var subscription: AnyCancellable?
    private var continuation: CheckedContinuation<AgentBackgroundJob, Error>?
    private var cancelled = false

    init(id: UUID, runtimeID: UUID) {
        self.id = id
        self.runtimeID = runtimeID
    }

    func start(registry: AgentJobRegistry, continuation: CheckedContinuation<AgentBackgroundJob, Error>) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }
        // @Published emits its current value synchronously on subscription;
        // there is no read-then-subscribe gap that could lose a fast exit.
        let token = registry.$jobs.sink { [weak self] jobs in self?.receive(jobs) }
        if self.continuation == nil { token.cancel() }
        else { subscription = token }
    }

    func cancel() {
        cancelled = true
        finish(.failure(CancellationError()))
    }

    private func receive(_ jobs: [AgentBackgroundJob]) {
        guard let job = jobs.first(where: { $0.id == id && $0.runtimeID == runtimeID }) else {
            finish(.failure(AgentJobError.jobNotFound(id.uuidString)))
            return
        }
        if job.isAlive, let failure = job.monitoringFailure {
            finish(.failure(AgentJobError.exitUnconfirmed(job.displayHandle, failure)))
            return
        }
        guard !job.isAlive else { return }
        // Copy the terminal snapshot before history pruning can evict it.
        finish(.success(job))
    }

    private func finish(_ result: Result<AgentBackgroundJob, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        subscription?.cancel()
        subscription = nil
        continuation.resume(with: result)
    }
}
