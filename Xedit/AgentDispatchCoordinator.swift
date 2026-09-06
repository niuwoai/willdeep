//
//  AgentDispatchCoordinator.swift
//  WillDeep
//
//  Deterministic state owner for the dispatch console. It projects existing
//  Goal sessions into durable dispatch records and never calls an LLM itself.
//

import Foundation
import Combine

final class AgentDispatchCoordinator: ObservableObject {
    @Published private(set) var goals: [AgentDispatchGoal]
    @Published var selectedGoalID: UUID?
    @Published var selectedTaskID: UUID?

    private let store: AgentDispatchStore
    private var backgroundSynchronizationRevision = 0

    init(store: AgentDispatchStore = AgentDispatchStore()) {
        self.store = store
        self.goals = store.load()
        self.selectedGoalID = goals.first?.id
        self.selectedTaskID = goals.first?.tasks.first?.id
    }

    var selectedGoal: AgentDispatchGoal? {
        guard let selectedGoalID else { return goals.first }
        return goals.first { $0.id == selectedGoalID } ?? goals.first
    }

    var selectedTask: AgentDispatchTask? {
        guard let selectedGoal else { return nil }
        guard let selectedTaskID else { return selectedGoal.tasks.first }
        return selectedGoal.tasks.first { $0.id == selectedTaskID } ?? selectedGoal.tasks.first
    }

    /// `sessions` must be the COMPLETE session catalog. The projection drops
    /// any persisted goal whose backing session is absent and persists the
    /// result immediately, so a partial list destroys recorded task states.
    /// AppState callers go through `synchronizeDispatchBoard()`, which
    /// refuses to project until the async catalog load has finished.
    func synchronize(with sessions: [AgentSession], projects: [AgentProject] = []) {
        backgroundSynchronizationRevision += 1
        applySynchronizedGoals(
            Self.synchronizedGoals(
                from: sessions,
                projects: projects,
                existingGoals: goals,
                defaultAcceptanceCriterion: L10n.Dispatch.defaultAcceptanceCriterion
            )
        )
    }

    /// Projects repository-backed session metadata away from the main actor.
    /// Rapid SwiftUI `onReceive` updates are coalesced by revision so an older
    /// projection can never overwrite a newer one.
    func synchronizeInBackground(with sessions: [AgentSession], projects: [AgentProject] = []) {
        backgroundSynchronizationRevision += 1
        let revision = backgroundSynchronizationRevision
        let existingGoals = goals
        let defaultAcceptanceCriterion = L10n.Dispatch.defaultAcceptanceCriterion

        Task.detached(priority: .utility) {
            let synchronizedGoals = Self.synchronizedGoals(
                from: sessions,
                projects: projects,
                existingGoals: existingGoals,
                defaultAcceptanceCriterion: defaultAcceptanceCriterion
            )
            await MainActor.run { [weak self] in
                guard let self,
                      self.backgroundSynchronizationRevision == revision,
                      self.goals == existingGoals else {
                    return
                }
                self.applySynchronizedGoals(synchronizedGoals)
            }
        }
    }

    /// 一个会话够不够格在调度台里当「项目」。
    ///
    /// 只收编真正在调度台里开出来的会话：光有 goal 不算数——普通聊天从
    /// composer 就能进 Goal 模式，把它们也填进来会造出用户从没创建过的项目。
    /// 子任务会话由 `dispatchParentProjectID` 认领；`persistedTaskSessionIDs`
    /// 兜住老版本留下的重复项目。
    nonisolated static func isBoardProject(
        session: AgentSession,
        persistedTaskSessionIDs: Set<UUID>
    ) -> Bool {
        guard session.presentationScope == .dispatchBoard else { return false }
        // Goal-board projection does not remove the source conversation
        // from its workspace sidebar; it is an additional task view.
        guard session.hasBoardGoal else { return false }
        return session.dispatchParentProjectID == nil
            && !persistedTaskSessionIDs.contains(session.id)
    }

    /// 目录不完整时也能安全跑的一遍收敛：只清掉「目录里确实有这个会话、但它
    /// 已经不再是调度台项目」的行——典型是它后来变成了别的目标的子任务，或者
    /// 压根就是普通聊天被老版本收编进来的。
    ///
    /// 会话不在传入列表里的一律保留。这正是完整投影必须等目录装载完成的原因
    /// （见 `synchronize(with:)` 的注释）：启动期的空列表会把已完成节点整片抹掉。
    /// 按「在场才判决」这条规则重写之后，收敛不再依赖目录是否权威，于是那些
    /// 早就不该留着的行不用再等一个可能永远不来的完整投影。
    nonisolated static func reconciledGoals(
        existingGoals: [AgentDispatchGoal],
        sessions: [AgentSession]
    ) -> [AgentDispatchGoal] {
        guard !sessions.isEmpty else { return existingGoals }
        let persistedTaskSessionIDs = Set(
            existingGoals.flatMap { $0.tasks.compactMap(\.runtimeSessionID) }
        )
        let sessionsByID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return existingGoals.filter { goal in
            guard let session = sessionsByID[goal.id] else { return true }
            return isBoardProject(session: session, persistedTaskSessionIDs: persistedTaskSessionIDs)
        }
    }

    /// 目录还没装载完时的收敛入口。只做删除、不做重建，所以拿到半份目录也
    /// 不会伤到任何已记录的任务状态；没有变化就不写盘。
    func reconcileWithLoadedSessions(_ sessions: [AgentSession]) {
        let reconciled = Self.reconciledGoals(existingGoals: goals, sessions: sessions)
        guard reconciled.count != goals.count else { return }
        applySynchronizedGoals(reconciled)
    }

    private nonisolated static func synchronizedGoals(
        from sessions: [AgentSession],
        projects: [AgentProject],
        existingGoals: [AgentDispatchGoal],
        defaultAcceptanceCriterion: String
    ) -> [AgentDispatchGoal] {
        let persistedTaskSessionIDs = Set(
            existingGoals.flatMap { $0.tasks.compactMap(\.runtimeSessionID) }
        )
        let sourceSessions = sessions.filter { session in
            isBoardProject(session: session, persistedTaskSessionIDs: persistedTaskSessionIDs)
        }
        let existingByID = Dictionary(uniqueKeysWithValues: existingGoals.map { ($0.id, $0) })
        let projected = sourceSessions.map { session in
            Self.project(
                session: session,
                managedProject: projects.first { $0.id == session.projectID },
                existing: existingByID[session.id],
                defaultAcceptanceCriterion: defaultAcceptanceCriterion
            )
        }
        var ordered = projected.sorted { lhs, rhs in
            if lhs.activeTaskCount != rhs.activeTaskCount {
                return lhs.activeTaskCount > rhs.activeTaskCount
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        // Older builds could persist more than one unfinished project for the
        // same logical workspace. Keep the strongest/most-recent owner active
        // and pause the rest during projection so restore cannot reintroduce
        // an ambiguous project-level owner.
        var activeOwners: [AgentDispatchGoal] = []
        for index in ordered.indices where ordered[index].isOperationallyActive {
            if activeOwners.contains(where: {
                Self.goalsRepresentSameProject($0, ordered[index])
            }) {
                ordered[index].isPaused = true
            } else {
                activeOwners.append(ordered[index])
            }
        }
        return ordered
    }

    private nonisolated static func goalsRepresentSameProject(
        _ lhs: AgentDispatchGoal,
        _ rhs: AgentDispatchGoal
    ) -> Bool {
        guard let lhsProject = lhs.logicalProject,
              let rhsProject = rhs.logicalProject else {
            return false
        }
        if case (.some(.remote(_, _)), .some(.remote(_, _))) =
            (lhs.workspaceLocation, rhs.workspaceLocation) {
            return lhs.workspaceLocation == rhs.workspaceLocation
        }
        return AgentDispatchLogicalProjectResolver.representsSameProject(
            lhsProject,
            rhsProject
        )
    }

    private func applySynchronizedGoals(_ synchronizedGoals: [AgentDispatchGoal]) {
        goals = synchronizedGoals
        if selectedGoalID.flatMap({ id in goals.first(where: { $0.id == id }) }) == nil {
            selectedGoalID = goals.first?.id
        }
        reconcileSelectedTask()
        persist()
    }

    func selectGoal(_ id: UUID) {
        guard goals.contains(where: { $0.id == id }) else { return }
        selectedGoalID = id
        selectedTaskID = goals.first(where: { $0.id == id })?.tasks.first?.id
    }

    func selectTask(_ id: UUID) {
        guard let goal = selectedGoal, goal.tasks.contains(where: { $0.id == id }) else { return }
        selectedTaskID = id
    }

    /// Returns the unfinished, non-paused dispatch project that currently
    /// owns a logical project/workspace. Local Git worktrees collapse through
    /// their shared `--git-common-dir`; non-Git folders use standardized paths.
    func activeGoal(
        for location: WorkspaceLocation,
        excluding excludedGoalID: UUID? = nil
    ) -> AgentDispatchGoal? {
        let candidateProject = AgentDispatchLogicalProjectResolver.resolve(location: location)
        return goals.first { goal in
            guard goal.id != excludedGoalID,
                  goal.isOperationallyActive,
                  let project = goal.logicalProject else {
                return false
            }
            if case .remote = location {
                return goal.workspaceLocation == location
            }
            return AgentDispatchLogicalProjectResolver.representsSameProject(
                project,
                candidateProject
            )
        }
    }

    func conflictingActiveGoal(for goalID: UUID) -> AgentDispatchGoal? {
        guard let goal = goals.first(where: { $0.id == goalID }),
              let location = goal.workspaceLocation else {
            return nil
        }
        return activeGoal(for: location, excluding: goalID)
    }

    @discardableResult
    func removeGoal(id: UUID) -> AgentDispatchGoal? {
        guard let index = goals.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = goals.remove(at: index)
        if selectedGoalID == id {
            selectedGoalID = goals.indices.contains(index)
                ? goals[index].id
                : goals.last?.id
            selectedTaskID = selectedGoal?.tasks.first?.id
        } else {
            reconcileSelectedTask()
        }
        persist()
        return removed
    }

    func updateGoalExecutorChoice(_ choice: AgentDispatchExecutorChoice, goalID: UUID) {
        updateGoal(id: goalID) { goal in
            goal.executorChoice = choice
            goal.updatedAt = Date()
        }
    }

    func updateGoalTargetChoice(_ choice: AgentDispatchTargetChoice, goalID: UUID) {
        updateGoal(id: goalID) { goal in
            guard choice == .automatic || goal.workspaceLocation(for: choice) != nil else {
                return
            }
            goal.targetChoice = choice
            goal.updatedAt = Date()
        }
    }

    func updateGoalModelRouting(
        _ routing: AgentDispatchModelRouting,
        goalID: UUID
    ) {
        updateGoal(id: goalID) { goal in
            goal.modelRouting = routing
            goal.updatedAt = Date()
        }
    }

    func updateGoalCLIProfile(
        _ profileID: String?,
        executor: AgentExecutionAgent,
        goalID: UUID
    ) {
        updateGoal(id: goalID) { goal in
            var selections = goal.cliProfileSelections ?? [:]
            if let profileID, !profileID.isEmpty {
                selections[executor.rawValue] = profileID
            } else {
                selections.removeValue(forKey: executor.rawValue)
            }
            goal.cliProfileSelections = selections.isEmpty ? nil : selections
            goal.updatedAt = Date()
        }
    }

    func updateTaskExecutorChoice(
        _ choice: AgentDispatchExecutorChoice,
        goalID: UUID,
        taskID: UUID
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.executorChoice = choice
            task.updatedAt = Date()
        }
    }

    func updateTaskProfiles(
        primaryProfileID: String?,
        fallbackProfileIDs: [String],
        goalID: UUID,
        taskID: UUID
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.primaryProfileID = primaryProfileID
            task.fallbackProfileIDs = Self.uniqueStrings(
                fallbackProfileIDs.filter { $0 != primaryProfileID }
            )
            task.attemptedProfileIDs = nil
            task.activeProfileID = nil
            task.updatedAt = Date()
        }
    }

    func updatePlanningProfiles(
        primaryProfileID: String,
        fallbackProfileIDs: [String],
        goalID: UUID
    ) {
        updateGoal(id: goalID) { goal in
            goal.planningProfileID = primaryProfileID
            goal.planningFallbackProfileIDs = AgentDispatchPlannerSelection
                .normalizedFallbackProfileIDs(
                    primaryProfileID: primaryProfileID,
                    fallbackProfileIDs: fallbackProfileIDs
                )
            goal.updatedAt = Date()
        }
    }

    func updateWorkerProfiles(_ profileIDs: [String], goalID: UUID) {
        let normalized = Self.uniqueStrings(profileIDs)
        guard !normalized.isEmpty else { return }
        updateGoal(id: goalID) { goal in
            goal.selectedWorkerProfileIDs = normalized
            goal.updatedAt = Date()
        }
    }

    func updateTaskTargetChoice(
        _ choice: AgentDispatchTargetChoice,
        goalID: UUID,
        taskID: UUID
    ) {
        guard let goal = goals.first(where: { $0.id == goalID }),
              choice == .automatic || goal.workspaceLocation(for: choice) != nil else {
            return
        }
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.targetChoice = choice
            task.workspaceBindingID = nil
            task.updatedAt = Date()
        }
    }

    func updateTaskWorkspaceBinding(
        _ bindingID: String?,
        goalID: UUID,
        taskID: UUID
    ) {
        guard let goal = goals.first(where: { $0.id == goalID }) else { return }
        let binding = goal.workspaceBinding(id: bindingID)
        guard bindingID == nil || binding != nil else { return }
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.workspaceBindingID = binding?.id
            task.targetChoice = binding?.targetChoice ?? .automatic
            task.updatedAt = Date()
        }
    }

    func bindWorkspace(
        _ location: WorkspaceLocation,
        logicalProject: AgentDispatchLogicalProject,
        goalID: UUID,
        makePrimary: Bool
    ) {
        updateGoal(id: goalID) { goal in
            if makePrimary || goal.logicalProject == nil {
                goal.logicalProject = logicalProject
            }
            guard let boundProject = goal.logicalProject else { return }
            var bindings = goal.effectiveWorkspaceBindings
            let binding = AgentDispatchWorkspaceBinding(
                location: location,
                projectID: boundProject.id
            )
            if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
                bindings[index] = binding
            } else {
                bindings.append(binding)
            }
            if makePrimary || goal.workspaceLocation == nil {
                goal.workspaceLocation = location
            }
            goal.workspaceBindings = bindings
            if goal.targetChoice != .automatic,
               goal.workspaceLocation(for: goal.targetChoice) == nil {
                goal.targetChoice = .automatic
            }
            for index in goal.tasks.indices {
                let choice = goal.tasks[index].targetChoice
                if choice != .automatic, goal.workspaceLocation(for: choice) == nil {
                    goal.tasks[index].targetChoice = .automatic
                }
                if let bindingID = goal.tasks[index].workspaceBindingID,
                   !bindings.contains(where: { $0.id == bindingID }) {
                    goal.tasks[index].workspaceBindingID = nil
                }
            }
            goal.updatedAt = Date()
        }
    }

    @discardableResult
    func recordCommand(
        goalID: UUID,
        text: String,
        effect: AgentDispatchCommandEffect
    ) -> AgentDispatchCommand {
        let status: AgentDispatchCommandStatus = switch effect {
        case .appliedImmediately: .applied
        case .queuedForSafePoint: .queued
        case .requiresInterruptConfirmation: .pendingConfirmation
        }
        let command = AgentDispatchCommand(text: text, effect: effect, status: status)
        updateGoal(id: goalID) { goal in
            goal.commands.insert(command, at: 0)
            if goal.commands.count > 100 {
                goal.commands.removeLast(goal.commands.count - 100)
            }
            goal.updatedAt = Date()
        }
        return command
    }

    func resolveCommand(goalID: UUID, commandID: UUID, interrupted: Bool) {
        updateGoal(id: goalID) { goal in
            guard let index = goal.commands.firstIndex(where: { $0.id == commandID }) else { return }
            goal.commands[index].effect = interrupted
                ? .queuedForSafePoint
                : .requiresInterruptConfirmation
            goal.commands[index].status = interrupted ? .queued : .cancelled
            goal.updatedAt = Date()
        }
    }

    func cancelCommand(goalID: UUID, commandID: UUID) {
        updateGoal(id: goalID) { goal in
            guard let index = goal.commands.firstIndex(where: { $0.id == commandID }) else { return }
            goal.commands[index].status = .cancelled
            goal.updatedAt = Date()
        }
    }

    @discardableResult
    func setPaused(_ paused: Bool, goalID: UUID) -> Bool {
        if !paused, conflictingActiveGoal(for: goalID) != nil {
            return false
        }
        guard goals.contains(where: { $0.id == goalID }) else { return false }
        updateGoal(id: goalID) { goal in
            goal.isPaused = paused
            goal.updatedAt = Date()
        }
        return true
    }

    @discardableResult
    func appendTask(
        title: String,
        goalID: UUID,
        dependencyIDs requestedDependencyIDs: [UUID]? = nil,
        acceptanceCriteria requestedAcceptanceCriteria: [String]? = nil
    ) -> AgentDispatchTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var appended: AgentDispatchTask?
        updateGoal(id: goalID) { goal in
            let validTaskIDs = Set(goal.tasks.map(\.id))
            let dependencies = requestedDependencyIDs.map {
                Self.uniqueIDs($0.filter(validTaskIDs.contains))
            }
                ?? []
            let criteria = requestedAcceptanceCriteria?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                ?? []
            let task = AgentDispatchTask(
                title: trimmed,
                state: dependencies.allSatisfy { dependencyID in
                    goal.tasks.first(where: { $0.id == dependencyID })?.state == .merged
                } ? .queued : .blocked,
                dependencyIDs: dependencies,
                branchName: Self.branchName(for: trimmed),
                acceptanceCriteria: criteria.isEmpty
                    ? [L10n.Dispatch.defaultAcceptanceCriterion]
                    : criteria
            )
            goal.tasks.append(task)
            goal.updatedAt = Date()
            appended = task
        }
        if let appended {
            selectedTaskID = appended.id
        }
        return appended
    }

    @discardableResult
    func updateTaskDefinition(
        goalID: UUID,
        taskID: UUID,
        title: String,
        dependencyIDs requestedDependencyIDs: [UUID],
        acceptanceCriteria requestedAcceptanceCriteria: [String]
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let goal = goals.first(where: { $0.id == goalID }),
              let existingTask = goal.tasks.first(where: { $0.id == taskID }),
              existingTask.pendingDecisionIDs?.isEmpty != false,
              existingTask.state != .running,
              existingTask.state != .reviewing else {
            return false
        }

        let validTaskIDs = Set(goal.tasks.map(\.id)).subtracting([taskID])
        let dependencyIDs = Self.uniqueIDs(
            requestedDependencyIDs.filter(validTaskIDs.contains)
        )
        guard !Self.dependenciesCreateCycle(
            taskID: taskID,
            dependencyIDs: dependencyIDs,
            tasks: goal.tasks
        ) else {
            return false
        }

        let criteria = requestedAcceptanceCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedIDs = Set(goal.tasks.filter { $0.state == .merged }.map(\.id))
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.title = trimmedTitle
            task.dependencyIDs = dependencyIDs
            task.acceptanceCriteria = criteria.isEmpty
                ? [L10n.Dispatch.defaultAcceptanceCriterion]
                : criteria
            task.branchName = Self.branchName(for: trimmedTitle)
            if task.state == .blocked || task.state == .queued {
                task.state = Set(dependencyIDs).isSubset(of: mergedIDs) ? .queued : .blocked
            }
            task.updatedAt = Date()
        }
        return true
    }

    /// Human intervention may clarify what a node should deliver and how it
    /// is accepted, but it must not rewrite the scheduler-owned graph topology.
    @discardableResult
    func updateTaskOutcome(
        goalID: UUID,
        taskID: UUID,
        title: String,
        acceptanceCriteria requestedAcceptanceCriteria: [String]
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let goal = goals.first(where: { $0.id == goalID }),
              let existingTask = goal.tasks.first(where: { $0.id == taskID }),
              existingTask.state != .running,
              existingTask.state != .reviewing else {
            return false
        }

        let criteria = requestedAcceptanceCriteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.title = trimmedTitle
            task.acceptanceCriteria = criteria.isEmpty
                ? [L10n.Dispatch.defaultAcceptanceCriterion]
                : criteria
            task.branchName = Self.branchName(for: trimmedTitle)
            task.updatedAt = Date()
        }
        return true
    }

    func markTaskStarted(
        goalID: UUID,
        taskID: UUID,
        executor: AgentExecutionAgent,
        profileID: String? = nil,
        target: AgentDispatchTargetChoice,
        runtimeSessionID: UUID
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.state = .running
            task.resolvedExecutor = executor
            task.activeProfileID = profileID
            if let profileID {
                var attempted = task.attemptedProfileIDs ?? []
                if !attempted.contains(profileID) {
                    attempted.append(profileID)
                }
                task.attemptedProfileIDs = attempted
            }
            task.resolvedTarget = target
            if task.runtimeSessionID != runtimeSessionID {
                task.operatorAcceptedAt = nil
            }
            task.runtimeSessionID = runtimeSessionID
            var runtimeSessionIDs = task.runtimeSessionIDs ?? []
            if !runtimeSessionIDs.contains(runtimeSessionID) {
                runtimeSessionIDs.append(runtimeSessionID)
            }
            task.runtimeSessionIDs = runtimeSessionIDs
            task.acceptanceRecoveryAttempts = 0
            task.updatedAt = Date()
        }
    }

    func recordTaskAcceptanceRecoveryAttempts(
        goalID: UUID,
        taskID: UUID,
        attempts: Int
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.acceptanceRecoveryAttempts = max(0, attempts)
            task.updatedAt = Date()
        }
    }

    func pinTaskInputRevision(goalID: UUID, taskID: UUID, bindingID: String, baseRevision: String, inputRevision: String) {
        updateGoal(id: goalID) { goal in
            guard let index = goal.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            var bases = goal.integrationBaseRevisions ?? [:]
            if bases[bindingID] == nil { bases[bindingID] = baseRevision }
            goal.integrationBaseRevisions = bases
            if goal.tasks[index].inputRevision == nil { goal.tasks[index].inputRevision = inputRevision }
            goal.tasks[index].updatedAt = Date()
            goal.updatedAt = Date()
        }
    }

    func updateTaskState(
        goalID: UUID,
        taskID: UUID,
        state: AgentDispatchTaskState
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            if task.pendingDecisionIDs?.isEmpty == false && state != .cancelled && state != .failed { return }
            if state == .cancelled || state == .failed { task.pendingDecisionIDs = nil }
            task.state = state
            task.updatedAt = Date()
        }
        if state == .merged {
            unlockReadyTasks(goalID: goalID)
        }
    }

    func recordOperatorAcceptance(goalID: UUID, taskID: UUID) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.operatorAcceptedAt = Date()
            task.state = .reviewing
            task.updatedAt = Date()
        }
    }

    func applyDeliveredRecord(_ record: AgentDispatchDeliveryRecord) throws {
        guard record.phase == .delivered, let receipt = record.receipt,
              let verification = record.verificationReceipt, verification.isValid,
              verification.revision == receipt.integratedRevision, verification.id == record.verificationID,
              receipt.snapshot == record.candidate.snapshot,
              let goal = goals.first(where: { $0.id == record.goalID }), !goal.isPaused,
              let task = goal.tasks.first(where: { $0.id == record.taskID }), task.runtimeSessionID == record.runtimeID,
              [.running, .reviewing, .accepted].contains(task.state) else {
            throw AgentDispatchJournalError.invalidTransition
        }
        updateTask(goalID: record.goalID, taskID: record.taskID) { task in
            task.artifactSnapshot = receipt.snapshot
            task.integrationCandidate = record.candidate
            task.integrationReceipt = receipt
            task.state = .merged
            task.updatedAt = Date()
        }
        unlockReadyTasks(goalID: record.goalID)
    }

    func resetForTests() {
        goals = []
        selectedGoalID = nil
        selectedTaskID = nil
        persist()
    }

    func updateGoal(id: UUID, change: (inout AgentDispatchGoal) -> Void) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        change(&goals[index])
        persist()
    }

    func updateTask(
        goalID: UUID,
        taskID: UUID,
        change: (inout AgentDispatchTask) -> Void
    ) {
        updateGoal(id: goalID) { goal in
            guard let index = goal.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            change(&goal.tasks[index])
            goal.updatedAt = Date()
        }
    }

    private func unlockReadyTasks(goalID: UUID) {
        updateGoal(id: goalID) { goal in
            let mergedIDs = Set(goal.tasks.filter { $0.state == .merged }.map(\.id))
            for index in goal.tasks.indices where goal.tasks[index].state == .blocked {
                if goal.tasks[index].pendingDecisionIDs?.isEmpty != false,
                   Set(goal.tasks[index].dependencyIDs).isSubset(of: mergedIDs) {
                    goal.tasks[index].state = .queued
                    goal.tasks[index].updatedAt = Date()
                }
            }
        }
    }

    private func reconcileSelectedTask() {
        guard let goal = selectedGoal else {
            selectedTaskID = nil
            return
        }
        if selectedTaskID.flatMap({ id in goal.tasks.first(where: { $0.id == id }) }) == nil {
            selectedTaskID = goal.tasks.first?.id
        }
    }

    private func persist() {
        store.save(goals)
    }

    private static func dependenciesCreateCycle(
        taskID: UUID,
        dependencyIDs: [UUID],
        tasks: [AgentDispatchTask]
    ) -> Bool {
        var dependenciesByTask = Dictionary(
            uniqueKeysWithValues: tasks.map { ($0.id, $0.dependencyIDs) }
        )
        dependenciesByTask[taskID] = dependencyIDs

        func reachesTask(_ currentID: UUID, visited: inout Set<UUID>) -> Bool {
            if currentID == taskID {
                return true
            }
            guard visited.insert(currentID).inserted else {
                return false
            }
            return dependenciesByTask[currentID, default: []].contains { dependencyID in
                reachesTask(dependencyID, visited: &visited)
            }
        }

        return dependencyIDs.contains { dependencyID in
            var visited: Set<UUID> = []
            return reachesTask(dependencyID, visited: &visited)
        }
    }

    private static func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated static func project(
        session: AgentSession,
        managedProject: AgentProject? = nil,
        existing: AgentDispatchGoal?,
        defaultAcceptanceCriterion: String
    ) -> AgentDispatchGoal {
        let sourceGoal = session.currentGoal ?? AgentGoal()
        let sourceWorkspace = session.workspaceLocation
            ?? session.workspaceRootPath.map { WorkspaceLocation.local(path: $0) }
        // Existing records intentionally do not inherit a newly available
        // session workspace. A legacy Goal that was saved without a binding
        // must remain visibly unbound until the user binds it once.
        let primaryWorkspace = existing == nil ? sourceWorkspace : existing?.workspaceLocation
        let logicalProject: AgentDispatchLogicalProject? = if let existing {
            existing.logicalProject
                ?? existing.workspaceLocation.map {
                    AgentDispatchLogicalProjectResolver.resolve(
                        location: $0,
                        preferredLocalProjectPath: session.sidebarWorkspaceRootPath,
                        managedProject: managedProject
                    )
                }
        } else {
            sourceWorkspace.map {
                AgentDispatchLogicalProjectResolver.resolve(
                    location: $0,
                    preferredLocalProjectPath: session.sidebarWorkspaceRootPath,
                    managedProject: managedProject
                )
            }
        }
        // Do not trust pre-project secondary mappings. In particular, rc3
        // SSH records may contain a runtime's generic default directory,
        // which was never explicitly confirmed as this project's checkout.
        // Preserve only mappings already tagged with this logical project;
        // the primary workspace is reinserted below and every other legacy
        // checkout must be mapped once under the new invariant.
        var workspaceBindings = (existing?.workspaceBindings ?? []).filter {
            $0.projectID == logicalProject?.id
        }
        if let primaryWorkspace, let logicalProject {
            let primaryBinding = AgentDispatchWorkspaceBinding(
                location: primaryWorkspace,
                projectID: logicalProject.id
            )
            if let index = workspaceBindings.firstIndex(where: { $0.id == primaryBinding.id }) {
                workspaceBindings[index] = primaryBinding
            } else {
                workspaceBindings.insert(primaryBinding, at: 0)
            }
        }
        // Session projection must not reset host-owned immutable inputs. Keep
        // each pin only while its exact project-owned workspace mapping still
        // exists; never transfer a removed mapping's base to another root.
        let retainedBindingIDs = Set(workspaceBindings.map(\.id))
        let integrationBaseRevisions = existing?.integrationBaseRevisions?.filter {
            retainedBindingIDs.contains($0.key)
        }
        let oldTasks = Dictionary(
            uniqueKeysWithValues: (existing?.tasks ?? []).map { ($0.id, $0) }
        )
        let plannedNodes = sourceGoal.dispatchPlan?.nodes ?? []
        let sourceTaskIDs: Set<UUID>
        let projectedTasks: [AgentDispatchTask]
        if !plannedNodes.isEmpty {
            sourceTaskIDs = Set(plannedNodes.map(\.id))
            projectedTasks = plannedNodes.map { node in
                var task = oldTasks[node.id] ?? AgentDispatchTask(
                    id: node.id,
                    title: node.title,
                    dependencyIDs: node.dependencyIDs,
                    planNodeKey: node.key,
                    primaryProfileID: node.primaryProfileID,
                    fallbackProfileIDs: node.fallbackProfileIDs,
                    branchName: branchName(for: node.title),
                    acceptanceCriteria: node.acceptanceCriteria,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt
                )
                task.title = node.title
                task.dependencyIDs = node.dependencyIDs
                task.planNodeKey = node.key
                task.primaryProfileID = node.primaryProfileID
                task.fallbackProfileIDs = node.fallbackProfileIDs
                if task.runtimeSessionID == nil {
                    task.verificationCommands = node.verificationCommands
                    task.scheduling = node.scheduling
                }
                task.acceptanceCriteria = node.acceptanceCriteria.isEmpty
                    ? [defaultAcceptanceCriterion]
                    : node.acceptanceCriteria
                // Dependency-derived state may only move a task between the
                // two not-yet-started states. This used to run for every
                // task without a runtime session, so a node completed by
                // hand (accepted/merged, never linked to a runtime) was
                // knocked back to queued/blocked on every board
                // synchronization — "finished yesterday, not started today".
                if task.runtimeSessionID == nil,
                   task.pendingDecisionIDs?.isEmpty != false,
                   task.state == .queued || task.state == .blocked {
                    task.state = node.dependencyIDs.isEmpty ? .queued : .blocked
                }
                task.updatedAt = max(task.updatedAt, session.updatedAt)
                if existing?.statement != sourceGoal.statement, task.pendingDecisionIDs?.isEmpty == false {
                    task.pendingDecisionIDs = nil
                    task.resumedDecisionIDs = nil
                    task.state = .cancelled
                }
                return task
            }
        } else {
            // Until the planner emits a dispatch graph, acceptance items stay
            // exclusively in the synthetic acceptance gate. Projecting them
            // as task cards makes the board look like one flat parallel wave
            // and, worse, lets the scheduler mistake evidence for work.
            sourceTaskIDs = Set(sourceGoal.checklist.map(\.id))
            projectedTasks = []
        }
        let acceptancePlaceholderIDs = Set(sourceGoal.checklist.map(\.id))
        let manuallyAppendedTasks = (existing?.tasks ?? []).filter {
            !sourceTaskIDs.contains($0.id)
                && !acceptancePlaceholderIDs.contains($0.id)
                && $0.planNodeKey == nil
        }
        var tasks = projectedTasks + manuallyAppendedTasks
        let mergedIDs = Set(tasks.filter { $0.state == .merged }.map(\.id))
        for index in tasks.indices where tasks[index].state == .blocked {
            if tasks[index].pendingDecisionIDs?.isEmpty != false,
               Set(tasks[index].dependencyIDs).isSubset(of: mergedIDs) {
                tasks[index].state = .queued
            }
        }
        return AgentDispatchGoal(
            id: session.id,
            sessionID: session.id,
            title: session.title,
            statement: sourceGoal.statement,
            logicalProject: logicalProject,
            workspaceLocation: primaryWorkspace,
            workspaceBindings: workspaceBindings,
            integrationBaseRevisions: integrationBaseRevisions,
            decisions: existing?.decisions,
            tasks: tasks,
            executorChoice: existing?.executorChoice ?? .automatic,
            targetChoice: existing?.targetChoice ?? .automatic,
            modelRouting: existing?.modelRouting ?? .costOptimized,
            planningProfileID: sourceGoal.planningProfileID
                ?? existing?.planningProfileID
                ?? AgentExecutionProfile.recommendedPlannerID,
            planningFallbackProfileIDs: AgentDispatchPlannerSelection
                .normalizedFallbackProfileIDs(
                    primaryProfileID: sourceGoal.planningProfileID
                        ?? existing?.planningProfileID
                        ?? AgentExecutionProfile.recommendedPlannerID,
                    fallbackProfileIDs: sourceGoal.planningFallbackProfileIDs
                        ?? existing?.planningFallbackProfileIDs
                        ?? []
                ),
            selectedWorkerProfileIDs: sourceGoal.selectedWorkerProfileIDs
                ?? existing?.selectedWorkerProfileIDs
                ?? [AgentExecutionProfile.recommendedWorkerID],
            cliProfileSelections: existing?.cliProfileSelections,
            isPaused: existing?.isPaused ?? false,
            commands: existing?.commands ?? [],
            createdAt: existing?.createdAt ?? session.createdAt,
            updatedAt: max(existing?.updatedAt ?? session.updatedAt, session.updatedAt)
        )
    }

    nonisolated static func branchName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = title.lowercased().unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(6)
            .joined(separator: "-")
        return "dispatch/\(slug.isEmpty ? "task" : slug)"
    }
}

nonisolated enum AgentDispatchLogicalProjectResolver {
    /// Derive the board's logical project for a workspace.
    ///
    /// When the session belongs to a user-managed `AgentProject`, that
    /// project supplies the name and primary folder, so the board and the
    /// sidebar can never disagree about what a project is called. Without
    /// one, the pre-existing path-derived behaviour is unchanged.
    static func resolve(
        location: WorkspaceLocation,
        preferredLocalProjectPath: String? = nil,
        managedProject: AgentProject? = nil
    ) -> AgentDispatchLogicalProject {
        let primaryPath: String
        let repositoryIdentity: String?
        switch location {
        case .local(let rawPath):
            primaryPath = normalizedLocalPath(
                preferredLocalProjectPath
                    ?? canonicalLocalProjectPath(for: rawPath)
                    ?? rawPath
            )
            repositoryIdentity = localRepositoryIdentity(for: rawPath)
                ?? localRepositoryIdentity(for: primaryPath)
        case .remote(_, let rawPath):
            primaryPath = RemotePathValidator.normalizedWorkspaceRoot(rawPath)
            repositoryIdentity = nil
        }
        let url = URL(fileURLWithPath: primaryPath)
        let derivedName = url.lastPathComponent.isEmpty ? primaryPath : url.lastPathComponent
        return AgentDispatchLogicalProject(
            displayName: managedProject?.resolvedDisplayName ?? derivedName,
            // The managed project's own primary folder wins: a project may
            // span several folders, and the board must anchor on the same one
            // the sidebar treats as primary.
            primaryWorkspacePath: managedProject?.primaryFolderPath ?? primaryPath,
            localRepositoryIdentity: repositoryIdentity,
            managedProjectID: managedProject?.id
        )
    }

    static func localCheckoutBelongs(
        to project: AgentDispatchLogicalProject,
        path: String
    ) -> Bool {
        let normalized = normalizedLocalPath(path)
        if let expectedIdentity = project.localRepositoryIdentity {
            return localRepositoryIdentity(for: normalized) == expectedIdentity
        }
        return normalized == normalizedLocalPath(project.primaryWorkspacePath)
    }

    static func representsSameProject(
        _ lhs: AgentDispatchLogicalProject,
        _ rhs: AgentDispatchLogicalProject
    ) -> Bool {
        // A managed project is an exact answer; the checks below only ever
        // approximated one from paths and repository fingerprints.
        if let lhsManaged = lhs.managedProjectID, let rhsManaged = rhs.managedProjectID {
            return lhsManaged == rhsManaged
        }
        if let lhsIdentity = lhs.localRepositoryIdentity,
           let rhsIdentity = rhs.localRepositoryIdentity {
            return lhsIdentity == rhsIdentity
        }
        return normalizedLocalPath(lhs.primaryWorkspacePath)
            == normalizedLocalPath(rhs.primaryWorkspacePath)
    }

    static func localRepositoryIdentity(for path: String) -> String? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard let root = AppState.findGitRepositoryRoot(startingAt: candidate) else {
            return nil
        }
        let rawCommonDirectory = AppState.runGit(
            arguments: ["rev-parse", "--git-common-dir"],
            in: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCommonDirectory.isEmpty else { return nil }
        let commonDirectory: URL
        if rawCommonDirectory.hasPrefix("/") {
            commonDirectory = URL(fileURLWithPath: rawCommonDirectory)
        } else {
            commonDirectory = root.appendingPathComponent(rawCommonDirectory)
        }
        return commonDirectory.standardizedFileURL.path
    }

    private static func canonicalLocalProjectPath(for path: String) -> String? {
        guard let repositoryIdentity = localRepositoryIdentity(for: path) else {
            return nil
        }
        let commonDirectory = URL(fileURLWithPath: repositoryIdentity).standardizedFileURL
        guard commonDirectory.lastPathComponent == ".git" else { return nil }
        return commonDirectory.deletingLastPathComponent().path
    }

    private static func normalizedLocalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct AgentDispatchStore {
    private static let defaultsKey = "com.willdeep.agentDispatch.goals.v1"
    private let defaults: UserDefaults

    /// AppState-based tests construct the real coordinator chain; before
    /// this redirect they loaded — and via `resetForTests()` / projection
    /// persists WIPED — the user's actual dispatch board in `.standard`,
    /// which is one of the ways completed projects came back "not started".
    /// Same lesson as `AgentSessionStore.testSandboxDirectory`: redirect
    /// the entire test process so a newly added test cannot get it wrong.
    /// The `willdeep-dispatch-` prefix is registered with
    /// TestDefaultsHygiene, so leftover suites get swept.
    private static let processDefaults: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        let underTest = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard underTest,
              let sandbox = UserDefaults(
                  suiteName: "willdeep-dispatch-process-\(ProcessInfo.processInfo.processIdentifier)"
              ) else {
            return .standard
        }
        return sandbox
    }()

    init(defaults: UserDefaults = AgentDispatchStore.processDefaults) {
        self.defaults = defaults
    }

    func load() -> [AgentDispatchGoal] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([AgentDispatchGoal].self, from: data)) ?? []
    }

    func save(_ goals: [AgentDispatchGoal]) {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
