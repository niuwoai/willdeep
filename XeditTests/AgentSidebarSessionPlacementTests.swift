import Foundation
import Testing
@testable import WillDeep

@Suite("Sidebar session placement")
struct AgentSidebarSessionPlacementTests {
    private static func session(
        title: String,
        createdAt: Date,
        pinnedAt: Date? = nil,
        messages: [AgentMessage] = []
    ) -> AgentSession {
        AgentSession(
            title: title,
            createdAt: createdAt,
            // Pin updatedAt too: an empty session's lastActivityAt falls
            // back to updatedAt, and the default "now" would race with
            // the explicit message timestamps used below.
            updatedAt: createdAt,
            messages: messages,
            pinnedAt: pinnedAt
        )
    }

    @Test("unpinned sessions order by creation time, newest first")
    func unpinnedSessionsOrderByCreation() {
        let older = Self.session(title: "older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = Self.session(title: "newer", createdAt: Date(timeIntervalSince1970: 2_000))

        let ordered = [older, newer].sorted(by: AgentSidebarSessionPlacement.workspaceOrder)

        #expect(ordered.map(\.title) == ["newer", "older"])
    }

    @Test("background activity does not reshuffle the group")
    func activityDoesNotReorderSessions() {
        // The old session received a fresh assistant reply (background
        // stream, scheduled task, …). Under lastActivityAt ordering it
        // jumped above newer sessions; creation order must ignore it.
        let older = Self.session(
            title: "older-but-active",
            createdAt: Date(timeIntervalSince1970: 1_000),
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "late reply",
                    createdAt: Date(timeIntervalSince1970: 9_999)
                )
            ]
        )
        let newer = Self.session(title: "newer-idle", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(older.lastActivityAt > newer.lastActivityAt)

        let ordered = [older, newer].sorted(by: AgentSidebarSessionPlacement.workspaceOrder)

        #expect(ordered.map(\.title) == ["newer-idle", "older-but-active"])
    }

    @Test("equal timestamps still yield one deterministic order")
    func equalTimestampsAreDeterministic() {
        // Swift's sort is unstable — a comparator that treats two rows as
        // equal lets them swap on every re-sort, and the sidebar re-sorts
        // whenever the shared AppState publishes (editor keystrokes
        // included). Equal dates must fall through to the immutable id.
        let sharedDate = Date(timeIntervalSince1970: 7_000)
        let a = Self.session(title: "a", createdAt: sharedDate)
        let b = Self.session(title: "b", createdAt: sharedDate)

        let forward = [a, b].sorted(by: AgentSidebarSessionPlacement.workspaceOrder)
        let backward = [b, a].sorted(by: AgentSidebarSessionPlacement.workspaceOrder)

        #expect(forward.map(\.id) == backward.map(\.id))

        let pinnedA = Self.session(title: "pa", createdAt: sharedDate, pinnedAt: sharedDate)
        let pinnedB = Self.session(title: "pb", createdAt: sharedDate, pinnedAt: sharedDate)
        let pinnedForward = AgentSidebarSessionPlacement.globalPinnedSessions(from: [pinnedA, pinnedB])
        let pinnedBackward = AgentSidebarSessionPlacement.globalPinnedSessions(from: [pinnedB, pinnedA])
        #expect(pinnedForward.map(\.id) == pinnedBackward.map(\.id))
    }

    @Test("pinned sessions stay above unpinned ones, most recently pinned first")
    func pinnedSessionsLeadTheGroup() {
        let pinnedEarly = Self.session(
            title: "pinned-early",
            createdAt: Date(timeIntervalSince1970: 3_000),
            pinnedAt: Date(timeIntervalSince1970: 5_000)
        )
        let pinnedLate = Self.session(
            title: "pinned-late",
            createdAt: Date(timeIntervalSince1970: 1_000),
            pinnedAt: Date(timeIntervalSince1970: 6_000)
        )
        let unpinned = Self.session(title: "unpinned", createdAt: Date(timeIntervalSince1970: 9_000))

        let ordered = [unpinned, pinnedEarly, pinnedLate]
            .sorted(by: AgentSidebarSessionPlacement.workspaceOrder)

        #expect(ordered.map(\.title) == ["pinned-late", "pinned-early", "unpinned"])
    }
}

@Suite("Sidebar group ordering")
struct AgentSidebarGroupOrderingTests {
    @Test("project groups are born when the project was created")
    func projectGroupBirthDate() {
        let project = AgentProject(
            displayName: "aipipe",
            folderPaths: ["/tmp/aipipe"],
            createdAt: Date(timeIntervalSince1970: 5_000)
        )
        let key = AgentSession.projectSidebarGroupKeyPrefix + project.id.uuidString
        let birth = AgentSidebarSessionPlacement.groupBirthDate(
            groupKey: key,
            sessions: [],
            projects: [project]
        )
        #expect(birth == Date(timeIntervalSince1970: 5_000))
    }

    @Test("bare folder groups are born with their earliest session")
    func pathGroupBirthDate() {
        let sessions = [
            AgentSession(title: "b", createdAt: Date(timeIntervalSince1970: 9_000)),
            AgentSession(title: "a", createdAt: Date(timeIntervalSince1970: 3_000)),
        ]
        let birth = AgentSidebarSessionPlacement.groupBirthDate(
            groupKey: "/tmp/some-folder",
            sessions: sessions,
            projects: []
        )
        // 最早会话代表分组诞生时刻 —— 新会话加入不会改变它，顺序才冻得住。
        #expect(birth == Date(timeIntervalSince1970: 3_000))
    }

    @Test("groups order by birth date descending with no-workspace pinned last")
    func groupOrderIsCreationDescending() {
        let older = (key: "/tmp/older", birthDate: Date(timeIntervalSince1970: 1_000), displayName: "zzz")
        let newer = (key: "/tmp/newer", birthDate: Date(timeIntervalSince1970: 2_000), displayName: "aaa")
        let noWorkspace = (
            key: AgentSession.noWorkspaceSidebarGroupKey,
            birthDate: Date(timeIntervalSince1970: 9_999),
            displayName: "no workspace"
        )

        // 新分组在前，与名字典序无关。
        #expect(AgentSidebarSessionPlacement.groupOrder(lhs: newer, rhs: older))
        #expect(!AgentSidebarSessionPlacement.groupOrder(lhs: older, rhs: newer))
        // 「无工作区」永远垫底，即便它的时间戳最新。
        #expect(AgentSidebarSessionPlacement.groupOrder(lhs: older, rhs: noWorkspace))
        #expect(!AgentSidebarSessionPlacement.groupOrder(lhs: noWorkspace, rhs: newer))
    }

    @Test("equal birth dates fall back to name then key for determinism")
    func groupOrderTieBreakers() {
        let sameDate = Date(timeIntervalSince1970: 4_000)
        let alpha = (key: "/tmp/a", birthDate: sameDate, displayName: "alpha")
        let beta = (key: "/tmp/b", birthDate: sameDate, displayName: "beta")
        #expect(AgentSidebarSessionPlacement.groupOrder(lhs: alpha, rhs: beta))
        #expect(!AgentSidebarSessionPlacement.groupOrder(lhs: beta, rhs: alpha))
    }
}

@Suite("New session project binding")
struct AgentNewSessionProjectBindingTests {
    @MainActor
    @Test("a new chat in a project folder joins the project's sidebar group")
    func newSessionBindsToOwningProject() throws {
        let appState = AppState()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try #require(
            appState.createAgentProject(displayName: "aipipe", folderPaths: [folder.path])
        )

        // The sidebar "+" on a project group hands over the primary folder
        // path — the session must land in the project group, not in a
        // second path-keyed group with the same display name.
        let session = appState.startNewAgentSession(inWorkspaceAt: folder.path)

        #expect(session.projectID == project.id)
        #expect(
            session.workspaceSidebarGroupKey
                == AgentSession.projectSidebarGroupKeyPrefix + project.id.uuidString
        )
    }

    @MainActor
    @Test("launch migration rebinds stray sessions even when every project already exists")
    func launchMigrationRebindsStraySessions() throws {
        let appState = AppState()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-rebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = try #require(
            appState.createAgentProject(displayName: "rebind", folderPaths: [folder.path])
        )

        // A session persisted without its binding (e.g. written by another
        // AppState instance) — the folder is already claimed, so migration
        // creates nothing. The rebind must still run and heal it; the old
        // early-return skipped it and the sidebar kept a duplicate group.
        let stray = AgentSession(
            title: "stray",
            workspaceRootPath: folder.path
        )
        appState.agentSessions.append(stray)
        #expect(appState.agentSessions.first(where: { $0.id == stray.id })?.projectID == nil)

        let created = appState.migrateAgentWorkspacesToProjects()

        #expect(created.isEmpty)
        #expect(
            appState.agentSessions.first(where: { $0.id == stray.id })?.projectID == project.id
        )
    }

    @MainActor
    @Test("a new chat outside every project keeps a path group")
    func newSessionOutsideProjectsStaysPathKeyed() throws {
        let appState = AppState()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-unclaimed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = appState.startNewAgentSession(inWorkspaceAt: folder.path)

        #expect(session.projectID == nil)
        #expect(session.workspaceSidebarGroupKey == folder.standardizedFileURL.path)
    }
}
