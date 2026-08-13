//
//  AgentGoalContinuationBudgetTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Goal continuation budget")
struct AgentGoalContinuationBudgetTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func budget(
        wallClockLimit: TimeInterval? = nil,
        maximumContinuations: Int = 64,
        segmentStartedAt: Date? = nil,
        continuationsUsed: Int = 0,
        wrapUpDispatched: Bool = false
    ) -> AgentGoalContinuationBudget {
        AgentGoalContinuationBudget(
            wallClockLimit: wallClockLimit,
            maximumContinuations: maximumContinuations,
            segmentStartedAt: segmentStartedAt,
            continuationsUsed: continuationsUsed,
            wrapUpDispatched: wrapUpDispatched
        )
    }

    @Test("首次判定会开启预算窗口并继续执行")
    func firstEvaluationOpensTheSegment() {
        let result = AgentGoalContinuationPolicy.evaluate(
            budget: budget(),
            now: now,
            consecutiveRoundsWithoutProgress: 0
        )
        #expect(result.outcome == .continueExecution(rung: .guidance))
        #expect(result.budget.segmentStartedAt == now)
        #expect(result.budget.continuationsUsed == 1)
    }

    @Test("无进展轮次沿阶梯升级，但结论始终是继续")
    func stallingEscalatesThroughTheLadder() {
        let rungs = (1...6).map { rounds in
            AgentGoalContinuationPolicy.rung(forRoundsWithoutProgress: rounds)
        }
        #expect(rungs == [.guidance, .guidance, .reconcile, .reconcile, .backoff, .backoff])

        let stalled = AgentGoalContinuationPolicy.evaluate(
            budget: budget(segmentStartedAt: now, continuationsUsed: 9),
            now: now,
            consecutiveRoundsWithoutProgress: 6
        )
        #expect(stalled.outcome == .continueExecution(rung: .backoff))
    }

    @Test("对账与退避档携带额外约束，引导档不加噪音")
    func escalationTextOnlyAppearsWhenItEarnsItsPlace() {
        #expect(AgentGoalContinuationPolicy.escalation(for: .guidance) == nil)
        #expect(
            AgentGoalContinuationPolicy.escalation(for: .reconcile)?
                .contains("git status") == true
        )
        #expect(
            AgentGoalContinuationPolicy.escalation(for: .backoff)?
                .contains("waiting on") == true
        )
    }

    @Test("wall-clock 用尽转入软停")
    func wallClockExhaustionSoftStops() {
        let result = AgentGoalContinuationPolicy.evaluate(
            budget: budget(
                wallClockLimit: 60,
                segmentStartedAt: now.addingTimeInterval(-61)
            ),
            now: now,
            consecutiveRoundsWithoutProgress: 0
        )
        #expect(result.outcome == .wrapUp(reason: .wallClock))
        #expect(result.budget.wrapUpDispatched)
    }

    @Test("续推次数用尽转入软停")
    func continuationExhaustionSoftStops() {
        let result = AgentGoalContinuationPolicy.evaluate(
            budget: budget(
                maximumContinuations: 3,
                segmentStartedAt: now,
                continuationsUsed: 3
            ),
            now: now,
            consecutiveRoundsWithoutProgress: 0
        )
        #expect(result.outcome == .wrapUp(reason: .continuations))
        #expect(result.budget.wrapUpDispatched)
    }

    @Test("窗口未到期时不会因为耗时而停")
    func timeWithinTheSegmentKeepsExecuting() {
        let result = AgentGoalContinuationPolicy.evaluate(
            budget: budget(
                wallClockLimit: 3_600,
                segmentStartedAt: now.addingTimeInterval(-600)
            ),
            now: now,
            consecutiveRoundsWithoutProgress: 1
        )
        #expect(result.outcome == .continueExecution(rung: .guidance))
        #expect(result.budget.wrapUpDispatched == false)
    }

    @Test("交接已交付后停在原地，不再反复追问")
    func haltAfterHandoverWasDelivered() {
        let result = AgentGoalContinuationPolicy.evaluate(
            budget: budget(segmentStartedAt: now, continuationsUsed: 4, wrapUpDispatched: true),
            now: now,
            consecutiveRoundsWithoutProgress: 9
        )
        #expect(result.outcome == .halt)
        #expect(result.budget.continuationsUsed == 4)
    }

    @Test("续期保留限额但清空已用额度")
    func restartingKeepsLimitsAndDropsSpend() {
        let restarted = budget(
            wallClockLimit: 120,
            maximumContinuations: 7,
            segmentStartedAt: now,
            continuationsUsed: 6,
            wrapUpDispatched: true
        ).restarted
        #expect(restarted.wallClockLimit == 120)
        #expect(restarted.maximumContinuations == 7)
        #expect(restarted.continuationsUsed == 0)
        #expect(restarted.wrapUpDispatched == false)
        #expect(restarted.segmentStartedAt == nil)
    }

    @Test("交接提示包含全部交接分节与未完成验收项")
    func handoverPromptCarriesEveryHandoverSection() {
        let prompt = AgentGoalContinuationPolicy.wrapUpPrompt(
            remainingAcceptance: ["Tests pass", "Docs updated"]
        )
        for section in ["STATE:", "DONE:", "REMAINING:", "BLOCKERS:", "NEXT:"] {
            #expect(prompt.contains(section))
        }
        #expect(prompt.contains("Tests pass"))
        #expect(prompt.contains("Docs updated"))
        #expect(prompt.contains("no new edits"))
    }

    @Test("默认预算随 Goal 编解码往返")
    func budgetSurvivesGoalCoding() throws {
        var goal = AgentGoal(statement: "Ship", checklist: [.init(text: "Verified")])
        goal.continuationBudget = budget(
            wallClockLimit: 90,
            maximumContinuations: 5,
            segmentStartedAt: now,
            continuationsUsed: 2
        )
        let data = try JSONEncoder().encode(goal)
        let decoded = try JSONDecoder().decode(AgentGoal.self, from: data)
        #expect(decoded.continuationBudget == goal.continuationBudget)
    }

    @Test("旧会话没有预算字段也能解码")
    func legacyGoalWithoutBudgetStillDecodes() throws {
        let json = #"{"statement":"Ship","checklist":[]}"#
        let decoded = try JSONDecoder().decode(
            AgentGoal.self,
            from: Data(json.utf8)
        )
        #expect(decoded.continuationBudget == nil)
        #expect(decoded.statement == "Ship")
    }
}
