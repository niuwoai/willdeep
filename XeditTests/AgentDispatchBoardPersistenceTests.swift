//
//  AgentDispatchBoardPersistenceTests.swift
//  WillDeepTests
//
//  调度台节点状态的持久化与投影安全。背景 bug（2026-08-14 用户报告）：
//  已完成的调度台项目在某次重新打开 App 后全部回到「未启动」。根因有二：
//  1. `agentSessions` 异步装载完成前，任何 synchronize 都会把「空会话
//     列表的投影」（= 空面板）立即写盘，抹掉已完成 goal 的任务状态；
//     目录装载完成后重投影，任务从计划节点全量重建为 queued/blocked。
//  2. 投影里 `runtimeSessionID == nil` 的任务每次同步都被无条件按依赖
//     重算状态，手工验收过的节点会被打回 queued。
//
//  刻意独立成 @Suite 而不挂进 WillDeepTests extension：函数级
//  -only-testing 选不中聚合 suite（静默跑 0 个用例报 TEST SUCCEEDED）。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("调度台状态持久化", .serialized)
@MainActor
struct AgentDispatchBoardPersistenceTests {
    @Test("会话目录装载完成前 synchronize 不得抹掉已存的面板")
    func projectionRefusedUntilSessionCatalogLoads() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(
            rootDirectory: workspace,
            dispatchStore: AgentDispatchStore(defaults: sandbox.defaults)
        )
        // 种入一个已完成的面板。直连协调器是合法的种子路径——门禁保护的
        // 是「拿 AppState 的 agentSessions 当真相」的调用。
        let session = makePlannedSession()
        appState.agentDispatchCoordinator.synchronize(with: [session])
        let taskID = try #require(
            appState.agentDispatchCoordinator.goals.first?.tasks.first?.id
        )
        appState.agentDispatchCoordinator.updateTaskState(
            goalID: session.id,
            taskID: taskID,
            state: .merged
        )

        // 初始化里那次磁盘装载是异步的，主线程同步代码段内该标志必然还是
        // false——这正是线上触发抹盘的时间窗。
        #expect(!appState.hasLoadedAgentSessionCatalog)
        #expect(appState.agentSessions.isEmpty)

        // 门禁必须拒绝这次投影。修复前：goals 被投影成 []，并立即写盘。
        appState.synchronizeDispatchBoard()
        appState.synchronizeDispatchBoardInBackground()

        #expect(appState.agentDispatchCoordinator.goals.count == 1)
        #expect(
            appState.agentDispatchCoordinator.goals.first?
                .tasks.first?.state == .merged
        )
        // 存储侧同样未被清空。
        let reloaded = AgentDispatchStore(defaults: sandbox.defaults).load()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.tasks.first?.state == .merged)
    }

    @Test("手工完成的节点不因重投影回到未启动")
    func manuallyCompletedTaskSurvivesResynchronization() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let coordinator = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        let session = makePlannedSession()
        coordinator.synchronize(with: [session])
        let goal = try #require(coordinator.goals.first)
        #expect(goal.tasks.count == 2)
        let first = goal.tasks[0]
        let second = goal.tasks[1]
        // 计划节点 2 依赖节点 1：初始应为 queued + blocked。
        #expect(first.state == .queued)
        #expect(second.state == .blocked)

        // 手工验收节点 1（从未关联运行会话，runtimeSessionID == nil）。
        coordinator.updateTaskState(goalID: goal.id, taskID: first.id, state: .accepted)
        coordinator.synchronize(with: [session])
        #expect(
            coordinator.goals.first?.tasks.first?.state == .accepted,
            "重投影不得把已验收节点打回未启动"
        )
        // accepted 不解锁依赖：节点 2 仍 blocked（解锁语义只认 merged）。
        #expect(coordinator.goals.first?.tasks.last?.state == .blocked)

        // merged 之后，重投影要把依赖它的节点解锁为 queued——
        // 「只许在未启动区间重算」不能把解锁逻辑也一并冻结。
        coordinator.updateTaskState(goalID: goal.id, taskID: first.id, state: .merged)
        coordinator.synchronize(with: [session])
        #expect(coordinator.goals.first?.tasks.first?.state == .merged)
        #expect(coordinator.goals.first?.tasks.last?.state == .queued)
    }

    @Test("节点状态写盘后可被新协调器原样读回")
    func taskStatesRoundTripThroughStore() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.cleanup() }
        let session = makePlannedSession()
        do {
            let coordinator = AgentDispatchCoordinator(
                store: AgentDispatchStore(defaults: sandbox.defaults)
            )
            coordinator.synchronize(with: [session])
            let goal = try #require(coordinator.goals.first)
            coordinator.updateTaskState(
                goalID: goal.id,
                taskID: goal.tasks[0].id,
                state: .merged
            )
        }
        // 模拟重启：全新协调器从同一存储装载。
        let relaunched = AgentDispatchCoordinator(
            store: AgentDispatchStore(defaults: sandbox.defaults)
        )
        #expect(relaunched.goals.first?.tasks.first?.state == .merged)
        // 目录装载完成后的完整重投影也不得回退该状态。
        relaunched.synchronize(with: [session])
        #expect(relaunched.goals.first?.tasks.first?.state == .merged)
    }

    private func makePlannedSession() -> AgentSession {
        let firstID = UUID()
        let secondID = UUID()
        return AgentSession(
            title: "调度台项目",
            workspaceRootPath: "/tmp/willdeep-dispatch-project",
            presentationScope: .dispatchBoard,
            currentGoal: AgentGoal(
                statement: "交付项目",
                checklist: [AgentGoal.Item(text: "全部完成")],
                dispatchPlan: AgentGoalDispatchPlan(nodes: [
                    .init(
                        id: firstID,
                        key: "TASK-1",
                        title: "实现",
                        dependencyIDs: [],
                        primaryProfileID: AgentExecutionProfile.recommendedWorkerID,
                        fallbackProfileIDs: [],
                        acceptanceCriteria: ["实现完成"]
                    ),
                    .init(
                        id: secondID,
                        key: "TASK-2",
                        title: "验收",
                        dependencyIDs: [firstID],
                        primaryProfileID: AgentExecutionProfile.recommendedWorkerID,
                        fallbackProfileIDs: [],
                        acceptanceCriteria: ["验收通过"]
                    ),
                ])
            )
        )
    }

    private func makeSandbox() throws -> DispatchDefaultsSandbox {
        // 前缀沿用 AgentDispatchCoordinatorTests 的 "willdeep-dispatch-"，
        // TestDefaultsHygiene 已登记该前缀，残留壳会被清理。
        let suiteName = "willdeep-dispatch-persistence-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return DispatchDefaultsSandbox(suiteName: suiteName, defaults: defaults)
    }
}

private struct DispatchDefaultsSandbox {
    let suiteName: String
    let defaults: UserDefaults

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
