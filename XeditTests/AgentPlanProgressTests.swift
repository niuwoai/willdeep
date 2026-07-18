//
//  AgentPlanProgressTests.swift
//  WillDeepTests
//
//  Covers AgentPlanParser.extract step→Step conversion plus
//  applyProgress(to:from:) — the model-driven progress reporting that
//  flips per-step status as the agent works.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentPlanProgressTests {
    /// Initial extract turns numbered lines into Steps with .pending status.
    @Test
    func extractProducesPendingSteps() {
        let content = """
        Sure, here's the plan:

        ```plan
        We'll do it in three passes.
        1. Read the file
        2. Edit it
        3. Run the tests
        ```
        """
        let plan = AgentPlanParser.extract(from: content)
        #expect(plan != nil)
        #expect(plan?.steps.count == 3)
        #expect(plan?.steps.map(\.status) == [.pending, .pending, .pending])
        #expect(plan?.steps.first?.text == "Read the file")
        #expect(plan?.summary == "We'll do it in three passes.")
    }

    /// A progress block flips matched step indexes to the new status and
    /// promotes the plan to .executing once any step is touched.
    @Test
    func applyProgressFlipsStatuses() {
        var plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B"),
                AgentPlan.Step(text: "C")
            ],
            summary: ""
        )
        let reply = """
        Working on it.

        ```progress
        1: done
        2: in_progress
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next != nil)
        plan = next!
        #expect(plan.status == .executing)
        #expect(plan.steps[0].status == .done)
        #expect(plan.steps[1].status == .inProgress)
        #expect(plan.steps[2].status == .pending)
    }

    /// All steps terminal ⇒ plan flips to .done.
    @Test
    func allTerminalStepsCompletesPlan() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A", status: .done),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        2: done
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.status == .done)
        #expect(next?.steps[1].status == .done)
    }

    /// Some providers emit one progress block around every large section.
    /// The parser must fold the whole reply, with later statuses winning.
    @Test
    func multipleProgressBlocksAreMergedInOrder() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "Draft"),
                AgentPlan.Step(text: "Write"),
                AgentPlan.Step(text: "Verify")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        1: in_progress
        ```
        Drafting is complete.
        ```progress
        1: done
        2: in_progress
        ```
        Writing and verification are complete.
        ```progress
        2: done
        3: done
        ```
        """

        let next = AgentPlanParser.applyProgress(to: plan, from: reply)

        #expect(next?.status == .done)
        #expect(next?.steps.map(\.status) == [.done, .done, .done])
    }

    /// Unknown status tokens are dropped — the rest of the block still applies.
    @Test
    func unknownStatusTokensIgnored() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        1: warp-speed
        2: done
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps[0].status == .pending)
        #expect(next?.steps[1].status == .done)
    }

    /// Out-of-range step indexes don't crash and don't corrupt other steps.
    @Test
    func outOfRangeIndexesIgnored() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )
        let reply = """
        ```progress
        99: done
        1: in_progress
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps.count == 1)
        #expect(next?.steps[0].status == .inProgress)
    }

    /// No ```progress block → returns nil so the caller leaves the plan alone.
    @Test
    func noProgressBlockReturnsNil() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )
        let reply = "Just prose, no progress block here."
        #expect(AgentPlanParser.applyProgress(to: plan, from: reply) == nil)
    }

    @MainActor
    @Test("completed plan mode requires a fresh plan before later writes")
    func completedPlanModeRequiresFreshPlan() {
        let plan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "Ship previous request", status: .done)],
            summary: ""
        )
        let runtime = AgentRuntime(session: AgentSession(title: "Done plan"))
        runtime.interactionMode = .plan
        runtime.currentPlan = plan

        #expect(runtime.isPlanGateActive == true)

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .plan,
            currentPlan: plan
        )
        #expect(prompt.contains("=== PLAN MODE — ACTIVE ==="))
        #expect(prompt.contains("Before ANY tool call"))
    }

    @MainActor
    @Test("same session later plan block replaces completed plan")
    func laterPlanBlockReplacesCompletedPlan() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentInteractionMode = .plan
        appState.agentCurrentPlan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "Finish the first request", status: .done)],
            summary: ""
        )
        appState.agentMessages = [
            AgentMessage(role: .user, content: "Now do another thing"),
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. Inspect the follow-up request
                2. Patch the follow-up behavior
                ```
                """
            )
        ]

        appState.captureAgentPlanFromLatestMessage()

        #expect(appState.agentCurrentPlan?.status == .proposed)
        #expect(appState.agentCurrentPlan?.steps.map(\.text) == [
            "Inspect the follow-up request",
            "Patch the follow-up behavior"
        ])
    }

    /// Accepts a variety of separator + status token forms — the agent
    /// shouldn't have to be pedantic.
    @Test
    func parserToleratesAlternateFormatting() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B"),
                AgentPlan.Step(text: "C"),
                AgentPlan.Step(text: "D")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        - 1. complete
          2) running
        step 3: failed
        4 skipped
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps[0].status == .done)
        #expect(next?.steps[1].status == .inProgress)
        #expect(next?.steps[2].status == .failed)
        #expect(next?.steps[3].status == .skipped)
    }

    @Test("approved plan with unfinished work continues automatically")
    func unfinishedApprovedPlanContinuesAutomatically() {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "A", status: .done),
                AgentPlan.Step(text: "B", status: .inProgress)
            ],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .continueExecution)
    }

    @Test("automatic continuation yields to queued user input")
    func automaticContinuationYieldsToQueuedUserInput() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: true
        )

        #expect(decision == .stop)
    }

    @Test("automatic continuation stops for terminal plans")
    func automaticContinuationStopsForTerminalPlans() {
        let plan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "A", status: .done)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .stop)
    }

    @Test("automatic continuation pauses after repeated no-progress replies")
    func automaticContinuationPausesAfterRepeatedNoProgress() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 1,
            consecutiveNoProgressReplies: 2,
            hasQueuedUserMessages: false
        )

        #expect(decision == .pauseAfterNoProgress)
    }

    @Test("automatic continuation has a hard safety limit")
    func automaticContinuationHasHardSafetyLimit() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumAutomaticContinuations,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .pauseAfterLimit)
    }

    @Test("plan prompt requires complete deliverable coverage")
    func planPromptRequiresCompleteDeliverableCoverage() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .plan,
            currentPlan: nil
        )

        #expect(prompt.contains("complete delivery contract"))
        #expect(prompt.contains("not just an outline, sample, first chapter"))
        #expect(prompt.contains("web_fetch for validated public URLs"))
    }
}
