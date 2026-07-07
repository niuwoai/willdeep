import Foundation
import Testing
@testable import WillDeep

struct AgentRecentSessionEdgeRailTests {
    @Test("recent edge rail shows chatted active sessions by activity, not pinned order")
    func recentItemsFilterAndSortByActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let xeditPath = "/tmp/Xedit"
        let teamifyPath = "/tmp/Teamify"
        let hiddenPath = "/tmp/Hidden"

        let older = session(
            title: "Older chat",
            workspace: xeditPath,
            userAt: now.addingTimeInterval(-3_600),
            assistantAt: now.addingTimeInterval(-3_500),
            pinnedAt: now
        )
        let newer = session(
            title: "Newer chat",
            workspace: teamifyPath,
            userAt: now.addingTimeInterval(-120),
            assistantAt: now.addingTimeInterval(-60)
        )
        let hidden = session(
            title: "Hidden chat",
            workspace: hiddenPath,
            userAt: now.addingTimeInterval(-30),
            assistantAt: now.addingTimeInterval(-20)
        )
        let archived = session(
            title: "Archived chat",
            workspace: xeditPath,
            userAt: now.addingTimeInterval(-10),
            assistantAt: now.addingTimeInterval(-5),
            archivedAt: now
        )
        let empty = AgentSession(
            title: "Empty chat",
            workspaceRootPath: teamifyPath,
            updatedAt: now
        )

        let items = AgentRecentSessionEdgeRailLogic.recentItems(
            from: [older, newer, hidden, archived, empty],
            hiddenWorkspaceKeys: [hiddenPath],
            limit: 4
        )

        #expect(items.map(\.session.id) == [newer.id, older.id])
        #expect(items.map(\.workspaceDisplayName) == ["Teamify", "Xedit"])
        #expect(items.map(\.workspaceInitials) == ["TE", "XE"])
    }

    @Test("recent edge rail workspace initials stay compact and visible")
    func workspaceInitialsUseTwoVisibleCharacters() {
        #expect(AgentRecentSessionEdgeRailLogic.workspaceInitials(from: "muchtoken") == "MU")
        #expect(AgentRecentSessionEdgeRailLogic.workspaceInitials(from: "X") == "XX")
        #expect(AgentRecentSessionEdgeRailLogic.workspaceInitials(from: "飞书项目") == "飞书")
        #expect(AgentRecentSessionEdgeRailLogic.workspaceInitials(from: " ! ") == "??")
    }

    private func session(
        title: String,
        workspace: String,
        userAt: Date,
        assistantAt: Date,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            title: title,
            workspaceRootPath: workspace,
            updatedAt: assistantAt,
            messages: [
                AgentMessage(role: .user, content: title, createdAt: userAt),
                AgentMessage(role: .assistant, content: "Done", createdAt: assistantAt),
            ],
            pinnedAt: pinnedAt,
            archivedAt: archivedAt
        )
    }
}
