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

    /// The handover is now the input to an automatic resume, not just advice
    /// for the user. It has to say so, and it has to warn that anything left
    /// unwritten is lost once compression replaces the old turns.
    @Test("交接提示告知会自动续跑，并提醒锚点必须落在文字里")
    func handoffPromptAnnouncesAutomaticResume() {
        let prompt = AgentContextRunwayPolicy.handoffPrompt(
            snapshot: .init(usedTokens: 95_000, contextWindow: 100_000)
        )

        #expect(prompt.contains("resume the work automatically"))
        #expect(prompt.contains("written into ANCHORS now or it is gone"))
    }

    /// Resumption points the model back at its own handover instead of
    /// restating the task — the handover survives compression in the kept
    /// tail, and re-describing it would just spend the window again.
    @Test("续跑提示指回自己的交接，且报出第几次续跑与上限")
    func resumePromptDefersToTheHandover() {
        let prompt = AgentContextRunwayPolicy.resumePrompt(attempt: 2)

        #expect(prompt.contains("NEXT PROMPT"))
        #expect(prompt.contains("REMAINING"))
        #expect(prompt.contains("ANCHORS"))
        #expect(prompt.contains("do not start over"))
        // The model should be able to tell how much rope is left.
        #expect(prompt.contains("2"))
        #expect(prompt.contains("\(AgentContextRunwayPolicy.maximumAutomaticResumes)"))
    }

    /// An unattended stop → compress → resume → stop loop spends real money,
    /// so the ceiling must exist and stay small.
    @Test("自动续跑次数有上限")
    func automaticResumesAreCapped() {
        #expect(AgentContextRunwayPolicy.maximumAutomaticResumes >= 1)
        #expect(AgentContextRunwayPolicy.maximumAutomaticResumes <= 5)
    }

    /// Observed failure: the model reasons its way past "do not call tools"
    /// ("reading an already finished job is not new work"). Saying the host
    /// refuses the call removes the argument.
    @Test("交接提示声明工具调用会被宿主拒绝")
    func handoffPromptDeclaresToolCallsAreRefused() {
        let prompt = AgentContextRunwayPolicy.handoffPrompt(
            snapshot: .init(usedTokens: 95_000, contextWindow: 100_000)
        )

        #expect(prompt.contains("Do not call tools"))
        #expect(prompt.contains("refused by the host"))
    }

    @Test("拒绝通知点名被拒工具，并指明该写去哪儿")
    func refusalNoticeNamesTheToolAndRedirectsIt() {
        let notice = AgentContextRunwayPolicy.refusedToolCallNotice(
            toolNames: ["get_job_output"]
        )

        #expect(notice.contains("get_job_output"))
        #expect(notice.contains("did not run"))
        #expect(notice.contains("REMAINING"))
        #expect(notice.contains("NEXT PROMPT"))
    }

    /// The refusal is dispatched from the same round that parsed the calls, so
    /// an empty name list means the round produced calls we could not name —
    /// the notice still has to read as a complete sentence.
    @Test("没有工具名时拒绝通知仍然成句")
    func refusalNoticeReadsWithoutToolNames() {
        let notice = AgentContextRunwayPolicy.refusedToolCallNotice(toolNames: [])

        #expect(notice.contains("The tool call did not run"))
    }

    @Test("markup 丢弃通知说明没有工具运行")
    func discardedMarkupNoticeExplainsNothingRan() {
        let notice = AgentContextRunwayPolicy.discardedMarkupNotice()

        #expect(notice.contains("Nothing ran"))
        #expect(notice.contains("NEXT PROMPT"))
    }

    /// Refusing costs a round out of an already-full window, so the budget has
    /// to be small — but it must exist, or one stubborn model ends the turn
    /// with no handover at all.
    @Test("交接重试次数有上限且不为零")
    func handoverRetriesAreBoundedButPresent() {
        #expect(AgentContextRunwayPolicy.maximumHandoverRetries >= 1)
        #expect(AgentContextRunwayPolicy.maximumHandoverRetries <= 3)
    }
}
