//
//  AgentGoalBudgetedContinuationTests.swift
//  WillDeepTests
//
//  Goal 执行阶段撞上普通续跑轮次上限时的接管行为。
//
//  同一个 Goal 过去有两套边界：计划标记完成后，验收阶段按 wall-clock 预算
//  走退避阶梯、永不硬停；而计划还在执行时，续跑在 24 轮处直接停下。于是
//  最需要长跑的任务反而被一个用户无从理解的代理指标切断。设计契约是
//  「预算是唯一的硬边界」（docs/LONG_HORIZON_AUTONOMY.md §1.2 / §2.1），
//  这些用例锁的就是这条边界。
//

import WillDeepCore
import Foundation
import Testing

@testable import WillDeep

@MainActor
@Suite("Goal 轮次上限交给预算裁决", .serialized)
struct AgentGoalBudgetedContinuationTests {
    private func makeAppRuntime(goal: AgentGoal) -> (AppState, AgentRuntime) {
        let appState = AppState()
        let session = AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(
                status: .executing,
                steps: [AgentPlan.Step(text: "实现并验证")],
                summary: ""
            ),
            currentGoal: goal
        )
        let runtime = AgentRuntime(session: session)
        // 走排队分支，避免用例真的发起一次模型请求。
        runtime.isResponding = true
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]
        appState.activeAgentSessionID = session.id
        appState.subscribeToActiveRuntime()
        return (appState, runtime)
    }

    private func goal(
        remaining: Bool = true,
        budget: AgentGoalContinuationBudget? = nil
    ) -> AgentGoal {
        var goal = AgentGoal(
            statement: "Ship safely",
            checklist: [
                .init(text: "已经完成的验收", done: true),
                .init(text: "还没完成的验收", done: !remaining),
            ]
        )
        goal.continuationBudget = budget
        return goal
    }

    @Test("工具批次到期只排一次收尾，不再启动审核或反复续跑")
    func expiredToolBatchQueuesOneWrapUp() throws {
        let (appState, runtime) = makeAppRuntime(goal: goal(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast)))
        let assistant = AgentMessage(role: .assistant, content: "")
        runtime.messages.append(assistant)
        #expect(appState.stopExpiredGoalToolRound(for: runtime, assistantID: assistant.id))
        #expect(runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.queuedMessages.first?.source == .hostInstruction)
        #expect(runtime.toolCalls.isEmpty)
        #expect(appState.stopExpiredGoalToolRound(for: runtime, assistantID: assistant.id))
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.currentGoal?.checklist.last?.done == false)
    }

    @Test("预算还有余量时接管轮次上限，继续推进而不是硬停")
    func budgetRunwayTakesOverFromTheRoundLimit() throws {
        let (appState, runtime) = makeAppRuntime(goal: goal())

        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))

        let instruction = try #require(runtime.queuedMessages.last)
        #expect(instruction.source == .hostInstruction)
        #expect(instruction.text.contains("还没完成的验收"))
        // 已勾选项不重复展开——续推提示词只谈剩下要干的事。
        #expect(!instruction.text.contains("已经完成的验收"))
        #expect(instruction.text.contains("do not restart Goal Teams"))
        // 锁「不该报达到上限」，而不是 `errorMessage == nil`：`AppState()` 读
        // 真实 Keychain，派发路径在未登录的机器上会写入 some.im 登录提示，
        // 拿 nil 当断言等于把本机登录态混进判据。
        #expect(runtime.errorMessage != L10n.PlanContinuation.safetyLimitPaused)
    }

    /// 预算窗口必须真的开始计时。只读探测会让 `segmentStartedAt` 永远是 nil，
    /// 于是轮次上限被接管之后就再没有任何边界了。
    @Test("接管会推进预算：开窗计时并累计续推次数")
    func takingOverAdvancesTheBudget() {
        let (appState, runtime) = makeAppRuntime(goal: goal())

        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))

        let budget = runtime.currentGoal?.continuationBudget
        #expect(budget?.segmentStartedAt != nil)
        #expect(budget?.continuationsUsed == 1)
    }

    @Test("预算耗尽时改为请求交接快照，并把预算状态告诉用户")
    func spentBudgetAsksForAHandover() throws {
        let spent = AgentGoalContinuationBudget(
            wallClockLimit: 1,
            maximumContinuations: 64,
            segmentStartedAt: Date(timeIntervalSince1970: 0),
            continuationsUsed: 0,
            wrapUpDispatched: false
        )
        let (appState, runtime) = makeAppRuntime(goal: goal(budget: spent))

        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))

        let instruction = try #require(runtime.queuedMessages.last)
        #expect(instruction.text.contains("handover snapshot"))
        #expect(instruction.text.contains("还没完成的验收"))
        // 有序收尾是要让用户知道的，但它是通知不是错误。
        #expect(runtime.errorMessage == L10n.GoalPlanning.budgetExhausted)
        #expect(runtime.errorSeverity == .notice)
        #expect(runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
    }

    /// 交接已经要过一次，就不再向模型纠缠——但要把「为什么停」说给用户听。
    /// 交接那一轮自己的横幅活不下来（派发交接指令的 dispatch 会清掉上一轮
    /// 错误态），这里的安静停机是用户唯一可靠的知情机会；落回轮次上限的
    /// 旧文案则连停机原因都是错的。
    @Test("交接请求过之后不再发消息，但挂上预算横幅而非轮次横幅")
    func alreadyHandedOverClaimsTheBudgetBanner() {
        let done = AgentGoalContinuationBudget(
            wallClockLimit: 4 * 60 * 60,
            maximumContinuations: 64,
            segmentStartedAt: Date(),
            continuationsUsed: 3,
            wrapUpDispatched: true
        )
        let (appState, runtime) = makeAppRuntime(goal: goal(budget: done))

        // 返回 true：接管的是「结局的呈现」，调用方不得再弹轮次上限横幅。
        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))
        #expect(runtime.queuedMessages.isEmpty)
        #expect(runtime.errorMessage == L10n.GoalPlanning.budgetExhausted)
        #expect(runtime.errorSeverity == .notice)
    }

    @Test("验收清单已经全勾时不接管")
    func completedChecklistIsNotPushedFurther() {
        let (appState, runtime) = makeAppRuntime(goal: goal(remaining: false))

        #expect(!appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))
        #expect(runtime.queuedMessages.isEmpty)
    }

    /// 普通模式没有 Goal 预算这条边界，8 轮上限仍然是它的终态。
    @Test("普通模式不受影响")
    func ordinaryModeIsUntouched() {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.interactionMode = .normal

        #expect(!appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime))
        #expect(runtime.queuedMessages.isEmpty)
    }

    @Test("工具轮数和压缩边界都消耗同一份持久化预算", arguments: [
        AgentGoalRunBoundary.toolRoundLimit, .contextCompaction,
    ])
    func mechanicalBoundariesUseGoalBudget(boundary: AgentGoalRunBoundary) throws {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.contextRunwayResumeCount = 20
        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: boundary))
        #expect(runtime.currentGoal?.continuationBudget?.continuationsUsed == 1)
        #expect(try #require(runtime.queuedMessages.last).text.contains(boundary.instruction))
    }

    @Test("压缩续跑保持原执行器，不静默改用原生 Agent")
    func continuationPreservesExecutor() throws {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.executionAgent = .claudeCode
        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: .contextCompaction))
        #expect(try #require(runtime.queuedMessages.last).executionAgent == .claudeCode)
    }

    @Test("第四次上下文交接仍安排 Goal 续跑，普通任务保留保护上限")
    func fourthHandoffUsesGoalAuthority() {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.contextRunwayResumeCount = AgentContextRunwayPolicy.maximumAutomaticResumes
        appState.concludeContextRunwayHandoff(for: runtime, finishReason: "stop")
        #expect(runtime.pendingContextRunwayResume)
        runtime.interactionMode = .normal
        runtime.pendingContextRunwayResume = false
        appState.concludeContextRunwayHandoff(for: runtime, finishReason: "stop")
        #expect(!runtime.pendingContextRunwayResume)
    }

    @Test("预算从执行开始，后续轮次不重置起点也不花续推次数")
    func executionStartsClockExactlyOnce() {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        let start = Date(timeIntervalSince1970: 1_000)
        appState.beginGoalExecutionBudgetIfNeeded(for: runtime, now: start)
        appState.beginGoalExecutionBudgetIfNeeded(for: runtime, now: start.addingTimeInterval(100))
        #expect(runtime.currentGoal?.continuationBudget?.segmentStartedAt == start)
        #expect(runtime.currentGoal?.continuationBudget?.continuationsUsed == 0)
        #expect(appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: .toolRoundLimit))
        #expect(runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
    }

    @Test("未批准计划不开始执行预算")
    func proposedPlanDoesNotSpendBudget() {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.currentPlan?.status = .proposed
        appState.beginGoalExecutionBudgetIfNeeded(for: runtime)
        #expect(runtime.currentGoal?.continuationBudget == nil)
    }

    @Test("Stop 和排队用户指令都阻止机械边界续跑")
    func stopAndOperatorInputWin() {
        let (appState, runtime) = makeAppRuntime(goal: goal())
        runtime.currentPlan?.interruptedAt = Date()
        #expect(!appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: .toolRoundLimit))
        #expect(!appState.canResumeAfterContextCompaction(for: runtime))
        runtime.currentPlan?.interruptedAt = nil
        runtime.queuedMessages.append(AgentQueuedMessage(text: "停止实现，先解释", images: [], source: .operatorInput))
        #expect(!appState.continueGoalOnBudgetInsteadOfRoundLimit(for: runtime, boundary: .contextCompaction))
        #expect(runtime.queuedMessages.count == 1)
        #expect(runtime.currentGoal?.continuationBudget == nil)
    }
}
