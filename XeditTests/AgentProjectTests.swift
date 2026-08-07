import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentProjectTests {
    private func project(
        name: String,
        folders: [String],
        updatedAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) -> AgentProject {
        AgentProject(displayName: name, folderPaths: folders, updatedAt: updatedAt)
    }

    // MARK: Path matching

    @Test("a folder claims itself and everything beneath it")
    func folderContainment() {
        #expect(AgentProject.folder("/Users/rocky/Sites/tokenhub", contains: "/Users/rocky/Sites/tokenhub"))
        #expect(AgentProject.folder("/Users/rocky/Sites/tokenhub", contains: "/Users/rocky/Sites/tokenhub/web"))
    }

    @Test("matching respects path boundaries")
    func containmentIsNotPrefixMatching() {
        // /a/b must not swallow /a/bc — a plain hasPrefix would.
        #expect(!AgentProject.folder("/Users/rocky/Sites/tokenhub", contains: "/Users/rocky/Sites/tokenhub-web"))
        #expect(!AgentProject.folder("/Users/rocky/Sites/tokenhub", contains: "/Users/rocky/Sites"))
    }

    @Test("paths normalize before comparison")
    func pathNormalization() {
        #expect(AgentProject.normalizedPath("/Users/rocky/Sites/tokenhub/") == "/Users/rocky/Sites/tokenhub")
        #expect(AgentProject.normalizedPath("  /Users/rocky/Sites/tokenhub  ") == "/Users/rocky/Sites/tokenhub")
        #expect(AgentProject.normalizedPath("") == nil)
        #expect(AgentProject.normalizedPath("/") == nil)

        // Trailing slashes must not create a second, non-matching folder.
        let withSlash = project(name: "tokenhub", folders: ["/Users/rocky/Sites/tokenhub/"])
        #expect(withSlash.contains(path: "/Users/rocky/Sites/tokenhub/api"))
    }

    // MARK: Multiple folders

    @Test("one project spans several folders")
    func projectSpansFolders() {
        let full = project(
            name: "TokenHub",
            folders: ["/Users/rocky/Sites/tokenhub", "/Users/rocky/Sites/tokenhub-web"]
        )

        #expect(full.contains(path: "/Users/rocky/Sites/tokenhub/internal"))
        #expect(full.contains(path: "/Users/rocky/Sites/tokenhub-web/src"))
        #expect(!full.contains(path: "/Users/rocky/Sites/other"))
    }

    @Test("the primary folder is the first one, and names it when unnamed")
    func primaryFolderAndNameFallback() {
        let named = project(name: "TokenHub", folders: ["/Users/rocky/Sites/tokenhub"])
        #expect(named.resolvedDisplayName == "TokenHub")

        // A blank name would render as an empty sidebar group.
        let blank = project(name: "   ", folders: ["/Users/rocky/Sites/tokenhub"])
        #expect(blank.resolvedDisplayName == "tokenhub")
        #expect(blank.primaryFolderPath == "/Users/rocky/Sites/tokenhub")
    }

    // MARK: Shared folders (decision 2)

    @Test("the most specific project wins when several claim a path")
    func deepestMatchWins() throws {
        let broad = project(name: "全部站点", folders: ["/Users/rocky/Sites"])
        let specific = project(name: "TokenHub", folders: ["/Users/rocky/Sites/tokenhub"])

        let owner = try #require(
            AgentProjectResolver.project(
                for: "/Users/rocky/Sites/tokenhub/api",
                in: [broad, specific]
            )
        )

        #expect(owner.id == specific.id)
    }

    @Test("equally specific claims are broken by recency, deterministically")
    func tiesBreakByRecency() throws {
        let older = project(name: "旧", folders: ["/Users/rocky/Sites/tokenhub"], updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = project(name: "新", folders: ["/Users/rocky/Sites/tokenhub"], updatedAt: Date(timeIntervalSince1970: 2_000))

        let owner = try #require(
            AgentProjectResolver.project(for: "/Users/rocky/Sites/tokenhub", in: [older, newer])
        )
        // Must not depend on array order.
        let reversed = try #require(
            AgentProjectResolver.project(for: "/Users/rocky/Sites/tokenhub", in: [newer, older])
        )

        #expect(owner.id == newer.id)
        #expect(reversed.id == newer.id)
    }

    @Test("an unclaimed path resolves to no project")
    func unclaimedPathHasNoProject() {
        let some = project(name: "TokenHub", folders: ["/Users/rocky/Sites/tokenhub"])

        #expect(AgentProjectResolver.project(for: "/Users/rocky/Sites/elsewhere", in: [some]) == nil)
        #expect(AgentProjectResolver.project(for: nil, in: [some]) == nil)
        #expect(AgentProjectResolver.project(for: "/Users/rocky/Sites/tokenhub", in: []) == nil)
    }

    @Test("other claimants of a path can be listed for the removal rules")
    func otherClaimantsAreDiscoverable() {
        let a = project(name: "A", folders: ["/Users/rocky/Sites/shared"])
        let b = project(name: "B", folders: ["/Users/rocky/Sites/shared"])
        let unrelated = project(name: "C", folders: ["/Users/rocky/Sites/other"])

        let others = AgentProjectResolver.otherProjectsClaiming(
            path: "/Users/rocky/Sites/shared",
            excluding: a.id,
            in: [a, b, unrelated]
        )

        // Removing A must be able to see that B still needs this folder.
        #expect(others.map(\.id) == [b.id])
    }

    // MARK: Sidebar grouping

    @Test("a project owns the group key outright")
    func projectDrivesGroupKey() {
        let projectID = UUID()
        var session = AgentSession(title: "会话", workspaceRootPath: "/Users/rocky/Sites/tokenhub")
        session.projectID = projectID

        #expect(session.workspaceSidebarGroupKey == "project:\(projectID.uuidString)")
        #expect(AgentSession.projectID(fromSidebarGroupKey: session.workspaceSidebarGroupKey) == projectID)
    }

    @Test("two folders in one project land in the same group")
    func sharedProjectSharesGroup() {
        let projectID = UUID()
        var backend = AgentSession(title: "后端", workspaceRootPath: "/Users/rocky/Sites/tokenhub")
        var frontend = AgentSession(title: "前端", workspaceRootPath: "/Users/rocky/Sites/tokenhub-web")
        backend.projectID = projectID
        frontend.projectID = projectID

        // The whole point: separate repos, one sidebar group.
        #expect(backend.workspaceSidebarGroupKey == frontend.workspaceSidebarGroupKey)
    }

    @Test("sessions without a project keep today's path grouping exactly")
    func legacySessionsAreUnchanged() {
        let session = AgentSession(title: "旧会话", workspaceRootPath: "/Users/rocky/Sites/tokenhub")

        #expect(session.projectID == nil)
        #expect(session.workspaceSidebarGroupKey == "/Users/rocky/Sites/tokenhub")
        #expect(AgentSession.projectID(fromSidebarGroupKey: session.workspaceSidebarGroupKey) == nil)
    }

    @Test("a project outranks the worktree grouping root")
    func projectOutranksWorktreeRoot() {
        let projectID = UUID()
        var session = AgentSession(title: "worktree 会话", workspaceRootPath: "/Users/rocky/Sites/tokenhub-wt")
        session.sidebarWorkspaceRootPath = "/Users/rocky/Sites/tokenhub"
        session.projectID = projectID

        #expect(session.workspaceSidebarGroupKey == "project:\(projectID.uuidString)")
    }

    @Test("project keys cannot collide with filesystem paths")
    func keyNamespacesAreDisjoint() {
        // Group keys are otherwise absolute paths, which always start with "/".
        #expect(AgentSession.projectSidebarGroupKeyPrefix.hasPrefix("/") == false)
        #expect(AgentSession.projectID(fromSidebarGroupKey: "/Users/rocky/Sites/project:abc") == nil)
    }

    // MARK: Persistence

    @Test("projectID survives an encode/decode round trip")
    func sessionRoundTripKeepsProject() throws {
        let projectID = UUID()
        var session = AgentSession(title: "会话", workspaceRootPath: "/Users/rocky/Sites/tokenhub")
        session.projectID = projectID

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: try JSONEncoder().encode(session)
        )

        #expect(decoded.projectID == projectID)
    }

    @Test("sessions saved before projects existed decode with none")
    func legacySessionJSONDecodes() throws {
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "title": "旧会话",
          "workspaceRootPath": "/Users/rocky/Sites/tokenhub",
          "presentationScope": "workspace",
          "createdAt": 760000000,
          "updatedAt": 760000000,
          "messages": []
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(legacy.utf8))

        #expect(decoded.projectID == nil)
        #expect(decoded.workspaceSidebarGroupKey == "/Users/rocky/Sites/tokenhub")
    }

    @Test("projects round-trip through their store")
    func projectStoreRoundTrip() throws {
        defer { AgentProjectStore.removeAll() }
        let saved = [
            project(name: "TokenHub", folders: ["/Users/rocky/Sites/tokenhub", "/Users/rocky/Sites/tokenhub-web"])
        ]

        #expect(AgentProjectStore.save(saved))
        let loaded = AgentProjectStore.load()

        #expect(loaded == saved)
        #expect(loaded.first?.folderPaths.count == 2)
    }

    @Test("a missing store file is empty, not a failure")
    func missingStoreLoadsEmpty() {
        AgentProjectStore.removeAll()

        #expect(AgentProjectStore.load().isEmpty)
    }

    @Test("the store lives beside the session directory, not inside it")
    func storeLocation() {
        // Inside would put it in the path the session loader scans.
        #expect(AgentProjectStore.fileURL.lastPathComponent == "projects.json")
        #expect(AgentProjectStore.fileURL.deletingLastPathComponent() != AgentSessionStore.directory)
    }
}
