//
//  AppStateAgentDispatchOrchestration.swift
//  WillDeep
//
//  Bridges durable dispatch-console records to real Agent runtimes.
//

import AppKit
import Foundation

nonisolated enum AgentDispatchLaunchResult: Equatable {
    case started(runtimeSessionID: UUID)
    case blocked(message: String)
}

extension AppState {
    func startGoalConversationInLocalWorkspace() {
        let panel = Self.folderOpenPanel()
        panel.title = L10n.Dispatch.chooseWorkspace
        panel.message = L10n.Dispatch.chooseWorkspaceMessage
        panel.prompt = L10n.Dispatch.chooseWorkspaceAction
        Self.presentFolderOpenPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            _ = self.startNewAgentSession(inWorkspaceAt: url.standardizedFileURL.path)
            self.setAgentInteractionMode(.goal)
        }
    }

    func chooseLocalWorkspaceForDispatchGoal(
        goalID: UUID,
        completion: @escaping (String?) -> Void
    ) {
        let panel = Self.folderOpenPanel()
        panel.title = L10n.Dispatch.chooseWorkspace
        panel.message = L10n.Dispatch.mapWorkspaceMessage
        panel.prompt = L10n.Dispatch.chooseWorkspaceAction
        Self.presentFolderOpenPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                completion(nil)
                return
            }
            completion(
                self.bindDispatchGoalWorkspace(
                    goalID: goalID,
                    location: .local(path: url.standardizedFileURL.path)
                )
            )
        }
    }

    func bindDispatchGoalWorkspace(
        goalID: UUID,
        location: WorkspaceLocation
    ) -> String? {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }) else {
            return L10n.Dispatch.launchFailed
        }
        let isPrimaryBinding = goal.workspaceLocation == nil
        if isPrimaryBinding {
            guard let sourceRuntime = runtime(for: goal.sessionID) else {
                return L10n.Dispatch.launchFailed
            }
            guard !sourceRuntime.isResponding && !sourceRuntime.isCompressingContext else {
                return L10n.Dispatch.workspaceBusy
            }
            switch location {
            case .local(let rawPath):
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard Self.isExistingDirectory(url) else {
                    return L10n.Dispatch.workspaceMissing
                }
                _ = activateSecurityScope(for: url)
                registerRecentFolder(url)
                sourceRuntime.rebindWorkspace(to: url.path)
            case .remote(let runtimeID, let rawPath):
                guard AgentRuntimeStore.descriptor(id: runtimeID) != nil else {
                    return L10n.Dispatch.remoteWorkspaceUnavailable
                }
                sourceRuntime.rebindRemoteWorkspace(
                    runtimeID: runtimeID,
                    path: RemotePathValidator.normalizedWorkspaceRoot(rawPath)
                )
            }
            sourceRuntime.worktreeChanges = .init()
            sourceRuntime.agentArtifactPaths = []
            persistAgentSession(runtime: sourceRuntime)
        }

        agentDispatchCoordinator.bindWorkspace(
            location,
            goalID: goalID,
            makePrimary: isPrimaryBinding
        )
        agentDispatchCoordinator.synchronize(with: agentSessions)
        return nil
    }

    func submitDispatchGoalInstruction(
        goalID: UUID,
        commandID: UUID,
        text: String,
        effect: AgentDispatchCommandEffect
    ) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let runtime = runtime(for: goal.sessionID) else {
            agentDispatchCoordinator.cancelCommand(goalID: goalID, commandID: commandID)
            return
        }

        let prompt = Self.dispatchGoalInstructionPrompt(text)
        let queued = AgentQueuedMessage(
            text: prompt,
            executionAgent: .willDeep,
            source: .operatorInput
        )

        switch effect {
        case .queuedForSafePoint:
            runtime.queuedMessages.append(queued)
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        case .appliedImmediately:
            if runtime.isResponding || runtime.isCompressingContext {
                runtime.queuedMessages.append(queued)
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            } else {
                dispatchAgentMessageUsingSelectedExecutor(
                    .willDeep,
                    for: runtime,
                    text: prompt,
                    images: [],
                    source: .operatorInput
                )
            }
        case .requiresInterruptConfirmation:
            break
        }
    }

    func confirmDispatchGoalInterrupt(
        goalID: UUID,
        commandID: UUID,
        text: String
    ) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let runtime = runtime(for: goal.sessionID) else {
            agentDispatchCoordinator.cancelCommand(goalID: goalID, commandID: commandID)
            return
        }

        let queued = AgentQueuedMessage(
            text: Self.dispatchGoalInstructionPrompt(text),
            executionAgent: .willDeep,
            source: .operatorInput
        )
        if runtime.isResponding {
            runtime.queuedMessages.insert(queued, at: 0)
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            stopAgentResponse(for: runtime)
        } else {
            dispatchAgentMessageUsingSelectedExecutor(
                .willDeep,
                for: runtime,
                text: queued.text,
                images: [],
                source: .operatorInput
            )
        }
        agentDispatchCoordinator.resolveCommand(
            goalID: goalID,
            commandID: commandID,
            interrupted: true
        )
    }

    func launchDispatchTask(
        goalID: UUID,
        taskID: UUID
    ) -> AgentDispatchLaunchResult {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID }) else {
            return .blocked(message: L10n.Dispatch.launchFailed)
        }
        guard !goal.isPaused else {
            return .blocked(message: L10n.Dispatch.goalPausedLaunch)
        }
        guard goal.workspaceLocation != nil else {
            return .blocked(message: L10n.Dispatch.workspaceRequired)
        }
        guard task.state == .queued || task.state == .failed || task.state == .cancelled else {
            return .blocked(message: L10n.Dispatch.waitingForDependencies)
        }

        guard let target = goal.resolvedTargetChoice(taskChoice: task.targetChoice),
              let workspaceLocation = goal.workspaceLocation(for: target) else {
            return .blocked(message: L10n.Dispatch.workspaceMappingRequired)
        }
        let available = availableDispatchExecutors(on: target)
        let executorChoice = task.executorChoice == .automatic
            ? goal.executorChoice
            : task.executorChoice
        let decision = AgentDispatchExecutorResolver.resolve(
            title: task.title,
            choice: executorChoice,
            availableExecutors: available
        )
        guard decision.isAvailable else {
            return .blocked(message: L10n.Dispatch.noExecutorOnTarget)
        }

        guard let runtime = createDispatchTaskRuntime(workspaceLocation: workspaceLocation) else {
            return .blocked(message: L10n.Dispatch.launchFailed)
        }
        runtime.session.title = "\(goal.title) · \(task.title)"
        runtime.session.titleIsUserSet = true
        runtime.interactionMode = .goal
        runtime.currentGoal = AgentGoal(
            statement: task.title,
            checklist: task.acceptanceCriteria.map { AgentGoal.Item(text: $0) }
        )
        runtime.executionAgent = decision.executor
        persistAgentSession(runtime: runtime)

        agentDispatchCoordinator.markTaskStarted(
            goalID: goalID,
            taskID: taskID,
            executor: decision.executor,
            target: target,
            runtimeSessionID: runtime.id
        )

        dispatchAgentMessageUsingSelectedExecutor(
            decision.executor,
            for: runtime,
            text: Self.dispatchTaskPrompt(goal: goal, task: task),
            images: [],
            source: .hostInstruction
        )
        agentPrimaryDestination = .dispatchBoard
        monitorDispatchTaskRuntime(
            runtime,
            goalID: goalID,
            taskID: taskID
        )
        return .started(runtimeSessionID: runtime.id)
    }

    func openDispatchTaskConversation(runtimeSessionID: UUID) {
        guard selectAgentSession(id: runtimeSessionID) else { return }
        agentPrimaryDestination = .conversation
    }

    private func availableDispatchExecutors(
        on target: AgentDispatchTargetChoice
    ) -> Set<AgentExecutionAgent> {
        switch target {
        case .automatic, .local:
            return AgentDispatchExecutorResolver.localAvailableExecutors()
        case .remote(let runtimeID):
            return AgentRuntimeStore.descriptor(id: runtimeID)?
                .capabilities.availableExecutionAgents ?? [.willDeep]
        }
    }

    private func createDispatchTaskRuntime(
        workspaceLocation: WorkspaceLocation
    ) -> AgentRuntime? {
        switch workspaceLocation {
        case .local(let path):
            let session = startNewAgentSession(inWorkspaceAt: path)
            return runtime(for: session.id)
        case .remote(let runtimeID, let path):
            guard AgentRuntimeStore.descriptor(id: runtimeID) != nil else { return nil }
            let session = startNewAgentSession(inWorkspaceAt: nil)
            guard let taskRuntime = runtime(for: session.id) else { return nil }
            taskRuntime.rebindRemoteWorkspace(
                runtimeID: runtimeID,
                path: path
            )
            persistAgentSession(runtime: taskRuntime)
            return taskRuntime
        }
    }

    private func monitorDispatchTaskRuntime(
        _ runtime: AgentRuntime,
        goalID: UUID,
        taskID: UUID
    ) {
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            while runtime.isResponding || runtime.isAwaitingProviderSlot {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
            }
            let state: AgentDispatchTaskState = runtime.errorMessage == nil
                ? .reviewing
                : .failed
            self.agentDispatchCoordinator.updateTaskState(
                goalID: goalID,
                taskID: taskID,
                state: state
            )
        }
    }

    nonisolated private static func dispatchGoalInstructionPrompt(_ text: String) -> String {
        """
        <goal-orchestrator-instruction>
        \(text)
        </goal-orchestrator-instruction>

        Treat this as a user-authored revision to the active Goal. Preserve completed work and current evidence. Apply the instruction at a safe execution boundary, update the plan/checklist when needed, and explain any task or executor changes before continuing.
        """
    }

    nonisolated private static func dispatchTaskPrompt(
        goal: AgentDispatchGoal,
        task: AgentDispatchTask
    ) -> String {
        let criteria = task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
        return """
        Goal: \(goal.statement)

        Assigned task: \(task.title)
        Suggested branch: \(task.branchName)

        Acceptance criteria:
        \(criteria)

        Work only inside the assigned workspace. Preserve unrelated changes. Before reporting completion, provide concrete evidence such as tests, build output, or a focused diff summary. Do not merge into a shared branch; WillDeep owns review and integration.
        """
    }
}
