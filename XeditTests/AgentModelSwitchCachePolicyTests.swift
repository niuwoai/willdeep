import Foundation
import Testing
@testable import WillDeep

/// 真实事故（客户日志，2026-09-10）：同一个会话里从 deepseek-v4-flash 换到
/// deepseek-v4-pro，切换前一条请求 578k token、命中缓存 578k、首响应 5.1 秒；
/// 切换后第一条 586k token、**命中 0**、首响应 85.1 秒。缓存随即重建，后面
/// 又回到 6 到 8 秒。用户只看到「忽然变慢了」，没法把它和一次看起来免费的
/// 模型切换连起来。
@Suite
struct AgentModelSwitchCachePolicyTests {
    @Test("上下文够大时才提醒，小会话保持安静")
    func warnsOnlyWhenTheContextIsLarge() {
        let threshold = AgentModelSwitchCachePolicy.warningTokenThreshold
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: threshold) != nil)
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: threshold - 1) == nil)
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: 0) == nil)
        // 读不到 provider 的真实用量时不猜：宁可不提醒，也不要按一个估算值
        // 去吓唬人。
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: nil) == nil)
    }

    /// 门槛必须落在那两个真实样本之间：16.4 万冷预填只用了 4.3 秒，没什么好
    /// 说的；58.6 万用了 85.1 秒，必须说。
    @Test("门槛落在观测到的两个样本之间")
    func thresholdSitsBetweenTheObservedSamples() {
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: 163_913) == nil)
        #expect(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: 585_622) != nil)
    }

    @Test("提醒里带上量级，并且不承诺具体秒数")
    func warningStatesTheScaleWithoutPromisingSeconds() throws {
        let warning = try #require(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: 585_622))
        #expect(warning.contains("586k"))
        // 冷预填有多慢取决于 provider 吞吐。给一个站不住的秒数比不给更糟。
        #expect(!warning.contains("秒"))
        #expect(!warning.lowercased().contains("second"))
    }

    @Test("量级按数量级取整，百万级换单位")
    func tokenScaleRoundsByMagnitude() {
        #expect(AgentModelSwitchCachePolicy.approximateTokens(585_622) == "586k")
        #expect(AgentModelSwitchCachePolicy.approximateTokens(200_000) == "200k")
        #expect(AgentModelSwitchCachePolicy.approximateTokens(1_240_000) == "1.2M")
        #expect(AgentModelSwitchCachePolicy.approximateTokens(1_000_000) == "1.0M")
    }

    /// 提醒是**追加**在原有那句后面的，不是替换。切换本身仍然要说清楚，
    /// 否则大会话里用户就看不到自己换到了哪个模型。
    @Test("提醒追加在原有的切换说明之后")
    @MainActor
    func warningIsAppendedToTheExistingNotice() throws {
        let changed = L10n.AgentModelPicker.modelChanged(from: "deepseek-v4-flash", to: "deepseek-v4-pro")
        let warning = try #require(AgentModelSwitchCachePolicy.cacheWarning(usedTokens: 585_622))
        let combined = [changed, warning].joined(separator: " ")
        #expect(combined.hasPrefix(changed))
        #expect(combined.contains("deepseek-v4-pro"))
        #expect(combined.contains("586k"))
    }
}
