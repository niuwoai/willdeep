//
//  WorkflowPipelineTests.swift
//  XeditTests
//
//  1.85.0-rc19:WorkflowEngine.pipeline + WorkflowState 行为回归。
//  pipeline 自身是 parallel 的语法糖,这里只验「形态对」(items 都
//  跑了 / 失败返回 nil / shared state actor 在并发下不丢更新)。
//
//  没造 AgentSubagent runner 真跑,而是直接验内部行为 —— phase 1 的
//  AgentStructuredSchemaTests 已经覆盖 schema 校验路径;phase 3 重写
//  DeepResearchWorkflow 时再做端到端冒烟。
//

import Foundation
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("workflow 启动绑定调用 runtime，缺参数不再假报 started")
    func workflowStartTargetsExactRuntimeAndRejectsMissingArguments() async {
        let appState = AppState()
        let firstSession = appState.startNewAgentSession()
        guard let firstRuntime = appState.runtime(for: firstSession.id) else {
            Issue.record("first runtime should exist")
            return
        }
        let secondSession = appState.startNewAgentSession()
        guard let secondRuntime = appState.runtime(for: secondSession.id) else {
            Issue.record("second runtime should exist")
            return
        }
        #expect(appState.activeAgentSessionID == secondSession.id)

        let rejected = appState.startWorkflow(
            workflow: WorkflowLifecycleTestDefinition(requiresArgs: true, blocksUntilCancelled: false),
            args: "",
            runtimeID: firstSession.id,
            notifyAgentOnCompletion: false
        )
        guard case .rejected = rejected else {
            Issue.record("missing args should reject instead of reporting started")
            return
        }
        #expect(firstRuntime.workflowTasks.isEmpty)
        #expect(firstRuntime.messages.isEmpty)

        let started = appState.startWorkflow(
            workflow: WorkflowLifecycleTestDefinition(requiresArgs: false, blocksUntilCancelled: true),
            args: "target first runtime",
            runtimeID: firstSession.id,
            notifyAgentOnCompletion: false
        )
        guard case .started(let reportID) = started else {
            Issue.record("workflow should start")
            return
        }
        #expect(firstRuntime.messages.contains(where: { $0.workflowReport?.id == reportID }))
        #expect(!secondRuntime.messages.contains(where: { $0.workflowReport?.id == reportID }))
        #expect(firstRuntime.workflowTasks[reportID] != nil)

        appState.cancelWorkflow(reportID: reportID, runtimeID: firstSession.id)
        for _ in 0..<50 {
            if firstRuntime.workflowTasks[reportID] == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let report = firstRuntime.messages.first(where: { $0.workflowReport?.id == reportID })?.workflowReport
        #expect(report?.status == .cancelled)
        #expect(report?.finishedAt != nil)
        #expect(firstRuntime.workflowTasks[reportID] == nil)

        let activeStarted = appState.startWorkflow(
            workflow: WorkflowLifecycleTestDefinition(requiresArgs: false, blocksUntilCancelled: true),
            args: "stop through slash action",
            runtimeID: secondSession.id,
            notifyAgentOnCompletion: false
        )
        guard case .started(let activeReportID) = activeStarted else {
            Issue.record("active runtime workflow should start")
            return
        }
        appState.stopAgentResponse()
        for _ in 0..<50 {
            if secondRuntime.workflowTasks[activeReportID] == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let activeReport = secondRuntime.messages.first(where: {
            $0.workflowReport?.id == activeReportID
        })?.workflowReport
        #expect(activeReport?.status == .cancelled)
        #expect(secondRuntime.workflowTasks[activeReportID] == nil)
    }

    @MainActor
    @Test("workflow 完成事件生成模型可见通知并只消费一次")
    func workflowCompletionNoticeReturnsResultToAgentOnce() {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        guard let runtime = appState.runtime(for: session.id) else {
            Issue.record("runtime should exist")
            return
        }
        let report = WorkflowReport(
            workflowName: "test-workflow",
            displayTitle: "Test Workflow",
            args: "question",
            status: .done,
            finishedAt: Date(),
            summary: "Final synthesized answer"
        )
        runtime.messages.append(AgentMessage(role: .workflowReport, content: "", workflowReport: report))
        runtime.pendingWorkflowCompletionReportIDs = [report.id]

        let consumed = appState.consumePendingWorkflowCompletions(for: runtime)
        #expect(consumed == [report])
        #expect(appState.consumePendingWorkflowCompletions(for: runtime).isEmpty)

        let notice = AppState.workflowCompletionNotice(for: report)
        #expect(notice.contains("<workflow-completion>"))
        #expect(notice.contains("status: done"))
        #expect(notice.contains("Final synthesized answer"))
        let providerReady = AgentClient.providerReadyMessages([
            AgentMessage(role: .system, content: notice)
        ])
        #expect(providerReady.first?.content == notice)
    }

    @MainActor
    @Test("workflow parallel 在父任务取消时传播 CancellationError")
    func workflowParallelPropagatesCancellation() async {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let engine = WorkflowEngine(
            reportID: UUID(),
            runtimeID: session.id,
            workspaceURL: nil,
            configuration: .default,
            someIMContext: nil,
            appState: appState
        )
        let task = Task {
            try await engine.parallel(maxConcurrent: 2, [
                { try await Task.sleep(nanoseconds: 10_000_000_000); return "a" },
                { try await Task.sleep(nanoseconds: 10_000_000_000); return "b" },
            ])
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled parallel workflow should throw")
        } catch is CancellationError {
            // Expected: cancellation must not be swallowed into nil results.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @MainActor
    @Test("重开会话时未完成的普通 workflow 自动归一为 cancelled")
    func interruptedGenericWorkflowNormalizesToCancelled() {
        let report = WorkflowReport(
            workflowName: "interrupted",
            displayTitle: "Interrupted",
            args: "",
            status: .running
        )
        let runtime = AgentRuntime(session: AgentSession(messages: [
            AgentMessage(role: .workflowReport, content: "", workflowReport: report)
        ]))

        #expect(runtime.messages.first?.workflowReport?.status == .cancelled)
        #expect(runtime.messages.first?.workflowReport?.finishedAt != nil)
        #expect(runtime.messages.first?.workflowReport?.summary == L10n.WorkflowCard.interrupted)
    }

    @MainActor
    @Test("WorkflowState actor:并发 update 不丢任何值")
    func workflowStateActorAggregatesAllUpdatesUnderContention() async {
        let counter = WorkflowState(0)
        // 100 个并发 task 各自 +1,最后必须读到 100,且每次 update 闭包
        // 也能拿到当时的 new value(给 caller 反馈用)。
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await counter.update { value -> Int in
                        value += 1
                        return value
                    }
                }
            }
            var observed: Set<Int> = []
            for await new in group {
                observed.insert(new)
            }
            // 100 个 new value 应该是 1..100 每个出现一次。
            #expect(observed == Set(1...100))
        }
        let final = await counter.snapshot()
        #expect(final == 100)
    }

    @MainActor
    @Test("WorkflowState 配 Set 跑 URL dedup,重复 url 被吃掉")
    func workflowStateDedupesURLsAcrossConcurrentInserters() async {
        let seen = WorkflowState(Set<String>())
        let urls = [
            "https://a.com/p1", "https://b.com/p2", "https://a.com/p1",
            "https://c.com/p3", "https://b.com/p2", "https://d.com/p4",
            "https://a.com/p1",
        ]
        var insertedFlags: [Bool] = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let inserted = await seen.update { $0.insert(url).inserted }
                    return (i, inserted)
                }
            }
            // 按原 index 排序结果,断言才稳。
            var collected: [(Int, Bool)] = []
            for await pair in group { collected.append(pair) }
            collected.sort { $0.0 < $1.0 }
            insertedFlags = collected.map(\.1)
        }
        let finalCount = await seen.snapshot().count
        #expect(finalCount == 4)
        // inserted 标志:7 个 url 里有 4 个唯一,所以应该有 4 个 true。
        #expect(insertedFlags.filter { $0 }.count == 4)
    }

    @MainActor
    @Test("Workflow watchdog times out without waiting for a stuck operation")
    func workflowWatchdogDoesNotWaitForUncancellableOperation() async {
        // 断言的本意是"没有傻等操作自然结束"，不是测量 watchdog 的精度。
        //
        // 这条已经被加固过一次：当时按"满载抖动 0.63s"把被守护操作放到 5s、
        // 判据放到 2s。2026-09-12 满载全量又被击穿，实测 2.18s——抖动的量级
        // 比上次估的大三倍多。所以这次不是把 2s 挪到 3s，而是把两端一起拉开：
        // 操作 60s、判据 15s。判据与噪声差一个量级，与信号也差四倍，任何一边
        // 再变化几倍都不会误判。往上挪一点点只会把同一个问题推到下一次满载。
        let stuckOperationSeconds: UInt64 = 60
        let elapsedBudget: TimeInterval = 15

        var didTimeout = false
        // 计时从 watchdog 启动那一刻算起。
        let startedAt = Date()

        do {
            _ = try await AppState.runWorkflowWithWatchdog(seconds: 0.05) {
                await withCheckedContinuation { continuation in
                    Task.detached {
                        try? await Task.sleep(nanoseconds: stuckOperationSeconds * 1_000_000_000)
                        continuation.resume()
                    }
                }
                return "late result"
            }
            #expect(Bool(false), "watchdog should time out before the operation completes")
        } catch {
            if case WorkflowError.timedOut = error {
                didTimeout = true
            } else {
                #expect(Bool(false), "expected WorkflowError.timedOut, got \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(didTimeout)
        #expect(
            elapsed < elapsedBudget,
            "watchdog 应在 \(elapsedBudget)s 内返回（实测 \(elapsed)s），说明它没有等被守护的 \(stuckOperationSeconds)s 操作跑完"
        )
    }

    // MARK: - 省心托管 workflow 模型解析 (1.155.0-rc9)
    //
    // 主循环每回合跑 routing judge,workflow 子 agent 之前直接拿静态
    // 配置模型、绕过托管路由。修复后:floor 与 high 取高者,按 workflow
    // 声明的任务域解析成 some.im 虚拟模型。

    @MainActor
    @Test("省心托管:workflow 模型 floor 与 high 取高者、按域映射")
    func managedWorkflowModelResolvesFloorAndDomain() {
        // 默认 floor(.low)抬到 high。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .general, hasCodingPlan: false)
                == SomeIMManagedModel.autoPro
        )
        // 会话 floor 已升到 premium 时不降档。
        #expect(
            AppState.managedWorkflowModel(floor: .premium, domain: .general, hasCodingPlan: false)
                == SomeIMManagedModel.autoPremium
        )
        // coding 域走 code* 梯子。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .coding, hasCodingPlan: false)
                == SomeIMManagedModel.codeHigh
        )
        // coding plan 不改变 general 域，仍走 auto 梯子。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .general, hasCodingPlan: true)
                == SomeIMManagedModel.autoPro
        )
        // coding plan 只接管 coding 域。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .coding, hasCodingPlan: true)
                == SomeIMManagedModel.codingPlanHigh
        )
    }

    @MainActor
    @Test("workflow 任务域声明:读代码的 coding,其余默认 general")
    func workflowManagedDomainDeclarations() {
        #expect(CodeReviewWorkflow().managedDomain == .coding)
        #expect(BugHuntWorkflow().managedDomain == .coding)
        #expect(PRReviewWorkflow().managedDomain == .coding)
        #expect(DeepResearchWorkflow().managedDomain == .general)
    }
}

private struct WorkflowLifecycleTestDefinition: WorkflowDefinition {
    let requiresArgs: Bool
    let blocksUntilCancelled: Bool

    var name: String { "workflow-lifecycle-test" }
    var displayTitle: String { "Workflow Lifecycle Test" }
    var slashCommand: String { "/workflow-lifecycle-test" }
    var shortDescription: String { "Test-only workflow" }
    var argsPlaceholder: String { "<input>" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { !requiresArgs }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        if blocksUntilCancelled {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return "done"
    }
}
