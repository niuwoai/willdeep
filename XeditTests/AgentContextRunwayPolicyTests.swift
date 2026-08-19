//
//  AgentContextRunwayPolicyTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

@Suite("Context runway handoff")
struct AgentContextRunwayPolicyTests {
    @Test("首轮请求即使很大也先让模型处理用户请求")
    func firstRoundIsNeverPreempted() {
        let decision = AgentContextRunwayPolicy.evaluate(
            usedTokens: 99_000,
            contextWindow: 100_000,
            toolRound: 0,
            handoffAlreadyRequested: false
        )
        #expect(decision == .continueExecution)
    }

    @Test("长工具回合达到九成窗口时转入有序交接")
    func laterRoundHandsOffAtCriticalUsage() {
        let decision = AgentContextRunwayPolicy.evaluate(
            usedTokens: 180_000,
            contextWindow: 200_000,
            toolRound: 3,
            handoffAlreadyRequested: false
        )
        #expect(
            decision == .handoff(.init(
                usedTokens: 180_000,
                contextWindow: 200_000
            ))
        )
    }

    @Test("九成以下继续执行且交接不会重复派发")
    func safeUsageContinuesAndHandoffDoesNotRepeat() {
        #expect(
            AgentContextRunwayPolicy.evaluate(
                usedTokens: 179_999,
                contextWindow: 200_000,
                toolRound: 5,
                handoffAlreadyRequested: false
            ) == .continueExecution
        )
        #expect(
            AgentContextRunwayPolicy.evaluate(
                usedTokens: 195_000,
                contextWindow: 200_000,
                toolRound: 5,
                handoffAlreadyRequested: true
            ) == .continueExecution
        )
    }

    @Test("交接提示明确区分同会话压缩与新会话恢复")
    func promptCarriesDurableContinuationContract() {
        let prompt = AgentContextRunwayPolicy.handoffPrompt(
            snapshot: .init(usedTokens: 95_000, contextWindow: 100_000)
        )

        for section in ["PAUSE:", "DONE:", "ANCHORS:", "REMAINING:", "NEXT PROMPT:"] {
            #expect(prompt.contains(section))
        }
        #expect(prompt.contains("Do not call tools"))
        #expect(prompt.contains("full transcript locally"))
        #expect(prompt.contains("does not automatically inherit"))
        #expect(prompt.contains("95000") || prompt.contains("95_000"))
        #expect(prompt.contains("95%"))
    }
}
