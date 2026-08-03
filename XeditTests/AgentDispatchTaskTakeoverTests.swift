//
//  AgentDispatchTaskTakeoverTests.swift
//  WillDeepTests
//


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

    @Test("任务会话只保留干预和证据工具")
    func taskToolPolicyHidesUnrelatedUtilities() {
        let primary = AgentDispatchTaskToolPolicy.primaryKinds(
            hasPlan: true,
            activeExperts: []
        )
        let overflow = AgentDispatchTaskToolPolicy.overflowKinds(activeExperts: [])

        #expect(primary == [.plan, .files, .terminal, .diff])
        #expect(overflow == [.preview, .widget])
        #expect(!primary.contains(.mediaTasks))
        #expect(!primary.contains(.embeddedBrowser))
        #expect(!overflow.contains(.imageEditor))
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
