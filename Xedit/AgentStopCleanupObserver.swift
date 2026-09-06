import Combine
import Foundation

/// Event-driven local-process receipts, including deliberately quiet Stop
/// completions. Remember each terminal receipt before history can be pruned.
@MainActor
final class AgentStopCleanupObserver {
    private let jobIDs: Set<UUID>
    private var terminalIDs: Set<UUID> = []
    private var subscription: AnyCancellable?
    private var onComplete: (() -> Void)?

    init(jobIDs: Set<UUID>, onComplete: @escaping () -> Void) {
        self.jobIDs = jobIDs
        self.onComplete = onComplete
    }

    func start(registry: AgentJobRegistry) {
        subscription = registry.$jobs.dropFirst().sink { [weak self] jobs in self?.receive(jobs) }
        receive(registry.jobs)
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
        onComplete = nil
    }

    private func receive(_ jobs: [AgentBackgroundJob]) {
        guard onComplete != nil else { return }
        terminalIDs.formUnion(jobs.filter { jobIDs.contains($0.id) && !$0.isAlive }.map(\.id))
        guard terminalIDs == jobIDs else { return }
        let completion = onComplete
        cancel()
        completion?()
    }
}
