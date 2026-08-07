import Foundation
import Testing
@testable import WillDeep

/// The reported path, step by step: switch a working conversation to Goal
/// mode, then click away to another chat. The conversation was reachable from
/// neither surface — "永远回不来了". These pin the whole route, not just the
/// first step, because the first step alone (mode switch) already looked fine
/// once the session was still selected.
///
/// The invariant every case here defends is reachability: no state may fall
/// between the sidebar and the Goals board. A workspace conversation now keeps
/// its sidebar seat in every mode, and the board projects goal-bearing ones on
/// top of that, so the two surfaces overlap instead of partitioning.
@Suite
@MainActor
struct AgentGoalModeSessionRecoveryTests {
    private let workspace = "/Users/rocky/Sites/tokenhub"

    private func session(
        title: String,
        goal: AgentGoal? = nil,
        interactionMode: AgentInteractionMode = .normal,
        withUserMessage: Bool = true,
        workspacePath: String? = nil
    ) -> AgentSession {
        AgentSession(
            title: title,
            workspaceRootPath: workspacePath ?? workspace,
            messages: withUserMessage ? [AgentMessage(role: .user, content: "帮我分析下当前项目")] : [],
            interactionMode: interactionMode,
            currentGoal: goal
        )
    }

    /// Mirrors `AgentDispatchCoordinator.synchronizedGoals`' adoption test.
    private func boardAdopts(_ session: AgentSession) -> Bool {
        session.hasBoardGoal && session.dispatchParentProjectID == nil
    }

    @Test("a Goal-mode conversation stays in the sidebar after switching away")
    func goalModeSessionSurvivesSwitchingAway() {
        // The exact report: Goal mode is on, no goal stated yet, and the
        // conversation has real content behind it.
        let goalSession = session(title: "分析当前项目", interactionMode: .goal)
        let other = session(title: "另一个聊天")

        // Click the other chat — the goal session is no longer active.
        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [goalSession, other],
            activeID: other.id
        )

        #expect(visible.contains { $0.id == goalSession.id }, "the Goal-mode chat disappeared once it stopped being active")
        #expect(visible.contains { $0.id == other.id })
    }

    @Test("its workspace group is still there to click back into")
    func workspaceGroupStillListsIt() {
        let goalSession = session(title: "分析当前项目", interactionMode: .goal)
        let other = session(title: "另一个聊天", workspacePath: "/Users/rocky/Sites/other")

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [goalSession, other],
            activeID: other.id
        )

        // Even with the active chat in a different workspace, tokenhub's
        // group must survive — that group vanishing is what made the
        // conversation unreachable.
        #expect(visible.contains { $0.workspaceSidebarGroupKey == workspace })
    }

    /// This used to assert the opposite — that stating a goal *removed* the
    /// conversation from the sidebar and handed ownership to the board. That
    /// stopped being true in cc97ab60, which redefined
    /// `belongsInWorkspaceSidebar` as `presentationScope == .workspace` so a
    /// workspace conversation keeps its sidebar seat whether it is ordinary or
    /// Goal-driven. The board became an additional projection rather than a
    /// transfer of ownership, which serves this suite's actual concern (never
    /// unreachable) strictly better: two surfaces beat one.
    @Test("once a goal is stated the board shows it without taking it out of the sidebar")
    func statedGoalIsReachableThroughTheBoard() {
        let stated = session(
            title: "分析当前项目",
            goal: AgentGoal(statement: "把充电站点击跳转修好"),
            interactionMode: .goal
        )

        // It keeps its place in the workspace group...
        #expect(stated.belongsInWorkspaceSidebar)
        // ...and the board adopts it as well, with selectDispatchGoal routing
        // back to goal.sessionID.
        #expect(boardAdopts(stated))
    }

    @Test("no state falls between the two surfaces")
    func everyStepOfTheReportedPathIsReachable() {
        let steps: [(String, AgentSession)] = [
            ("普通模式", session(title: "起点")),
            ("刚切目标、未定目标", session(title: "切换后", interactionMode: .goal)),
            ("目标对象为空", session(title: "空目标", goal: AgentGoal(), interactionMode: .goal)),
            ("已定目标", session(title: "已定目标", goal: AgentGoal(statement: "修复跳转"), interactionMode: .goal)),
        ]

        for (label, candidate) in steps {
            let reachable = candidate.belongsInWorkspaceSidebar || boardAdopts(candidate)
            #expect(reachable, "\(label)：会话在侧栏与目标看板中都不可见")
        }
    }

    @Test("the empty-chat rule is unrelated to Goal mode")
    func emptyChatHidingIsNotAGoalRegression() {
        // A brand-new chat with no messages is hidden once you click away
        // and the workspace already has real history. That predates Goal
        // mode and applies to normal chats identically — worth pinning so
        // it is not mistaken for this bug returning.
        let emptyNormal = session(title: "空的普通会话", withUserMessage: false)
        let emptyGoal = session(title: "空的目标会话", interactionMode: .goal, withUserMessage: false)
        let withHistory = session(title: "有历史")

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [emptyNormal, emptyGoal, withHistory],
            activeID: withHistory.id
        )

        #expect(!visible.contains { $0.id == emptyNormal.id })
        // Same treatment, same reason — not a Goal-mode problem.
        #expect(!visible.contains { $0.id == emptyGoal.id })
    }
}
