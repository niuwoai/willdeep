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

    @Test("Profile 回退链跳过已尝试和不可用执行器并保持顺序")
    func profileFallbackSkipsAttemptedAndUnavailableProfiles() throws {
        let profiles = [
            AgentExecutionProfile(
                id: "primary",
                name: "Primary",
                executor: .willDeep,
                modelID: "planner"
            ),
            AgentExecutionProfile(
                id: "unavailable",
                name: "Unavailable",
                executor: .claudeCode,
                modelID: "claude-model"
            ),
            AgentExecutionProfile(
                id: "fallback",
                name: "Fallback",
                executor: .codexCLI,
                modelID: "codex-model"
            ),
        ]

        let selected = try #require(
            AgentDispatchProfileResolver.next(
                primaryProfileID: "primary",
                fallbackProfileIDs: ["unavailable", "fallback"],
                attemptedProfileIDs: ["primary"],
                availableExecutors: [.willDeep, .codexCLI],
                profiles: profiles
            )
        )
        #expect(selected.id == "fallback")
        #expect(
            AgentDispatchProfileResolver.hasUntriedFallback(
                fallbackProfileIDs: ["unavailable", "fallback"],
                attemptedProfileIDs: ["primary", "unavailable"]
            )
        )
        #expect(
            !AgentDispatchProfileResolver.hasUntriedFallback(
                fallbackProfileIDs: ["unavailable", "fallback"],
                attemptedProfileIDs: ["primary", "unavailable", "fallback"]
            )
        )
    }

    @Test("任务执行会话不会再次投影成侧栏项目")
    func taskSessionsDoNotBecomeProjects() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let taskID = UUID()
        let projectSession = AgentSession(
            title: "顶层项目",
            workspaceRootPath: "/tmp/project",
            presentationScope: .dispatchBoard,
            currentGoal: AgentGoal(
                statement: "交付项目",
                checklist: [AgentGoal.Item(id: taskID, text: "实现")]
            )
        )
        coordinator.synchronize(with: [projectSession])

        let explicitChild = AgentSession(
            title: "显式归属任务",
            workspaceRootPath: "/tmp/project",
            presentationScope: .dispatchBoard,
            dispatchParentProjectID: projectSession.id,
            dispatchTaskID: taskID,
            currentGoal: AgentGoal(
                statement: "实现",
                checklist: [AgentGoal.Item(text: "测试通过")]
            )
        )
        coordinator.synchronize(with: [projectSession, explicitChild])
        #expect(coordinator.goals.map(\.id) == [projectSession.id])

        let legacyChildID = UUID()
        coordinator.markTaskStarted(
            goalID: projectSession.id,
            taskID: taskID,
            executor: .willDeep,
            target: .local,
            runtimeSessionID: legacyChildID
        )
        let legacyChild = AgentSession(
            id: legacyChildID,
            title: "旧版本任务",
            workspaceRootPath: "/tmp/project",
            presentationScope: .dispatchBoard,
            currentGoal: AgentGoal(
                statement: "旧版本任务",
                checklist: [AgentGoal.Item(text: "测试通过")]
            )
        )
        coordinator.synchronize(with: [projectSession, explicitChild, legacyChild])
        #expect(coordinator.goals.map(\.id) == [projectSession.id])
    }

    @Test("项目保存规划执行模型与本地 CLI Profile")
    func projectPreservesRoleRoutingAndCLIProfiles() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let session = AgentSession(
            title: "模型组合",
            workspaceRootPath: "/tmp/project",
            currentGoal: AgentGoal(
                statement: "组合模型交付",
                checklist: [AgentGoal.Item(text: "执行")]
            )
        )
        coordinator.synchronize(with: [session])
        #expect(coordinator.selectedGoal?.effectiveModelRouting == .costOptimized)

        coordinator.updateGoalModelRouting(
            AgentDispatchModelRouting(
                planningModelID: "planner-large",
                executionModelID: "worker-small"
            ),
            goalID: session.id
        )
        coordinator.updateGoalCLIProfile(
            "codex:fast",
            executor: .codexCLI,
            goalID: session.id
        )
        coordinator.synchronize(with: [session])

        let project = try #require(coordinator.selectedGoal)
        #expect(project.effectiveModelRouting.planningModelID == "planner-large")
        #expect(project.effectiveModelRouting.executionModelID == "worker-small")
        #expect(project.selectedCLIProfileID(for: .codexCLI) == "codex:fast")
    }

    @Test("任务图按真实依赖分层并把末端节点连接到验收关卡")
    func graphLayoutUsesDependencyLayers() throws {
        let root = AgentDispatchTask(title: "根节点")
        let left = AgentDispatchTask(title: "左分支", dependencyIDs: [root.id])
        let right = AgentDispatchTask(title: "右分支", dependencyIDs: [root.id])
        let merge = AgentDispatchTask(
            title: "汇聚",
            dependencyIDs: [left.id, right.id]
        )

        let layout = AgentDispatchGraphLayout(tasks: [root, left, right, merge])
        let rootCenter = try #require(layout.taskCenters[root.id])
        let leftCenter = try #require(layout.taskCenters[left.id])
        let rightCenter = try #require(layout.taskCenters[right.id])
        let mergeCenter = try #require(layout.taskCenters[merge.id])

        #expect(rootCenter.x < leftCenter.x)
        #expect(leftCenter.x == rightCenter.x)
        #expect(leftCenter.y != rightCenter.y)
        #expect(leftCenter.x < mergeCenter.x)
        #expect(mergeCenter.x < layout.gateCenter.x)
        #expect(layout.edges.count == 5)
        #expect(layout.edges.contains(AgentDispatchGraphEdge(sourceID: merge.id, targetID: nil)))
    }

    @Test("AI 任务图支持分叉、双上游汇聚、节点 Profile 与稳定 ID")
    func aiDispatchGraphProjectsRealDAGAndProfiles() throws {
        let content = """
        ```dispatch-graph
        {
          "nodes": [
            {
              "id": "ROOT-1",
              "title": "读取需求",
              "depends_on": [],
              "profile": "planner",
              "fallback_profiles": ["fallback"],
              "acceptance": ["需求边界明确"]
            },
            {
              "id": "LEFT-1",
              "title": "实现左分支",
              "depends_on": ["ROOT-1"],
              "profile": "worker",
              "fallback_profiles": ["fallback"],
              "acceptance": ["左分支测试通过"]
            },
            {
              "id": "RIGHT-1",
              "title": "实现右分支",
              "depends_on": ["ROOT-1"],
              "profile": "worker",
              "fallback_profiles": ["fallback"],
              "acceptance": ["右分支测试通过"]
            },
            {
              "id": "MERGE-1",
              "title": "集成验收",
              "depends_on": ["LEFT-1", "RIGHT-1"],
              "profile": "planner",
              "fallback_profiles": ["fallback"],
              "acceptance": ["集成测试通过"]
            }
          ]
        }
        ```
        """
        let availableProfiles: Set<String> = ["planner", "worker", "fallback"]
        let first = try #require(
            AgentGoalDispatchPlanParser.extract(
                from: content,
                availableProfileIDs: availableProfiles,
                namespace: "project-1"
            )
        )
        let second = try #require(
            AgentGoalDispatchPlanParser.extract(
                from: content,
                availableProfileIDs: availableProfiles,
                namespace: "project-1"
            )
        )
        #expect(first.nodes.map(\.id) == second.nodes.map(\.id))

        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let session = AgentSession(
            title: "真实 DAG",
            workspaceRootPath: "/tmp/Graph",
            currentGoal: AgentGoal(
                statement: "并行实现并汇聚",
                checklist: [AgentGoal.Item(text: "集成测试通过")],
                dispatchPlan: first
            )
        )
        coordinator.synchronize(with: [session])

        let tasks = try #require(coordinator.selectedGoal?.tasks)
        let left = try #require(tasks.first { $0.title == "实现左分支" })
        let right = try #require(tasks.first { $0.title == "实现右分支" })
        let merge = try #require(tasks.first { $0.title == "集成验收" })
        #expect(tasks.count == 4)
        #expect(Set(merge.dependencyIDs) == Set([left.id, right.id]))
        #expect(merge.primaryProfileID == "planner")
        #expect(merge.fallbackProfileIDs == ["fallback"])
        #expect(merge.state == .blocked)

        let manual = try #require(
            coordinator.appendTask(
                title: "人工补充",
                goalID: session.id,
                acceptanceCriteria: ["人工验收"]
            )
        )
        var revisedSession = session
        revisedSession.currentGoal?.dispatchPlan = AgentGoalDispatchPlan(
            nodes: Array(first.nodes.prefix(2))
        )
        revisedSession.updatedAt = Date().addingTimeInterval(1)
        coordinator.synchronize(with: [revisedSession])
        let revisedTasks = try #require(coordinator.selectedGoal?.tasks)
        #expect(revisedTasks.contains { $0.id == manual.id })
        #expect(!revisedTasks.contains { $0.title == "实现右分支" })
        #expect(!revisedTasks.contains { $0.title == "集成验收" })
    }

    @Test("结构化节点编辑拒绝循环依赖并保留原计划")
    func taskDefinitionRejectsDependencyCycles() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let firstID = UUID()
        let secondID = UUID()
        coordinator.synchronize(
            with: [
                AgentSession(
                    title: "Graph",
                    workspaceRootPath: "/tmp/Graph",
                    currentGoal: AgentGoal(
                        statement: "构建任务图",
                        checklist: [
                            AgentGoal.Item(id: firstID, text: "第一步"),
                            AgentGoal.Item(id: secondID, text: "第二步"),
                        ],
                        dispatchPlan: AgentGoalDispatchPlan(
                            nodes: [
                                AgentGoalDispatchPlan.Node(
                                    id: firstID,
                                    key: "FIRST-1",
                                    title: "第一步",
                                    dependencyIDs: [],
                                    primaryProfileID: nil,
                                    fallbackProfileIDs: [],
                                    acceptanceCriteria: ["第一步完成"]
                                ),
                                AgentGoalDispatchPlan.Node(
                                    id: secondID,
                                    key: "SECOND-1",
                                    title: "第二步",
                                    dependencyIDs: [firstID],
                                    primaryProfileID: nil,
                                    fallbackProfileIDs: [],
                                    acceptanceCriteria: ["第二步完成"]
                                ),
                            ]
                        )
                    )
                ),
            ]
        )
        let goalID = try #require(coordinator.selectedGoal?.id)

        let updated = coordinator.updateTaskDefinition(
            goalID: goalID,
            taskID: firstID,
            title: "第一步",
            dependencyIDs: [secondID],
            acceptanceCriteria: ["通过测试"]
        )

        #expect(!updated)
        #expect(coordinator.selectedGoal?.tasks.first?.dependencyIDs.isEmpty == true)
    }

    @Test("追加节点可以显式选择多个前置节点和验收标准")
    func appendTaskSupportsGraphDefinition() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        coordinator.synchronize(
            with: [
                AgentSession(
                    title: "Graph",
                    workspaceRootPath: "/tmp/Graph",
                    currentGoal: AgentGoal(
                        statement: "并行任务",
                        checklist: [
                            AgentGoal.Item(text: "任务 A"),
                            AgentGoal.Item(text: "任务 B"),
                        ]
                    )
                ),
            ]
        )
        let goalID = try #require(coordinator.selectedGoal?.id)
        let dependencies = try #require(coordinator.selectedGoal?.tasks.map(\.id))

        let appended = try #require(
            coordinator.appendTask(
                title: "汇聚节点",
                goalID: goalID,
                dependencyIDs: dependencies,
                acceptanceCriteria: ["报告完整", "测试通过"]
            )
        )

        #expect(appended.dependencyIDs == dependencies)
        #expect(appended.acceptanceCriteria == ["报告完整", "测试通过"])
        #expect(appended.state == .blocked)
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

    @Test("未收到指令的 Goal 直接删除，收到指令后需要确认")
    func goalDeletionConfirmationTracksCommandsAndOwnedSessions() {
        let sourceID = UUID()
        let firstTaskRuntimeID = UUID()
        let secondTaskRuntimeID = UUID()
        let taskWithoutRuntime = AgentDispatchTask(title: "等待")
        let firstTask = AgentDispatchTask(
            title: "执行一",
            runtimeSessionID: firstTaskRuntimeID
        )
        let secondTask = AgentDispatchTask(
            title: "执行二",
            runtimeSessionID: secondTaskRuntimeID
        )
        var goal = AgentDispatchGoal(
            id: sourceID,
            sessionID: sourceID,
            title: "Delete Contract",
            statement: "验证删除",
            tasks: [firstTask, secondTask, taskWithoutRuntime],
            executorChoice: .automatic,
            targetChoice: .automatic,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )

        #expect(!goal.deletionRequiresConfirmation)
        #expect(goal.ownedSessionIDs == [sourceID, firstTaskRuntimeID, secondTaskRuntimeID])

        goal.commands.append(
            AgentDispatchCommand(
                text: "开始执行",
                effect: .appliedImmediately,
                status: .applied
            )
        )

        #expect(goal.deletionRequiresConfirmation)
    }

    @Test("仅全部合并或显式暂停会释放项目调度名额")
    func dispatchSlotReleaseRequiresCompletionOrPause() {
        let queued = AgentDispatchTask(title: "排队", state: .queued)
        var goal = AgentDispatchGoal(
            id: UUID(),
            sessionID: UUID(),
            title: "Slot",
            statement: "验证名额",
            tasks: [queued],
            executorChoice: .automatic,
            targetChoice: .automatic,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )

        #expect(!goal.isComplete)
        #expect(goal.isOperationallyActive)

        goal.tasks[0].state = .failed
        #expect(!goal.isComplete)
        #expect(goal.isOperationallyActive)

        goal.isPaused = true
        #expect(!goal.isOperationallyActive)

        goal.isPaused = false
        goal.tasks[0].state = .merged
        #expect(goal.isComplete)
        #expect(!goal.isOperationallyActive)
    }

    @Test("共享 Git common directory 的不同 checkout 属于同一调度项目")
    func logicalProjectIdentityCollapsesWorktrees() {
        let first = AgentDispatchLogicalProject(
            displayName: "Main",
            primaryWorkspacePath: "/repo/main",
            localRepositoryIdentity: "/repo/main/.git"
        )
        let second = AgentDispatchLogicalProject(
            displayName: "Feature",
            primaryWorkspacePath: "/repo/worktrees/feature",
            localRepositoryIdentity: "/repo/main/.git"
        )

        #expect(AgentDispatchLogicalProjectResolver.representsSameProject(first, second))
    }

    @Test("删除 Goal 会持久化并把选中项移到相邻 Goal")
    func coordinatorRemovalPersistsAndReconcilesSelection() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let store = AgentDispatchStore(defaults: sandbox.defaults)
        let coordinator = AgentDispatchCoordinator(store: store)
        let first = AgentSession(
            title: "First",
            workspaceRootPath: "/tmp/first",
            updatedAt: Date(timeIntervalSince1970: 10),
            currentGoal: AgentGoal(statement: "第一项", checklist: [])
        )
        let second = AgentSession(
            title: "Second",
            workspaceRootPath: "/tmp/second",
            updatedAt: Date(timeIntervalSince1970: 20),
            currentGoal: AgentGoal(statement: "第二项", checklist: [])
        )
        coordinator.synchronize(with: [first, second])
        coordinator.selectGoal(second.id)

        let removed = coordinator.removeGoal(id: second.id)

        #expect(removed?.id == second.id)
        #expect(coordinator.goals.map(\.id) == [first.id])
        #expect(coordinator.selectedGoalID == first.id)
        #expect(store.load().map(\.id) == [first.id])
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

    @Test("调度台选择工作区后保留结构化 Goal 草稿，不创建聊天消息")
    func dispatchGoalDraftKeepsOrchestratorDestination() throws {
        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()

        let session = appState.startDispatchGoalSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        let runtime = try #require(appState.runtime(for: session.id))

        #expect(appState.activeAgentSessionID == session.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
        #expect(runtime.session.presentationScope == .dispatchBoard)
        #expect(runtime.interactionMode == .goal)
        #expect(runtime.currentGoal == nil)
        #expect(runtime.messages.isEmpty)
        #expect(appState.isPreparingDispatchGoal)

        appState.setAgentGoal(statement: "留在调度台", items: ["生成任务图"])

        #expect(!appState.isPreparingDispatchGoal)
        #expect(runtime.messages.isEmpty)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
        #expect(appState.agentDispatchCoordinator.selectedGoalID == session.id)
    }

    @Test("同一工作区重复创建调度项目会复用现有项目")
    func duplicateDispatchProjectReusesExistingSession() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-single-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        let first = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        appState.setAgentGoal(statement: "唯一调度", items: ["完成实现"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        let sessionCount = appState.agentSessions.count

        let reused = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)

        #expect(reused.id == first.id)
        #expect(appState.activeAgentSessionID == first.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
        #expect(appState.agentSessions.count == sessionCount)
        #expect(appState.agentDispatchCoordinator.goals.count == 1)
    }

    @Test("暂停释放调度名额，但存在新项目时旧项目不能恢复")
    func pausedDispatchReleasesSlotAndResumeChecksConflict() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        let first = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        appState.setAgentGoal(statement: "旧调度", items: ["旧任务"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        #expect(appState.agentDispatchCoordinator.setPaused(true, goalID: first.id))

        let second = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        #expect(second.id != first.id)
        appState.setAgentGoal(statement: "新调度", items: ["新任务"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)

        #expect(
            appState.agentDispatchCoordinator.activeGoal(
                for: .local(path: workspace.path)
            )?.id == second.id
        )
        #expect(!appState.agentDispatchCoordinator.setPaused(false, goalID: first.id))
        #expect(appState.agentDispatchCoordinator.goals.first(where: { $0.id == first.id })?.isPaused == true)
    }

    @Test("恢复旧调度后，尚未定义的新草稿不能成为第二个运行项目")
    func activeDispatchRejectsCompetingDraftDefinition() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-draft-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        let first = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        appState.setAgentGoal(statement: "旧调度", items: ["旧任务"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        #expect(appState.agentDispatchCoordinator.setPaused(true, goalID: first.id))

        let draft = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        #expect(draft.id != first.id)
        #expect(appState.agentDispatchCoordinator.setPaused(false, goalID: first.id))

        appState.setAgentGoal(statement: "冲突草稿", items: ["不能启动"])

        let draftRuntime = try #require(appState.runtime(for: draft.id))
        #expect(draftRuntime.currentGoal == nil)
        #expect(draftRuntime.errorMessage == L10n.Dispatch.projectAlreadyRunning("旧调度"))
    }

    @Test("恢复时同一项目的多个历史调度只保留一个运行")
    func synchronizationPausesDuplicateLegacyDispatchProjects() {
        let workspace = "/tmp/willdeep-legacy-single-dispatch"
        let older = AgentSession(
            title: "Older",
            workspaceRootPath: workspace,
            updatedAt: Date(timeIntervalSince1970: 10),
            currentGoal: AgentGoal(
                statement: "旧项目",
                checklist: [.init(text: "实现")]
            )
        )
        let newer = AgentSession(
            title: "Newer",
            workspaceRootPath: workspace,
            updatedAt: Date(timeIntervalSince1970: 20),
            currentGoal: AgentGoal(
                statement: "新项目",
                checklist: [.init(text: "实现")]
            )
        )
        let coordinator = AgentDispatchCoordinator()
        coordinator.resetForTests()

        coordinator.synchronize(with: [older, newer])

        #expect(coordinator.goals.filter(\.isOperationallyActive).count == 1)
        #expect(coordinator.goals.first(where: { $0.id == newer.id })?.isPaused == false)
        #expect(coordinator.goals.first(where: { $0.id == older.id })?.isPaused == true)
    }

    @Test("调度项目及子任务通知都返回调度台而不是聊天")
    func dispatchNotificationsRevealOwningProjectBoard() throws {
        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        let project = appState.startDispatchGoalSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        appState.setAgentGoal(statement: "通知路由", items: ["执行节点"])
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
        let taskID = try #require(
            appState.agentDispatchCoordinator.selectedGoal?.tasks.first?.id
        )

        appState.agentPrimaryDestination = .conversation
        appState.revealAgentSessionFromNotification(id: project.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
        #expect(appState.agentDispatchCoordinator.selectedGoalID == project.id)

        let child = appState.startNewAgentSession(
            inWorkspaceAt: FileManager.default.temporaryDirectory.path
        )
        let childRuntime = try #require(appState.runtime(for: child.id))
        childRuntime.session.dispatchParentProjectID = project.id
        childRuntime.session.dispatchTaskID = taskID
        appState.persistAgentSession(runtime: childRuntime)

        appState.agentPrimaryDestination = .conversation
        appState.revealAgentSessionFromNotification(id: child.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
        #expect(appState.activeAgentSessionID == project.id)
        #expect(appState.agentDispatchCoordinator.selectedGoalID == project.id)
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
