//
//  AgentWorkerMidRunEscalationTests.swift
//  WillDeepTests
//
//  worker 跑到一半撞上下文窗口时，换下一档继续，而不是抛错让整轮重来。
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Worker 中途换档")
nonisolated struct AgentWorkerMidRunEscalationTests {
    private func config(model: String) -> AgentConfiguration {
        AgentConfiguration(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://worker-tier.invalid/v1",
            model: model,
            apiKey: "test"
        )
    }

    /// 观测字段的意义：回答「小模型究竟在多少 token 上撑不住」。此前日志里
    /// 只有升级**之后**的最终数字（那条 24.9 万），跟失败点无关。
    @Test("Outcome 能带出换档时的累计 prompt 与原模型")
    func outcomeCarriesEscalationObservation() {
        var outcome = AgentSubagentRunner.Outcome(
            report: "done",
            usageTokens: 100,
            roundCount: 3,
            toolInvocationCount: 1
        )
        #expect(outcome.midRunEscalationPromptTokens == nil)
        #expect(outcome.midRunEscalatedFromModel == nil)

        outcome.midRunEscalationPromptTokens = 96_000
        outcome.midRunEscalatedFromModel = "someim-32b"
        #expect(outcome.midRunEscalationPromptTokens == 96_000)
        #expect(outcome.midRunEscalatedFromModel == "someim-32b")
    }

    /// timing 日志要能统计，所以这两个值必须是独立字段而不是塞进自由文本的
    /// note 里——note 现在已经被 "escalated from X" 占着，混在一起没法统计。
    @Test("timing 条目独立记录换档观测")
    func timingEntryRecordsEscalationFields() {
        let entry = AgentWorkerTimingLog.WorkerRunEntry(
            runID: UUID(),
            sessionID: UUID(),
            userMessageID: nil,
            profileID: "ops_runner",
            source: "modelSpawn",
            status: "completed",
            model: "someim-auto-flash",
            providerID: "some-im",
            requestedAt: Date(),
            startedAt: Date(),
            finishedAt: Date(),
            midRunEscalationPromptTokens: 96_000,
            midRunEscalatedFromModel: "someim-32b"
        )
        #expect(entry.midRunEscalationPromptTokens == 96_000)
        #expect(entry.midRunEscalatedFromModel == "someim-32b")
        #expect(entry.note == nil)
    }

    /// 档位链是换档的唯一依据，方向不能反。
    @Test("档位链方向固定")
    func tierChainGoesOneWay() {
        #expect(AgentWorkerTier.standard.next == .advanced)
        #expect(AgentWorkerTier.advanced.next == .expert)
        #expect(AgentWorkerTier.expert.next == nil)
    }

    /// 没有下一档时不该假装能换——最高档撞窗就是任务本身超出了这条链。
    @Test("最高档没有下一档可换")
    func expertTierHasNowhereToEscalate() {
        #expect(AgentWorkerTier.expert.next == nil)
    }

    /// 同一个模型不算「下一档」：换了也过不了同一道校验，只是白切一次。
    @Test("同模型不构成换档")
    func sameModelIsNotAnEscalation() {
        let a = config(model: "someim-32b")
        let b = config(model: "someim-32b")
        #expect(AppState.sameWorkerModel(a, b))

        let c = config(model: "someim-auto-flash")
        #expect(!AppState.sameWorkerModel(a, c))
    }
}
