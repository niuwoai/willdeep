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
    @discardableResult
    func deleteDispatchGoal(goalID: UUID) -> Bool {
        guard let goal = agentDispatchCoordinator.removeGoal(id: goalID) else {
            return false
        }

        for sessionID in goal.ownedSessionIDs {
            if let runtime = runtime(for: sessionID) {
                stopAgentResponse(for: runtime)
            }
            deleteAgentSession(id: sessionID)
        }
        return true
    }

    func startDispatchGoalInLocalWorkspace() {
        let panel = Self.folderOpenPanel()
        panel.title = L10n.Dispatch.chooseWorkspace
        panel.message = L10n.Dispatch.chooseWorkspaceMessage
        panel.prompt = L10n.Dispatch.chooseWorkspaceAction
        Self.presentFolderOpenPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.startDispatchGoalSession(
                inWorkspaceAt: url.standardizedFileURL.path
            )
        }
    }

    /// Creates the structured Goal draft without leaving the orchestrator.
    /// `startNewAgentSession(inWorkspaceAt:)` intentionally routes ordinary
    /// callers to the conversation destination, so the dispatch entry point
    /// must restore its own presentation scope and destination explicitly.
    @discardableResult
    func startDispatchGoalSession(inWorkspaceAt workspacePath: String) -> AgentSession {
        let session = startNewAgentSession(inWorkspaceAt: workspacePath)
        guard let runtime = runtime(for: session.id) else {
            agentPrimaryDestination = .dispatchBoard
            return session
        }

        runtime.session.presentationScope = .dispatchBoard
        setAgentInteractionMode(.goal)
        applyDispatchModel(
            AgentDispatchModelRouting.costOptimized.planningModelID,
            to: runtime
        )
        agentPrimaryDestination = .dispatchBoard
        persistAgentSession(runtime: runtime)
        return runtime.session
    }

    var isPreparingDispatchGoal: Bool {
        guard agentPrimaryDestination == .dispatchBoard,
              let runtime = activeRuntime else {
            return false
        }
        return runtime.session.presentationScope == .dispatchBoard
            && runtime.interactionMode == .goal
            && runtime.currentGoal == nil
    }

    func selectDispatchGoal(_ goalID: UUID) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }) else {
            return
        }
        agentDispatchCoordinator.selectGoal(goalID)
        _ = selectAgentSession(id: goal.sessionID)
        agentPrimaryDestination = .dispatchBoard
    }

    func updateDispatchGoalModelRouting(
        _ routing: AgentDispatchModelRouting,
        goalID: UUID
    ) {
        agentDispatchCoordinator.updateGoalModelRouting(routing, goalID: goalID)
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let runtime = runtime(for: goal.sessionID) else {
            return
        }
        applyDispatchModel(routing.planningModelID, to: runtime)
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
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

    func chooseRemoteWorkspaceForDispatchGoal(
        goalID: UUID,
        runtime: RuntimeDescriptor,
        completion: @escaping (String?) -> Void
    ) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }) else {
            completion(L10n.Dispatch.launchFailed)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.Dispatch.chooseRemoteWorkspace
        alert.informativeText = L10n.Dispatch.remoteWorkspaceMessage(
            projectName: goal.logicalProject?.displayName ?? goal.title,
            runtimeName: runtime.displayName
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Dispatch.bindWorkspace)
        alert.addButton(withTitle: L10n.Dispatch.cancel)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = goal.workspaceLocation(for: .remote(runtime.id))?.path
            ?? runtime.defaultWorkspacePath
        input.placeholderString = runtime.defaultWorkspacePath
        input.usesSingleLineMode = true
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(nil)
            return
        }
        let path = RemotePathValidator.normalizedWorkspaceRoot(input.stringValue)
        guard !path.isEmpty else {
            completion(L10n.Dispatch.remoteWorkspacePathRequired)
            return
        }
        completion(
            bindDispatchGoalWorkspace(
                goalID: goalID,
                location: .remote(runtimeID: runtime.id, path: path)
            )
        )
    }

    func bindDispatchGoalWorkspace(
        goalID: UUID,
        location: WorkspaceLocation
    ) -> String? {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }) else {
            return L10n.Dispatch.launchFailed
        }
        let isPrimaryBinding = !goal.isWorkspaceBound
        let logicalProject: AgentDispatchLogicalProject
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
                let normalizedPath = RemotePathValidator.normalizedWorkspaceRoot(rawPath)
                guard !normalizedPath.isEmpty else {
                    return L10n.Dispatch.remoteWorkspacePathRequired
                }
                sourceRuntime.rebindRemoteWorkspace(
                    runtimeID: runtimeID,
                    path: normalizedPath
                )
            }
            sourceRuntime.worktreeChanges = .init()
            sourceRuntime.agentArtifactPaths = []
            persistAgentSession(runtime: sourceRuntime)
            logicalProject = AgentDispatchLogicalProjectResolver.resolve(location: location)
        } else {
            guard let existingProject = goal.logicalProject else {
                return L10n.Dispatch.workspaceRequired
            }
            switch location {
            case .local(let rawPath):
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard Self.isExistingDirectory(url) else {
                    return L10n.Dispatch.workspaceMissing
                }
                guard AgentDispatchLogicalProjectResolver.localCheckoutBelongs(
                    to: existingProject,
                    path: url.path
                ) else {
                    return L10n.Dispatch.workspaceProjectMismatch
                }
                _ = activateSecurityScope(for: url)
                registerRecentFolder(url)
            case .remote(let runtimeID, let rawPath):
                guard AgentRuntimeStore.descriptor(id: runtimeID) != nil else {
                    return L10n.Dispatch.remoteWorkspaceUnavailable
                }
                guard !RemotePathValidator.normalizedWorkspaceRoot(rawPath).isEmpty else {
                    return L10n.Dispatch.remoteWorkspacePathRequired
                }
            }
            logicalProject = existingProject
        }

        agentDispatchCoordinator.bindWorkspace(
            location,
            logicalProject: logicalProject,
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

        applyDispatchModel(goal.effectiveModelRouting.planningModelID, to: runtime)
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

        applyDispatchModel(goal.effectiveModelRouting.planningModelID, to: runtime)
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
        guard goal.isWorkspaceBound else {
            return .blocked(message: L10n.Dispatch.workspaceRequired)
        }
        guard task.state == .queued || task.state == .failed || task.state == .cancelled else {
            return .blocked(message: L10n.Dispatch.waitingForDependencies)
        }

        guard let workspaceBinding = goal.resolvedWorkspaceBinding(for: task) else {
            return .blocked(message: L10n.Dispatch.workspaceMappingRequired)
        }
        let target = workspaceBinding.targetChoice
        let workspaceLocation = workspaceBinding.location
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
        runtime.session.presentationScope = .dispatchBoard
        runtime.session.dispatchParentProjectID = goal.id
        runtime.session.dispatchTaskID = task.id
        runtime.interactionMode = .goal
        runtime.currentGoal = AgentGoal(
            statement: task.title,
            checklist: task.acceptanceCriteria.map { AgentGoal.Item(text: $0) }
        )
        runtime.executionAgent = decision.executor
        if decision.executor == .willDeep {
            applyDispatchModel(
                goal.effectiveModelRouting.executionModelID,
                to: runtime
            )
        }
        persistAgentSession(runtime: runtime)

        agentDispatchCoordinator.markTaskStarted(
            goalID: goalID,
            taskID: taskID,
            executor: decision.executor,
            target: target,
            runtimeSessionID: runtime.id
        )

        let delegatedProfile = selectedDispatchCLIProfile(
            goal: goal,
            executor: decision.executor
        )
        dispatchAgentMessageUsingSelectedExecutor(
            decision.executor,
            for: runtime,
            text: Self.dispatchTaskPrompt(
                goal: goal,
                task: task,
                workspaceBinding: workspaceBinding
            ),
            images: [],
            delegatedProfile: delegatedProfile,
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

    private func applyDispatchModel(_ modelID: String?, to runtime: AgentRuntime) {
        guard let modelID,
              agentModelIsCompatibleWithActiveProvider(modelID) else {
            runtime.sessionModelOverride = nil
            return
        }
        runtime.managedRouting = nil
        runtime.sessionModelOverride = modelID
        recordFetchedAgentModels([modelID])
    }

    private func selectedDispatchCLIProfile(
        goal: AgentDispatchGoal,
        executor: AgentExecutionAgent
    ) -> LocalAgentCLIProfile? {
        guard let profileID = goal.selectedCLIProfileID(for: executor) else {
            return nil
        }
        return LocalAgentCLIProfile.discover(
            workspacePath: goal.logicalProject?.primaryWorkspacePath
        ).first {
            $0.id == profileID && $0.executor == executor
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
        task: AgentDispatchTask,
        workspaceBinding: AgentDispatchWorkspaceBinding
    ) -> String {
        let criteria = task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
        let project = goal.logicalProject
        return """
        Goal: \(goal.statement)

        Assigned task: \(task.title)
        Suggested branch: \(task.branchName)
        Logical project: \(project?.displayName ?? "Unbound")
        Project root: \(project?.primaryWorkspacePath ?? "Unbound")
        Assigned checkout: \(workspaceBinding.location.path)

        Acceptance criteria:
        \(criteria)

        Work only inside the assigned checkout. It is a checkout of the fixed logical project above; do not switch this Task to another repository. Preserve unrelated changes. Before reporting completion, provide concrete evidence such as tests, build output, or a focused diff summary. Do not merge into a shared branch; WillDeep owns review and integration.
        """
    }
}
