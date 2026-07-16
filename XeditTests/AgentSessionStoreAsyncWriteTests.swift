//
//  AgentSessionStoreAsyncWriteTests.swift
//  XeditTests
//
//  Regression tests for the 1.129.0-rc29 async session-write pipeline:
//  persists are coalesced onto a serial background queue, pending
//  snapshots are served by load(id:) before they land on disk, and
//  delete cancels queued writes so it can never be "resurrected".
//
//  Uses the real Application Support store with a synthetic session id;
//  the defer'd delete keeps the user's store clean (same pattern as
//  AgentBackgroundJobsTests' session cleanup).
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentSessionStoreAsyncWriteTests {

    @Test("async saves coalesce, flush to disk, and serve the pending snapshot")
    func asyncSaveFlushesAndServesPendingSnapshot() throws {
        var session = AgentSession(title: "async-write-probe", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        session.messages = [AgentMessage(role: .user, content: "hello async store")]
        AgentSessionStore.saveAsync(session)

        // Readable immediately — either from the pending snapshot (write
        // still queued) or from disk (drain already ran). Both must agree.
        #expect(AgentSessionStore.load(id: id)?.title == "async-write-probe")

        // A second save before the flush replaces the payload; after the
        // flush the LATEST snapshot must be what's on disk.
        session.title = "async-write-probe-updated"
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()
        #expect(AgentSessionStore.load(id: id)?.title == "async-write-probe-updated")
        #expect(AgentSessionStore.load(id: id)?.messages.count == 1)
    }

    @Test("delete cancels a queued async write instead of being resurrected")
    func deleteCancelsQueuedWrite() throws {
        var session = AgentSession(title: "delete-cancels-write", workspaceRootPath: nil)
        let id = session.id

        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()
        #expect(AgentSessionStore.load(id: id) != nil)

        // Queue another write, then delete before it necessarily lands.
        // The pending payload must be dropped — after the flush there is
        // neither a file nor a pending snapshot left.
        session.title = "should-never-hit-disk"
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.delete(id: id)
        AgentSessionStore.flushPendingWrites()
        #expect(AgentSessionStore.load(id: id) == nil)
    }

    @Test("a save issued after delete wins — earlier drains cannot steal it")
    func saveAfterDeleteWins() throws {
        var session = AgentSession(title: "pre-delete", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        // saveAsync(S1) → delete → saveAsync(S2): S1's drain block runs
        // BEFORE the queued delete and must not grab S2's payload (seq
        // gating), or the delete would wipe a save that logically
        // followed it. S2's own drain lands after the delete.
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.delete(id: id)
        session.title = "post-delete"
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()
        #expect(AgentSessionStore.load(id: id)?.title == "post-delete")
    }

    @Test("loadAll overlays pending snapshots and never marks them empty-metadata-only")
    func loadAllOverlaysPendingSnapshots() throws {
        var session = AgentSession(title: "loadall-overlay-probe", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        session.messages = [AgentMessage(role: .user, content: "real history")]
        AgentSessionStore.saveAsync(session)

        // A second AppState instance (Settings window) can call loadAll
        // while the write is still queued. The session must be present
        // with its real title either way (pending overlay or already
        // flushed) …
        let listed = AgentSessionStore.loadAll().first(where: { $0.id == id })
        #expect(listed?.title == "loadall-overlay-probe")
        // … and must NEVER end up classified as "metadata-only without a
        // user message" — that exact state made pruneEmptyAgentSessions
        // delete sessions with real history during the write window.
        let misclassified = AgentSessionStore.isMetadataOnly(id)
            && !AgentSessionStore.metadataOnlySessionHasUserMessage(id)
        #expect(!misclassified)

        AgentSessionStore.flushPendingWrites()
        #expect(AgentSessionStore.load(id: id)?.messages.count == 1)
    }

    @Test("session saves maintain a lightweight launch catalog sidecar")
    func saveMaintainsLightweightCatalogSidecar() throws {
        var session = AgentSession(title: "catalog-sidecar-probe", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        session.messages = [
            AgentMessage(role: .user, content: String(repeating: "large transcript payload ", count: 2_000))
        ]
        #expect(AgentSessionStore.save(session))

        let fullURL = AgentSessionStore.directory.appendingPathComponent("\(id.uuidString).json")
        let catalogURL = AgentSessionStore.catalogURL(for: id)
        let fullSize = try Data(contentsOf: fullURL).count
        let catalogSize = try Data(contentsOf: catalogURL).count

        #expect(catalogSize < fullSize)
        let listed = AgentSessionStore.loadAll().first(where: { $0.id == id })
        #expect(listed?.title == "catalog-sidecar-probe")
        #expect(listed?.messages.isEmpty == true)
        #expect(AgentSessionStore.isMetadataOnly(id))
        #expect(AgentSessionStore.metadataOnlySessionHasUserMessage(id))
    }

    @Test("a stale catalog sidecar falls back to the conversation and repairs itself")
    func staleCatalogFallsBackAndRepairs() throws {
        var session = AgentSession(title: "catalog-before", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        session.messages = [AgentMessage(role: .user, content: "history")]
        #expect(AgentSessionStore.save(session))

        session.title = "catalog-after-with-a-different-file-size"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fullURL = AgentSessionStore.directory.appendingPathComponent("\(id.uuidString).json")
        try encoder.encode(session).write(to: fullURL, options: .atomic)

        let listed = AgentSessionStore.loadAll().first(where: { $0.id == id })
        #expect(listed?.title == "catalog-after-with-a-different-file-size")

        // A second read must now be served by the repaired sidecar and keep
        // the same metadata. This also catches repair writes targeting the
        // wrong UUID/path.
        let listedAgain = AgentSessionStore.loadAll().first(where: { $0.id == id })
        #expect(listedAgain?.title == "catalog-after-with-a-different-file-size")
    }

    @Test("starting a new chat hides old empty placeholders without deleting their files")
    func startingNewChatKeepsOlderEmptySessionOnDisk() throws {
        let appState = AppState(rootDirectory: nil)
        let first = appState.startNewAgentSession()
        AgentSessionStore.flushPendingWrites()
        defer { AgentSessionStore.delete(id: first.id) }

        let firstURL = AgentSessionStore.directory
            .appendingPathComponent("\(first.id.uuidString).json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
            ofItemAtPath: firstURL.path
        )

        let second = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: second.id) }

        #expect(AgentSessionStore.load(id: first.id) != nil)
        #expect(appState.agentSessions.contains(where: { $0.id == first.id }))
    }

    @Test("missing history file reports a recoverable session-switch failure")
    func missingHistoryFileDoesNotSilentlySwallowSessionSelection() {
        let appState = AppState(rootDirectory: nil)
        let active = appState.startNewAgentSession()
        let stale = AgentSession(title: "Recoverable history")
        AgentSessionStore.delete(id: stale.id)
        AgentSessionStore.markMetadataOnlyForTesting(stale.id, hasUserMessage: true)
        defer {
            AgentSessionStore.clearMetadataOnlyForTesting(stale.id)
            AgentSessionStore.delete(id: active.id)
        }
        appState.agentSessions.insert(stale, at: 0)

        let selected = appState.selectAgentSession(id: stale.id)

        #expect(!selected)
        #expect(appState.activeAgentSessionID == active.id)
        #expect(appState.agentSessionLoadFailure == AgentSessionLoadFailure(
            id: stale.id,
            title: stale.title
        ))
        #expect(appState.agentSessions.contains(where: { $0.id == stale.id }))

        appState.dismissAgentSessionLoadFailure()
        #expect(appState.agentSessionLoadFailure == nil)
    }

    @Test("pin/archive survive the runtime's next persist")
    func pinAndArchiveSurviveRuntimePersist() throws {
        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }

        appState.agentMessages = [AgentMessage(role: .user, content: "pin me")]
        appState.toggleAgentSessionPinned(id: session.id)
        appState.toggleAgentSessionArchived(id: session.id)

        // The runtime's own persist used to write back its stale session
        // copy (pinnedAt/archivedAt nil), silently un-pinning the row.
        appState.persistActiveAgentSession()

        let row = appState.agentSessions.first(where: { $0.id == session.id })
        #expect(row?.pinnedAt != nil)
        #expect(row?.archivedAt != nil)
    }
}
