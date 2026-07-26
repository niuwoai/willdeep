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

    func synchronize(with sessions: [AgentSession]) {
        let sourceSessions = sessions.filter { session in
            guard let goal = session.currentGoal else { return false }
            return !goal.isEmpty
        }
        let existingByID = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
        let projected = sourceSessions.map { session in
            Self.project(session: session, existing: existingByID[session.id])
        }
        goals = projected.sorted { lhs, rhs in
            if lhs.activeTaskCount != rhs.activeTaskCount {
                return lhs.activeTaskCount > rhs.activeTaskCount
            }
            return lhs.updatedAt > rhs.updatedAt
        }

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

    func updateGoalExecutorChoice(_ choice: AgentDispatchExecutorChoice, goalID: UUID) {
        updateGoal(id: goalID) { goal in
            goal.executorChoice = choice
            goal.updatedAt = Date()
        }
    }

    func updateGoalTargetChoice(_ choice: AgentDispatchTargetChoice, goalID: UUID) {
        updateGoal(id: goalID) { goal in
            goal.targetChoice = choice
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

    func updateTaskTargetChoice(
        _ choice: AgentDispatchTargetChoice,
        goalID: UUID,
        taskID: UUID
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.targetChoice = choice
            task.updatedAt = Date()
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

    func setPaused(_ paused: Bool, goalID: UUID) {
        updateGoal(id: goalID) { goal in
            goal.isPaused = paused
            goal.updatedAt = Date()
        }
    }

    @discardableResult
    func appendTask(title: String, goalID: UUID) -> AgentDispatchTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var appended: AgentDispatchTask?
        updateGoal(id: goalID) { goal in
            let predecessor = goal.tasks.last
            let dependencies = predecessor.map { [$0.id] } ?? []
            let task = AgentDispatchTask(
                title: trimmed,
                state: predecessor == nil || predecessor?.state == .merged ? .queued : .blocked,
                dependencyIDs: dependencies,
                branchName: Self.branchName(for: trimmed),
                acceptanceCriteria: [L10n.Dispatch.defaultAcceptanceCriterion]
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

    func markTaskStarted(
        goalID: UUID,
        taskID: UUID,
        executor: AgentExecutionAgent,
        target: AgentDispatchTargetChoice,
        runtimeSessionID: UUID
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.state = .running
            task.resolvedExecutor = executor
            task.resolvedTarget = target
            task.runtimeSessionID = runtimeSessionID
            task.updatedAt = Date()
        }
    }

    func updateTaskState(
        goalID: UUID,
        taskID: UUID,
        state: AgentDispatchTaskState
    ) {
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.state = state
            task.updatedAt = Date()
        }
        if state == .merged {
            unlockReadyTasks(goalID: goalID)
        }
    }

    func resetForTests() {
        goals = []
        selectedGoalID = nil
        selectedTaskID = nil
        persist()
    }

    private func updateGoal(id: UUID, change: (inout AgentDispatchGoal) -> Void) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        change(&goals[index])
        persist()
    }

    private func updateTask(
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
                if Set(goal.tasks[index].dependencyIDs).isSubset(of: mergedIDs) {
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

    private static func project(
        session: AgentSession,
        existing: AgentDispatchGoal?
    ) -> AgentDispatchGoal {
        let sourceGoal = session.currentGoal ?? AgentGoal()
        let oldTasks = Dictionary(uniqueKeysWithValues: (existing?.tasks ?? []).map { ($0.id, $0) })
        let sourceTaskIDs = Set(sourceGoal.checklist.map(\.id))
        let firstIncompleteIndex = sourceGoal.checklist.firstIndex { !$0.done }
        let projectedTasks = sourceGoal.checklist.enumerated().map { index, item -> AgentDispatchTask in
            var task = oldTasks[item.id] ?? AgentDispatchTask(
                id: item.id,
                title: item.text,
                dependencyIDs: index > 0 ? [sourceGoal.checklist[index - 1].id] : [],
                branchName: branchName(for: item.text),
                acceptanceCriteria: [L10n.Dispatch.defaultAcceptanceCriterion],
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
            task.title = item.text
            if item.done {
                task.state = .merged
            } else if task.state == .merged {
                task.state = index == firstIncompleteIndex ? .queued : .blocked
            } else if task.runtimeSessionID == nil {
                task.state = index == firstIncompleteIndex ? .queued : .blocked
            }
            task.updatedAt = max(task.updatedAt, session.updatedAt)
            return task
        }
        let manuallyAppendedTasks = (existing?.tasks ?? []).filter {
            !sourceTaskIDs.contains($0.id)
        }
        var tasks = projectedTasks + manuallyAppendedTasks
        let mergedIDs = Set(tasks.filter { $0.state == .merged }.map(\.id))
        for index in tasks.indices where tasks[index].state == .blocked {
            if Set(tasks[index].dependencyIDs).isSubset(of: mergedIDs) {
                tasks[index].state = .queued
            }
        }
        return AgentDispatchGoal(
            id: session.id,
            sessionID: session.id,
            title: session.title,
            statement: sourceGoal.statement,
            tasks: tasks,
            executorChoice: existing?.executorChoice ?? .automatic,
            targetChoice: existing?.targetChoice ?? .automatic,
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

struct AgentDispatchStore {
    private static let defaultsKey = "com.willdeep.agentDispatch.goals.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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
