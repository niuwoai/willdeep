import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentGoalLaunchRecoveryTests {
    @Test("live Goal execution checkpoint resumes after launch")
    func liveExecutionResumes() {
        let session = makeSession(
            planStatus: .executing,
            checkpoint: AgentGoalTurnRecoveryCheckpoint()
        )

        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .resumeExecution)
    }

    @Test("unfinished Goal without checkpoint stays paused")
    func unfinishedWithoutCheckpointStaysPaused() {
        let session = makeSession(planStatus: .executing)

        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .none)
    }

    @Test("Plan approval remains an explicit user gate after launch")
    func proposedPlanDoesNotResume() {
        let session = makeSession(
            planStatus: .proposed,
            checkpoint: AgentGoalTurnRecoveryCheckpoint()
        )

        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .discardStaleCheckpoint)
    }

    @Test("interrupted Goal Teams planning restarts")
    @MainActor
    func interruptedPlanningRestarts() {
        let goal = makeGoal()
        var session = makeSession(planStatus: nil)
        session.goalPlanningState = makePlanningState(goal: goal, phase: .collecting)

        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .restartPlanning)

        let restoredRuntime = AgentRuntime(session: session)
        var restoredSession = restoredRuntime.session
        restoredSession.goalPlanningState = restoredRuntime.goalPlanningState
        #expect(restoredSession.goalPlanningState?.phase == .blocked)
        #expect(AgentGoalLaunchRecoveryPolicy.reconciledAction(
            catalogAction: .restartPlanning,
            restoredSession: restoredSession
        ) == .restartPlanning)
    }

    @Test("blocked Goal planning waits for manual retry")
    func blockedPlanningDoesNotRestart() {
        let goal = makeGoal()
        var session = makeSession(planStatus: nil)
        session.goalPlanningState = makePlanningState(goal: goal, phase: .blocked)

        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session) == .none)
    }

    @Test("archived and completed Goals never auto-resume")
    func archivedAndCompletedGoalsDoNotResume() {
        var archived = makeSession(
            planStatus: .executing,
            checkpoint: AgentGoalTurnRecoveryCheckpoint()
        )
        archived.archivedAt = Date()
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: archived) == .discardStaleCheckpoint)

        var completed = makeSession(
            planStatus: .executing,
            checkpoint: AgentGoalTurnRecoveryCheckpoint()
        )
        completed.currentGoal?.checklist[0].done = true
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: completed) == .discardStaleCheckpoint)
    }

    @Test("checkpoint arming requires native approved Goal work")
    func checkpointArmingIsNarrow() {
        let goal = makeGoal()
        let approved = makePlan(status: .approved)

        #expect(AgentGoalLaunchRecoveryPolicy.shouldArmExecutionCheckpoint(
            interactionMode: .goal,
            executionAgent: .willDeep,
            goal: goal,
            plan: approved
        ))
        #expect(!AgentGoalLaunchRecoveryPolicy.shouldArmExecutionCheckpoint(
            interactionMode: .normal,
            executionAgent: .willDeep,
            goal: goal,
            plan: approved
        ))
        #expect(!AgentGoalLaunchRecoveryPolicy.shouldArmExecutionCheckpoint(
            interactionMode: .goal,
            executionAgent: .claudeCode,
            goal: goal,
            plan: approved
        ))
    }

    @Test("recovery prompt preserves approval gates and checks side effects")
    func recoveryPromptIsConservative() {
        let notice = AgentGoalLaunchRecoveryPolicy.executionContinuationNotice(
            checkpoint: AgentGoalTurnRecoveryCheckpoint()
        )

        #expect(notice.contains("never assume it failed"))
        #expect(notice.contains("Preserve normal approval and confirmation gates"))
        #expect(notice.contains("progress and goal-check blocks"))
    }

    @MainActor
    @Test("explicit Stop clears launch recovery authority immediately")
    func explicitStopClearsCheckpoint() {
        let appState = AppState()
        appState.startNewAgentSession()
        let runtime = appState.activeRuntime
        runtime?.interactionMode = .goal
        runtime?.currentGoal = makeGoal()
        runtime?.currentPlan = makePlan(status: .executing)
        runtime?.goalTurnRecoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint()
        runtime?.isResponding = true

        appState.stopAgentResponse()

        #expect(runtime?.goalTurnRecoveryCheckpoint == nil)
    }

    private func makeSession(
        planStatus: AgentPlan.Status?,
        checkpoint: AgentGoalTurnRecoveryCheckpoint? = nil
    ) -> AgentSession {
        AgentSession(
            interactionMode: .goal,
            currentPlan: planStatus.map(makePlan),
            currentGoal: makeGoal(),
            goalTurnRecoveryCheckpoint: checkpoint
        )
    }

    private func makeGoal() -> AgentGoal {
        AgentGoal(
            statement: "Ship reliable launch recovery",
            checklist: [AgentGoal.Item(text: "Recovery verified")]
        )
    }

    private func makePlan(status: AgentPlan.Status) -> AgentPlan {
        AgentPlan(
            status: status,
            steps: [AgentPlan.Step(text: "Resume safely", status: .inProgress)],
            summary: ""
        )
    }

    private func makePlanningState(
        goal: AgentGoal,
        phase: AgentGoalPlanningState.Phase
    ) -> AgentGoalPlanningState {
        AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal),
            phase: phase,
            members: [
                .init(roleID: "requirements", displayName: "Requirements", status: .running),
                .init(roleID: "architecture", displayName: "Architecture", status: .pending),
                .init(roleID: "testing", displayName: "Testing", status: .pending),
            ]
        )
    }
}
