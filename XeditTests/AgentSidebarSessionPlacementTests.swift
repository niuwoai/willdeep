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
