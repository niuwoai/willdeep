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
    /// Pet/system-notification navigation follows the session's product
    /// scope. Dispatch child runtimes return to their owning project graph
    /// instead of dropping the user into a chat transcript.
    func revealAgentSessionFromNotification(id sessionID: UUID) {
        guard let session = agentSessions.first(where: { $0.id == sessionID }) else {
            _ = selectAgentSession(id: sessionID)
            return
        }
        if let projectID = session.dispatchParentProjectID,
           agentDispatchCoordinator.goals.contains(where: { $0.id == projectID }) {
            selectDispatchGoal(projectID)
            return
        }
        _ = selectAgentSession(id: sessionID)
        if session.presentationScope == .dispatchBoard {
            if agentDispatchCoordinator.goals.contains(where: { $0.id == sessionID }) {
                agentDispatchCoordinator.selectGoal(sessionID)
            }
            agentPrimaryDestination = .dispatchBoard
        }
    }

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
        let normalizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let location = WorkspaceLocation.local(path: normalizedPath)
        agentDispatchCoordinator.synchronize(with: agentSessions)

        if let existingGoal = agentDispatchCoordinator.activeGoal(for: location),
           let existingSession = agentSessions.first(where: { $0.id == existingGoal.sessionID }) {
            selectDispatchGoal(existingGoal.id)
            return existingSession
        }

        if let existingDraft = agentSessions.first(where: { session in
            guard !session.isArchived,
                  session.presentationScope == .dispatchBoard,
                  session.dispatchParentProjectID == nil,
                  session.currentGoal == nil,
                  let draftLocation = session.workspaceLocation
                    ?? session.workspaceRootPath.map({ .local(path: $0) }) else {
                return false
            }
            return Self.dispatchLocationsRepresentSameProject(draftLocation, location)
        }) {
            _ = selectAgentSession(id: existingDraft.id)
            agentPrimaryDestination = .dispatchBoard
            return existingDraft
        }

        let session = startNewAgentSession(inWorkspaceAt: normalizedPath)
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

    private static func dispatchLocationsRepresentSameProject(
        _ lhs: WorkspaceLocation,
        _ rhs: WorkspaceLocation
    ) -> Bool {
        switch (lhs, rhs) {
        case (.remote, .remote):
            return lhs == rhs
        case (.local, .local):
            return AgentDispatchLogicalProjectResolver.representsSameProject(
                AgentDispatchLogicalProjectResolver.resolve(location: lhs),
                AgentDispatchLogicalProjectResolver.resolve(location: rhs)
            )
        default:
            return false
        }
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

    func updateDispatchPlanningProfiles(
        primaryProfileID: String,
        fallbackProfileIDs: [String],
        goalID: UUID
    ) {
        agentDispatchCoordinator.updatePlanningProfiles(
            primaryProfileID: primaryProfileID,
            fallbackProfileIDs: fallbackProfileIDs,
            goalID: goalID
        )
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let runtime = runtime(for: goal.sessionID) else {
            return
        }
        var sourceGoal = runtime.currentGoal ?? AgentGoal()
        sourceGoal.planningProfileID = primaryProfileID
        sourceGoal.planningFallbackProfileIDs = fallbackProfileIDs
        sourceGoal.planningAttemptedProfileIDs = nil
        runtime.currentGoal = sourceGoal
        if let profile = dispatchExecutionProfiles(for: goal).first(where: {
            $0.id == primaryProfileID && $0.executor == .willDeep
        }) {
            applyDispatchModel(profile.modelID, to: runtime)
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    func updateDispatchWorkerProfiles(_ profileIDs: [String], goalID: UUID) {
        agentDispatchCoordinator.updateWorkerProfiles(profileIDs, goalID: goalID)
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let runtime = runtime(for: goal.sessionID) else {
            return
        }
        var sourceGoal = runtime.currentGoal ?? AgentGoal()
        sourceGoal.selectedWorkerProfileIDs = profileIDs
        runtime.currentGoal = sourceGoal
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    func updateDispatchTaskProfiles(
        primaryProfileID: String?,
        fallbackProfileIDs: [String],
        goalID: UUID,
        taskID: UUID
    ) {
        agentDispatchCoordinator.updateTaskProfiles(
            primaryProfileID: primaryProfileID,
            fallbackProfileIDs: fallbackProfileIDs,
            goalID: goalID,
            taskID: taskID
        )
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID }),
              let runtimeID = task.runtimeSessionID,
              let taskRuntime = runtime(for: runtimeID),
              let profile = dispatchExecutionProfiles(for: goal).first(where: {
                  $0.id == primaryProfileID
              }) else {
            return
        }
        taskRuntime.executionAgent = profile.executor
        if profile.executor == .willDeep {
            taskRuntime.sessionProviderIDOverride = profile.providerID
            applyDispatchModel(profile.modelID, to: taskRuntime)
        } else {
            taskRuntime.sessionProviderIDOverride = nil
            taskRuntime.sessionModelOverride = nil
        }
        persistAgentSession(runtime: taskRuntime, touchUpdatedAt: false, moveToFront: false)
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
        guard goal.hasExecutablePlan else {
            return .blocked(message: L10n.Dispatch.planNotReady)
        }
        if let conflict = agentDispatchCoordinator.conflictingActiveGoal(for: goalID) {
            return .blocked(
                message: L10n.Dispatch.projectAlreadyRunning(
                    conflict.statement.isEmpty ? conflict.title : conflict.statement
                )
            )
        }
        guard goal.isWorkspaceBound else {
            return .blocked(message: L10n.Dispatch.workspaceRequired)
        }
        guard task.state == .queued
                || task.state == .reviewing
                || task.state == .failed
                || task.state == .cancelled else {
            return .blocked(message: L10n.Dispatch.waitingForDependencies)
        }

        guard let workspaceBinding = goal.resolvedWorkspaceBinding(for: task) else {
            return .blocked(message: L10n.Dispatch.workspaceMappingRequired)
        }
        let target = workspaceBinding.targetChoice
        let available = availableDispatchExecutors(on: target)
        let profiles = dispatchExecutionProfiles(for: goal)
        let selectedWorkerIDs = goal.effectiveWorkerProfileIDs
        let selectedWorkerSet = Set(selectedWorkerIDs)
        let taskPrimary = task.primaryProfileID.flatMap {
            selectedWorkerSet.contains($0) ? $0 : nil
        }
        let taskFallbacks = (task.fallbackProfileIDs ?? []).filter(selectedWorkerSet.contains)
        let busyProfileIDs = Set(goal.tasks.compactMap { candidate -> String? in
            guard candidate.id != task.id,
                  candidate.state == .running || candidate.state == .reviewing else {
                return nil
            }
            return candidate.activeProfileID
        })
        let profile = AgentDispatchProfileResolver.next(
            primaryProfileID: taskPrimary,
            fallbackProfileIDs: taskFallbacks,
            selectedWorkerProfileIDs: selectedWorkerIDs,
            attemptedProfileIDs: task.attemptedProfileIDs ?? [],
            busyProfileIDs: busyProfileIDs,
            availableExecutors: available,
            profiles: profiles
        )
        let hasProfilePolicy = !selectedWorkerIDs.isEmpty
        if task.executorChoice == .automatic, hasProfilePolicy, profile == nil {
            return .blocked(message: L10n.Dispatch.noProfileAvailable)
        }
        let workspaceLocation: WorkspaceLocation
        switch isolatedDispatchWorkspaceLocation(
            task: task,
            source: workspaceBinding.location
        ) {
        case .success(let isolatedLocation):
            workspaceLocation = isolatedLocation
        case .failure(let message):
            return .blocked(message: message)
        }
        let executorChoice = task.executorChoice == .automatic
            ? goal.executorChoice
            : task.executorChoice
        let decision: AgentDispatchExecutorDecision
        if task.executorChoice == .automatic, let profile {
            decision = AgentDispatchExecutorDecision(
                executor: profile.executor,
                reason: .userPinned,
                isAvailable: available.contains(profile.executor)
            )
        } else {
            decision = AgentDispatchExecutorResolver.resolve(
                title: task.title,
                choice: executorChoice,
                availableExecutors: available
            )
        }
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
        runtime.currentPlan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: task.title, status: .inProgress)],
            summary: L10n.Dispatch.executionRunning
        )
        runtime.executionAgent = decision.executor
        if decision.executor == .willDeep {
            runtime.sessionProviderIDOverride = profile?.providerID
            applyDispatchModel(
                profile?.modelID ?? goal.effectiveModelRouting.executionModelID,
                to: runtime
            )
        }
        persistAgentSession(runtime: runtime)

        agentDispatchCoordinator.markTaskStarted(
            goalID: goalID,
            taskID: taskID,
            executor: decision.executor,
            profileID: profile?.id,
            target: target,
            runtimeSessionID: runtime.id
        )

        let delegatedProfile = profile?.delegatedProfile
            ?? selectedDispatchCLIProfile(goal: goal, executor: decision.executor)
        dispatchAgentMessageUsingSelectedExecutor(
            decision.executor,
            for: runtime,
            text: Self.dispatchTaskPrompt(
                goal: goal,
                task: task,
                workspaceLocation: workspaceLocation
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

    @discardableResult
    func launchReadyDispatchTasks(goalID: UUID) -> [AgentDispatchLaunchResult] {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              !goal.isPaused else {
            return [.blocked(message: L10n.Dispatch.goalPausedLaunch)]
        }
        guard goal.hasExecutablePlan else {
            return [.blocked(message: L10n.Dispatch.planNotReady)]
        }
        let capacity = max(1, goal.effectiveWorkerProfileIDs.count)
        let availableSlots = max(0, capacity - goal.activeTaskCount)
        guard availableSlots > 0 else { return [] }
        let readyTaskIDs = goal.tasks
            .filter { $0.state == .queued }
            .prefix(availableSlots)
            .map(\.id)
        return readyTaskIDs.map {
            launchDispatchTask(goalID: goalID, taskID: $0)
        }
    }

    /// Reattaches task completion monitoring after the app or dispatch board
    /// is reopened. Child runtimes are durable, so their final goal state must
    /// be reconciled before the coordinator can unlock downstream nodes.
    func resumeDispatchGoal(goalID: UUID) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              !goal.isPaused else {
            return
        }
        for task in goal.tasks where task.state == .running || task.state == .reviewing {
            guard let runtimeSessionID = task.runtimeSessionID,
                  let taskRuntime = runtime(for: runtimeSessionID) else {
                continue
            }
            monitorDispatchTaskRuntime(
                taskRuntime,
                goalID: goalID,
                taskID: task.id
            )
        }
        if goal.activeTaskCount == 0 {
            _ = launchReadyDispatchTasks(goalID: goalID)
        }
    }

    func openDispatchTaskConversation(runtimeSessionID: UUID) {
        guard selectAgentSession(id: runtimeSessionID) else { return }
        agentPrimaryDestination = .conversation
    }

    @discardableResult
    func prepareDispatchTaskTakeover(runtimeSessionID: UUID) -> Bool {
        selectAgentSession(
            id: runtimeSessionID,
            preservingPrimaryDestination: true
        )
    }

    func openDispatchProject(goalID: UUID, taskID: UUID?) {
        agentDispatchCoordinator.selectGoal(goalID)
        if let taskID {
            agentDispatchCoordinator.selectTask(taskID)
        }
        agentPrimaryDestination = .dispatchBoard
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

    private enum DispatchWorkspaceResolution {
        case success(WorkspaceLocation)
        case failure(String)
    }

    private func isolatedDispatchWorkspaceLocation(
        task: AgentDispatchTask,
        source: WorkspaceLocation
    ) -> DispatchWorkspaceResolution {
        guard case .local(let sourcePath) = source else {
            return .success(source)
        }
        if let previousRuntimeID = task.runtimeSessionID,
           let previousRuntime = runtime(for: previousRuntimeID),
           case .local(let previousPath)? = previousRuntime.workspaceLocation,
           FileManager.default.fileExists(atPath: previousPath) {
            return .success(.local(path: previousPath))
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        guard Self.findGitRepositoryRoot(startingAt: sourceURL) != nil else {
            return .success(source)
        }
        let branchName = "\(task.branchName)-\(task.id.uuidString.prefix(8).lowercased())"
        switch Self.createGitWorktree(from: sourceURL, branchName: branchName) {
        case .success(let created):
            return .success(.local(path: created.worktree.path))
        case .failure(let failure):
            return .failure(failure.message)
        }
    }

    private func monitorDispatchTaskRuntime(
        _ runtime: AgentRuntime,
        goalID: UUID,
        taskID: UUID
    ) {
        guard dispatchMonitoredRuntimeIDsByTaskID[taskID] != runtime.id else {
            return
        }
        dispatchMonitoredRuntimeIDsByTaskID[taskID] = runtime.id
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer {
                if self.dispatchMonitoredRuntimeIDsByTaskID[taskID] == runtime.id {
                    self.dispatchMonitoredRuntimeIDsByTaskID[taskID] = nil
                }
            }
            while runtime.isResponding || runtime.isAwaitingProviderSlot {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
            }
            let hasCompletedAcceptance = runtime.currentGoal.map {
                !$0.checklist.isEmpty && $0.checklist.allSatisfy(\.done)
            } ?? false
            let state: AgentDispatchTaskState
            if runtime.errorMessage != nil {
                state = .failed
            } else if hasCompletedAcceptance {
                state = .merged
            } else {
                state = .reviewing
            }
            self.agentDispatchCoordinator.updateTaskState(
                goalID: goalID,
                taskID: taskID,
                state: state
            )
            if state == .failed,
               let refreshedGoal = self.agentDispatchCoordinator.goals.first(where: {
                   $0.id == goalID
               }),
               let refreshedTask = refreshedGoal.tasks.first(where: {
                   $0.id == taskID
               }),
               refreshedTask.executorChoice == .automatic,
               AgentDispatchProfileResolver.hasUntriedFallback(
                   fallbackProfileIDs: refreshedTask.fallbackProfileIDs ?? [],
                   selectedWorkerProfileIDs: refreshedGoal.effectiveWorkerProfileIDs,
                   attemptedProfileIDs: refreshedTask.attemptedProfileIDs ?? []
               ) {
                _ = self.launchDispatchTask(goalID: goalID, taskID: taskID)
            } else if state == .merged {
                _ = self.launchReadyDispatchTasks(goalID: goalID)
            }
        }
    }

    private func applyDispatchModel(_ modelID: String?, to runtime: AgentRuntime) {
        guard let modelID else {
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

    private func dispatchExecutionProfiles(
        for goal: AgentDispatchGoal
    ) -> [AgentExecutionProfile] {
        AgentExecutionProfileStore().availableProfiles(
            workspacePath: goal.logicalProject?.primaryWorkspacePath
        )
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
        workspaceLocation: WorkspaceLocation
    ) -> String {
        let criteria = task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
        let project = goal.logicalProject
        return """
        Goal: \(goal.statement)

        Assigned task: \(task.title)
        Suggested branch: \(task.branchName)
        Logical project: \(project?.displayName ?? "Unbound")
        Project root: \(project?.primaryWorkspacePath ?? "Unbound")
        Assigned checkout: \(workspaceLocation.path)

        Acceptance criteria:
        \(criteria)

        Execute this node directly as an unattended run. Do not create another Goal, dispatch graph, or team of agents. Work only inside the assigned checkout. It is a checkout of the fixed logical project above; do not switch this Task to another repository. Preserve unrelated changes. Diagnose and recover from ordinary Git/worktree, dependency, build, test, path, and transient tool failures yourself; prefer safe reversible repairs and retry before stopping. Do not ask the user for confirmation or implementation preferences: no operator is attached to this task conversation. If missing credentials, private interactive control, or an unavoidable product decision makes completion impossible, report a concrete blocked reason to the scheduler instead of opening an approval or question card. Before reporting completion, provide concrete evidence such as tests, build output, or a focused diff summary. Do not merge into a shared branch; WillDeep owns review and integration.

        In the final response, update the visible execution step with a closed `progress` block and evaluate every acceptance criterion with a closed `goal-check` block. Mark an item done only when the evidence actually proves it.
        """
    }
}
