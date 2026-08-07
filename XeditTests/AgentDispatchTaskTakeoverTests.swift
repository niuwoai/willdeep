//
//  AgentDispatchTaskTakeoverTests.swift
//  WillDeepTests
//


import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDispatchTaskTakeoverTests {
    @Test("运行中切换模型保留当前请求并标记下一轮生效")
    func modelPresentationSeparatesActiveAndNextTurnModels() {
        let presentation = AgentDispatchTaskModelPresentation.resolve(
            activeTurnModelID: "deepseek-v4-flash",
            configuredModelID: "gpt-5.6-sol",
            persistedModelID: "deepseek-v4-flash"
        )

        #expect(presentation.currentModelID == "deepseek-v4-flash")
        #expect(presentation.nextModelID == "gpt-5.6-sol")
        #expect(presentation.switchAppliesNextTurn)
    }

    @Test("空闲节点直接展示已经切换的模型")
    func modelPresentationUsesConfiguredModelWhenIdle() {
        let presentation = AgentDispatchTaskModelPresentation.resolve(
            activeTurnModelID: nil,
            configuredModelID: "gpt-5.6-terra",
            persistedModelID: "deepseek-v4-flash"
        )

        #expect(presentation.currentModelID == "gpt-5.6-terra")
        #expect(presentation.nextModelID == "gpt-5.6-terra")
        #expect(!presentation.switchAppliesNextTurn)
    }

    @Test("旧任务缺少运行时覆盖时回退到持久化模型")
    func modelPresentationFallsBackToPersistedModel() {
        let presentation = AgentDispatchTaskModelPresentation.resolve(
            activeTurnModelID: "  ",
            configuredModelID: nil,
            persistedModelID: "kimi-k3"
        )

        #expect(presentation.currentModelID == "kimi-k3")
        #expect(presentation.nextModelID == "kimi-k3")
        #expect(!presentation.switchAppliesNextTurn)
    }

    @Test("节点指标只统计 assistant 侧的完整 provider 用量")
    func metricsUseProviderTurnTotalsWithoutDoubleCountingUserText() throws {
        let now = Date()
        let session = AgentSession(
            title: "dispatch task",
            modelID: "gpt-4o-mini",
            providerID: "openai",
            createdAt: now.addingTimeInterval(-632),
            updatedAt: now,
            messages: [
                AgentMessage(
                    role: .user,
                    content: String(repeating: "user prompt ", count: 500),
                    createdAt: now.addingTimeInterval(-620)
                ),
                AgentMessage(
                    role: .assistant,
                    content: "done",
                    usageTokens: 1_500,
                    promptTokens: 1_000,
                    completionTokens: 500,
                    elapsedSeconds: 12,
                    createdAt: now.addingTimeInterval(-12)
                ),
            ]
        )
        let task = AgentDispatchTask(title: "实现节点", state: .running)

        let metrics = AgentDispatchTaskMetrics.make(task: task, session: session, now: now)

        #expect(metrics.totalTokens == 1_500)
        #expect(metrics.duration == 632)
        #expect(metrics.hasEstimatedTokens == false)
        #expect(try #require(metrics.estimatedCostUSD) > 0)
        #expect(metrics.hasUnpricedUsage == false)
    }

    @Test("外部 CLI 的黑盒用量显示估算标记但不伪造费用")
    func delegatedExternalUsageRemainsUnpriced() {
        let now = Date()
        let session = AgentSession(
            title: "external dispatch task",
            modelID: "gpt-5",
            providerID: "openai",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now,
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: String(repeating: "external output ", count: 40),
                    origin: .delegatedExternal,
                    originLabel: "Claude Code",
                    createdAt: now
                ),
            ]
        )
        let task = AgentDispatchTask(title: "CLI 节点", state: .reviewing)

        let metrics = AgentDispatchTaskMetrics.make(task: task, session: session, now: now)

        #expect((metrics.totalTokens ?? 0) > 0)
        #expect(metrics.hasEstimatedTokens)
        #expect(metrics.estimatedCostUSD == nil)
        #expect(metrics.hasUnpricedUsage)
    }

    @Test("节点重试累计全部运行会话的用量与执行时间")
    func retriedTaskMetricsAccumulateEveryAttempt() throws {
        let now = Date()
        let firstID = UUID()
        let secondID = UUID()
        let first = AgentSession(
            id: firstID,
            title: "first attempt",
            modelID: "gpt-4o-mini",
            providerID: "openai",
            createdAt: now.addingTimeInterval(-180),
            updatedAt: now.addingTimeInterval(-120),
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "failed",
                    usageTokens: 700,
                    promptTokens: 500,
                    completionTokens: 200,
                    createdAt: now.addingTimeInterval(-120)
                ),
            ]
        )
        let second = AgentSession(
            id: secondID,
            title: "second attempt",
            modelID: "gpt-4o-mini",
            providerID: "openai",
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now,
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "retrying",
                    usageTokens: 300,
                    promptTokens: 200,
                    completionTokens: 100,
                    createdAt: now
                ),
            ]
        )
        let task = AgentDispatchTask(
            title: "重试节点",
            state: .running,
            runtimeSessionID: secondID,
            runtimeSessionIDs: [firstID, secondID]
        )

        let metrics = AgentDispatchTaskMetrics.make(
            task: task,
            sessions: [first, second],
            now: now
        )

        #expect(metrics.totalTokens == 1_000)
        #expect(metrics.duration == 90)
        #expect(try #require(metrics.estimatedCostUSD) > 0)
    }

    @Test("已完成节点不把后续会话元数据更新时间计入执行耗时")
    func completedTaskDurationStopsAtFinalMessageEnd() {
        let now = Date()
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            title: "completed dispatch task",
            modelID: "gpt-4o-mini",
            providerID: "openai",
            createdAt: now.addingTimeInterval(-5 * 3_600),
            updatedAt: now,
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "done",
                    elapsedSeconds: 15,
                    createdAt: now.addingTimeInterval(-5 * 3_600 + 45)
                ),
            ]
        )
        let task = AgentDispatchTask(
            title: "已完成节点",
            state: .merged,
            runtimeSessionID: sessionID,
            runtimeSessionIDs: [sessionID]
        )

        let metrics = AgentDispatchTaskMetrics.make(
            task: task,
            sessions: [session],
            now: now
        )

        #expect(metrics.duration == 60)
    }

    @Test("无运行记录的排队节点不冒充已有消耗")
    func queuedTaskWithoutUsageShowsEmptyMetrics() {
        let metrics = AgentDispatchTaskMetrics.make(
            task: AgentDispatchTask(title: "排队节点"),
            session: AgentSession(title: "empty")
        )

        #expect(metrics == .empty)
    }

    @Test("节点指标使用紧凑但不损失有效小数的格式")
    func compactMetricFormattingPreservesUsefulPrecision() {
        #expect(AgentDispatchMetricFormatting.tokenCount(18_400) == "18.4k")
        #expect(AgentDispatchMetricFormatting.tokenCount(12_000) == "12k")
        #expect(AgentDispatchMetricFormatting.tokenCount(nil) == L10n.Dispatch.metricUnavailable)
    }

    @Test("任务会话保留干预证据工具并向浏览器专家开放内置浏览器")
    func taskToolPolicyIncludesRuntimeBrowserForBrowserExpert() {
        let primary = AgentDispatchTaskToolPolicy.primaryKinds(
            hasPlan: true,
            activeExperts: [.browserOps]
        )
        let overflow = AgentDispatchTaskToolPolicy.overflowKinds(activeExperts: [.browserOps])

        #expect(primary == [.plan, .files, .terminal, .diff])
        #expect(overflow == [.preview, .embeddedBrowser, .widget])
        #expect(!primary.contains(.mediaTasks))
        #expect(!primary.contains(.embeddedBrowser))
        #expect(!overflow.contains(.imageEditor))
    }

    @Test("调度节点默认启用浏览器专家并优先使用 runtime 内置浏览器")
    func dispatchRuntimeEnablesAndPromptsForEmbeddedBrowser() {
        let experts = AppState.dispatchTaskExperts(from: [])
        let goal = AgentDispatchGoal(
            id: UUID(),
            sessionID: UUID(),
            title: "Web 验收",
            statement: "验证网页交互",
            tasks: [],
            executorChoice: .automatic,
            targetChoice: .local,
            isPaused: false,
            commands: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        let task = AgentDispatchTask(
            title: "检查页面",
            acceptanceCriteria: ["表单可以提交"]
        )
        let prompt = AppState.dispatchTaskPrompt(
            goal: goal,
            task: task,
            workspaceLocation: .local(path: "/tmp/project")
        )

        #expect(experts.contains(.browserOps))
        #expect(prompt.contains("embedded_browser_*"))
        #expect(prompt.contains("Use Playwright"))
    }

    @Test("并行调度节点拥有互不抢页的独立内置浏览器")
    func dispatchRuntimesOwnIndependentEmbeddedBrowsers() async throws {
        let firstID = UUID()
        let secondID = UUID()
        defer {
            AgentEmbeddedBrowserController.release(for: firstID)
            AgentEmbeddedBrowserController.release(for: secondID)
        }

        let first = AgentEmbeddedBrowserController.controller(for: firstID)
        let sameFirst = AgentEmbeddedBrowserController.controller(for: firstID)
        let second = AgentEmbeddedBrowserController.controller(for: secondID)

        #expect(first === sameFirst)
        #expect(first !== second)
        #expect(!first.isReady)
        #expect(!second.isReady)

        _ = try await AgentEmbeddedBrowserTools.navigate(
            arguments: [
                "url": .string(
                    "data:text/html,%3Cp%20id%3D%22ready%22%3EBackground%20ready%3C%2Fp%3E"
                ),
            ],
            runtimeID: firstID
        )
        let waitResult = try await AgentEmbeddedBrowserTools.waitFor(
            arguments: [
                "condition": .string("text"),
                "value": .string("Background ready"),
                // What is under test is that each node gets its own browser,
                // not how fast WebKit paints. 3s was enough on an idle box and
                // lost the whole test under a full-load parallel run.
                "timeout_ms": .number(20_000),
            ],
            runtimeID: firstID
        )

        #expect(first.isReady)
        #expect(!second.isReady)
        #expect(waitResult.payload.contains("\"matched\" : true"))
        #expect(AgentEmbeddedBrowserController.hasController(for: firstID))
        #expect(AgentEmbeddedBrowserController.hasController(for: secondID))
    }

    @Test("停止单个节点只叫停该节点，不暂停整个项目，且监听不再回写状态")
    func stoppingOneNodeCancelsItWithoutPausingTheProject() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let rootTaskID = UUID()
        let downstreamTaskID = UUID()
        let appState = AppState()
        appState.agentDispatchCoordinator.resetForTests()
        let projectSession = appState.startDispatchGoalSession(inWorkspaceAt: workspace.path)
        let projectRuntime = try #require(appState.runtime(for: projectSession.id))
        projectRuntime.currentGoal = AgentGoal(
            statement: "停止单个节点",
            checklist: [AgentGoal.Item(text: "全部节点完成")],
            dispatchPlan: AgentGoalDispatchPlan(nodes: [
                .init(
                    id: rootTaskID,
                    key: "ROOT-1",
                    title: "首节点",
                    dependencyIDs: [],
                    primaryProfileID: nil,
                    fallbackProfileIDs: [],
                    acceptanceCriteria: ["首节点完成"]
                ),
                .init(
                    id: downstreamTaskID,
                    key: "NEXT-1",
                    title: "后续节点",
                    dependencyIDs: [rootTaskID],
                    primaryProfileID: nil,
                    fallbackProfileIDs: [],
                    acceptanceCriteria: ["后续节点完成"]
                ),
            ])
        )
        appState.persistAgentSession(runtime: projectRuntime)
        appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)

        let childSession = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        let childRuntime = try #require(appState.runtime(for: childSession.id))
        childRuntime.session.dispatchParentProjectID = projectSession.id
        childRuntime.session.dispatchTaskID = rootTaskID
        // 验收全绿：监听一旦还活着就会把节点写成 merged 并解锁下游，
        // 用它来证明停止之后监听确实退租了。
        childRuntime.currentGoal = AgentGoal(
            statement: "完成首节点",
            checklist: [AgentGoal.Item(text: "验收通过", done: true)]
        )
        appState.persistAgentSession(runtime: childRuntime)
        appState.agentDispatchCoordinator.markTaskStarted(
            goalID: projectSession.id,
            taskID: rootTaskID,
            executor: .willDeep,
            target: .local,
            runtimeSessionID: childSession.id
        )

        childRuntime.isResponding = true
        childRuntime.input = "继续处理"
        #expect(appState.sendDispatchTaskTakeoverInstruction(
            goalID: projectSession.id,
            taskID: rootTaskID,
            runtimeSessionID: childSession.id
        ))
        #expect(appState.dispatchMonitoredRuntimeIDsByTaskID[rootTaskID] == childSession.id)

        #expect(appState.stopDispatchTask(goalID: projectSession.id, taskID: rootTaskID))

        let stoppedGoal = try #require(
            appState.agentDispatchCoordinator.goals.first(where: { $0.id == projectSession.id })
        )
        #expect(stoppedGoal.tasks.first(where: { $0.id == rootTaskID })?.state == .cancelled)
        #expect(!stoppedGoal.isPaused)
        #expect(appState.dispatchMonitoredRuntimeIDsByTaskID[rootTaskID] == nil)
        #expect(!childRuntime.shouldConsumeQueueAfterStop)

        childRuntime.isResponding = false
        try await Task.sleep(for: .milliseconds(700))

        let tasks = try #require(
            appState.agentDispatchCoordinator.goals
                .first(where: { $0.id == projectSession.id })?.tasks
        )
        #expect(tasks.first(where: { $0.id == rootTaskID })?.state == .cancelled)
        #expect(tasks.first(where: { $0.id == downstreamTaskID })?.state == .blocked)
    }

    @Test("调度台启动节点不会把操作员甩进普通聊天界面")
    func launchingDispatchRuntimeKeepsOperatorOnTheBoard() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-dispatch-destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState()
        appState.agentPrimaryDestination = .dispatchBoard

        let taskSession = appState.withPreservedAgentPrimaryDestination {
            appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        }
        #expect(appState.activeAgentSessionID == taskSession.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)

        // 对照组：普通「新建聊天」照旧切到会话界面，包裹的存在才有意义。
        _ = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        #expect(appState.agentPrimaryDestination == .conversation)
    }

    @Test("回车发送、修饰键换行、输入法组字期间的回车属于候选词上屏")
    func returnKeySubmitsUnlessModifiedOrComposing() {
        #expect(SubmitOnReturnKeyPolicy.submits(modifiers: [], hasMarkedText: false))
        #expect(!SubmitOnReturnKeyPolicy.submits(modifiers: [.shift], hasMarkedText: false))
        #expect(!SubmitOnReturnKeyPolicy.submits(modifiers: [.option], hasMarkedText: false))
        #expect(!SubmitOnReturnKeyPolicy.submits(modifiers: [.control], hasMarkedText: false))
        #expect(!SubmitOnReturnKeyPolicy.submits(modifiers: [], hasMarkedText: true))
        #expect(SubmitOnReturnKeyPolicy.submits(modifiers: [.capsLock], hasMarkedText: false))
    }

    @Test("窄窗口下侧栏收窄让位，任务图不会被整列挤没")
    func sidePanelWidthAlwaysLeavesRoomForTheGraph() {
        let takeover = AgentDispatchBoardLayout.preferredTakeoverWidth
        let inspector = AgentDispatchBoardLayout.preferredInspectorWidth
        let graphFloor = AgentDispatchBoardLayout.minimumGraphWidth
        let panelFloor = AgentDispatchBoardLayout.minimumPanelWidth

        // 宽窗口：按理想宽度，行为与改动前一致。
        #expect(
            AgentDispatchBoardLayout.sidePanelWidth(
                availableWidth: 1_280,
                preferredWidth: takeover
            ) == takeover
        )
        #expect(
            AgentDispatchBoardLayout.sidePanelWidth(
                availableWidth: 1_280,
                preferredWidth: inspector
            ) == inspector
        )

        // 中等宽度：抽屉收窄，任务图正好拿到保底宽度。
        let mediumWidth = AgentDispatchBoardLayout.sidePanelWidth(
            availableWidth: 560,
            preferredWidth: takeover
        )
        #expect(mediumWidth < takeover)
        #expect(560 - mediumWidth >= graphFloor)

        // 截图里那种约 420pt 的窄窗口：抽屉不得吃满整宽，且不低于可读下限。
        let narrowWidth = AgentDispatchBoardLayout.sidePanelWidth(
            availableWidth: 427,
            preferredWidth: takeover
        )
        #expect(narrowWidth == panelFloor)
        #expect(narrowWidth < 427)
        #expect(427 - narrowWidth > 0)

        // 首帧还没量到尺寸时按理想宽度渲染，避免闪一帧窄面板。
        #expect(
            AgentDispatchBoardLayout.sidePanelWidth(
                availableWidth: 0,
                preferredWidth: takeover
            ) == takeover
        )
        // 极端退化宽度下也不得溢出容器。
        #expect(
            AgentDispatchBoardLayout.sidePanelWidth(
                availableWidth: 180,
                preferredWidth: takeover
            ) == 180
        )
    }

    @Test("调度台抽屉选中任务会话时不离开调度台")
    func takeoverSelectionPreservesDispatchDestination() {
        let appState = AppState()
        let first = appState.startNewAgentSession()
        let second = appState.startNewAgentSession()
        #expect(appState.activeAgentSessionID == second.id)

        appState.agentPrimaryDestination = .dispatchBoard
        #expect(
            appState.selectAgentSession(
                id: first.id,
                preservingPrimaryDestination: true
            )
        )

        #expect(appState.activeAgentSessionID == first.id)
        #expect(appState.agentPrimaryDestination == .dispatchBoard)
    }
}
