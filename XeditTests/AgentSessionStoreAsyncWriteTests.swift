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

    @Test("starting a new chat never touches an older chat's history file")
    func startingNewChatKeepsOlderSessionWithHistoryOnDisk() throws {
        let appState = AppState(rootDirectory: nil)
        let first = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: first.id) }
        // Give it substance, which is what makes it worth protecting.
        appState.agentMessages = [AgentMessage(role: .user, content: "real history")]
        appState.persistActiveAgentSession()
        AgentSessionStore.flushPendingWrites()

        let firstURL = AgentSessionStore.directory
            .appendingPathComponent("\(first.id.uuidString).json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 60)],
            ofItemAtPath: firstURL.path
        )

        let second = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: second.id) }

        #expect(AgentSessionStore.load(id: first.id)?.messages.count == 1)
        #expect(appState.agentSessions.contains(where: { $0.id == first.id }))
    }

    @Test("a brand-new chat exists in memory but not yet on disk")
    func newChatIsNotPersistedUntilItHasSubstance() {
        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        AgentSessionStore.flushPendingWrites()

        // The row is live and selectable; only the file is absent.
        #expect(appState.agentSessions.contains(where: { $0.id == session.id }))
        #expect(appState.activeAgentSessionID == session.id)
        #expect(AgentSessionStore.load(id: session.id) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: AgentSessionStore.fileURL(for: session.id).path
        ))

        // The first real persist is what creates it.
        appState.agentMessages = [AgentMessage(role: .user, content: "now it matters")]
        appState.persistActiveAgentSession()
        AgentSessionStore.flushPendingWrites()

        #expect(AgentSessionStore.load(id: session.id)?.messages.count == 1)
    }

    @Test("dispatch-scoped sessions are still persisted at creation")
    func dispatchScopedSessionIsPersistedImmediately() {
        let appState = AppState(rootDirectory: nil)
        let session = appState.startNewAgentSession(
            inWorkspaceAt: nil,
            makeActive: false,
            presentationScope: .dispatchBoard
        )
        defer { AgentSessionStore.delete(id: session.id) }
        AgentSessionStore.flushPendingWrites()

        // Orchestrator-owned work must survive a crash before its first turn.
        #expect(AgentSessionStore.load(id: session.id) != nil)
    }

    @Test("missing history file reports a recoverable session-switch failure")
    func missingHistoryFileDoesNotSilentlySwallowSessionSelection() {
        let appState = AppState(rootDirectory: nil)
        let active = appState.startNewAgentSession()
        let stale = AgentSession(title: "Recoverable history")
        AgentSessionStore.delete(id: stale.id)
        // Metadata-only classification is per-AppState now, so seed the
        // instance under test rather than the process-wide tracker.
        appState.markAgentSessionMetadataOnlyForTesting(stale.id, hasUserMessage: true)
        defer { AgentSessionStore.delete(id: active.id) }
        appState.agentSessions.insert(stale, at: 0)

        let selected = appState.selectAgentSession(id: stale.id)

        #expect(!selected)
        #expect(appState.activeAgentSessionID == active.id)
        #expect(appState.agentSessionLoadFailure == AgentSessionLoadFailure(
            id: stale.id,
            title: stale.title,
            reason: .missing
        ))
        #expect(appState.agentSessions.contains(where: { $0.id == stale.id }))

        appState.dismissAgentSessionLoadFailure()
        #expect(appState.agentSessionLoadFailure == nil)
    }

    @Test("unreadable history file reports the file as present, not missing")
    func unreadableHistoryFileReportsUnreadableReason() throws {
        let appState = AppState(rootDirectory: nil)
        let active = appState.startNewAgentSession()
        let broken = AgentSession(title: "Corrupt history")
        let url = AgentSessionStore.fileURL(for: broken.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let garbage = Data("{ not json at all".utf8)
        try garbage.write(to: url)
        appState.markAgentSessionMetadataOnlyForTesting(broken.id, hasUserMessage: true)
        defer {
            AgentSessionStore.delete(id: active.id)
            AgentSessionStore.delete(id: broken.id)
        }
        appState.agentSessions.insert(broken, at: 0)

        #expect(!appState.selectAgentSession(id: broken.id))
        #expect(appState.activeAgentSessionID == active.id)
        let failure = try #require(appState.agentSessionLoadFailure)
        #expect(failure.id == broken.id)
        if case .unreadable(let error) = failure.reason {
            #expect(!error.isEmpty)
        } else {
            Issue.record("expected .unreadable, got \(failure.reason)")
        }
        // The sidebar entry stays and the bytes on disk are untouched.
        #expect(appState.agentSessions.contains(where: { $0.id == broken.id }))
        AgentSessionStore.flushPendingWrites()
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("selecting an old conversation cannot evict its runtime before activation")
    func selectingOldConversationProtectsMaterializedRuntime() {
        let appState = AppState(rootDirectory: nil)
        let now = Date()
        let active = AgentSession(title: "active", updatedAt: now)
        let target = AgentSession(
            title: "old conversation",
            updatedAt: now.addingTimeInterval(-3_600),
            messages: [AgentMessage(role: .user, content: "persisted history")]
        )
        let fillers = (0..<7).map { offset in
            AgentSession(
                title: "cached-\(offset)",
                updatedAt: now.addingTimeInterval(TimeInterval(-offset))
            )
        }

        appState.agentSessions = [active, target] + fillers
        appState.activeAgentSessionID = active.id
        appState.agentRuntimes[active.id] = AgentRuntime(session: active)
        for filler in fillers {
            appState.agentRuntimes[filler.id] = AgentRuntime(session: filler)
        }

        #expect(appState.selectAgentSession(id: target.id))
        #expect(appState.activeAgentSessionID == target.id)
        #expect(appState.loadedRuntime(for: target.id)?.messages.first?.content == "persisted history")
    }

    @Test("reselecting a highlighted conversation repairs a missing runtime")
    func reselectingActiveConversationRepairsMissingRuntime() {
        let appState = AppState(rootDirectory: nil)
        let session = AgentSession(
            title: "highlighted conversation",
            messages: [AgentMessage(role: .user, content: "history is still here")]
        )
        appState.agentSessions = [session]
        appState.activeAgentSessionID = session.id

        #expect(appState.loadedRuntime(for: session.id) == nil)
        #expect(appState.selectAgentSession(id: session.id))
        #expect(appState.loadedRuntime(for: session.id)?.messages.first?.content == "history is still here")
    }

    // MARK: - Abandoned empty-session sweep

    /// Builds an on-disk session the sweep should consider abandoned:
    /// zero messages, no workspace, no project, and last touched `age` ago.
    private func seedAbandonedPlaceholder(
        age: TimeInterval,
        mutate: (inout AgentSession) -> Void = { _ in }
    ) -> AgentSession {
        var session = AgentSession(title: "新对话", workspaceRootPath: nil)
        session.updatedAt = Date(timeIntervalSinceNow: -age)
        mutate(&session)
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()
        return session
    }

    private func attach(_ session: AgentSession, to appState: AppState) {
        appState.agentSessions.insert(session, at: 0)
    }

    /// Sweep tests must own the catalog. With the launch load enabled, its
    /// task also calls `sweepAbandonedEmptySessions()` and can win the race at
    /// the first `await` here, leaving the assertions reading someone else's
    /// result (`sweptAbandonedEmptySessionCount == 0` because it already ran).
    private func sweepTestAppState() -> AppState {
        AppState(rootDirectory: nil, loadSessionCatalog: false)
    }

    @Test("the launch sweep removes an abandoned placeholder and both its sidecars")
    func sweepRemovesAbandonedPlaceholder() async {
        let appState = sweepTestAppState()
        let stale = seedAbandonedPlaceholder(age: 30 * 24 * 60 * 60)
        defer { AgentSessionStore.delete(id: stale.id) }
        attach(stale, to: appState)

        await appState.sweepAbandonedEmptySessions()

        #expect(appState.sweptAbandonedEmptySessionCount == 1)
        #expect(!appState.agentSessions.contains { $0.id == stale.id })
        #expect(!FileManager.default.fileExists(
            atPath: AgentSessionStore.fileURL(for: stale.id).path
        ))
        // A leftover sidecar would keep costing a decode on every launch.
        #expect(!FileManager.default.fileExists(
            atPath: AgentSessionStore.catalogURL(for: stale.id).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: AgentSessionStore.usageCatalogURL(for: stale.id).path
        ))
    }

    @Test("the sweep spares placeholders that are recent, bound, pinned, or scoped")
    func sweepSparesEverythingButAbandonedPlaceholders() async {
        let appState = sweepTestAppState()
        let old = 30.0 * 24 * 60 * 60

        let recent = seedAbandonedPlaceholder(age: 60)
        let workspaceBound = seedAbandonedPlaceholder(age: old) {
            $0.workspaceRootPath = "/tmp/xedit-sweep-probe"
            $0.workspaceLocation = .local(path: "/tmp/xedit-sweep-probe")
        }
        let projectBound = seedAbandonedPlaceholder(age: old) { $0.projectID = UUID() }
        let pinned = seedAbandonedPlaceholder(age: old) { $0.pinnedAt = Date() }
        let archived = seedAbandonedPlaceholder(age: old) { $0.archivedAt = Date() }
        let dispatch = seedAbandonedPlaceholder(age: old) { $0.presentationScope = .dispatchBoard }
        let survivors = [recent, workspaceBound, projectBound, pinned, archived, dispatch]
        defer { survivors.forEach { AgentSessionStore.delete(id: $0.id) } }
        survivors.forEach { attach($0, to: appState) }

        await appState.sweepAbandonedEmptySessions()

        #expect(appState.sweptAbandonedEmptySessionCount == 0)
        for survivor in survivors {
            #expect(appState.agentSessions.contains { $0.id == survivor.id })
            #expect(FileManager.default.fileExists(
                atPath: AgentSessionStore.fileURL(for: survivor.id).path
            ))
        }
    }

    @Test("a session with history is never swept, however old and unbound")
    func sweepNeverRemovesRealHistory() async {
        let appState = sweepTestAppState()
        let withHistory = seedAbandonedPlaceholder(age: 365 * 24 * 60 * 60) {
            $0.messages = [AgentMessage(role: .user, content: "do not delete me")]
        }
        defer { AgentSessionStore.delete(id: withHistory.id) }
        attach(withHistory, to: appState)

        await appState.sweepAbandonedEmptySessions()

        #expect(appState.agentSessions.contains { $0.id == withHistory.id })
        #expect(AgentSessionStore.load(id: withHistory.id)?.messages.count == 1)
    }

    @Test("the disk gate refuses to delete a file that gained history after the scan")
    func deleteGateRefusesSessionThatGainedHistory() {
        var session = AgentSession(title: "新对话", workspaceRootPath: nil)
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()

        // Simulates another WillDeep process flushing a real turn into this id
        // between the caller's in-memory scan and the delete attempt.
        session.messages = [AgentMessage(role: .user, content: "typed in another window")]
        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()

        #expect(!AgentSessionStore.deleteIfStillEmptyAndUnattached(id: id))
        #expect(AgentSessionStore.load(id: id)?.messages.count == 1)
    }

    @Test("a session whose only message is a workflow report is never swept")
    func sweepSparesSessionWithNonUserMessagesOnly() async {
        let appState = sweepTestAppState()
        // Found on the reference install: three files with a lone
        // `workflowReport` or `system` row and no user turn. The sidebar does
        // not surface them, and a "no user message" gate would delete them.
        let reportOnly = seedAbandonedPlaceholder(age: 30 * 24 * 60 * 60) {
            $0.messages = [AgentMessage(role: .workflowReport, content: "workflow output")]
        }
        defer { AgentSessionStore.delete(id: reportOnly.id) }
        attach(reportOnly, to: appState)

        await appState.sweepAbandonedEmptySessions()

        #expect(appState.sweptAbandonedEmptySessionCount == 0)
        #expect(AgentSessionStore.load(id: reportOnly.id)?.messages.count == 1)
        // Even asked directly, the gate must refuse.
        #expect(!AgentSessionStore.deleteIfStillEmptyAndUnattached(id: reportOnly.id))
    }

    @Test("the disk gate keeps a file it cannot decode")
    func deleteGateKeepsUndecodableFile() throws {
        // The 1.167.0-rc5 prune treated "failed to decode" as "empty" and
        // deleted real history behind a momentarily unreadable file.
        let id = UUID()
        let url = AgentSessionStore.fileURL(for: id)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not a session }".utf8).write(to: url)

        #expect(!AgentSessionStore.deleteIfStillEmptyAndUnattached(id: id))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a resident runtime protects an otherwise abandoned placeholder")
    func sweepSparesPlaceholderWithResidentRuntime() async {
        let appState = sweepTestAppState()
        let stale = seedAbandonedPlaceholder(age: 30 * 24 * 60 * 60)
        defer { AgentSessionStore.delete(id: stale.id) }
        attach(stale, to: appState)
        let runtime = AgentRuntime(session: stale)
        runtime.input = "half-typed thought"
        appState.agentRuntimes[stale.id] = runtime

        await appState.sweepAbandonedEmptySessions()

        #expect(appState.agentSessions.contains { $0.id == stale.id })
        #expect(AgentSessionStore.load(id: stale.id) != nil)
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
