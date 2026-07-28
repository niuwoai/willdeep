import Foundation
import Testing
@testable import WillDeep

@Suite("Plan continuation")
struct AgentPlanContinuationTests {
    @Test(
        "planning-only intent is recognized",
        arguments: [
            "只规划，不要执行",
            "先列计划，暂不执行",
            "不要动代码，只要计划",
            "plan only",
            "do not implement",
        ]
    )
    func recognizesPlanningOnlyIntent(text: String) {
        #expect(AgentExecutionIntentPolicy.requestsPlanningOnly(text))
    }

    @Test(
        "execution intent overrides planning words",
        arguments: [
            "",
            "请先列计划，然后直接执行",
            "不要只规划，直接做",
            "plan first, then execute directly",
            "just do it",
        ]
    )
    func executionIntentDoesNotPause(text: String) {
        #expect(!AgentExecutionIntentPolicy.requestsPlanningOnly(text))
    }

    @Test("ordinary prompt plans once and executes without approval")
    func ordinaryPromptPlansAndExecutes() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: nil,
            globalRules: nil
        )

        #expect(prompt.contains("emit exactly one complete numbered `plan` fenced block near the start"))
        #expect(prompt.contains("continue executing it in the same turn without waiting for plan approval"))
        #expect(prompt.contains("Do not plan again on later tool rounds"))
        #expect(!prompt.contains("PLAN MODE"))
    }

    @Test("ordinary prompt pins an active plan instead of planning again")
    func activePlanIsPinnedInOrdinaryPrompt() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: AgentPlan(
                status: .approved,
                summary: "Keep this contract",
                stepTexts: ["Inspect current behavior", "Implement the fix", "Verify the result"]
            ),
            globalRules: nil
        )

        #expect(prompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
        #expect(prompt.contains("1. [pending] Inspect current behavior"))
        #expect(prompt.contains("2. [pending] Implement the fix"))
        #expect(prompt.contains("3. [pending] Verify the result"))
        #expect(prompt.contains("Do not emit a replacement `plan` block"))
    }

    @MainActor
    @Test("ordinary model plan becomes executable immediately")
    func ordinaryPlanIsCapturedWithoutApproval() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Ordinary Plan"))
        runtime.interactionMode = .normal
        runtime.messages = [
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. Inspect
                2. Implement
                3. Verify
                ```
                """
            )
        ]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .captured)
        #expect(runtime.currentPlan?.status == .approved)
        #expect(runtime.currentPlan?.steps.map(\.text) == ["Inspect", "Implement", "Verify"])
    }

    @Test("approved and executing plans are active execution contracts")
    func activeExecutionContractIsDetected() {
        #expect(AgentPlanContinuationPolicy.hasActiveExecutionContract(
            AgentPlan(status: .approved, summary: "", stepTexts: ["Implement"])
        ))
        #expect(AgentPlanContinuationPolicy.hasActiveExecutionContract(
            AgentPlan(status: .executing, summary: "", stepTexts: ["Verify"])
        ))
        #expect(!AgentPlanContinuationPolicy.hasActiveExecutionContract(
            AgentPlan(status: .proposed, summary: "", stepTexts: ["Legacy"])
        ))
        #expect(!AgentPlanContinuationPolicy.hasActiveExecutionContract(
            AgentPlan(status: .done, summary: "", stepTexts: ["Done"])
        ))
    }

    @MainActor
    @Test("a later model plan cannot overwrite an active execution contract")
    func activeExecutionPlanCannotBeOverwritten() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Pinned Plan"))
        runtime.interactionMode = .normal
        runtime.currentPlan = AgentPlan(
            status: .approved,
            summary: "Original",
            stepTexts: ["Original implementation", "Original verification"]
        )
        runtime.messages = [
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. Replacement step
                2. Repeat everything
                ```
                """
            )
        ]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .noProposal)
        #expect(runtime.currentPlan?.status == .approved)
        #expect(runtime.currentPlan?.steps.map(\.text) == [
            "Original implementation",
            "Original verification",
        ])
    }

    @MainActor
    @Test("explicit revision replaces the ordinary plan without switching modes")
    func explicitRevisionQueuesReplacementGuidance() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.interactionMode = .normal
        runtime.currentPlan = AgentPlan(
            status: .executing,
            summary: "Original contract",
            stepTexts: ["Keep completed work", "Finish verification"]
        )
        runtime.isResponding = true

        appState.requestPlanRevision(note: "Replace only the verification approach")

        #expect(runtime.interactionMode == .normal)
        #expect(runtime.currentPlan == nil)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.queuedMessages[0].text.contains(
            "Replace only the verification approach"
        ))
        #expect(runtime.queuedMessages[0].text.contains(
            "continue executing it without waiting for plan approval"
        ))
    }

    @Test("delegated executors receive the active plan")
    func delegatedTaskPinsActivePlan() {
        let task = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: "继续",
            currentPlan: AgentPlan(
                status: .approved,
                summary: "Keep the agreed scope",
                stepTexts: ["Inspect the path", "Implement the fix", "Run regression tests"]
            )
        )

        #expect(task.contains("=== ACTIVE WILLDEEP PLAN — EXECUTE, DO NOT RE-PLAN ==="))
        #expect(task.contains("Plan summary: Keep the agreed scope"))
        #expect(task.contains("1. [pending] Inspect the path"))
        #expect(task.contains("2. [pending] Implement the fix"))
        #expect(task.contains("3. [pending] Run regression tests"))
    }

    @Test("planning-only delegated tasks receive a read-only contract")
    func delegatedPlanningOnlyTaskIsReadOnly() {
        let text = "只规划，不要执行"
        let task = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: text,
            currentPlan: AgentPlan(
                status: .approved,
                summary: "",
                stepTexts: ["Inspect"]
            )
        )

        #expect(task.contains(text))
        #expect(task.contains("=== PLANNING ONLY — READ-ONLY ==="))
        #expect(!task.contains("ACTIVE WILLDEEP PLAN"))
    }

    @Test("planning-only intent blocks write and danger tools")
    func planningOnlyIntentBlocksExecutionRisks() {
        #expect(!AgentExecutionIntentPolicy.blocksExecution(risk: .read))
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .write))
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .danger))
        #expect(!AgentExecutionIntentPolicy.blocksExecution(risk: .userInput))
    }

    @Test("legacy Plan mode persistence migrates to ordinary mode")
    func legacyPlanModeDecodesAsNormal() throws {
        let decoded = try JSONDecoder().decode(
            AgentInteractionMode.self,
            from: Data(#""plan""#.utf8)
        )

        #expect(decoded == .normal)
        #expect(AgentInteractionMode.allCases == [.normal, .goal])
    }
}
