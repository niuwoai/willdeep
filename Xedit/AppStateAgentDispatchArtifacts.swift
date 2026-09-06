import Foundation

extension AppState {
    /// Pin the input before creating a checkout or launching a worker. A
    /// continuation uses its original input; a new node starts from the latest
    /// host-published integration, never an unrelated moving source HEAD.
    func prepareDispatchInputRevision(
        goal: AgentDispatchGoal,
        task: AgentDispatchTask,
        binding: AgentDispatchWorkspaceBinding
    ) -> Result<String?, AgentGitWorktreeFailure> {
        guard case .local(let path) = binding.location,
              let root = Self.findGitRepositoryRoot(startingAt: URL(fileURLWithPath: path)) else {
            return .success(nil)
        }
        if let revision = task.inputRevision { return .success(revision) }
        // A legacy runtime may already have committed changes. Its current
        // HEAD cannot retroactively serve as the verified input of that work.
        if task.runtimeSessionID != nil {
            return .failure(AgentGitWorktreeFailure(message: L10n.Dispatch.artifactInputMissing))
        }
        let base: String
        if let pinned = goal.integrationBaseRevisions?[binding.id] {
            base = pinned
        } else {
            let result = Self.runGitCommand(arguments: ["rev-parse", "--verify", "HEAD^{commit}"], in: root)
            guard result.succeeded else { return .failure(.init(message: result.userMessage)) }
            base = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let result = Self.runGitCommand(
            arguments: ["rev-parse", "--verify", "--quiet", "\(AgentDispatchArtifactIntegrator.integratedRef(goalID: goal.id))^{commit}"],
            in: root, allowedExitStatuses: [0, 1]
        )
        guard result.succeeded else { return .failure(.init(message: result.userMessage)) }
        let input = result.status == 0 ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : base
        agentDispatchCoordinator.pinTaskInputRevision(
            goalID: goal.id, taskID: task.id, bindingID: binding.id, baseRevision: base, inputRevision: input
        )
        return .success(input)
    }
}
