//
//  AgentContextUsageSnapshotTests.swift
//  WillDeepTests
//
//  状态栏圆环（A）与 Compress 按钮（B）的口径回归：同一份 usage 快照上，
//  圆环、按钮门槛、自动压缩判定（C）与 runway 暂停指令（D）必须共用
//  裸 used/window 一个比值。历史事故：圆环双向扣减 baseline 显示 30%，
//  runway 同时按裸口径告诉模型 92%。
//

import WillDeepCore
import Testing

@testable import WillDeep

@Suite("Agent context usage snapshot")
struct AgentContextUsageSnapshotTests {
    @Test("圆环比值是裸 used/window，不再双向扣减 baseline")
    func ringFractionIsBareUsedOverWindow() {
        let snapshot = AgentContextTokenUsageSnapshot(
            usedTokens: 92_000,
            baselineTokens: 60_000,
            contextWindow: 100_000
        )
        // 旧的双向扣减口径会得出 (92k−60k)/(100k−60k) = 80%；更极端的
        // baseline 占比下同一快照曾显示 30%。裸口径下就是 92%。
        #expect(snapshot.usedFraction == 0.92)
        #expect(Int(snapshot.usedFraction * 100) == 92)
    }

    @Test("同一组数字下圆环百分比与 runway 暂停指令的百分比一致")
    func ringPercentMatchesRunwayHandoffPercent() {
        let usedTokens = 933_120
        let contextWindow = 1_000_000
        let ring = AgentContextTokenUsageSnapshot(
            usedTokens: usedTokens,
            baselineTokens: 220_000,
            contextWindow: contextWindow
        )
        let runway = AgentContextRunwayPolicy.Snapshot(
            usedTokens: usedTokens,
            contextWindow: contextWindow
        )
        #expect(Int(ring.usedFraction * 100) == runway.usedPercent)
    }

    @Test("比值夹在 [0,1]，零窗口不崩")
    func fractionClampsAndSurvivesZeroWindow() {
        let overflowing = AgentContextTokenUsageSnapshot(
            usedTokens: 500_000,
            baselineTokens: 0,
            contextWindow: 128_000
        )
        #expect(overflowing.usedFraction == 1)
        let degenerate = AgentContextTokenUsageSnapshot(
            usedTokens: 0,
            baselineTokens: 0,
            contextWindow: 0
        )
        #expect(degenerate.usedFraction == 0)
    }

    @Test("对话/基线细分只进 tooltip：拆分自洽且 baseline 超过 used 时夹紧")
    func tooltipBreakdownStaysConsistent() {
        let snapshot = AgentContextTokenUsageSnapshot(
            usedTokens: 80_000,
            baselineTokens: 30_000,
            contextWindow: 200_000
        )
        #expect(snapshot.conversationTokens == 50_000)
        #expect(snapshot.displayBaselineTokens == 30_000)
        #expect(snapshot.remainingTokens == 120_000)
        #expect(snapshot.conversationTokens + snapshot.displayBaselineTokens == snapshot.usedTokens)

        // provider 锚定的 used 可能短暂落后于刚变大的 baseline 估算；
        // 显示层夹紧，不产生负的对话净占用。
        let lagging = AgentContextTokenUsageSnapshot(
            usedTokens: 10_000,
            baselineTokens: 30_000,
            contextWindow: 200_000
        )
        #expect(lagging.displayBaselineTokens == 10_000)
        #expect(lagging.conversationTokens == 0)
    }

    @Test("Compress 按钮门槛与圆环同口径：>50% 且消息数 >6")
    func manualCompressOfferUsesBareFraction() {
        let pastHalf = AgentContextTokenUsageSnapshot(
            usedTokens: 51_000,
            baselineTokens: 40_000,
            contextWindow: 100_000
        )
        #expect(pastHalf.shouldOfferManualCompression(messageCount: 7) == true)
        #expect(pastHalf.shouldOfferManualCompression(messageCount: 6) == false)

        // 旧圆环口径下 (51k−40k)/(100k−40k) ≈ 18%——若按钮跟着那套算式
        // 就永远不出现。裸口径 51% 越线，按钮出现。
        let atHalf = AgentContextTokenUsageSnapshot(
            usedTokens: 50_000,
            baselineTokens: 0,
            contextWindow: 100_000
        )
        #expect(atHalf.shouldOfferManualCompression(messageCount: 40) == false)
    }

    @Test("自动压缩分母用后台 runtime 自己的窗口，不借前台会话的")
    @MainActor
    func autoCompressDenominatorFollowsRuntimeOwnWindow() {
        let appState = AppState()

        // 用 custom preset 的 provider entry 钉死模型名：custom 不受
        // `normalized` 的陈旧模型重置（真实 preset 会把认不出的 id 重置
        // 成家族默认），也不依赖本机 Settings 里配了哪个 provider。
        let entry16k = AgentProviderEntry(
            providerID: AgentProviderPreset.customID,
            baseURL: "https://example.invalid/v1",
            flashPrimary: "test-model-16k",
            proPrimary: "test-model-16k",
            routingMode: .flash
        )
        let entry1M = AgentProviderEntry(
            providerID: AgentProviderPreset.customID,
            baseURL: "https://example.invalid/v1",
            flashPrimary: "test-model-1m",
            proPrimary: "test-model-1m",
            routingMode: .flash
        )
        appState.agentProviderLibrary.entries.append(contentsOf: [entry16k, entry1M])

        // 后台会话：16k 窗口的小模型。
        let backgroundSession = appState.startNewAgentSession()
        guard let backgroundRuntime = appState.agentRuntimes[backgroundSession.id] else {
            Issue.record("background runtime missing after startNewAgentSession")
            return
        }
        backgroundRuntime.sessionProviderEntryID = entry16k.id

        // 前台（active）会话：1M 窗口的大模型。
        let foregroundSession = appState.startNewAgentSession()
        appState.agentRuntimes[foregroundSession.id]?.sessionProviderEntryID = entry1M.id

        // 后台会话塞入 ~24k tokens（96k ASCII chars），远超 16k 窗口的
        // 75%，但只占 1M 窗口的 ~3%。
        let bigChunk = String(repeating: "a", count: 12_000)
        for _ in 0..<8 {
            backgroundRuntime.messages.append(AgentMessage(role: .user, content: bigChunk))
        }

        #expect(appState.agentContextWindow(for: backgroundRuntime) == 16_000)
        // 分母若错借前台 1M 窗口，这里会是 false，后台会话永远不自动压缩。
        #expect(appState.shouldAutoCompressNow(for: backgroundRuntime) == true)
        // 同一时刻前台自己的窗口仍按前台模型解析。
        #expect(appState.agentContextWindow == 1_000_000)
    }
}
