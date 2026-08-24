//
//  AgentPlanSurfaceExclusivityTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

/// The floating plan card and the composer progress pill render the same
/// checklist from the same `agentCurrentPlan`. Exactly one of them may be on
/// screen at a time — the regression this guards is both showing at once for
/// the entire execution.
@Suite("Plan surface exclusivity")
struct AgentPlanSurfaceExclusivityTests {
    private func plan(_ status: AgentPlan.Status, steps: Int = 3) -> AgentPlan {
        AgentPlan(
            status: status,
            summary: "",
            stepTexts: (1...steps).map { "step \($0)" }
        )
    }

    /// The reported bug: a live turn showed the floating card *and* the pill.
    @Test("执行中 composer 有进度条时浮动卡让位")
    func floatingCardYieldsWhileComposerProgressIsUp() {
        let executing = plan(.approved)

        #expect(
            AgentPlanCardExpansionPolicy.shouldDisplayFloatingCard(
                executing,
                isComposerProgressVisible: true
            ) == false
        )
    }

    @Test("回合结束后浮动卡回来，计划仍可查看与操作")
    func floatingCardReturnsWhenTheTurnEnds() {
        for status in [AgentPlan.Status.proposed, .approved, .executing] {
            #expect(
                AgentPlanCardExpansionPolicy.shouldDisplayFloatingCard(
                    plan(status),
                    isComposerProgressVisible: false
                )
            )
        }
    }

    /// A finished plan is not progress any more, so neither surface may
    /// resurrect it just because a turn is idle.
    @Test("done 的计划两种情况下都不显示")
    func donePlanNeverShowsTheFloatingCard() {
        for visible in [true, false] {
            #expect(
                AgentPlanCardExpansionPolicy.shouldDisplayFloatingCard(
                    plan(.done),
                    isComposerProgressVisible: visible
                ) == false
            )
        }
    }

    /// A proposal is waiting on a human decision: the pill is not up (it
    /// requires a live turn), so the card must be present and open.
    @Test("待决策的计划自动展开，其余状态不自动展开")
    func onlyProposedPlansOpenThemselves() {
        #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: .proposed))
        for status in [AgentPlan.Status.approved, .executing, .done, .rejected] {
            #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: status) == false)
        }
    }

    /// The one-way latch: expansion used to be set true and never false, so a
    /// card opened while `.proposed` stayed fully expanded through execution.
    @Test("离开待决策状态时折叠，展开不再是单向锁")
    func leavingProposedFoldsTheCardBack() {
        #expect(AgentPlanCardExpansionPolicy.shouldCollapse(onStatusChangeTo: .approved))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapse(onStatusChangeTo: .executing))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapse(onStatusChangeTo: .proposed) == false)
    }

    /// Guards the exclusivity end-to-end against the pill's own rule: the
    /// pill needs a live turn, and precisely then the card stands down.
    @Test("两个面在任一时刻至多显示一个")
    func atMostOneSurfaceIsEverVisible() {
        for status in [AgentPlan.Status.proposed, .approved, .executing, .done] {
            let candidate = plan(status)
            for isResponding in [true, false] {
                let pill = AgentComposerTaskProgressSnapshot.preferred(
                    plan: candidate,
                    goal: nil,
                    isResponding: isResponding
                ) != nil
                let card = AgentPlanCardExpansionPolicy.shouldDisplayFloatingCard(
                    candidate,
                    isComposerProgressVisible: pill
                )
                #expect(!(pill && card), "status \(status) responding \(isResponding)")
            }
        }
    }
}
