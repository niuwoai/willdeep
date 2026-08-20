import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSidebarCollapseAllTests {
    @Test("collapse all folds every listed project")
    func collapseAllFoldsEverything() {
        let ids = ["~/a", "~/b", "~/c"]

        let collapsed = AgentSidebarCollapseAll.toggled(workspaceIDs: ids, collapsed: [])

        #expect(collapsed == Set(ids))
    }

    @Test("a partially folded list folds the rest rather than unfolding")
    func partialStateCollapsesTheRemainder() {
        // Clicking with one project already folded should finish the job, not
        // undo it — otherwise the control's effect depends on invisible state.
        let ids = ["~/a", "~/b", "~/c"]

        let collapsed = AgentSidebarCollapseAll.toggled(workspaceIDs: ids, collapsed: ["~/b"])

        #expect(collapsed == Set(ids))
    }

    @Test("once everything is folded the control unfolds instead")
    func fullyCollapsedFlipsToExpand() {
        let ids = ["~/a", "~/b"]

        #expect(AgentSidebarCollapseAll.isEverythingCollapsed(
            workspaceIDs: ids,
            collapsed: Set(ids)
        ))
        #expect(AgentSidebarCollapseAll.toggled(
            workspaceIDs: ids,
            collapsed: Set(ids)
        ).isEmpty)
    }

    @Test("expanding leaves folders that are not on screen alone")
    func expandDoesNotTouchUnlistedWorkspaces() {
        // The stored set outlives the visible list: a project whose sessions
        // are all archived keeps its key. Expanding "all" must not silently
        // unfold something the user cannot see and never asked about.
        let visible = ["~/a", "~/b"]
        let stored: Set<String> = ["~/a", "~/b", "~/offscreen"]

        let collapsed = AgentSidebarCollapseAll.toggled(workspaceIDs: visible, collapsed: stored)

        #expect(collapsed == ["~/offscreen"])
    }

    @Test("an empty list is not treated as fully collapsed")
    func emptyListIsNotCollapsed() {
        // Vacuous truth would render the control as "expand all" on a sidebar
        // with no projects at all.
        #expect(!AgentSidebarCollapseAll.isEverythingCollapsed(workspaceIDs: [], collapsed: []))
    }

    @Test("the control only appears once there is more than one project")
    func controlNeedsMoreThanOneProject() {
        #expect(!AgentSidebarCollapseAll.isAvailable(workspaceCount: 0))
        // With a single group, collapsing "all" folds the very thing being
        // looked at and saves nothing.
        #expect(!AgentSidebarCollapseAll.isAvailable(workspaceCount: 1))
        #expect(AgentSidebarCollapseAll.isAvailable(workspaceCount: 2))
    }
}
