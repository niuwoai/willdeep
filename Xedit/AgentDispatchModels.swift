//
//  AgentDispatchModels.swift
//  WillDeep
//
//  Durable, UI-independent models for the Goal-first dispatch console.
//

import Foundation

nonisolated enum AgentDispatchTaskState: String, Codable, CaseIterable {
    case blocked
    case queued
    case running
    case reviewing
    case accepted
    case failed
    case cancelled
    case merged

    var isTerminal: Bool {
        switch self {
        case .failed, .cancelled, .merged:
            return true
        default:
            return false
        }
    }
}

nonisolated enum AgentDispatchExecutorChoice: String, Codable, CaseIterable, Identifiable {
    case automatic
    case willDeep
    case claudeCode
    case codexCLI
    case hermesCLI
    case cursorAgent
    case clineCLI

    var id: String { rawValue }

    var pinnedExecutor: AgentExecutionAgent? {
        switch self {
        case .automatic: return nil
        case .willDeep: return .willDeep
        case .claudeCode: return .claudeCode
        case .codexCLI: return .codexCLI
        case .hermesCLI: return .hermesCLI
        case .cursorAgent: return .cursorAgent
        case .clineCLI: return .clineCLI
        }
    }

    init(executor: AgentExecutionAgent) {
        switch executor {
        case .willDeep: self = .willDeep
        case .claudeCode: self = .claudeCode
        case .codexCLI: self = .codexCLI
        case .hermesCLI: self = .hermesCLI
        case .cursorAgent: self = .cursorAgent
        case .clineCLI: self = .clineCLI
        }
    }
}

nonisolated enum AgentDispatchTargetChoice: Codable, Equatable, Hashable {
    case automatic
    case local
    case remote(UUID)
}

/// Per-project model roles. Planning stays on the top-level project session;
/// ordinary implementation runs use the execution model on child task
/// sessions. Model IDs are provider-agnostic so relay providers such as
/// some.im can combine model families without changing the project shape.
nonisolated struct AgentDispatchModelRouting: Codable, Equatable {
    static let recommendedPlanningModel = "kimi-k3"
    static let recommendedExecutionModel = "deepseek-v4-pro"

    var planningModelID: String?
    var executionModelID: String?

    static let costOptimized = AgentDispatchModelRouting(
        planningModelID: recommendedPlanningModel,
        executionModelID: recommendedExecutionModel
    )

    init(
        planningModelID: String? = recommendedPlanningModel,
        executionModelID: String? = recommendedExecutionModel
    ) {
        self.planningModelID = Self.normalized(planningModelID)
        self.executionModelID = Self.normalized(executionModelID)
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Stable identity for the logical project owned by a Goal.
///
/// Execution checkouts are deliberately kept outside this value: a Task may
/// run in another Git worktree or on SSH, but those paths are only mappings of
/// this same project and can never replace the Goal's primary project.
nonisolated struct AgentDispatchLogicalProject: Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var primaryWorkspacePath: String
    var localRepositoryIdentity: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        primaryWorkspacePath: String,
        localRepositoryIdentity: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.primaryWorkspacePath = primaryWorkspacePath
        self.localRepositoryIdentity = localRepositoryIdentity
    }
}

nonisolated struct AgentDispatchWorkspaceBinding: Codable, Equatable, Identifiable {
    var location: WorkspaceLocation
    /// Nil only for records written before logical-project ownership existed.
    /// Such mappings are ignored until synchronization migrates a previously
    /// bound Goal or the user explicitly binds an unbound legacy Goal.
    var projectID: UUID? = nil

    var id: String {
        switch location {
        case .local(let path):
            return "local:\(path)"
        case .remote(let runtimeID, let path):
            return "remote:\(runtimeID.uuidString):\(path)"
        }
    }

    var targetChoice: AgentDispatchTargetChoice {
        switch location {
        case .local:
            return .local
        case .remote(let runtimeID, _):
            return .remote(runtimeID)
        }
    }
}

nonisolated enum AgentDispatchExecutorReason: String, Codable {
    case userPinned
    case testAndSearchFit
    case refactorAndArchitectureFit
    case localFallback
    case onlyAvailable
}

nonisolated struct AgentDispatchExecutorDecision: Equatable {
    let executor: AgentExecutionAgent
    let reason: AgentDispatchExecutorReason
    let isAvailable: Bool
}

nonisolated enum AgentDispatchProfileResolver {
    static func next(
        primaryProfileID: String?,
        fallbackProfileIDs: [String],
        attemptedProfileIDs: [String],
        availableExecutors: Set<AgentExecutionAgent>,
        profiles: [AgentExecutionProfile]
    ) -> AgentExecutionProfile? {
        let candidates = [primaryProfileID].compactMap { $0 } + fallbackProfileIDs
        let attempted = Set(attemptedProfileIDs)
        return candidates
            .filter { !attempted.contains($0) }
            .compactMap { id in profiles.first(where: { $0.id == id }) }
            .first { availableExecutors.contains($0.executor) }
    }

    static func hasUntriedFallback(
        fallbackProfileIDs: [String],
        attemptedProfileIDs: [String]
    ) -> Bool {
        let attempted = Set(attemptedProfileIDs)
        return fallbackProfileIDs.contains { !attempted.contains($0) }
    }
}

nonisolated struct AgentDispatchTask: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var state: AgentDispatchTaskState
    var dependencyIDs: [UUID]
    /// Stable AI-authored key when this task came from `dispatch-graph`.
    /// Nil marks a human-appended node or a legacy acceptance placeholder.
    var planNodeKey: String? = nil
    var executorChoice: AgentDispatchExecutorChoice
    var targetChoice: AgentDispatchTargetChoice
    var resolvedExecutor: AgentExecutionAgent?
    /// AI-selected primary execution profile. A human executor override can
    /// still replace it from the inspector.
    var primaryProfileID: String? = nil
    /// Ordered failover chain. Values are stable app-owned profile IDs.
    var fallbackProfileIDs: [String]? = nil
    /// Persisted attempt ledger prevents retry loops across relaunches.
    var attemptedProfileIDs: [String]? = nil
    var activeProfileID: String? = nil
    var resolvedTarget: AgentDispatchTargetChoice?
    var runtimeSessionID: UUID?
    var runtimeSessionIDs: [UUID]? = nil
    /// Optional checkout override. The referenced binding must belong to the
    /// Goal's logical project; otherwise launch validation rejects it.
    var workspaceBindingID: String?
    var branchName: String
    var acceptanceCriteria: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        state: AgentDispatchTaskState = .queued,
        dependencyIDs: [UUID] = [],
        planNodeKey: String? = nil,
        executorChoice: AgentDispatchExecutorChoice = .automatic,
        targetChoice: AgentDispatchTargetChoice = .automatic,
        resolvedExecutor: AgentExecutionAgent? = nil,
        primaryProfileID: String? = nil,
        fallbackProfileIDs: [String]? = nil,
        attemptedProfileIDs: [String]? = nil,
        activeProfileID: String? = nil,
        resolvedTarget: AgentDispatchTargetChoice? = nil,
        runtimeSessionID: UUID? = nil,
        runtimeSessionIDs: [UUID]? = nil,
        workspaceBindingID: String? = nil,
        branchName: String = "",
        acceptanceCriteria: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.dependencyIDs = dependencyIDs
        self.planNodeKey = planNodeKey
        self.executorChoice = executorChoice
        self.targetChoice = targetChoice
        self.resolvedExecutor = resolvedExecutor
        self.primaryProfileID = primaryProfileID
        self.fallbackProfileIDs = fallbackProfileIDs
        self.attemptedProfileIDs = attemptedProfileIDs
        self.activeProfileID = activeProfileID
        self.resolvedTarget = resolvedTarget
        self.runtimeSessionID = runtimeSessionID
        self.runtimeSessionIDs = runtimeSessionIDs
        self.workspaceBindingID = workspaceBindingID
        self.branchName = branchName
        self.acceptanceCriteria = acceptanceCriteria
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated enum AgentDispatchCommandEffect: String, Codable {
    case appliedImmediately
    case queuedForSafePoint
    case requiresInterruptConfirmation
}

nonisolated enum AgentDispatchCommandStatus: String, Codable {
    case applied
    case queued
    case pendingConfirmation
    case cancelled
}

nonisolated struct AgentDispatchCommand: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var effect: AgentDispatchCommandEffect
    var status: AgentDispatchCommandStatus
    var createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        effect: AgentDispatchCommandEffect,
        status: AgentDispatchCommandStatus,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.effect = effect
        self.status = status
        self.createdAt = createdAt
    }
}

nonisolated struct AgentDispatchGoal: Codable, Equatable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var title: String
    var statement: String
    /// Nil means the Goal is a legacy unbound record and cannot execute.
    var logicalProject: AgentDispatchLogicalProject? = nil
    var workspaceLocation: WorkspaceLocation? = nil
    var workspaceBindings: [AgentDispatchWorkspaceBinding]? = nil
    var tasks: [AgentDispatchTask]
    var executorChoice: AgentDispatchExecutorChoice
    var targetChoice: AgentDispatchTargetChoice
    /// Nil on legacy records; callers use `effectiveModelRouting` so old
    /// projects receive the cost-optimized defaults without migration UI.
    var modelRouting: AgentDispatchModelRouting? = nil
    var planningProfileID: String? = nil
    var planningFallbackProfileIDs: [String]? = nil
    /// Selected local CLI profile IDs keyed by `AgentExecutionAgent.rawValue`.
    /// Profiles are discovered from the user's Codex/Claude configuration;
    /// only the stable ID is stored with the project.
    var cliProfileSelections: [String: String]? = nil
    var isPaused: Bool
    var commands: [AgentDispatchCommand]
    var createdAt: Date
    var updatedAt: Date

    var progressFraction: Double {
        guard !tasks.isEmpty else { return 0 }
        let completed = tasks.filter { $0.state == .merged }.count
        return Double(completed) / Double(tasks.count)
    }

    var activeTaskCount: Int {
        tasks.filter { $0.state == .running || $0.state == .reviewing }.count
    }

    var isExecutionActive: Bool {
        activeTaskCount > 0
    }

    var hasStartedExecution: Bool {
        tasks.contains {
            $0.runtimeSessionID != nil
                || ![.blocked, .queued].contains($0.state)
        }
    }

    var hasReadyTask: Bool {
        tasks.contains { $0.state == .queued }
    }

    var effectiveModelRouting: AgentDispatchModelRouting {
        modelRouting ?? .costOptimized
    }

    func selectedCLIProfileID(for executor: AgentExecutionAgent) -> String? {
        cliProfileSelections?[executor.rawValue]
    }

    var effectivePlanningProfileID: String {
        planningProfileID ?? AgentExecutionProfile.recommendedPlannerID
    }

    var effectivePlanningFallbackProfileIDs: [String] {
        planningFallbackProfileIDs ?? []
    }

    var deletionRequiresConfirmation: Bool {
        !commands.isEmpty
    }

    var ownedSessionIDs: Set<UUID> {
        Set(
            [sessionID]
                + tasks.flatMap { $0.runtimeSessionIDs ?? [] }
                + tasks.compactMap(\.runtimeSessionID)
        )
    }

    var isWorkspaceBound: Bool {
        logicalProject != nil && workspaceLocation != nil
    }

    var projectDisplayText: String? {
        guard let logicalProject else { return nil }
        return "\(logicalProject.displayName) · \(logicalProject.primaryWorkspacePath)"
    }

    var effectiveWorkspaceBindings: [AgentDispatchWorkspaceBinding] {
        guard let logicalProject, let workspaceLocation else { return [] }
        var result: [AgentDispatchWorkspaceBinding] = []
        result.append(
            AgentDispatchWorkspaceBinding(
                location: workspaceLocation,
                projectID: logicalProject.id
            )
        )
        for binding in workspaceBindings ?? []
        where binding.projectID == logicalProject.id
            && !result.contains(where: { $0.id == binding.id }) {
            result.append(binding)
        }
        return result
    }

    var availableTargetChoices: [AgentDispatchTargetChoice] {
        var choices: [AgentDispatchTargetChoice] = []
        for choice in effectiveWorkspaceBindings.map(\.targetChoice)
        where !choices.contains(choice) {
            choices.append(choice)
        }
        return choices
    }

    func workspaceBinding(id: String?) -> AgentDispatchWorkspaceBinding? {
        guard let id else { return nil }
        return effectiveWorkspaceBindings.first { $0.id == id }
    }

    func resolvedWorkspaceBinding(
        for task: AgentDispatchTask
    ) -> AgentDispatchWorkspaceBinding? {
        if let selectedID = task.workspaceBindingID {
            return workspaceBinding(id: selectedID)
        }
        guard let target = resolvedTargetChoice(taskChoice: task.targetChoice),
              let location = workspaceLocation(for: target),
              let logicalProject else {
            return nil
        }
        return AgentDispatchWorkspaceBinding(
            location: location,
            projectID: logicalProject.id
        )
    }

    func resolvedTargetChoice(
        taskChoice: AgentDispatchTargetChoice
    ) -> AgentDispatchTargetChoice? {
        let requested = taskChoice == .automatic ? targetChoice : taskChoice
        if requested != .automatic {
            return workspaceLocation(for: requested) == nil ? nil : requested
        }
        guard isWorkspaceBound, let workspaceLocation else { return nil }
        return AgentDispatchWorkspaceBinding(location: workspaceLocation).targetChoice
    }

    func workspaceLocation(
        for targetChoice: AgentDispatchTargetChoice
    ) -> WorkspaceLocation? {
        switch targetChoice {
        case .automatic:
            return workspaceLocation
        case .local, .remote:
            return effectiveWorkspaceBindings.first {
                $0.targetChoice == targetChoice
            }?.location
        }
    }
}

nonisolated enum AgentDispatchCommandClassifier {
    static func effect(for text: String, isGoalRunning: Bool) -> AgentDispatchCommandEffect {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("立即中断")
            || normalized.contains("马上中断")
            || normalized.contains("/interrupt") {
            return .requiresInterruptConfirmation
        }

        let immediatePrefixes = [
            "追加任务",
            "添加任务",
            "add task",
            "调整优先级",
            "adjust priority",
            "暂停全部",
            "pause all",
            "恢复全部",
            "resume all",
        ]
        if immediatePrefixes.contains(where: normalized.hasPrefix) {
            return .appliedImmediately
        }
        return isGoalRunning ? .queuedForSafePoint : .appliedImmediately
    }

    static func appendedTaskTitle(from text: String) -> String? {
        let prefixes = ["追加任务", "添加任务", "Add Task", "add task"]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return nil }
        let suffix = text.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：: \n\t"))
        return suffix.isEmpty ? nil : suffix
    }
}

nonisolated enum AgentDispatchExecutorResolver {
    static func resolve(
        title: String,
        choice: AgentDispatchExecutorChoice,
        availableExecutors: Set<AgentExecutionAgent>
    ) -> AgentDispatchExecutorDecision {
        if let pinned = choice.pinnedExecutor {
            return AgentDispatchExecutorDecision(
                executor: pinned,
                reason: .userPinned,
                isAvailable: availableExecutors.contains(pinned)
            )
        }

        let normalized = title.lowercased()
        let testAndSearchKeywords = [
            "test", "测试", "回归", "rg", "搜索", "search", "debug", "排查",
        ]
        if testAndSearchKeywords.contains(where: normalized.contains),
           availableExecutors.contains(.codexCLI) {
            return AgentDispatchExecutorDecision(
                executor: .codexCLI,
                reason: .testAndSearchFit,
                isAvailable: true
            )
        }

        let refactorKeywords = [
            "refactor", "重构", "架构", "architecture", "设计", "跨文件",
        ]
        if refactorKeywords.contains(where: normalized.contains),
           availableExecutors.contains(.claudeCode) {
            return AgentDispatchExecutorDecision(
                executor: .claudeCode,
                reason: .refactorAndArchitectureFit,
                isAvailable: true
            )
        }

        if availableExecutors.contains(.willDeep) {
            return AgentDispatchExecutorDecision(
                executor: .willDeep,
                reason: availableExecutors.count == 1 ? .onlyAvailable : .localFallback,
                isAvailable: true
            )
        }

        let fallback = availableExecutors.first ?? .willDeep
        return AgentDispatchExecutorDecision(
            executor: fallback,
            reason: .onlyAvailable,
            isAvailable: availableExecutors.contains(fallback)
        )
    }

    @MainActor
    static func localAvailableExecutors() -> Set<AgentExecutionAgent> {
        localAvailableExecutors(discoveries: LocalAgentCLI.discoverAll())
    }

    @MainActor
    static func localAvailableExecutors(
        discoveries: [LocalAgentCLI.Discovery]
    ) -> Set<AgentExecutionAgent> {
        var result: Set<AgentExecutionAgent> = [.willDeep]
        for discovery in discoveries where discovery.path != nil {
            switch discovery.cli.id {
            case "claude-code": result.insert(.claudeCode)
            case "codex-cli": result.insert(.codexCLI)
            case "hermes-cli": result.insert(.hermesCLI)
            case "cursor-cli": result.insert(.cursorAgent)
            case "cline-cli": result.insert(.clineCLI)
            default: break
            }
        }
        return result
    }
}
