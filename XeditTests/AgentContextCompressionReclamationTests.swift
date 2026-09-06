import Testing
@testable import WillDeep

@Suite("压缩必须真实减少上下文并保留执行空间")
struct AgentContextCompressionReclamationTests {
    @Test("非空但没有缩短的摘要不能算回收")
    func rejectsNonShrinkingSummary() {
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 100, summaryTokens: 100, projectedTokens: 200, window: 1_000))
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 100, summaryTokens: 120, projectedTokens: 200, window: 1_000))
    }

    @Test("摘要缩短但尾部及固定开销仍太大时不能自动续跑")
    func rejectsOversizedProjection() {
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 1_000, summaryTokens: 100, projectedTokens: 751, window: 1_000))
    }

    @Test("缩短且达到目标水位才接受")
    func acceptsReclaimedWindow() {
        #expect(AgentContextCompressionReclamation.accepts(sourceTokens: 1_000, summaryTokens: 100, projectedTokens: 750, window: 1_000))
    }

    @Test("缺失或不一致的估算不作为成功证据")
    func invalidEstimatesAreRejected() {
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 0, summaryTokens: 1, projectedTokens: 10, window: 100))
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 100, summaryTokens: 0, projectedTokens: 10, window: 100))
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 100, summaryTokens: 10, projectedTokens: 5, window: 100))
        #expect(!AgentContextCompressionReclamation.accepts(sourceTokens: 100, summaryTokens: 10, projectedTokens: 15, window: 0))
    }
}
