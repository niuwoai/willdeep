import Foundation

extension AppState {
    /// Replay host-observed checks on the combined candidate, not on each
    /// worker's old tree. UI completion and worker prose are not evidence.
    func combinedDispatchVerificationCommands(
        candidate: AgentDispatchIntegrationCandidate, task: AgentDispatchTask,
        runtime: AgentRuntime, repository: URL
    ) async throws -> [String] {
        let own = Self.dispatchVerificationCommands(task: task, runtime: runtime)
        guard task.operatorAcceptedAt != nil || !own.isEmpty else {
            throw AgentDispatchDeliveryError.missingVerification
        }
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == candidate.goalID }) else {
            throw AgentDispatchDeliveryError.staleRuntime
        }
        let identity = try await AgentDispatchArtifactIntegrator.repositoryIdentity(in: repository)
        var commands: [String] = []
        var identities: [String: URL] = [:]
        for prior in goal.tasks where prior.id != task.id && prior.state == .merged {
            guard let binding = goal.resolvedWorkspaceBinding(for: prior) else {
                throw AgentDispatchDeliveryError.missingInput
            }
            // Separate repositories need their own final/semantic verifier;
            // never run their commands in this candidate's checkout.
            guard case .local(let path) = binding.location else { continue }
            let priorIdentity: URL
            if let cached = identities[path] { priorIdentity = cached }
            else {
                priorIdentity = try await AgentDispatchArtifactIntegrator.repositoryIdentity(in: URL(fileURLWithPath: path))
                identities[path] = priorIdentity
            }
            guard priorIdentity == identity else { continue }
            guard let record = try dispatchDeliveryJournal.load(goalID: goal.id, taskID: prior.id),
                  record.phase == .delivered, let receipt = record.receipt,
                  receipt == prior.integrationReceipt,
                  receipt.snapshot == record.candidate.snapshot,
                  receipt.integratedRevision == record.candidate.revision,
                  let verified = record.verificationReceipt, verified.isValid,
                  verified.id == record.verificationID, verified.revision == receipt.integratedRevision else {
                throw AgentDispatchJournalError.corrupt
            }
            guard try await AgentDispatchArtifactIntegrator.isAncestor(receipt.integratedRevision,
                of: candidate.previousRevision, in: repository) else {
                throw AgentDispatchDeliveryError.retryIntegration
            }
            commands.append(contentsOf: verified.commands)
        }
        // An explicit override covers this node only, not prior nodes' checks.
        if task.operatorAcceptedAt == nil { commands.append(contentsOf: own) }
        var seen = Set<String>()
        return commands.filter { seen.insert($0).inserted }
    }
}
