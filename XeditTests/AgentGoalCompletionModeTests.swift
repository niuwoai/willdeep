import Foundation
import Testing
@testable import WillDeep

@Suite("Goal 完成后退出目标模式")
@MainActor
struct AgentGoalCompletionModeTests {
    private func runtime() -> AgentRuntime {
        AgentRuntime(session: AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: .executing, summary: "", stepTexts: ["Verify"]),
            currentGoal: AgentGoal(statement: "Finish this goal", checklist: [.init(text: "Verified")])
        ))
    }

    @Test("完成切回普通模式，保留证据、草稿与排队输入并可持久化恢复")
    func completionPersistsOrdinaryMode() throws {
        let runtime = runtime()
        runtime.currentPlan?.status = .done
        runtime.currentGoal?.checklist[0].done = true
        runtime.input = "下一条普通问题"
        runtime.messages = [.init(role: .user, content: "Goal request"),
                            .init(role: .assistant, content: "Goal finished")]
        runtime.queuedMessages = [.init(text: "排队的追问", images: [], source: .operatorInput)]
        runtime.goalTurnRecoveryCheckpoint = .init()
        let history = runtime.messages
        let goal = runtime.currentGoal

        #expect(runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .normal)
        #expect(runtime.currentGoal == goal)
        #expect(runtime.currentPlan?.status == .done)
        #expect(runtime.messages == history)
        #expect(runtime.input == "下一条普通问题")
        #expect(runtime.queuedMessages.first?.text == "排队的追问")
        #expect(runtime.goalTurnRecoveryCheckpoint == nil)
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        runtime.persist(touchUpdatedAt: false)
        defer { AgentSessionStore.delete(id: runtime.id) }
        let saved = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(runtime.session))
        #expect(saved.interactionMode == .normal)
        #expect(AgentRuntime(session: saved).interactionMode == .normal)
    }

    @Test("旧会话中的已完成 Goal 恢复后也为普通模式")
    func completedLegacySessionRestoresAsOrdinary() {
        let goal = AgentGoal(statement: "Finished", checklist: [.init(text: "Verified", done: true)])
        let restored = AgentRuntime(session: AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: .done, summary: "", stepTexts: ["Verified"]),
            currentGoal: goal,
            goalPlanningState: .init(goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
                                     phase: .completed, members: [])
        ))
        #expect(restored.interactionMode == .normal)
        #expect(restored.session.interactionMode == .normal)
        #expect(restored.currentGoal == goal)
        #expect(restored.goalPlanningState?.phase == .completed)
    }

    @Test("后续普通回合不重新启动历史 Goal 计时或套用 Goal 参数")
    func ordinaryFollowUpDoesNotReopenGoalBudget() throws {
        let suite = "goal-completion-mode-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let runtime = runtime()
        runtime.currentPlan?.status = .done
        runtime.currentGoal?.checklist[0].done = true
        var budget = AgentGoalContinuationBudget(wallClockLimit: 60)
        budget.activeElapsedSeconds = 17
        runtime.currentGoal?.continuationBudget = budget
        #expect(runtime.returnToNormalModeAfterGoalCompletion())
        let completedGoal = runtime.currentGoal
        let parameters = AgentRuntimeParameters()
        runtime.runtimeParameters = parameters
        runtime.isResponding = true
        app.applySharedGoalLimits(for: runtime)
        #expect(runtime.currentGoal == completedGoal)
        #expect(runtime.runtimeParameters == parameters)
        #expect(runtime.currentGoal?.continuationBudget?.segmentStartedAt == nil)
    }

    @Test("计划完成但验收未完成、空清单、无目标及预算暂停都不退出")
    func unfinishedGoalKeepsItsMode() {
        let runtime = runtime()
        runtime.currentPlan?.status = .done
        runtime.currentGoal?.continuationBudget = .init(wrapUpDispatched: true)
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .goal)
        runtime.currentGoal?.checklist = []
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        runtime.currentGoal = nil
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .goal)
    }

    @Test("验收勾选不能绕过未结束计划", arguments: [AgentPlan.Status.approved, .executing])
    func unfinishedPlanKeepsGoalMode(_ status: AgentPlan.Status) {
        let runtime = runtime()
        runtime.currentPlan?.status = status
        runtime.currentGoal?.checklist[0].done = true
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .goal)
    }

    @Test("验收候选未通过宿主复核不得退出", arguments: [
        AgentGoalVerification.Phase.pending, .verifying, .rejected,
    ])
    func unverifiedClaimKeepsGoalMode(_ phase: AgentGoalVerification.Phase) throws {
        let runtime = runtime()
        runtime.currentPlan?.status = .done
        runtime.currentGoal?.checklist[0].done = true
        let goal = try #require(runtime.currentGoal)
        runtime.currentGoal?.verification = .init(id: UUID(), messageID: UUID(),
            contractDigest: AgentGoalVerification.contractDigest(goal),
            criterionIDs: goal.checklist.map(\.id), phase: phase)
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .goal)
        #expect(AgentRuntime(session: AgentSession(interactionMode: .goal,
            currentPlan: runtime.currentPlan, currentGoal: runtime.currentGoal)).interactionMode == .goal)
    }

    @Test("只完成中间阶段仍为目标模式，最后阶段完成才退出")
    func roadmapMustBeComplete() {
        let runtime = runtime()
        runtime.currentPlan?.status = .done
        runtime.currentGoal?.checklist[0].done = true
        runtime.goalRoadmap = .init(phases: [
            .init(id: "P1", title: "Implementation", acceptanceCriteria: ["Implemented"], status: .completed),
            .init(id: "P2", title: "Delivery", acceptanceCriteria: ["Delivered"], status: .planning),
        ])
        #expect(!runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .goal)
        runtime.goalRoadmap?.phases[1].status = .completed
        #expect(runtime.returnToNormalModeAfterGoalCompletion())
        #expect(runtime.interactionMode == .normal)
    }
}
