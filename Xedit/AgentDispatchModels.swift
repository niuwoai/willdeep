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
    case cursorAgent
    case clineCLI

    var id: String { rawValue }

    var pinnedExecutor: AgentExecutionAgent? {
        switch self {
        case .automatic: return nil
        case .willDeep: return .willDeep
        case .claudeCode: return .claudeCode
        case .codexCLI: return .codexCLI
        case .cursorAgent: return .cursorAgent
        case .clineCLI: return .clineCLI
        }
    }

    init(executor: AgentExecutionAgent) {
        switch executor {
        case .willDeep: self = .willDeep
        case .claudeCode: self = .claudeCode
        case .codexCLI: self = .codexCLI
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

nonisolated struct AgentDispatchTask: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var state: AgentDispatchTaskState
    var dependencyIDs: [UUID]
    var executorChoice: AgentDispatchExecutorChoice
    var targetChoice: AgentDispatchTargetChoice
    var resolvedExecutor: AgentExecutionAgent?
    var resolvedTarget: AgentDispatchTargetChoice?
    var runtimeSessionID: UUID?
    var branchName: String
    var acceptanceCriteria: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        state: AgentDispatchTaskState = .queued,
        dependencyIDs: [UUID] = [],
        executorChoice: AgentDispatchExecutorChoice = .automatic,
        targetChoice: AgentDispatchTargetChoice = .automatic,
        resolvedExecutor: AgentExecutionAgent? = nil,
        resolvedTarget: AgentDispatchTargetChoice? = nil,
        runtimeSessionID: UUID? = nil,
        branchName: String = "",
        acceptanceCriteria: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.dependencyIDs = dependencyIDs
        self.executorChoice = executorChoice
        self.targetChoice = targetChoice
        self.resolvedExecutor = resolvedExecutor
        self.resolvedTarget = resolvedTarget
        self.runtimeSessionID = runtimeSessionID
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
    var tasks: [AgentDispatchTask]
    var executorChoice: AgentDispatchExecutorChoice
    var targetChoice: AgentDispatchTargetChoice
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
            case "cursor-cli": result.insert(.cursorAgent)
            case "cline-cli": result.insert(.clineCLI)
            default: break
            }
        }
        return result
    }
}
