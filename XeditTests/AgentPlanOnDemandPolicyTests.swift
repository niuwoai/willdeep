//
//  AgentPlanOnDemandPolicyTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

@Suite("Plan on demand")
nonisolated struct AgentPlanOnDemandPolicyTests {
    /// The whole point: a task that finishes inside a few rounds never pays
    /// for a plan or its reporting machinery.
    @Test("小任务在阈值之下不触发")
    func smallTurnsNeverTrigger() {
        for round in 0..<AgentPlanOnDemandPolicy.toolRoundThreshold {
            #expect(
                AgentPlanOnDemandPolicy.shouldRequestPlan(
                    toolRound: round,
                    succeededWriteCalls: AgentPlanOnDemandPolicy.succeededWriteCallThreshold - 1,
                    hasActivePlan: false,
                    interactionMode: .normal,
                    isUnattendedDispatchTask: false
                ) == false
            )
        }
    }

    @Test("纯只读调查跑满轮次也不请求计划")
    func readOnlyInvestigationNeverTriggersFromRoundsAlone() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: AgentPlanOnDemandPolicy.toolRoundThreshold,
                succeededWriteCalls: 0,
                hasActivePlan: false,
                interactionMode: .normal,
                isUnattendedDispatchTask: false
            ) == false
        )
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: AgentPlanOnDemandPolicy.toolRoundThreshold * 3,
                succeededWriteCalls: 0,
                hasActivePlan: false,
                interactionMode: .normal,
                isUnattendedDispatchTask: false
            ) == false
        )
    }

    @Test("进入写执行后跑满轮次才请求计划")
    func executionRoundThresholdTriggersAfterWrite() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: AgentPlanOnDemandPolicy.toolRoundThreshold,
                succeededWriteCalls: 1,
                hasActivePlan: false,
                interactionMode: .normal,
                isUnattendedDispatchTask: false
            )
        )
    }

    /// Three landed mutations mark a turn multi-step even when it got there
    /// in fewer rounds than the round threshold.
    @Test("写调用数达标可提前触发")
    func writeCallThresholdTriggersEarly() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: 1,
                succeededWriteCalls: AgentPlanOnDemandPolicy.succeededWriteCallThreshold,
                hasActivePlan: false,
                interactionMode: .normal,
                isUnattendedDispatchTask: false
            )
        )
    }

    @Test("已有活跃计划时不再请求")
    func activePlanSuppressesRequest() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: 10,
                succeededWriteCalls: 10,
                hasActivePlan: true,
                interactionMode: .normal,
                isUnattendedDispatchTask: false
            ) == false
        )
    }

    /// Goal mode's plan is the acceptance loop's skeleton and has its own
    /// always-plan contract; the trip-wire must stay out of it.
    @Test("Goal 模式不走触发线")
    func goalModeIsExcluded() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: 10,
                succeededWriteCalls: 10,
                hasActivePlan: false,
                interactionMode: .goal,
                isUnattendedDispatchTask: false
            ) == false
        )
    }

    /// Dispatch-board tasks are dispatched with their own plan/graph
    /// contract, and the board projects node state from it.
    @Test("无人值守派发任务不走触发线")
    func unattendedDispatchIsExcluded() {
        #expect(
            AgentPlanOnDemandPolicy.shouldRequestPlan(
                toolRound: 10,
                succeededWriteCalls: 10,
                hasActivePlan: false,
                interactionMode: .normal,
                isUnattendedDispatchTask: true
            ) == false
        )
    }

    @Test("请求通知包含计划块、继续执行与 update_plan 三要素")
    func noticeCarriesTheContract() {
        let notice = AgentPlanOnDemandPolicy.requestNotice(toolRound: 5)

        #expect(notice.contains("`plan` fenced block"))
        #expect(notice.contains("REMAINING"))
        #expect(notice.contains("continue executing immediately in the same reply"))
        #expect(notice.contains("not a stopping point"))
        #expect(notice.contains("update_plan"))
        #expect(notice.contains("5 tool rounds"))
        #expect(notice.contains("at least 3 independent steps"))
        #expect(notice.contains("fewer than 3"))
    }

    /// The thresholds are the product decision: small enough that long tasks
    /// still get a visible checklist early, large enough that quick fixes
    /// never see one. Guard the band, not the exact value.
    @Test("阈值停留在小任务免打扰的区间")
    func thresholdsStayInTheAgreedBand() {
        #expect(AgentPlanOnDemandPolicy.toolRoundThreshold >= 3)
        #expect(AgentPlanOnDemandPolicy.toolRoundThreshold <= 6)
        #expect(AgentPlanOnDemandPolicy.succeededWriteCallThreshold >= 2)
        #expect(AgentPlanOnDemandPolicy.succeededWriteCallThreshold <= 5)
        #expect(AgentPlanOnDemandPolicy.minimumVisibleStepCount == 3)
    }
}
