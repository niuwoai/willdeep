//
//  AgentDispatchCoordinatorTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDispatchCoordinatorTests {
    @Test("Goal 指令按运行状态进入立即、安全点或中断确认")
    func commandEffectsRespectExecutionBoundary() {
        #expect(
            AgentDispatchCommandClassifier.effect(
                for: "调整验收标准",
                isGoalRunning: true
            ) == .queuedForSafePoint
        )
        #expect(
            AgentDispatchCommandClassifier.effect(
                for: "追加任务：补回归测试",
                isGoalRunning: true
            ) == .appliedImmediately
        )
        #expect(
            AgentDispatchCommandClassifier.effect(
                for: "立即中断，先修数据损坏",
                isGoalRunning: true
            ) == .requiresInterruptConfirmation
        )
        #expect(
            AgentDispatchCommandClassifier.effect(
                for: "调整验收标准",
                isGoalRunning: false
            ) == .appliedImmediately
        )
    }

    @Test("自动执行器按任务适配，用户强制指定不静默回退")
    func executorResolutionHonorsAutomaticAndPinnedChoices() {
        let available: Set<AgentExecutionAgent> = [.willDeep, .claudeCode, .codexCLI]

        let testDecision = AgentDispatchExecutorResolver.resolve(
            title: "运行 rg 搜索与回归测试",
            choice: .automatic,
            availableExecutors: available
        )
        #expect(testDecision.executor == .codexCLI)
        #expect(testDecision.reason == .testAndSearchFit)
        #expect(testDecision.isAvailable)

        let architectureDecision = AgentDispatchExecutorResolver.resolve(
            title: "跨文件架构重构",
            choice: .automatic,
            availableExecutors: available
        )
        #expect(architectureDecision.executor == .claudeCode)
        #expect(architectureDecision.reason == .refactorAndArchitectureFit)

        let pinnedUnavailable = AgentDispatchExecutorResolver.resolve(
            title: "任意任务",
            choice: .codexCLI,
            availableExecutors: [.willDeep]
        )
        #expect(pinnedUnavailable.executor == .codexCLI)
        #expect(!pinnedUnavailable.isAvailable)
    }

    @Test("Goal 清单同步保留人工追加任务、指令与执行策略")
    func synchronizationPreservesDispatchOwnedState() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let firstID = UUID()
        let session = AgentSession(
            title: "Orchestrator MVP",
            workspaceRootPath: "/tmp/Orchestrator",
            currentGoal: AgentGoal(
                statement: "交付可交互调度台",
                checklist: [
                    AgentGoal.Item(id: firstID, text: "搭建任务图"),
                    AgentGoal.Item(text: "接入 SSH"),
                ]
            )
        )

        coordinator.synchronize(with: [session])
        let goalID = try #require(coordinator.selectedGoal?.id)
        coordinator.updateGoalExecutorChoice(.claudeCode, goalID: goalID)
        _ = coordinator.recordCommand(
            goalID: goalID,
            text: "先补测试",
            effect: .queuedForSafePoint
        )
        let appended = try #require(
            coordinator.appendTask(title: "视觉验收", goalID: goalID)
        )

        var updatedSession = session
        updatedSession.currentGoal?.checklist[0].done = true
        updatedSession.updatedAt = Date().addingTimeInterval(1)
        coordinator.synchronize(with: [updatedSession])

        let synchronized = try #require(coordinator.selectedGoal)
        #expect(synchronized.executorChoice == .claudeCode)
        #expect(synchronized.commands.map(\.text).contains("先补测试"))
        #expect(synchronized.tasks.contains(where: { $0.id == appended.id }))
        #expect(synchronized.tasks.first(where: { $0.id == firstID })?.state == .merged)
        #expect(synchronized.tasks[1].state == .queued)
        #expect(synchronized.workspaceLocation == .local(path: "/tmp/Orchestrator"))
        #expect(synchronized.isWorkspaceBound)
        #expect(synchronized.logicalProject?.displayName == "Orchestrator")
        #expect(synchronized.projectDisplayText == "Orchestrator · /tmp/Orchestrator")
        #expect(synchronized.availableTargetChoices == [.local])
    }

    @Test("调度记录连同工作区映射可以持久化并重新载入")
    func storeRoundTrip() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let store = AgentDispatchStore(defaults: sandbox.defaults)
        let remoteRuntimeID = UUID()
        let project = AgentDispatchLogicalProject(
            displayName: "Project",
            primaryWorkspacePath: "/tmp/Project"
        )
        let goal = AgentDispatchGoal(
            id: UUID(),
            sessionID: UUID(),
            title: "持久化",
            statement: "重启后继续",
            logicalProject: project,
            workspaceLocation: .local(path: "/tmp/Project"),
            workspaceBindings: [
                AgentDispatchWorkspaceBinding(
                    location: .remote(runtimeID: remoteRuntimeID, path: "/srv/project"),
                    projectID: project.id
                ),
            ],
            tasks: [AgentDispatchTask(title: "第一步")],
            executorChoice: .automatic,
            targetChoice: .local,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )

        store.save([goal])

        #expect(store.load() == [goal])
    }

    @Test("旧调度记录缺少工作区字段时保持未绑定并可迁移")
    func legacyStoreDecodingKeepsGoalUnbound() throws {
        let goal = AgentDispatchGoal(
            id: UUID(),
            sessionID: UUID(),
            title: "旧 Goal",
            statement: "等待绑定",
            workspaceLocation: .local(path: "/tmp/Legacy"),
            workspaceBindings: [],
            tasks: [AgentDispatchTask(title: "第一步")],
            executorChoice: .automatic,
            targetChoice: .local,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        let encoded = try JSONEncoder().encode(goal)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "workspaceLocation")
        object.removeValue(forKey: "workspaceBindings")
        object.removeValue(forKey: "logicalProject")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AgentDispatchGoal.self, from: legacyData)

        #expect(decoded.workspaceLocation == nil)
        #expect(!decoded.isWorkspaceBound)
        #expect(decoded.effectiveWorkspaceBindings.isEmpty)
        #expect(decoded.resolvedTargetChoice(taskChoice: .automatic) == nil)
    }

    @Test("Goal 只能选择已映射执行环境")
    func targetChoiceRequiresWorkspaceMapping() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let remoteRuntimeID = UUID()
        let session = AgentSession(
            workspaceRootPath: "/tmp/Project",
            currentGoal: AgentGoal(statement: "跨环境交付", checklist: [.init(text: "实现")])
        )
        coordinator.synchronize(with: [session])
        let goalID = try #require(coordinator.selectedGoal?.id)
        let project = try #require(coordinator.selectedGoal?.logicalProject)

        coordinator.updateGoalTargetChoice(.remote(remoteRuntimeID), goalID: goalID)
        #expect(coordinator.selectedGoal?.targetChoice == .automatic)

        coordinator.bindWorkspace(
            .remote(runtimeID: remoteRuntimeID, path: "/srv/project"),
            logicalProject: project,
            goalID: goalID,
            makePrimary: false
        )
        coordinator.updateGoalTargetChoice(.remote(remoteRuntimeID), goalID: goalID)

        let goal = try #require(coordinator.selectedGoal)
        #expect(goal.targetChoice == .remote(remoteRuntimeID))
        #expect(
            goal.workspaceLocation(for: .remote(remoteRuntimeID))
                == .remote(runtimeID: remoteRuntimeID, path: "/srv/project")
        )
    }

    @Test("旧的未绑定 Goal 不会从会话静默继承工作区")
    func legacyUnboundGoalRequiresOneExplicitBinding() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceRootPath: "/tmp/Project",
            currentGoal: AgentGoal(statement: "旧目标", checklist: [.init(text: "实现")])
        )
        let unbound = AgentDispatchGoal(
            id: sessionID,
            sessionID: sessionID,
            title: "旧目标",
            statement: "旧目标",
            tasks: [AgentDispatchTask(title: "实现")],
            executorChoice: .automatic,
            targetChoice: .automatic,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        let store = AgentDispatchStore(defaults: sandbox.defaults)
        store.save([unbound])
        let coordinator = AgentDispatchCoordinator(store: store)

        coordinator.synchronize(with: [session])

        let synchronized = try #require(coordinator.selectedGoal)
        #expect(!synchronized.isWorkspaceBound)
        #expect(synchronized.logicalProject == nil)
        #expect(synchronized.workspaceLocation == nil)
    }

    @Test("旧 SSH 默认目录映射不会被当成已确认项目 checkout")
    func legacyRemoteMappingRequiresExplicitRemap() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let sessionID = UUID()
        let runtimeID = UUID()
        let session = AgentSession(
            id: sessionID,
            workspaceRootPath: "/tmp/Project",
            currentGoal: AgentGoal(statement: "迁移", checklist: [.init(text: "实现")])
        )
        let legacy = AgentDispatchGoal(
            id: sessionID,
            sessionID: sessionID,
            title: "迁移",
            statement: "迁移",
            workspaceLocation: .local(path: "/tmp/Project"),
            workspaceBindings: [
                AgentDispatchWorkspaceBinding(
                    location: .remote(runtimeID: runtimeID, path: "/srv/default")
                ),
            ],
            tasks: [AgentDispatchTask(title: "实现")],
            executorChoice: .automatic,
            targetChoice: .automatic,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        let store = AgentDispatchStore(defaults: sandbox.defaults)
        store.save([legacy])
        let coordinator = AgentDispatchCoordinator(store: store)

        coordinator.synchronize(with: [session])

        let synchronized = try #require(coordinator.selectedGoal)
        #expect(synchronized.isWorkspaceBound)
        #expect(synchronized.workspaceLocation(for: .remote(runtimeID)) == nil)
        #expect(synchronized.availableTargetChoices == [.local])
    }

    @Test("Task 可固定到同一逻辑项目的不同 checkout")
    func taskCanChooseDifferentCheckoutWithinLogicalProject() throws {
        let project = AgentDispatchLogicalProject(
            displayName: "Project",
            primaryWorkspacePath: "/repo/Project",
            localRepositoryIdentity: "/repo/Project/.git"
        )
        let worktree = AgentDispatchWorkspaceBinding(
            location: .local(path: "/worktrees/Project/task-a"),
            projectID: project.id
        )
        var task = AgentDispatchTask(title: "实现", workspaceBindingID: worktree.id)
        let goal = AgentDispatchGoal(
            id: UUID(),
            sessionID: UUID(),
            title: "Project",
            statement: "交付",
            logicalProject: project,
            workspaceLocation: .local(path: "/repo/Project"),
            workspaceBindings: [worktree],
            tasks: [task],
            executorChoice: .automatic,
            targetChoice: .automatic,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )

        #expect(goal.resolvedWorkspaceBinding(for: task) == worktree)

        task.workspaceBindingID = "local:/another/project"
        #expect(goal.resolvedWorkspaceBinding(for: task) == nil)
    }

    @Test("本机 checkout 必须共享同一个 Git common directory")
    func localCheckoutMustBelongToLogicalProject() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-project-\(UUID().uuidString)")
        let first = base.appendingPathComponent("First")
        let second = base.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(AppState.runGitCommand(arguments: ["init"], in: first).succeeded)
        #expect(AppState.runGitCommand(arguments: ["init"], in: second).succeeded)
        let project = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: first.path)
        )

        #expect(
            AgentDispatchLogicalProjectResolver.localCheckoutBelongs(
                to: project,
                path: first.path
            )
        )
        #expect(
            !AgentDispatchLogicalProjectResolver.localCheckoutBelongs(
                to: project,
                path: second.path
            )
        )
    }

    @Test("绑定另一个本机仓库会在 AppState 校验层被拒绝")
    func appStateRejectsDifferentLocalProjectMapping() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-bind-\(UUID().uuidString)")
        let first = base.appendingPathComponent("First")
        let second = base.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(AppState.runGitCommand(arguments: ["init"], in: first).succeeded)
        #expect(AppState.runGitCommand(arguments: ["init"], in: second).succeeded)

        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        _ = appState.startNewAgentSession(inWorkspaceAt: first.path)
        appState.setAgentInteractionMode(.goal)
        appState.setAgentGoal(statement: "固定项目", items: ["实现"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        let goalID = try #require(appState.agentDispatchCoordinator.selectedGoal?.id)

        let error = appState.bindDispatchGoalWorkspace(
            goalID: goalID,
            location: .local(path: second.path)
        )

        #expect(error == L10n.Dispatch.workspaceProjectMismatch)
    }

    @Test("SSH 映射缺少项目对应目录时不能绑定")
    func remoteMappingRequiresExplicitProjectPath() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let previousDefaults = AgentRuntimeStore.setTestDefaults(sandbox.defaults)
        defer { _ = AgentRuntimeStore.setTestDefaults(previousDefaults) }
        let descriptor = RuntimeDescriptor(
            displayName: "Build Host",
            host: "example.invalid",
            username: "builder",
            defaultWorkspacePath: "/srv/default"
        )
        AgentRuntimeStore.upsert(descriptor)

        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        _ = appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        appState.setAgentInteractionMode(.goal)
        appState.setAgentGoal(statement: "固定项目", items: ["实现"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        let goalID = try #require(appState.agentDispatchCoordinator.selectedGoal?.id)

        let error = appState.bindDispatchGoalWorkspace(
            goalID: goalID,
            location: .remote(runtimeID: descriptor.id, path: "   ")
        )

        #expect(error == L10n.Dispatch.remoteWorkspacePathRequired)
        #expect(
            appState.agentDispatchCoordinator.selectedGoal?
                .workspaceLocation(for: .remote(descriptor.id)) == nil
        )
    }

    @Test("无工作区会话不能进入 Goal 模式，绑定后可以")
    func goalModeRequiresWorkspace() throws {
        let appState = AppState()
        _ = appState.startNewAgentSession()
        let unboundRuntime = try #require(appState.activeRuntime)

        appState.setAgentInteractionMode(.goal)

        #expect(unboundRuntime.interactionMode == .normal)
        #expect(unboundRuntime.errorMessage == L10n.Dispatch.workspaceRequired)

        _ = appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        let boundRuntime = try #require(appState.activeRuntime)
        appState.setAgentInteractionMode(.goal)

        #expect(boundRuntime.interactionMode == .goal)
        #expect(boundRuntime.errorMessage == nil)
    }

    private func makeSandbox() throws -> DefaultsSandbox {
        let suiteName = "willdeep-dispatch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsSandbox(suiteName: suiteName, defaults: defaults)
    }
}

private struct DefaultsSandbox {
    let suiteName: String
    let defaults: UserDefaults

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
