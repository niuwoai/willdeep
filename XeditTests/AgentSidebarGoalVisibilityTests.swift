import Foundation
import Testing
@testable import WillDeep

/// The workspace sidebar and the Goals board must partition sessions: every
/// workspace-scoped session belongs to exactly one of them. A gap between the
/// two filters is not a cosmetic bug — the conversation disappears from the
/// app entirely, and takes its workspace group with it when it is the only
/// session there.
@Suite
@MainActor
struct AgentSidebarGoalVisibilityTests {
    private func session(
        goal: AgentGoal? = nil,
        interactionMode: AgentInteractionMode = .normal,
        scope: AgentSessionPresentationScope = .workspace,
        workspacePath: String? = "/Users/rocky/Sites/juhe"
    ) -> AgentSession {
        AgentSession(
            title: "分析当前项目",
            workspaceRootPath: workspacePath,
            presentationScope: scope,
            interactionMode: interactionMode,
            currentGoal: goal
        )
    }

    /// Mirrors `AgentDispatchCoordinator.synchronizedGoals`' adoption test.
    private func boardAdopts(_ session: AgentSession) -> Bool {
        session.hasBoardGoal && session.dispatchParentProjectID == nil
    }

    // MARK: The reported bug

    @Test("switching to Goal mode before stating a goal keeps the session visible")
    func goalModeWithoutGoalStaysInSidebar() {
        // The exact reported state: the user pressed 目标 and the goal has not
        // been defined yet.
        let switched = session(goal: nil, interactionMode: .goal)

        #expect(switched.belongsInWorkspaceSidebar)
        // And the board would not have taken it either — which is what made
        // it vanish from both surfaces.
        #expect(!boardAdopts(switched))
    }

    @Test("an empty goal object also keeps the session in the sidebar")
    func emptyGoalStaysInSidebar() {
        let switched = session(goal: AgentGoal(), interactionMode: .goal)

        #expect(switched.belongsInWorkspaceSidebar)
        #expect(!boardAdopts(switched))
    }

    @Test("the workspace group survives switching its only session to Goal mode")
    func workspaceGroupSurvivesModeSwitch() {
        let only = session(goal: nil, interactionMode: .goal)

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [only],
            activeID: only.id
        )

        #expect(visible.count == 1)
        #expect(visible.first?.workspaceSidebarGroupKey == "/Users/rocky/Sites/juhe")
    }

    // MARK: The original intent, still honored

    @Test("a session with a real goal moves to the board and leaves the sidebar")
    func statedGoalMovesToBoard() {
        let stated = session(
            goal: AgentGoal(statement: "Ship the charging-station screen"),
            interactionMode: .goal
        )

        #expect(!stated.belongsInWorkspaceSidebar)
        #expect(boardAdopts(stated))
    }

    @Test("a checklist alone is enough to count as a real goal")
    func checklistOnlyGoalCountsAsStated() {
        let stated = session(
            goal: AgentGoal(checklist: [.init(text: "Tapping a station navigates")]),
            interactionMode: .goal
        )

        #expect(!stated.belongsInWorkspaceSidebar)
        #expect(boardAdopts(stated))
    }

    // MARK: The partition itself

    @Test("every workspace-scoped session lands on exactly one surface")
    func surfacesPartitionWorkspaceSessions() {
        let cases: [AgentSession] = [
            session(),
            session(interactionMode: .goal),
            session(goal: AgentGoal(), interactionMode: .goal),
            session(goal: AgentGoal(statement: "Ship it"), interactionMode: .goal),
            session(goal: AgentGoal(checklist: [.init(text: "Done")])),
            session(workspacePath: nil),
        ]

        for candidate in cases {
            let inSidebar = candidate.belongsInWorkspaceSidebar
            let onBoard = boardAdopts(candidate)
            #expect(
                inSidebar != onBoard,
                "session with goal=\(String(describing: candidate.currentGoal?.statement)) mode=\(candidate.interactionMode.rawValue) appeared \(inSidebar && onBoard ? "twice" : "nowhere")"
            )
        }
    }

    @Test("dispatch-board child sessions stay out of the workspace sidebar")
    func dispatchChildrenStayOut() {
        // Scheduler-owned task sessions have their own surface and must not
        // reappear among ordinary conversations.
        let child = session(scope: .dispatchBoard)

        #expect(!child.belongsInWorkspaceSidebar)
    }

    @Test("roundtable sessions stay out of the workspace sidebar")
    func roundtableStaysOut() {
        #expect(!session(scope: .roundtable).belongsInWorkspaceSidebar)
    }
}
