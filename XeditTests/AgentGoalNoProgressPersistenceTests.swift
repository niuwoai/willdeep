import Foundation
import Testing
@testable import WillDeep

/// The no-progress round counter picks the backoff rung. It used to live
/// only in AgentRuntime memory, so a relaunch (or runtime eviction) dropped a
/// stuck Goal back to plain guidance. It now rides on the persisted budget.
@MainActor
@Suite("Goal 无进展计数跨重启持久化", .serialized)
struct AgentGoalNoProgressPersistenceTests {
    private func makeRuntime() -> (AppState, AgentRuntime) {
        let goal = AgentGoal(statement: "Ship safely", checklist: [.init(text: "Verified")])
        let session = AgentSession(
            interactionMode: .goal,
            currentPlan: AgentPlan(status: .done, summary: "", stepTexts: ["done"]),
            currentGoal: goal,
            goalPlanningState: AgentGoalPlanningState(
                goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal), phase: .executing, members: [])
        )
        let appState = AppState()
        let runtime = AgentRuntime(session: session)
        // Responding: continuations queue instead of reaching a provider.
        runtime.isResponding = true
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]
        return (appState, runtime)
    }

    @Test("连续无进展累计落盘，重建 runtime 后续上同一档退避")
    func counterSurvivesRelaunch() throws {
        let (appState, runtime) = makeRuntime()
        defer { AgentSessionStore.delete(id: runtime.id) }
        let rounds = AgentGoalContinuationPolicy.reconcileRounds + 1
        for _ in 0..<rounds {
            appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime, didAdvanceChecklist: false)
        }
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == rounds)
        #expect(runtime.currentGoal?.continuationBudget?.continuationsUsed == rounds)
        #expect(runtime.session.currentGoal?.continuationBudget?.roundsWithoutChecklistProgress == rounds)

        let persisted = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(runtime.session))
        let relaunched = AgentRuntime(session: persisted)
        #expect(relaunched.consecutiveGoalRoundsWithoutChecklistProgress == rounds)
        #expect(AgentGoalContinuationPolicy.rung(forRoundsWithoutProgress:
            relaunched.consecutiveGoalRoundsWithoutChecklistProgress) == .backoff)
    }

    @Test("有进展即归零且不留字段；Play 开新段清零")
    func progressAndNewSegmentReset() {
        let (appState, runtime) = makeRuntime()
        defer { AgentSessionStore.delete(id: runtime.id) }
        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime, didAdvanceChecklist: false)
        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime, didAdvanceChecklist: false)
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == 2)
        appState.prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime, didAdvanceChecklist: true)
        #expect(runtime.consecutiveGoalRoundsWithoutChecklistProgress == 0)
        #expect(runtime.currentGoal?.continuationBudget?.roundsWithoutChecklistProgress == nil)

        runtime.consecutiveGoalRoundsWithoutChecklistProgress = 3
        #expect(runtime.currentGoal?.continuationBudget?.restarted.roundsWithoutChecklistProgress == nil)
    }

    @Test("旧会话预算 JSON 没有计数字段按 0 解码；无 Goal 时读写安全")
    func legacyDecodeAndNoGoal() throws {
        let raw = #"{"wallClockLimit":14400,"maximumContinuations":64,"continuationsUsed":3,"wrapUpDispatched":false}"#
        let legacy = try JSONDecoder().decode(AgentGoalContinuationBudget.self, from: Data(raw.utf8))
        #expect(legacy.roundsWithoutChecklistProgress == nil)
        #expect(legacy.continuationsUsed == 3)
        var goal = AgentGoal(statement: "x", checklist: [.init(text: "y")])
        goal.continuationBudget = legacy
        #expect(AgentRuntime(session: AgentSession(interactionMode: .goal, currentGoal: goal))
            .consecutiveGoalRoundsWithoutChecklistProgress == 0)

        let bare = AgentRuntime(session: AgentSession())
        bare.consecutiveGoalRoundsWithoutChecklistProgress = 4
        #expect(bare.consecutiveGoalRoundsWithoutChecklistProgress == 0)
        #expect(bare.currentGoal == nil)
    }
}
