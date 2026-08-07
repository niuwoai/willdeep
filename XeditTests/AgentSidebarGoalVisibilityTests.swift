import Foundation
import Testing
@testable import WillDeep

/// Goal-board projection is additive. Composer mode and goal metadata must not
/// remove a workspace conversation from the sidebar.
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

    // MARK: Goal-board projection

    @Test("a session with a real goal remains in the sidebar and also appears on the board")
    func statedGoalAppearsOnBothSurfaces() {
        let stated = session(
            goal: AgentGoal(statement: "Ship the charging-station screen"),
            interactionMode: .goal
        )

        #expect(stated.belongsInWorkspaceSidebar)
        #expect(boardAdopts(stated))
    }

    @Test("a checklist alone is enough to count as a real goal")
    func checklistOnlyGoalCountsAsStated() {
        let stated = session(
            goal: AgentGoal(checklist: [.init(text: "Tapping a station navigates")]),
            interactionMode: .goal
        )

        #expect(stated.belongsInWorkspaceSidebar)
        #expect(boardAdopts(stated))
    }

    // MARK: Scope ownership

    @Test("every workspace-scoped session remains in the conversation sidebar")
    func workspaceScopeAlwaysKeepsConversationVisible() {
        let cases: [AgentSession] = [
            session(),
            session(interactionMode: .goal),
            session(goal: AgentGoal(), interactionMode: .goal),
            session(goal: AgentGoal(statement: "Ship it"), interactionMode: .goal),
            session(goal: AgentGoal(checklist: [.init(text: "Done")])),
            session(workspacePath: nil),
        ]

        for candidate in cases {
            #expect(candidate.belongsInWorkspaceSidebar)
        }
    }

    @Test("switching Composer mode preserves messages, plan, goal, and sidebar membership")
    func composerModeSwitchIsPresentationNeutral() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession(inWorkspaceAt: "/tmp/xedit-mode-switch")
        let runtime = try #require(appState.activeRuntime)
        let user = AgentMessage(role: .user, content: "检查服务")
        let progress = AgentMessage(role: .assistant, content: "正在读取日志")
        let goal = AgentGoal(statement: "检查服务健康")
        let plan = AgentPlan(
            status: .executing,
            steps: [.init(text: "读取日志", status: .inProgress)]
        )
        runtime.messages = [user, progress]
        runtime.currentGoal = goal
        runtime.currentPlan = plan

        appState.setAgentInteractionMode(.goal)
        appState.setAgentInteractionMode(.normal)

        #expect(appState.activeAgentSessionID == session.id)
        #expect(runtime.messages.map(\.id) == [user.id, progress.id])
        #expect(runtime.currentGoal == goal)
        #expect(runtime.currentPlan == plan)
        #expect(runtime.session.belongsInWorkspaceSidebar)
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
