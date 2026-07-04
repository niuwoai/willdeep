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

    @Test("pin/archive survive the runtime's next persist")
    func pinAndArchiveSurviveRuntimePersist() throws {
        let appState = AppState(rootDirectory: nil)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }

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
