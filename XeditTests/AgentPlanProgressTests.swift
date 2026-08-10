//
//  AgentPlanProgressTests.swift
//  WillDeepTests
//
//  Covers AgentPlanParser.extract step→Step conversion plus
//  applyProgress(to:from:) — the model-driven progress reporting that
//  flips per-step status as the agent works.
//

import Testing
import AppKit
import Foundation
import SwiftUI
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
    @Test("a completed ordinary plan does not create a planning gate")
    func completedOrdinaryPlanDoesNotGateLaterWork() {
        let plan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "Ship previous request", status: .done)],
            summary: ""
        )
        let runtime = AgentRuntime(session: AgentSession(title: "Done plan"))
        runtime.interactionMode = .normal
        runtime.currentPlan = plan

        #expect(runtime.isPlanGateActive == false)

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: plan
        )
        #expect(prompt.contains("=== ORDINARY MODE — PLAN WHEN USEFUL, THEN EXECUTE ==="))
        #expect(!prompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
    }

    @MainActor
    @Test("leaving Goal mode preserves its active execution plan")
    func leavingGoalModePreservesActivePlan() {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let runtime = appState.agentRuntimes[session.id]
        runtime?.interactionMode = .goal
        runtime?.currentPlan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "Execute")],
            summary: ""
        )

        appState.setAgentInteractionMode(.normal)

        #expect(appState.agentInteractionMode == .normal)
        #expect(appState.agentCurrentPlan?.status == .approved)
    }

    @MainActor
    @Test("Normal mode applies progress blocks to a carried-over approved plan")
    func normalModeAppliesProgressToCarriedOverPlan() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentInteractionMode = .normal
        appState.agentCurrentPlan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        appState.agentMessages = [
            AgentMessage(role: .user, content: "Plan approved. Execute the complete plan step by step."),
            AgentMessage(
                role: .assistant,
                content: """
                Working on it.
                ```progress
                1: done
                2: in_progress
                ```
                """
            )
        ]

        appState.captureAgentPlanFromLatestMessage()

        #expect(appState.agentCurrentPlan?.status == .executing)
        #expect(appState.agentCurrentPlan?.steps[0].status == .done)
        #expect(appState.agentCurrentPlan?.steps[1].status == .inProgress)
    }

    @MainActor
    @Test("same session later plan block replaces completed plan")
    func laterPlanBlockReplacesCompletedPlan() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentInteractionMode = .normal
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

        #expect(appState.agentCurrentPlan?.status == .approved)
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

    @Test("plan step text renders inline Markdown instead of delimiters")
    func planStepTextRendersInlineMarkdown() {
        let attributed = MarkdownInline.attributedString(
            from: "**`AgentPlan.swift`**: keep *status* synchronized"
        )

        #expect(String(attributed.characters) == "AgentPlan.swift: keep status synchronized")
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
        let codeRun = attributed.runs.first { run in
            run.inlinePresentationIntent?.contains(.code) == true
        }
        #expect(codeRun?.baselineOffset == MarkdownInline.inlineCodeBaselineOffset)
    }

    @Test("plan step index column fits double-digit numbering")
    func planStepIndexColumnFitsDoubleDigits() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        ]
        let doubleDigitWidth = ("10." as NSString).size(withAttributes: attributes).width

        #expect(AgentPlanStepLayoutMetrics.indexColumnWidth >= ceil(doubleDigitWidth))
    }

    @Test("full plan Markdown keeps every step and its live status")
    func fullPlanMarkdownKeepsEveryStepAndStatus() {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "Inspect **all** call sites", status: .done),
                AgentPlan.Step(text: "Implement the long description without truncating it", status: .inProgress),
                AgentPlan.Step(text: "Run focused tests", status: .failed),
            ],
            summary: "Keep the compact card readable."
        )

        let markdown = AgentPlanMarkdownFormatter.markdown(from: plan)
        let blocks = MarkdownPreviewParser.blocks(from: markdown)
        let listBlockCount = blocks.reduce(into: 0) { count, block in
            if case .unorderedList = block.kind {
                count += 1
            }
        }

        #expect(markdown.contains("# \(L10n.PlanCard.header)"))
        #expect(markdown.contains("- ✓ **1.** Inspect **all** call sites"))
        #expect(markdown.contains("- ◉ **2.** Implement the long description without truncating it"))
        #expect(markdown.contains("- ! **3.** Run focused tests"))
        #expect(listBlockCount == plan.steps.count)
        #expect(blocks.contains { $0.text.contains("without truncating it") })
    }

    @Test("plan card opens for newly planned work and collapses during execution")
    func planCardInitialExpansionFollowsExecutionState() {
        #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: .proposed))
        #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: .approved))
        #expect(!AgentPlanCardExpansionPolicy.initiallyExpanded(for: .executing))
        #expect(!AgentPlanCardExpansionPolicy.initiallyExpanded(for: .done))
        #expect(!AgentPlanCardExpansionPolicy.showsStatus(.approved, isInterrupted: false))
        #expect(AgentPlanCardExpansionPolicy.showsStatus(.executing, isInterrupted: false))
        #expect(AgentPlanCardExpansionPolicy.showsStatus(.approved, isInterrupted: true))
    }

    @Test("plan card collapses only when a new assistant round appears")
    func planCardCollapsesForNewAssistantRound() {
        let previousID = UUID()
        let nextID = UUID()

        #expect(!AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: nil
        ))
        #expect(!AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: previousID
        ))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: nextID
        ))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: nil,
            currentMessageID: nextID
        ))
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

    @Test("planning-only request never auto-executes a captured plan")
    func planningOnlyRequestStopsAutomaticContinuation() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false,
            allowsAutomaticExecution: false
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
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false
        )

        #expect(decision == .pauseAfterNoProgress)
    }

    @Test("automatic continuation requests one status-only reconciliation before pausing")
    func automaticContinuationReconcilesMissingProgressBeforePausing() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "Deploy", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 2,
            hasQueuedUserMessages: false
        )
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop"
        )

        #expect(decision == .reconcileProgress)
        #expect(notice.contains("minimum necessary read-only status or inspection tools"))
        #expect(notice.contains("write, danger, and user-input tools are blocked"))
        #expect(notice.contains("repeat the plan"))
        #expect(notice.contains("exactly one closed `progress` fenced block"))
        #expect(notice.contains("Do not infer completion without evidence"))
        #expect(AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.read))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.write))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.danger))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.userInput))
    }

    @Test("a run that is still executing tools keeps reconciling instead of pausing")
    func automaticContinuationKeepsReconcilingWhileToolsRun() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            evidence: .init(didExecuteTools: true)
        )

        #expect(decision == .reconcileProgress)
    }

    @Test("a live background job keeps reconciling and says so in the notice")
    func automaticContinuationKeepsReconcilingWhileBackgroundJobRuns() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 4,
            hasQueuedUserMessages: false,
            evidence: .init(hasRunningBackgroundJobs: true)
        )
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop",
            hasRunningBackgroundJobs: true
        )

        #expect(decision == .reconcileProgress)
        #expect(notice.contains("background job started by this conversation is still running"))
        #expect(notice.contains("keep that step `in_progress`"))
        // Still the full reconciliation contract, not a weaker variant.
        #expect(notice.contains("exactly one closed `progress` fenced block"))
        #expect(notice.contains("write, danger, and user-input tools are blocked"))
    }

    @Test("no-progress evidence never overrides the hard safety limit")
    func progressEvidenceDoesNotOverrideSafetyLimit() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        // The 8-round cap is what keeps the evidence path from spinning
        // forever, so it must win over every activity signal.
        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumAutomaticContinuations,
            consecutiveNoProgressReplies: 9,
            hasQueuedUserMessages: false,
            evidence: .init(didExecuteTools: true, hasRunningBackgroundJobs: true)
        )

        #expect(decision == .pauseAfterLimit)
    }

    @Test("an idle stalled run still pauses")
    func automaticContinuationStillPausesWithoutEvidence() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            evidence: .none
        )

        #expect(decision == .pauseAfterNoProgress)
        #expect(!AgentPlanAutoContinuationPolicy.ProgressEvidence.none.hasAny)
    }

    @Test("the plain reconciliation notice omits the background-job sentence")
    func progressReconciliationNoticeOmitsBackgroundJobsWhenNoneRun() {
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop"
        )

        #expect(!notice.contains("background job"))
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

    @Test("ordinary prompt creates one plan and immediately executes it")
    func ordinaryPromptDoesNotPauseAtPlanning() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: nil
        )

        #expect(prompt.contains("=== ORDINARY MODE — PLAN WHEN USEFUL, THEN EXECUTE ==="))
        #expect(prompt.contains("emit exactly one complete numbered `plan` fenced block"))
        #expect(prompt.contains("continue executing it in the same turn"))
        #expect(prompt.contains("Do not plan again on later tool rounds"))
        #expect(prompt.contains("explicitly asks only for analysis or a plan"))
        #expect(prompt.contains("privately preflight the complete request"))
        #expect(prompt.contains("Once execution starts, continue as an unattended run"))
        #expect(prompt.contains("ordinary Git/worktree"))

        let executionPrompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: AgentPlan(
                status: .approved,
                steps: [AgentPlan.Step(text: "Run the tests")],
                summary: ""
            )
        )
        #expect(executionPrompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
        #expect(executionPrompt.contains("refresh the visible checklist immediately"))
        #expect(executionPrompt.contains("Only a valid `progress` fenced block changes WillDeep's visible checklist"))
        #expect(executionPrompt.contains("Do not emit a replacement `plan` block"))
        #expect(executionPrompt.contains("The plan is now in unattended execution"))
        #expect(executionPrompt.contains("ordinary Git/worktree conflicts"))
        #expect(executionPrompt.contains("Re-contact the user only for missing authority or credentials"))
    }
}
