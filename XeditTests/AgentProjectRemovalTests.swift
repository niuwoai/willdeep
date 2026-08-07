import Foundation
import Testing
@testable import WillDeep

/// Removing a project deletes conversations. A folder may belong to several
/// projects. Together those two rules can destroy another project's history,
/// which is exactly what these pin down.
@Suite
@MainActor
struct AgentProjectRemovalTests {
    private func project(
        name: String,
        folders: [String],
        updatedAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) -> AgentProject {
        AgentProject(displayName: name, folderPaths: folders, updatedAt: updatedAt)
    }

    private func session(path: String, projectID: UUID?) -> AgentSession {
        var session = AgentSession(title: "会话", workspaceRootPath: path)
        session.projectID = projectID
        return session
    }

    // MARK: Exclusive vs shared

    @Test("conversations only in the removed project are deleted")
    func exclusiveSessionsAreDeleted() {
        let only = project(name: "TokenHub", folders: ["/Users/rocky/Sites/tokenhub"])
        let chat = session(path: "/Users/rocky/Sites/tokenhub", projectID: only.id)

        let plan = AgentProjectRemoval.plan(removing: only, projects: [only], sessions: [chat])

        #expect(plan.deletedSessionIDs == [chat.id])
        #expect(plan.rebindings.isEmpty)
        #expect(!plan.isNonDestructive)
    }

    @Test("conversations whose folder another project also owns are kept")
    func sharedSessionsSurvive() throws {
        let shared = "/Users/rocky/Sites/shared"
        let removed = project(name: "A", folders: [shared])
        let keeper = project(name: "B", folders: [shared])
        let chat = session(path: shared, projectID: removed.id)

        let plan = AgentProjectRemoval.plan(
            removing: removed,
            projects: [removed, keeper],
            sessions: [chat]
        )

        // Deleting it would silently destroy history project B still shows.
        #expect(plan.deletedSessionIDs.isEmpty)
        #expect(try #require(plan.rebindings[chat.id]) == keeper.id)
        #expect(plan.isNonDestructive)
    }

    @Test("a mixed project reports both numbers")
    func mixedRemovalReportsBothCounts() {
        let shared = "/Users/rocky/Sites/shared"
        let exclusive = "/Users/rocky/Sites/private"
        let removed = project(name: "A", folders: [shared, exclusive])
        let keeper = project(name: "B", folders: [shared])

        let sharedChat = session(path: shared, projectID: removed.id)
        let exclusiveChat = session(path: exclusive, projectID: removed.id)

        let plan = AgentProjectRemoval.plan(
            removing: removed,
            projects: [removed, keeper],
            sessions: [sharedChat, exclusiveChat]
        )

        // The confirmation must be able to say "1 deleted, 1 moved".
        #expect(plan.deletedCount == 1)
        #expect(plan.rebindingCount == 1)
        #expect(plan.deletedSessionIDs == [exclusiveChat.id])
        #expect(plan.rebindings[sharedChat.id] == keeper.id)
    }

    @Test("conversations in other projects are untouched")
    func otherProjectsAreUnaffected() {
        let removed = project(name: "A", folders: ["/Users/rocky/Sites/a"])
        let other = project(name: "B", folders: ["/Users/rocky/Sites/b"])
        let mine = session(path: "/Users/rocky/Sites/a", projectID: removed.id)
        let theirs = session(path: "/Users/rocky/Sites/b", projectID: other.id)

        let plan = AgentProjectRemoval.plan(
            removing: removed,
            projects: [removed, other],
            sessions: [mine, theirs]
        )

        #expect(plan.deletedSessionIDs == [mine.id])
        #expect(plan.rebindings[theirs.id] == nil)
    }

    @Test("unmanaged conversations are never touched")
    func unmanagedSessionsAreUntouched() {
        let removed = project(name: "A", folders: ["/Users/rocky/Sites/a"])
        // Same folder, but never bound to a project.
        let loose = session(path: "/Users/rocky/Sites/a", projectID: nil)

        let plan = AgentProjectRemoval.plan(removing: removed, projects: [removed], sessions: [loose])

        #expect(plan.deletedSessionIDs.isEmpty)
        #expect(plan.rebindings.isEmpty)
    }

    @Test("a project with no conversations removes nothing")
    func emptyProjectIsNonDestructive() {
        let empty = project(name: "空项目", folders: ["/Users/rocky/Sites/empty"])

        let plan = AgentProjectRemoval.plan(removing: empty, projects: [empty], sessions: [])

        #expect(plan.isNonDestructive)
        #expect(plan.deletedCount == 0)
    }

    @Test("the removed project cannot inherit its own conversations")
    func removedProjectIsExcludedFromInheritance() {
        // Passing the full list including the project being removed must not
        // let it match itself and keep everything alive.
        let removed = project(name: "A", folders: ["/Users/rocky/Sites/a"])
        let chat = session(path: "/Users/rocky/Sites/a", projectID: removed.id)

        let plan = AgentProjectRemoval.plan(removing: removed, projects: [removed], sessions: [chat])

        #expect(plan.deletedSessionIDs == [chat.id])
    }

    @Test("the inheriting project is chosen by the same rule new sessions use")
    func inheritanceUsesTheStandardRule() throws {
        let broad = project(name: "全部", folders: ["/Users/rocky/Sites"])
        let specific = project(name: "精确", folders: ["/Users/rocky/Sites/tokenhub"])
        let removed = project(name: "被删", folders: ["/Users/rocky/Sites/tokenhub"])
        let chat = session(path: "/Users/rocky/Sites/tokenhub", projectID: removed.id)

        let plan = AgentProjectRemoval.plan(
            removing: removed,
            projects: [broad, specific, removed],
            sessions: [chat]
        )

        // Deepest match wins, exactly as when the session was first bound.
        #expect(try #require(plan.rebindings[chat.id]) == specific.id)
    }

    // MARK: Path resolution

    @Test("a worktree conversation resolves through its project root")
    func worktreeSessionUsesSidebarRoot() {
        var worktree = AgentSession(title: "worktree", workspaceRootPath: "/Users/rocky/Sites/tokenhub-wt")
        worktree.sidebarWorkspaceRootPath = "/Users/rocky/Sites/tokenhub"

        // Grouping follows the project root, so removal must too.
        #expect(AgentProjectRemoval.sessionPath(worktree) == "/Users/rocky/Sites/tokenhub")
    }

    @Test("a remote workspace has no local folder to match")
    func remoteSessionHasNoLocalPath() {
        let remote = AgentSession(
            title: "远程",
            workspaceLocation: .remote(runtimeID: UUID(), path: "/srv/app")
        )

        #expect(AgentProjectRemoval.sessionPath(remote) == nil)
    }
}
