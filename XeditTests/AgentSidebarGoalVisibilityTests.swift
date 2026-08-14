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
    /// Keep in step with it: the console only owns what was started inside it.
    private func boardAdopts(_ session: AgentSession) -> Bool {
        session.presentationScope == .dispatchBoard
            && session.hasBoardGoal
            && session.dispatchParentProjectID == nil
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

    @Test("普通会话里定下的 Goal 留在侧边栏，但不会被收编成调度台项目")
    func statedGoalStaysOutOfTheConsole() {
        // 从 composer 切到目标模式不改 presentationScope，会话仍属工作区。
        // 调度台是独立系统，不该凭"有 Goal"就把它收进去。
        let stated = session(
            goal: AgentGoal(statement: "Ship the charging-station screen"),
            interactionMode: .goal
        )

        #expect(stated.presentationScope == .workspace)
        #expect(stated.belongsInWorkspaceSidebar)
        #expect(!boardAdopts(stated))
    }

    @Test("在调度台里创建的项目才进调度台")
    func consoleCreatedGoalIsAdopted() {
        let created = session(
            goal: AgentGoal(statement: "Ship the charging-station screen"),
            interactionMode: .goal,
            scope: .dispatchBoard
        )

        #expect(boardAdopts(created))
        #expect(!created.belongsInWorkspaceSidebar)
    }

    @Test("a checklist alone is enough to count as a real goal")
    func checklistOnlyGoalCountsAsStated() {
        let stated = session(
            goal: AgentGoal(checklist: [.init(text: "Tapping a station navigates")]),
            interactionMode: .goal,
            scope: .dispatchBoard
        )

        #expect(stated.hasBoardGoal)
        #expect(boardAdopts(stated))
    }

    private func snapshot(
        scope: AgentSessionPresentationScope,
        parentProjectID: UUID? = nil
    ) -> AgentWorkspaceSessionSnapshot {
        AgentWorkspaceSessionSnapshot(
            id: UUID(),
            title: "分析当前项目",
            workspaceRootPath: "/Users/rocky/Sites/juhe",
            workspaceDisplayName: "juhe",
            presentationScope: scope,
            isActive: false,
            isPinned: false,
            isArchived: false,
            isResponding: false,
            isAwaitingProviderSlot: false,
            queuedMessageCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            interactionMode: .goal,
            approvalMode: .smart,
            executionAgent: .willDeep,
            titleIsUserSet: false,
            goalStatement: "把充电站点击跳转修好",
            goalCompletedItemCount: 0,
            goalTotalItemCount: 1,
            goalIsComplete: false,
            goalPlanningPhase: nil,
            dispatchParentProjectID: parentProjectID,
            dispatchTaskID: nil,
            isDispatchProject: scope == .dispatchBoard && parentProjectID == nil,
            isDispatchPaused: false
        )
    }

    @Test("调度台的项目与子任务都算调度台自有，普通会话不算")
    func dispatchOwnershipCoversProjectsAndTasks() {
        // composer 顶部的 Goal 提示条据此过滤：调度台自有的会话不该在普通
        // 会话里冒出来，因为那条"打开"会把用户带离当前对话、切进调度台。
        #expect(snapshot(scope: .dispatchBoard).isDispatchOwned)
        #expect(snapshot(scope: .dispatchBoard, parentProjectID: UUID()).isDispatchOwned)
        // 子任务即便 scope 被写成 workspace，也仍归调度台所有。
        #expect(snapshot(scope: .workspace, parentProjectID: UUID()).isDispatchOwned)
        #expect(!snapshot(scope: .workspace).isDispatchOwned)
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
