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

    // MARK: Workspace → project migration

    private func session(
        workspacePath: String?,
        projectID: UUID? = nil,
        presentationScope: AgentSessionPresentationScope = .workspace
    ) -> AgentSession {
        AgentSession(
            title: "s",
            workspaceRootPath: workspacePath,
            projectID: projectID,
            presentationScope: presentationScope
        )
    }

    @Test("旧项目数据缺少置顶字段时按未置顶读取")
    func legacyProjectDecodesAsUnpinned() throws {
        let id = UUID()
        let data = try #require(
            """
            {
              "id": "\(id.uuidString)",
              "displayName": "Legacy",
              "folderPaths": ["/tmp/legacy"],
              "repositoryIdentities": [],
              "createdAt": 1000,
              "updatedAt": 1000
            }
            """.data(using: .utf8)
        )

        let decoded = try JSONDecoder().decode(AgentProject.self, from: data)

        #expect(!decoded.isPinned)
        #expect(decoded.pinnedAt == nil)
    }

    /// Projects replace workspaces outright, so every bare folder group has to
    /// become a project — otherwise the sidebar keeps listing both kinds of row.
    @Test("裸文件夹分组会被挑出来升级为项目")
    func bareFoldersAreSelectedForPromotion() {
        let sessions = [
            session(workspacePath: "/Users/rocky/Sites/tokenhub"),
            session(workspacePath: "/Users/rocky/Sites/juhe"),
        ]

        let folders = AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: []
        )

        #expect(folders == ["/Users/rocky/Sites/tokenhub", "/Users/rocky/Sites/juhe"])
    }

    @Test("同一文件夹只升级一次")
    func duplicateFoldersCollapse() {
        let sessions = [
            session(workspacePath: "/Users/rocky/Sites/tokenhub"),
            session(workspacePath: "/Users/rocky/Sites/tokenhub"),
        ]

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: []
        ) == ["/Users/rocky/Sites/tokenhub"])
    }

    /// Re-running on every launch must not keep minting projects.
    @Test("已被项目认领的文件夹不再重复升级")
    func claimedFoldersAreSkipped() {
        let sessions = [session(workspacePath: "/Users/rocky/Sites/tokenhub")]
        let existing = [project(name: "tokenhub", folders: ["/Users/rocky/Sites/tokenhub"])]

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: existing
        ).isEmpty)
    }

    /// A child of an already-claimed tree must not spawn a rival group.
    @Test("父目录已属于项目时子目录不另起一组")
    func childOfClaimedFolderIsSkipped() {
        let sessions = [session(workspacePath: "/Users/rocky/Sites/tokenhub/web")]
        let existing = [project(name: "tokenhub", folders: ["/Users/rocky/Sites/tokenhub"])]

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: existing
        ).isEmpty)
    }

    @Test("无工作区与已属项目的会话被跳过")
    func sessionsWithoutAPromotableFolderAreSkipped() {
        let sessions = [
            session(workspacePath: nil),
            session(workspacePath: "/Users/rocky/Sites/tokenhub", projectID: UUID()),
        ]

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: []
        ).isEmpty)
    }

    /// A remote workspace has no local folder a project could be built from.
    @Test("远程工作区不参与升级")
    func remoteWorkspacesAreSkipped() {
        var remote = session(workspacePath: nil)
        remote.workspaceLocation = .remote(runtimeID: UUID(), path: "/srv/app")

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: [remote],
            existing: []
        ).isEmpty)
    }

    @Test("调度台 worktree 不会被升级成项目")
    func dispatchWorktreesAreSkipped() {
        let dispatch = session(
            workspacePath: "/Users/rocky/.willdeep/worktrees/repo/dispatch--12345678",
            presentationScope: .dispatchBoard
        )

        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: [dispatch],
            existing: []
        ).isEmpty)
    }

    @Test("历史调度 worktree 项目会被识别但不会误伤普通项目")
    func leakedDispatchProjectsAreSelectedConservatively() {
        let leaked = project(
            name: "dispatch--12345678",
            folders: ["/Users/rocky/.willdeep/worktrees/repo/dispatch--12345678"]
        )
        let ordinary = project(
            name: "willdeep",
            folders: ["/Users/rocky/Sites/willdeep"]
        )
        let manuallyRenamed = project(
            name: "保留这个调度现场",
            folders: ["/Users/rocky/.willdeep/worktrees/repo/dispatch--87654321"]
        )
        let dispatchSession = session(
            workspacePath: leaked.primaryFolderPath,
            projectID: leaked.id,
            presentationScope: .dispatchBoard
        )

        let selected = AgentDispatchProjectLeakRepair.projectIDsToRemove(
            projects: [leaked, ordinary, manuallyRenamed],
            sessions: [dispatchSession],
            managedWorktreeRoot: "/Users/rocky/.willdeep/worktrees"
        )

        #expect(selected == [leaked.id])
    }

    @Test("有普通会话占用的 dispatch 名项目不会自动清理")
    func workspaceOwnedDispatchProjectIsKept() {
        let project = project(
            name: "dispatch--12345678",
            folders: ["/Users/rocky/.willdeep/worktrees/repo/dispatch--12345678"]
        )
        let ordinarySession = session(
            workspacePath: project.primaryFolderPath,
            projectID: project.id
        )

        #expect(AgentDispatchProjectLeakRepair.projectIDsToRemove(
            projects: [project],
            sessions: [ordinarySession],
            managedWorktreeRoot: "/Users/rocky/.willdeep/worktrees"
        ).isEmpty)
    }

    /// Guards the shape of the migration loop. The candidate list has to be a
    /// finite snapshot: an earlier version re-queried until the list came back
    /// empty, which never terminates if a created project fails to claim its
    /// own folder. Feeding a path that cannot become a project (it normalizes
    /// to nil) must still yield a finite result rather than a folder that
    /// stays "needing a project" forever.
    @Test("升级候选是有限快照，不会因无法认领而反复出现")
    func migrationCandidateListIsAFiniteSnapshot() {
        let sessions = [
            session(workspacePath: "/"),
            session(workspacePath: ""),
            session(workspacePath: "/Users/rocky/Sites/tokenhub"),
        ]

        let folders = AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: []
        )

        // "/" and "" cannot normalize into a project folder and must be
        // dropped outright, not returned as perpetual candidates.
        #expect(folders == ["/Users/rocky/Sites/tokenhub"])

        // Building the projects the migration would build must leave nothing
        // outstanding — the fixed point is reached in one pass.
        let built = folders.map {
            AgentProject(
                displayName: WorkspacePresentation.localDisplayName(path: $0),
                folderPaths: [$0]
            )
        }
        #expect(AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: sessions,
            existing: built
        ).isEmpty)
    }

    // MARK: Repairing sessions anchored to a project key

    /// rc18's sidebar handed "new chat in this group" the group key where a
    /// path belonged. For a bare folder the key is the path, so it stayed
    /// invisible until workspaces became projects — then the session's
    /// workspace root became the literal `/project:<uuid>`.
    @Test("被写成项目 key 的工作区路径会被还原为真实目录")
    func corruptedWorkspacePathIsRepairedToTheProjectFolder() {
        let project = project(name: "tokenhub", folders: ["/Users/rocky/Sites/tokenhub"])

        // The stored form is standardized, hence the leading slash.
        #expect(
            AgentWorkspacePathRepairPlan.plan(
                workspacePath: "/project:\(project.id.uuidString)",
                projects: [project]
            ) == .repair("/Users/rocky/Sites/tokenhub")
        )
        // The raw key form must be handled too.
        #expect(
            AgentWorkspacePathRepairPlan.plan(
                workspacePath: "project:\(project.id.uuidString)",
                projects: [project]
            ) == .repair("/Users/rocky/Sites/tokenhub")
        )
    }

    @Test("真实路径与空工作区不被误判为损坏")
    func healthyWorkspacePathsAreLeftAlone() {
        let project = project(name: "tokenhub", folders: ["/Users/rocky/Sites/tokenhub"])

        #expect(
            AgentWorkspacePathRepairPlan.plan(
                workspacePath: "/Users/rocky/Sites/tokenhub",
                projects: [project]
            ) == .notCorrupted
        )
        #expect(
            AgentWorkspacePathRepairPlan.plan(workspacePath: nil, projects: [project])
                == .notCorrupted
        )
        // A folder that merely starts with the word "project" is not a key.
        #expect(
            AgentWorkspacePathRepairPlan.plan(
                workspacePath: "/Users/rocky/projects/app",
                projects: [project]
            ) == .notCorrupted
        )
    }

    /// Leaving an unresolvable path in place would keep every file, terminal
    /// and git operation pointed at a directory that does not exist.
    @Test("项目已删除时清空工作区而不是留下无效路径")
    func corruptedPathWithoutItsProjectIsCleared() {
        #expect(
            AgentWorkspacePathRepairPlan.plan(
                workspacePath: "/project:\(UUID().uuidString)",
                projects: []
            ) == .clear
        )
    }

    /// The promoted project is named after the folder, not left blank or
    /// showing the raw group key.
    @Test("升级后的项目沿用文件夹名")
    func promotedProjectUsesFolderName() {
        let promoted = AgentProject(
            displayName: WorkspacePresentation.localDisplayName(path: "/Users/rocky/Sites/tokenhub"),
            folderPaths: ["/Users/rocky/Sites/tokenhub"]
        )

        #expect(promoted.resolvedDisplayName == "tokenhub")
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
