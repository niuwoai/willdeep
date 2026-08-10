//
//  AppStateAgentGoalRecovery.swift
//  WillDeep
//
//  Launch-time recovery for Goal-mode work. A durable execution checkpoint
//  distinguishes a model turn that was genuinely live when the process ended
//  from an incomplete Plan that the user intentionally paused. Goal Teams
//  planning has its own persisted phase ledger and is restarted only from
//  phases that represented in-flight work.
//

import Foundation

nonisolated enum AgentGoalLaunchRecoveryAction: Equatable {
    case none
    case restartPlanning
    case resumePhasePlanning
    case resumeExecution
    case discardStaleCheckpoint
}

nonisolated enum AgentGoalLaunchRecoveryPolicy {
    private static let terminalPlanStepStatuses: Set<AgentPlan.StepStatus> = [
        .done,
        .skipped,
        .failed,
    ]

    static func action(for session: AgentSession) -> AgentGoalLaunchRecoveryAction {
        let hasCheckpoint = session.goalTurnRecoveryCheckpoint != nil
        guard session.archivedAt == nil,
              session.presentationScope != .dispatchBoard,
              session.interactionMode == .goal,
              session.executionAgent == .willDeep,
              let goal = session.currentGoal,
              !goal.isEmpty,
              !isGoalComplete(goal) else {
            return hasCheckpoint ? .discardStaleCheckpoint : .none
        }

        if let plan = session.currentPlan,
           plan.status == .approved || plan.status == .executing,
           plan.steps.contains(where: { !terminalPlanStepStatuses.contains($0.status) }) {
            // The checkpoint is the only launch-time authority to restart an
            // executing Plan. Without it, the same shape may simply mean the
            // user pressed Stop and chose to leave the Plan unfinished.
            return hasCheckpoint ? .resumeExecution : .none
        }

        if let plan = session.currentPlan, plan.status == .proposed {
            // Explicit Plan approval never survives as implied permission.
            return hasCheckpoint ? .discardStaleCheckpoint : .none
        }

        if session.currentPlan == nil,
           session.goalRoadmap?.activePhase?.status == .planning {
            return .resumePhasePlanning
        }

        let planningCanRestart: Bool
        switch session.goalPlanningState?.phase {
        case nil:
            // `setAgentGoal` persists the definition immediately before it
            // launches planners. A process exit in that tiny gap leaves no
            // ledger, but the user's intent to begin planning is unambiguous.
            planningCanRestart = session.currentPlan == nil
                || session.currentPlan?.status == .rejected
                || session.currentPlan?.status == .done
        case .collecting, .arbitrating, .readyForProposal:
            planningCanRestart = true
        case .awaitingApproval, .executing, .completed, .blocked:
            planningCanRestart = false
        }

        if planningCanRestart {
            return .restartPlanning
        }
        return hasCheckpoint ? .discardStaleCheckpoint : .none
    }

    static func reconciledAction(
        catalogAction: AgentGoalLaunchRecoveryAction,
        restoredSession: AgentSession
    ) -> AgentGoalLaunchRecoveryAction {
        // AgentRuntime deliberately normalizes an interrupted planning ledger
        // to `.blocked`, because runtime-only network work cannot itself be
        // reconstructed. Launch recovery has the persisted catalog snapshot
        // needed to distinguish that interruption from a real/manual block,
        // so it may start a fresh planning generation. All execution recovery
        // decisions are revalidated against normalized live state.
        if catalogAction == .restartPlanning {
            guard restoredSession.archivedAt == nil,
                  restoredSession.presentationScope != .dispatchBoard,
                  restoredSession.interactionMode == .goal,
                  restoredSession.executionAgent == .willDeep,
                  let goal = restoredSession.currentGoal,
                  !goal.isEmpty,
                  !isGoalComplete(goal),
                  restoredSession.currentPlan == nil
                    || restoredSession.currentPlan?.status == .rejected
                    || restoredSession.currentPlan?.status == .done else {
                return action(for: restoredSession)
            }
            return .restartPlanning
        }
        return action(for: restoredSession)
    }

    static func shouldArmExecutionCheckpoint(
        interactionMode: AgentInteractionMode,
        executionAgent: AgentExecutionAgent,
        goal: AgentGoal?,
        plan: AgentPlan?
    ) -> Bool {
        guard interactionMode == .goal,
              executionAgent == .willDeep,
              let goal,
              !goal.isEmpty,
              !isGoalComplete(goal),
              let plan,
              plan.status == .approved || plan.status == .executing else {
            return false
        }
        return plan.steps.contains { !terminalPlanStepStatuses.contains($0.status) }
    }

    static func executionContinuationNotice(
        checkpoint: AgentGoalTurnRecoveryCheckpoint
    ) -> String {
        """
        WillDeep launch recovery: the app process stopped while this approved Goal-backed Plan was executing. Resume the same Goal from the persisted non-terminal step statuses.

        Before repeating any write, command, network request, or other external side effect, inspect the current workspace and conversation evidence. An interrupted tool call may already have changed external state, so never assume it failed merely because its response is incomplete. Preserve normal approval and confirmation gates. Continue until the Plan reaches a terminal state, and end each reply with the required progress and goal-check blocks.

        Recovery checkpoint: \(checkpoint.id.uuidString)
        """
    }

    static func phasePlanningContinuationNotice(roadmap: AgentGoalRoadmap) -> String? {
        guard let phase = roadmap.activePhase else { return nil }
        let phaseID = AgentContextBuilder.escapedUntrustedContext(phase.id)
        let phaseTitle = AgentContextBuilder.escapedUntrustedContext(phase.title)
        let acceptance = phase.acceptanceCriteria.map {
            "- \(AgentContextBuilder.escapedUntrustedContext($0))"
        }.joined(separator: "\n")
        return """
        WillDeep launch recovery: resume planning the active Goal phase only.
        <active_goal_phase id="\(phaseID)" position="\(roadmap.phasePositionText)">
        \(phaseTitle)
        </active_goal_phase>
        <phase_acceptance>
        \(acceptance)
        </phase_acceptance>
        Emit exactly one numbered fenced `plan` block with at most \(AgentGoalRoadmap.maximumStepsPerPhase) steps. Do not replace the roadmap, repeat completed phases, or call tools in this planning reply.
        """
    }

    private static func isGoalComplete(_ goal: AgentGoal) -> Bool {
        !goal.checklist.isEmpty && goal.checklist.allSatisfy(\.done)
    }
}

@MainActor
private final class AgentGoalLaunchRecoveryCoordinator {
    static let shared = AgentGoalLaunchRecoveryCoordinator()

    private var claimedSessionIDs: Set<AgentSession.ID> = []

    func claim(_ sessionID: AgentSession.ID) -> Bool {
        claimedSessionIDs.insert(sessionID).inserted
    }
}

@MainActor
extension AppState {
    /// Called by the real Agent window after the async session catalog load.
    /// The process-wide coordinator prevents a later editor-window AppState
    /// from launching the same recovery a second time during this app run.
    @discardableResult
    func resumeInterruptedGoalSessionsAfterLaunch() -> [AgentSession.ID] {
        guard hasLoadedAgentSessionCatalog else { return [] }

        var resumedSessionIDs: [AgentSession.ID] = []
        for catalogSession in agentSessions {
            let catalogAction = AgentGoalLaunchRecoveryPolicy.action(for: catalogSession)
            guard catalogAction != .none,
                  AgentGoalLaunchRecoveryCoordinator.shared.claim(catalogSession.id),
                  let runtime = runtime(for: catalogSession.id) else {
                continue
            }

            seedPersistedSessionModelOverride(for: runtime)
            var liveSession = runtime.session
            liveSession.currentPlan = runtime.currentPlan
            liveSession.currentGoal = runtime.currentGoal
            liveSession.goalPlanningState = runtime.goalPlanningState
            liveSession.goalRoadmap = runtime.goalRoadmap
            liveSession.goalTurnRecoveryCheckpoint = runtime.goalTurnRecoveryCheckpoint
            let liveAction = AgentGoalLaunchRecoveryPolicy.reconciledAction(
                catalogAction: catalogAction,
                restoredSession: liveSession
            )

            switch liveAction {
            case .none:
                continue
            case .discardStaleCheckpoint:
                runtime.goalTurnRecoveryCheckpoint = nil
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            case .restartPlanning:
                guard !runtime.isResponding else { continue }
                let revisionNote = runtime.goalPlanningState?.revisionNote
                runtime.goalTurnRecoveryCheckpoint = nil
                if startAgentGoalPlanningIfNeeded(
                    for: runtime,
                    forceRestart: true,
                    revisionNote: revisionNote
                ) {
                    resumedSessionIDs.append(runtime.id)
                }
            case .resumePhasePlanning:
                guard !runtime.isResponding,
                      !runtime.isAwaitingProviderSlot,
                      let roadmap = runtime.goalRoadmap,
                      let notice = AgentGoalLaunchRecoveryPolicy
                        .phasePlanningContinuationNotice(roadmap: roadmap) else {
                    continue
                }
                dispatchAgentMessage(
                    for: runtime,
                    text: notice,
                    images: [],
                    source: .hostInstruction
                )
                resumedSessionIDs.append(runtime.id)
            case .resumeExecution:
                guard !runtime.isResponding,
                      !runtime.isAwaitingProviderSlot,
                      let checkpoint = runtime.goalTurnRecoveryCheckpoint else {
                    continue
                }
                dispatchAgentMessage(
                    for: runtime,
                    text: AgentGoalLaunchRecoveryPolicy.executionContinuationNotice(
                        checkpoint: checkpoint
                    ),
                    images: [],
                    source: .hostInstruction
                )
                resumedSessionIDs.append(runtime.id)
            }
        }
        return resumedSessionIDs
    }
}
