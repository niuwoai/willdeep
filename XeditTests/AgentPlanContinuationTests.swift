import Testing
@testable import WillDeep

@Suite("Plan continuation")
struct AgentPlanContinuationTests {
    @Test(
        "explicit short approvals are recognized",
        arguments: [
            "继续",
            "继续执行。",
            "按这个计划执行",
            "好的，开始吧！",
            "continue",
            "Proceed with the plan.",
            "Looks good, go ahead!",
        ]
    )
    func recognizesExplicitApproval(text: String) {
        #expect(AgentPlanContinuationPolicy.isExplicitApproval(text))
    }

    @Test(
        "revision and negation messages are not approvals",
        arguments: [
            "",
            "继续修改计划",
            "先别执行",
            "执行前先改第二步",
            "continue planning",
            "do not execute",
            "please revise the plan",
        ]
    )
    func rejectsAmbiguousOrRevisionText(text: String) {
        #expect(!AgentPlanContinuationPolicy.isExplicitApproval(text))
    }

    @MainActor
    @Test("operator continuation promotes proposed Plan to Normal execution")
    func operatorContinuationPromotesPlan() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Continue Plan"))
        runtime.interactionMode = .plan
        runtime.currentPlan = AgentPlan(
            status: .proposed,
            summary: "Ship safely",
            stepTexts: ["Inspect", "Implement", "Verify"]
        )

        let promoted = appState.applyExplicitPlanContinuationIfNeeded(
            for: runtime,
            text: "继续",
            hasAttachments: false,
            source: .operatorInput
        )

        #expect(promoted)
        #expect(runtime.interactionMode == .normal)
        #expect(runtime.currentPlan?.status == .approved)
        #expect(runtime.currentPlan?.steps.map(\.text) == ["Inspect", "Implement", "Verify"])
    }

    @MainActor
    @Test("attachments and host instructions cannot implicitly approve a Plan")
    func guardedInputsDoNotPromotePlan() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Guarded Plan"))
        runtime.interactionMode = .plan
        runtime.currentPlan = AgentPlan(
            status: .proposed,
            summary: "",
            stepTexts: ["Inspect"]
        )

        #expect(!appState.applyExplicitPlanContinuationIfNeeded(
            for: runtime,
            text: "继续",
            hasAttachments: true,
            source: .operatorInput
        ))
        #expect(!appState.applyExplicitPlanContinuationIfNeeded(
            for: runtime,
            text: "继续",
            hasAttachments: false,
            source: .hostInstruction
        ))
        #expect(runtime.interactionMode == .plan)
        #expect(runtime.currentPlan?.status == .proposed)
    }

    @Test("Plan prompt pins the existing proposed steps instead of asking for another plan")
    func proposedPlanIsPinnedInPrompt() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .plan,
            currentPlan: AgentPlan(
                status: .proposed,
                summary: "Keep this contract",
                stepTexts: ["Inspect current behavior", "Implement the fix", "Verify the result"]
            ),
            globalRules: nil
        )

        #expect(prompt.contains("=== PLAN MODE — EXISTING PLAN AWAITS DECISION ==="))
        #expect(prompt.contains("Plan summary: Keep this contract"))
        #expect(prompt.contains("1. Inspect current behavior"))
        #expect(prompt.contains("2. Implement the fix"))
        #expect(prompt.contains("3. Verify the result"))
        #expect(prompt.contains("Do not repeat, reconstruct, or silently replace this plan"))
        #expect(!prompt.contains("Your only deliverable is a numbered plan"))
    }

    @Test("delegated executors receive the approved Plan as their execution contract")
    func delegatedTaskPinsApprovedPlan() {
        let task = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: "继续",
            currentPlan: AgentPlan(
                status: .approved,
                summary: "Keep the agreed scope",
                stepTexts: ["Inspect the path", "Implement the fix", "Run regression tests"]
            )
        )

        #expect(task.contains("=== APPROVED WILLDEEP PLAN — EXECUTE, DO NOT RE-PLAN ==="))
        #expect(task.contains("Plan summary: Keep the agreed scope"))
        #expect(task.contains("1. [pending] Inspect the path"))
        #expect(task.contains("2. [pending] Implement the fix"))
        #expect(task.contains("3. [pending] Run regression tests"))
    }

    @Test("delegated tasks remain unchanged when no Plan is approved")
    func delegatedTaskWithoutApprovedPlanIsUnchanged() {
        let task = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: "继续调查",
            currentPlan: AgentPlan(
                status: .proposed,
                summary: "",
                stepTexts: ["Inspect"]
            )
        )

        #expect(task == "继续调查")
    }
}
