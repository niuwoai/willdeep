//
//  AgentSessionTodoSummaryTests.swift
//  XeditTests
//

import Testing
@testable import WillDeep

@Suite
struct AgentSessionTodoSummaryTests {
    @Test("plan todo summary prefers the active in-progress step")
    func planSummaryUsesInProgressStep() {
        var session = AgentSession(title: "Plan")
        session.currentPlan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "Read files", status: .done),
                AgentPlan.Step(text: "Patch sidebar", status: .inProgress),
                AgentPlan.Step(text: "Run tests", status: .pending)
            ],
            summary: ""
        )

        let summary = AgentSessionTodoSummaryLogic.summary(for: session)
        #expect(summary?.kind == .plan)
        #expect(summary?.completed == 1)
        #expect(summary?.total == 3)
        #expect(summary?.text == "Patch sidebar")
        #expect(summary?.isComplete == false)
    }

    @Test("goal todo summary reports the next unchecked item")
    func goalSummaryUsesNextUncheckedItem() {
        var session = AgentSession(title: "Goal")
        session.currentGoal = AgentGoal(
            statement: "Ship todos",
            checklist: [
                AgentGoal.Item(text: "Persist", done: true),
                AgentGoal.Item(text: "Display", done: false)
            ]
        )

        let summary = AgentSessionTodoSummaryLogic.summary(for: session)
        #expect(summary?.kind == .goal)
        #expect(summary?.completed == 1)
        #expect(summary?.total == 2)
        #expect(summary?.text == "Display")
        #expect(summary?.isComplete == false)
    }

    @Test("rejected or empty work does not add sidebar todo noise")
    func rejectedAndEmptySummariesAreHidden() {
        var rejected = AgentSession(title: "Rejected")
        rejected.currentPlan = AgentPlan(
            status: .rejected,
            steps: [AgentPlan.Step(text: "Do not show")],
            summary: ""
        )
        #expect(AgentSessionTodoSummaryLogic.summary(for: rejected) == nil)

        let empty = AgentSession(title: "Empty")
        #expect(AgentSessionTodoSummaryLogic.summary(for: empty) == nil)
    }
}
