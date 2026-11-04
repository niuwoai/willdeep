import Foundation
import Testing
@testable import WillDeep

@Suite("子会话侧栏")
@MainActor
struct AgentChildSessionSidebarTests {
    private func session(
        _ title: String,
        parent: AgentSession.ID? = nil,
        pinned: Date? = nil,
        archived: Date? = nil,
        scope: AgentSessionPresentationScope = .workspace,
        messages: [AgentMessage] = []
    ) -> AgentSession {
        AgentSession(
            title: title,
            workspaceRootPath: "/tmp/child-sidebar-tests",
            presentationScope: scope,
            parentSessionID: parent,
            createdAt: Date(timeIntervalSince1970: 1_000),
            messages: messages,
            pinnedAt: pinned,
            archivedAt: archived
        )
    }

    @Test("父子层级按现有侧栏顺序排列，展开数量包含父会话的全部子会话")
    func orderedTreeAndRootLimit() {
        let first = session("First")
        let second = session("Second")
        let childA = session("Child A", parent: first.id)
        let childB = session("Child B", parent: first.id)
        let grandchild = session("Grandchild", parent: childA.id)
        let input = [second, childA, first, grandchild, childB]

        let rows = AgentChildSessionSidebar.rows(from: input)
        #expect(rows.map(\.session.id) == [second.id, first.id, childA.id, grandchild.id, childB.id])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 1])
        #expect(AgentChildSessionSidebar.initialRows(rows, rootLimit: 1).map(\.session.id) == [second.id])
        #expect(AgentChildSessionSidebar.initialRows(rows, rootLimit: 2).map(\.session.id) == rows.map(\.session.id))
    }

    @Test("折叠时限制历史子会话并保留后排父会话的活跃任务")
    func collapsedPreviewSurfacesUnfinishedTasks() {
        let roots = (0..<6).map { session("Parent \($0)") }
        let history = (0..<8).map { session("Finished \($0)", parent: roots[0].id) }
        var running = session("Running", parent: roots[5].id)
        running.childSessionAssignment = AgentChildSessionAssignment(
            prompt: "Review", status: .running
        )
        let rows = AgentChildSessionSidebar.rows(from: Array(roots.prefix(5)) + history + [roots[5], running])
        let preview = AgentChildSessionSidebar.initialRows(rows, rootLimit: 5)

        #expect(preview.count == 10)
        #expect(preview.contains { $0.id == roots[5].id })
        #expect(preview.contains { $0.id == running.id })
        #expect(!preview.contains { $0.id == history[3].id })
    }

    @Test("置顶和归档区优先保持各自的时间顺序")
    func orderedSectionsDoNotRegroup() {
        let parent = session("Parent")
        let child = session("Child", parent: parent.id)
        let chronological = [child, parent]
        #expect(AgentChildSessionSidebar.rows(from: chronological, groupRelated: false)
            .map(\.id) == chronological.map(\.id))
        #expect(AgentChildSessionSidebar.rows(from: chronological)
            .map(\.id) == [parent.id, child.id])
    }

    @Test("父会话缺失、在另一分组或形成环时，子会话仍保留")
    func missingParentsAndCyclesStayVisible() {
        let absent = session("Orphan", parent: UUID())
        let parent = session("Parent")
        let siblingSection = session("Other section", parent: parent.id)
        var cycleA = session("Cycle A")
        var cycleB = session("Cycle B", parent: cycleA.id)
        cycleA.parentSessionID = cycleB.id

        let rows = AgentChildSessionSidebar.rows(from: [absent, siblingSection, cycleA, cycleB])
        #expect(Set(rows.map(\.session.id)) == Set([absent.id, siblingSection.id, cycleA.id, cycleB.id]))
        #expect(rows.count == 4)
        #expect(rows.first?.depth == 0)
        #expect(rows[1].depth == 0)
    }

    @Test("置顶、归档和调度台归属沿用原有分区")
    func pinnedArchivedAndDispatchSectionsStaySeparate() {
        let parent = session("Parent")
        let pinnedChild = session("Pinned child", parent: parent.id, pinned: Date())
        let archivedChild = session("Archived child", parent: parent.id, archived: Date())
        let dispatchChild = session("Dispatch task", parent: parent.id, scope: .dispatchBoard)
        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [parent, pinnedChild, archivedChild, dispatchChild], activeID: parent.id
        )

        #expect(visible.contains { $0.id == pinnedChild.id })
        #expect(visible.contains { $0.id == archivedChild.id })
        #expect(!visible.contains { $0.id == dispatchChild.id })
        #expect(AgentSidebarSessionPlacement.globalPinnedSessions(from: visible).map(\.id) == [pinnedChild.id])
        let workspace = AgentSidebarSessionPlacement.workspaceSessions(from: visible)
        #expect(workspace.contains { $0.id == archivedChild.id })
        #expect(!workspace.contains { $0.id == pinnedChild.id })
        #expect(AgentChildSessionSidebar.rows(from: [archivedChild]).map(\.session.id) == [archivedChild.id])
    }

    @Test("尚无用户消息的子会话仍能出现在侧栏，已有消息可被标题搜索")
    func newlyCreatedChildIsVisibleAndSearchable() {
        let parent = session("Parent")
        let child = session("Find child task", parent: parent.id, messages: [
            AgentMessage(role: .user, content: "请检查项目")
        ])
        var emptyChild = session("Queued task", parent: parent.id)
        emptyChild.childSessionAssignment = AgentChildSessionAssignment(prompt: "Review the repository")
        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [parent, child, emptyChild], activeID: parent.id
        )
        #expect(Set(visible.map(\.id)).contains(child.id))
        #expect(Set(visible.map(\.id)).contains(emptyChild.id))
        let results = AgentSessionSearch.titleResults(
            sessions: [parent, child], projects: [], query: "Find child"
        )
        #expect(results.count == 1)
        let pendingResults = AgentSessionSearch.titleResults(
            sessions: [parent, emptyChild], projects: [], query: "Queued task",
            isMetadataOnly: { $0 == emptyChild.id }
        )
        #expect(pendingResults.count == 1)
        let orphan = session("Orphan task", parent: UUID())
        #expect(AgentSessionSearch.titleResults(
            sessions: [orphan], projects: [], query: "Orphan task",
            isMetadataOnly: { $0 == orphan.id }
        ).count == 1)
    }
}
