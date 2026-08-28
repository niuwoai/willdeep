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

    @Test("ordinary prompt defers planning until WillDeep or the user asks")
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

        #expect(prompt.contains("without a `plan` fenced block up front"))
        #expect(prompt.contains("continue executing in the same reply"))
        #expect(prompt.contains("do not re-plan on later rounds"))
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
        // 改写计划的提示词自 1.296.0-rc11 起带上了三步门槛,这里一并钉住:
        // 光断言"继续执行"会让门槛悄悄消失也照样绿。
        #expect(runtime.queuedMessages[0].text.contains(
            "at least \(AgentPlanOnDemandPolicy.minimumVisibleStepCount) independent execution steps remain"
        ))
        #expect(runtime.queuedMessages[0].text.contains(
            "Continue executing without waiting for plan approval"
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

    // MARK: - User interruption releases the plan contract

    private static func interruptedPlan(status: AgentPlan.Status = .executing) -> AgentPlan {
        var plan = AgentPlan(status: status, summary: "", stepTexts: ["Inspect", "Implement"])
        plan.interruptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return plan
    }

    @Test("an interrupted plan is no longer the execution contract")
    func interruptedPlanReleasesContract() {
        #expect(!AgentPlanContinuationPolicy.hasActiveExecutionContract(
            Self.interruptedPlan(status: .approved)
        ))
        #expect(!AgentPlanContinuationPolicy.hasActiveExecutionContract(
            Self.interruptedPlan(status: .executing)
        ))
    }

    /// The card used to keep reading "已中断" for a whole resumed turn —
    /// route edits, compiles, new files — because `interruptedAt` was cleared
    /// only by the end-of-turn capture. The stream now lifts it as soon as a
    /// `progress` block parses.
    @Test("流式里出现 progress 块即解除中断标记")
    func streamedProgressLiftsInterruption() throws {
        let plan = Self.interruptedPlan()
        let content = """
        继续完成中断的计划。先注册成员管理路由：

        ```progress
        1: done
        2: in_progress
        ```
        """

        let lifted = try #require(AgentPlanParser.liftingInterruption(of: plan, from: content))
        #expect(!lifted.isInterrupted)
        // Only the badge is lifted here; the checklist stays with the
        // end-of-turn capture, which sees the completed block.
        #expect(lifted.steps.map(\.status) == plan.steps.map(\.status))
    }

    /// The pause is a real contract release, so prose alone must not undo it.
    /// Only the explicit `progress` signal counts — otherwise a reply that
    /// merely mentions the old plan while starting new work would silently
    /// re-arm auto-continuation on it.
    @Test("没有 progress 块时中断标记保持不变")
    func proseAloneDoesNotLiftInterruption() {
        let plan = Self.interruptedPlan()

        #expect(AgentPlanParser.liftingInterruption(of: plan, from: "") == nil)
        #expect(AgentPlanParser.liftingInterruption(
            of: plan,
            from: "继续完成中断的计划。现在编译验证："
        ) == nil)
        // A progress block whose rows parse to nothing is not a resume signal.
        #expect(AgentPlanParser.liftingInterruption(
            of: plan,
            from: "```progress\n(nothing yet)\n```"
        ) == nil)
    }

    /// A plan that was never paused must not be rewritten by this path — it
    /// runs on every streaming flush, so a spurious non-nil return would
    /// republish `currentPlan` a few times a second.
    @Test("未中断的计划不被该路径改写")
    func activePlanIsLeftAlone() {
        let active = AgentPlan(status: .executing, summary: "", stepTexts: ["Inspect"])

        #expect(AgentPlanParser.liftingInterruption(
            of: active,
            from: "```progress\n1: done\n```"
        ) == nil)
    }

    @Test("interrupted plans decode from legacy payloads as active")
    func legacyPlanDecodesWithoutInterruption() throws {
        let legacy = #"{"status":"executing","steps":[],"summary":""}"#
        let decoded = try JSONDecoder().decode(AgentPlan.self, from: Data(legacy.utf8))

        #expect(!decoded.isInterrupted)
        #expect(AgentPlanContinuationPolicy.hasActiveExecutionContract(decoded))
    }

    @Test("delegated task text is not rewritten after an interruption")
    func interruptedPlanDoesNotHijackDelegatedTask() {
        let text = "帮我做另一件事"
        let task = AgentPlanContinuationPolicy.delegatedExecutionTask(
            userText: text,
            currentPlan: Self.interruptedPlan()
        )

        #expect(task == text)
    }

    @Test("auto continuation stops for an interrupted plan")
    func interruptedPlanStopsAutoContinuation() {
        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: Self.interruptedPlan(),
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .stop)
    }

    @Test("ordinary prompt swaps the contract block for interrupted guidance")
    func interruptedPlanPromptAllowsNewTask() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: Self.interruptedPlan(),
            globalRules: nil
        )

        #expect(prompt.contains("=== INTERRUPTED PLAN — USER DECIDES WHAT'S NEXT ==="))
        #expect(prompt.contains("1. [pending] Inspect"))
        #expect(!prompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
    }

    @MainActor
    @Test("a replacement plan is captured after an interruption")
    func replacementPlanIsCapturedAfterInterruption() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Interrupted"))
        runtime.interactionMode = .normal
        runtime.currentPlan = Self.interruptedPlan()
        // 普通模式的可见计划自 1.296.0-rc11 起要求至少
        // `minimumVisibleStepCount` 步,少于此数的围栏块根本不成为计划。
        // 这条用例要证的是"新计划顶掉被中断的旧计划",所以替换计划必须先
        // 够得着那道门槛,否则测的就变成门槛本身了。
        runtime.messages = [
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. New task step one
                2. New task step two
                3. New task step three
                ```
                """
            )
        ]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .captured)
        #expect(runtime.currentPlan?.steps.map(\.text) == [
            "New task step one",
            "New task step two",
            "New task step three"
        ])
        #expect(runtime.currentPlan?.isInterrupted == false)
    }

    @MainActor
    @Test("少于三步的替换计划不顶掉被中断的计划")
    func undersizedReplacementLeavesInterruptedPlanIntact() {
        // 门槛的另一面:两步的围栏块在普通模式下不是计划,既不该被捕获,也
        // 不该顺手把旧计划的中断标记清掉——否则用户按下 Stop 之后,模型随
        // 手发一个两步清单就能把"已暂停"的徽标抹掉,而计划并没有被接管。
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Interrupted"))
        runtime.interactionMode = .normal
        runtime.currentPlan = Self.interruptedPlan()
        runtime.messages = [
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. New task step one
                2. New task step two
                ```
                """
            )
        ]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .noProposal)
        #expect(runtime.currentPlan?.steps.map(\.text) == ["Inspect", "Implement"])
        #expect(runtime.currentPlan?.isInterrupted == true)
    }

    @MainActor
    @Test("a progress report resumes an interrupted plan")
    func progressReportResumesInterruptedPlan() {
        let appState = AppState()
        let runtime = AgentRuntime(session: AgentSession(title: "Resumed"))
        runtime.interactionMode = .normal
        runtime.currentPlan = Self.interruptedPlan()
        runtime.messages = [
            AgentMessage(
                role: .assistant,
                content: """
                Picking the plan back up.
                ```progress
                1: done
                ```
                """
            )
        ]

        let outcome = appState.captureAgentPlanFromLatestMessage(for: runtime)

        #expect(outcome == .noProposal)
        #expect(runtime.currentPlan?.isInterrupted == false)
        #expect(runtime.currentPlan?.steps.first?.status == .done)
    }
}
