import Foundation

extension AppState {
    /// Every start path checks the same live reservations. The candidate's
    /// old reviewing/failed state is not a reservation against itself, but a
    /// retiring process still is: it must exit before a replacement starts.
    func dispatchAdmissionIsAvailable(goalID: UUID, taskID: UUID, continuingRuntimeID: UUID? = nil) -> Bool {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }), !goal.isPaused,
              let task = goal.tasks.first(where: { $0.id == taskID }) else { return false }
        if let continuingRuntimeID {
            guard task.runtimeSessionID == continuingRuntimeID, let runtime = agentRuntimes[continuingRuntimeID],
                  !runtime.isResponding, !runtime.isAwaitingProviderSlot, !runtime.isCompressingContext else { return false }
            // Same owner may consume its own running server/worker; replacing
            // that owner must wait for those processes to retire instead.
        } else if dispatchTaskHasLiveWork(task)
                    || (task.state == .reviewing && dispatchMonitoredRuntimeIDsByTaskID[taskID] != nil) {
            return false
        }
        let capacity = AgentDispatchParallelismPolicy.taskLimit(providerConcurrencyLimit: perProviderConcurrencyLimit)
        let nodes = agentDispatchCoordinator.goals.flatMap { project in
            project.tasks.map { node -> AgentDispatchReadyScheduler.Node in
                let candidate = project.id == goalID && node.id == taskID
                return schedulingNode(task: node, goal: project, selectable: false, admissionCandidate: candidate)
            }
        }
        let occupied = Set(nodes.filter { $0.phase == .active }.map(\.id))
        guard goal.tasks.filter({ occupied.contains($0.id) }).count < capacity else { return false }
        return AgentDispatchReadyScheduler.ready(nodes: nodes, capacity: 1).contains(taskID)
    }

    func dispatchTaskHasLiveWork(_ task: AgentDispatchTask) -> Bool {
        guard let id = task.runtimeSessionID else { return false }
        let runtime = agentRuntimes[id]
        return runtime?.isResponding == true || runtime?.isAwaitingProviderSlot == true || runtime?.isCompressingContext == true
            || !agentJobRegistry.aliveJobs(forRuntime: id).isEmpty
            || agentSubagentRegistry.runs.contains { $0.parentRuntimeID == id && $0.status == .running }
    }

    func readyDispatchTaskIDs(goalID: UUID, capacity: Int) -> [UUID] {
        let nodes: [AgentDispatchReadyScheduler.Node] = agentDispatchCoordinator.goals.flatMap { goal in
            goal.tasks.map { task in schedulingNode(task: task, goal: goal, selectable: goal.id == goalID && !goal.isPaused) }
        }
        return AgentDispatchReadyScheduler.ready(nodes: nodes, capacity: capacity)
    }

    private func schedulingNode(task: AgentDispatchTask, goal: AgentDispatchGoal, selectable: Bool,
                                admissionCandidate: Bool = false) -> AgentDispatchReadyScheduler.Node {
        let phase: AgentDispatchReadyScheduler.Phase
        if admissionCandidate { phase = .queued }
        else if task.state != .merged && dispatchTaskHasLiveWork(task) { phase = .active }
        else { switch task.state {
        case .running, .reviewing, .accepted: phase = .active
        case .merged: phase = .integrated
        case .queued: phase = selectable && task.pendingDecisionIDs?.isEmpty != false ? .queued : .inactive
        default: phase = .inactive
        } }
        let hints = task.scheduling ?? AgentDispatchSchedulingHints()
        let binding = goal.resolvedWorkspaceBinding(for: task)
        let workspaceKey: String
        if case .local? = binding?.location, let repositoryIdentity = goal.logicalProject?.localRepositoryIdentity {
            workspaceKey = "repository:" + URL(fileURLWithPath: repositoryIdentity).standardizedFileURL.resolvingSymlinksInPath().path
        } else if case .local(let path)? = binding?.location {
            workspaceKey = "workspace:" + URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        } else {
            workspaceKey = "workspace:" + (binding?.id ?? "unbound:\(goal.id)")
        }
        let isolated: Bool
        if case .local(let sourcePath)? = binding?.location, goal.logicalProject?.localRepositoryIdentity != nil {
            if let runtimeID = task.runtimeSessionID {
                let path = agentSessions.first(where: { $0.id == runtimeID })?.workspaceRootPath
                isolated = path.map {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                        != URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
                } ?? false
            } else { isolated = true }
        } else { isolated = false }
        // Shared non-Git/remote checkouts cannot rely on after-the-fact
        // artifact checks to prevent concurrent writes to their actual files.
        var resources = [AgentDispatchReadyScheduler.Resource(key: workspaceKey, paths: isolated ? hints.normalizedWritePaths : nil)]
        for resource in hints.exclusiveResources ?? [] {
            let key = resource.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { resources.append(.init(key: "shared:" + key, paths: nil)) }
        }
        return .init(id: task.id, dependencies: task.dependencyIDs, phase: phase, cost: hints.cost, resources: resources)
    }

    nonisolated static var dispatchSchedulingContractPrompt: String {
        """
        Each node may include scheduling: {"write_paths":["repository-relative/file-or-directory"],"exclusive_resources":["shared build cache or port identity"],"estimated_seconds":60}. Declare the files/directories the node will publish and shared resources it must exclusively use; omit unknown estimates rather than inventing precision. Missing/invalid write scope reserves the whole workspace. Declared scope is frozen at launch, and out-of-scope artifacts cannot be integrated. Scheduling hints do not grant permissions.
        WillDeep performs candidate verification and Git integration between dependency nodes. Do not add a worker whose only purpose is to merge branches or repeat that host operation. Add an implementation integration task only for actual glue/code work. Keep real prerequisites and an executable final verification node for multi-part projects; do not invent a minimum number of layers or unnecessary planning/review rounds.
        """
    }
}
