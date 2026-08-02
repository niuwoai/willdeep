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
