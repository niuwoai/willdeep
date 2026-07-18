//
//  AgentSessionStoreTests.swift
//  XeditTests
//
//  Covers the pure parts of AgentSessionStore + the decode contract that
//  protects loadAll from a single corrupt file taking down the whole list.
//
//  Note: AgentSessionStore.save / loadAll / delete operate on the real
//  Application Support directory, so they are intentionally NOT exercised
//  here — running them would pollute the user's actual session store. The
//  invariants that matter (skip-corrupt-on-load, JSON round-trip,
//  newest-first ordering) are tested directly against JSONDecoder and the
//  pure `deriveTitle` helper.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentSessionStoreTests {

    // MARK: - deriveTitle

    /// Empty message list → fallback title. New chats land here.
    @Test
    func deriveTitleWithNoMessagesReturnsFallback() {
        let title = AgentSessionStore.deriveTitle(from: [])
        #expect(title == AgentSessionStore.defaultTitle)
    }

    @Test
    func placeholderTitleDetectorRecognizesDefaultsAndRealTitles() {
        #expect(AgentSessionStore.isPlaceholderTitle(AgentSessionStore.defaultTitle))
        #expect(AgentSessionStore.isPlaceholderTitle("New Chat"))
        #expect(AgentSessionStore.isPlaceholderTitle("新对话"))
        #expect(AgentSessionStore.isPlaceholderTitle("Chat"))
        #expect(AgentSessionStore.isPlaceholderTitle("   "))
        #expect(!AgentSessionStore.isPlaceholderTitle("Refactor AppState"))
        #expect(!AgentSessionStore.isPlaceholderTitle("排查 CPU 负载"))
    }

    @Test
    func sidebarApprovalBadgeDetectsUserBlockingStates() {
        let session = AgentSession(title: "Review tool call")

        #expect(AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: [.pendingApproval]
        ))
        #expect(AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: [.awaitingConfirm]
        ))
        #expect(AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: [.awaitingUserAnswer]
        ))
        #expect(AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            patchStatuses: [.pending]
        ))
        #expect(AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            planStatus: .proposed
        ))
    }

    @Test
    func sidebarApprovalBadgeIgnoresFinishedStates() {
        var session = AgentSession(title: "Finished work")
        session.currentPlan = AgentPlan(status: .approved, steps: [], summary: "Ready")

        #expect(!AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: [.running, .succeeded, .failed, .denied],
            patchStatuses: [.applied, .rejected, .failed]
        ))
        #expect(!AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            planStatus: .done
        ))
    }

    @Test
    func dockApprovalBadgeCountUsesRuntimeStateAndSkipsArchivedSessions() {
        let liveSession = AgentSession(title: "Needs answer")
        var archivedSession = AgentSession(title: "Archived plan")
        archivedSession.archivedAt = Date()
        archivedSession.currentPlan = AgentPlan(status: .proposed, steps: [], summary: "Review")

        let runtime = AgentRuntime(session: liveSession)
        runtime.toolCalls = [
            AgentToolCall(
                id: UUID(),
                messageID: UUID(),
                externalID: "call_ask_user",
                toolName: "ask_user",
                arguments: [:],
                risk: .userInput,
                status: .awaitingUserAnswer
            )
        ]

        let count = AgentSessionApprovalBadgeLogic.pendingApprovalSessionCount(
            sessions: [liveSession, archivedSession],
            runtimes: [liveSession.id: runtime]
        )

        #expect(count == 1)
    }

    @Test
    func sidebarKeepsOneEmptyPlaceholderPerNewWorkspace() {
        let firstWorkspace = "/tmp/willdeep-sidebar-project-a"
        let secondWorkspace = "/tmp/willdeep-sidebar-project-b"
        let firstEmpty = AgentSession(workspaceRootPath: firstWorkspace)
        let secondEmpty = AgentSession(workspaceRootPath: secondWorkspace)
        let staleSecondEmpty = AgentSession(workspaceRootPath: secondWorkspace)

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [secondEmpty, staleSecondEmpty, firstEmpty],
            activeID: secondEmpty.id
        )

        #expect(visible.map(\.id).contains(firstEmpty.id))
        #expect(visible.map(\.id).contains(secondEmpty.id))
        #expect(!visible.map(\.id).contains(staleSecondEmpty.id))
    }

    @Test
    func sidebarHidesEmptyPlaceholderWhenWorkspaceAlreadyHasHistory() {
        let workspace = "/tmp/willdeep-sidebar-history"
        let empty = AgentSession(workspaceRootPath: workspace)
        let chatted = AgentSession(
            title: "Real chat",
            workspaceRootPath: workspace,
            messages: [AgentMessage(role: .user, content: "ship it")]
        )

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [empty, chatted],
            activeID: nil
        )

        #expect(visible.map(\.id) == [chatted.id])
    }

    @Test
    func sidebarKeepsPinnedEmptySessionEvenOutsideActiveWorkspace() {
        let pinned = AgentSession(
            title: "Pinned draft",
            workspaceRootPath: "/tmp/willdeep-sidebar-pinned",
            pinnedAt: Date(timeIntervalSince1970: 200)
        )
        let active = AgentSession(workspaceRootPath: "/tmp/willdeep-sidebar-active")

        let visible = AgentSidebarSessionVisibility.visibleSessions(
            from: [pinned, active],
            activeID: active.id
        )

        #expect(visible.map(\.id).contains(pinned.id))
        #expect(visible.map(\.id).contains(active.id))
    }

    @Test
    func sidebarCollectsPinsAcrossWorkspacesWithoutDuplicatingWorkspaceRows() {
        let olderPin = AgentSession(
            title: "Pinned from Alpha",
            workspaceRootPath: "/tmp/alpha",
            updatedAt: Date(timeIntervalSince1970: 300),
            messages: [AgentMessage(role: .user, content: "alpha")],
            pinnedAt: Date(timeIntervalSince1970: 400)
        )
        let newerPin = AgentSession(
            title: "Pinned from Beta",
            workspaceRootPath: "/tmp/beta",
            updatedAt: Date(timeIntervalSince1970: 500),
            messages: [AgentMessage(role: .user, content: "beta")],
            pinnedAt: Date(timeIntervalSince1970: 600)
        )
        let regular = AgentSession(
            title: "Regular Alpha chat",
            workspaceRootPath: "/tmp/alpha",
            messages: [AgentMessage(role: .user, content: "regular")]
        )
        let archivedPin = AgentSession(
            title: "Archived pin",
            workspaceRootPath: "/tmp/beta",
            messages: [AgentMessage(role: .user, content: "archived")],
            pinnedAt: Date(timeIntervalSince1970: 700),
            archivedAt: Date(timeIntervalSince1970: 800)
        )
        let sessions = [olderPin, regular, archivedPin, newerPin]

        let pinned = AgentSidebarSessionPlacement.globalPinnedSessions(from: sessions)
        let workspaceRows = AgentSidebarSessionPlacement.workspaceSessions(from: sessions)

        #expect(pinned.map(\.id) == [newerPin.id, olderPin.id])
        #expect(workspaceRows.map(\.id) == [regular.id, archivedPin.id])
    }

    /// Skip non-user roles when picking the title source.
    @Test
    func deriveTitleUsesFirstUserMessageNotAssistant() {
        let messages: [AgentMessage] = [
            AgentMessage(role: .assistant, content: "Hello back"),
            AgentMessage(role: .user, content: "Refactor AppState"),
            AgentMessage(role: .user, content: "ignored")
        ]
        #expect(AgentSessionStore.deriveTitle(from: messages) == "Refactor AppState")
    }

    /// Whitespace-only user message falls back rather than producing a
    /// blank title in the sidebar.
    @Test
    func deriveTitleWithWhitespaceOnlyUserMessageFallsBack() {
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, content: "   \n\t  ")
        ]
        #expect(AgentSessionStore.deriveTitle(from: messages) == AgentSessionStore.defaultTitle)
    }

    /// 40 chars or fewer → returned verbatim. The boundary is inclusive
    /// — exactly 40 chars should NOT get the ellipsis.
    @Test
    func deriveTitleAt40CharsIsNotTruncated() {
        let exactly40 = String(repeating: "a", count: 40)
        let messages = [AgentMessage(role: .user, content: exactly40)]
        let title = AgentSessionStore.deriveTitle(from: messages)
        #expect(title == exactly40)
        #expect(!title.hasSuffix("…"))
    }

    /// 41 chars → truncated to 40 + ellipsis.
    @Test
    func deriveTitleOver40CharsIsTruncatedWithEllipsis() {
        let long = String(repeating: "x", count: 100)
        let title = AgentSessionStore.deriveTitle(from: [
            AgentMessage(role: .user, content: long)
        ])
        #expect(title.hasSuffix("…"))
        // 40 chars of body + the ellipsis character
        #expect(title.count == 41)
    }

    /// Newlines collapse to spaces so multi-line user input still renders
    /// as a single sidebar row.
    @Test
    func deriveTitleCollapsesNewlinesToSpaces() {
        let messages = [AgentMessage(role: .user, content: "line1\nline2")]
        let title = AgentSessionStore.deriveTitle(from: messages)
        #expect(title == "line1 line2")
        #expect(!title.contains("\n"))
    }

    // MARK: - Decode tolerance (mirrors loadAll's "skip-corrupt" intent)

    /// Round-trip a session through the same encoder/decoder pair the
    /// store uses (ISO-8601 dates, pretty-printed sorted keys) to lock
    /// in that valid JSON survives unchanged.
    @Test
    func encodedSessionRoundTripsCleanly() throws {
        let original = AgentSession(
            title: "Round-trip",
            workspaceRootPath: "/tmp/proj",
            modelID: "claude-opus-4-7",
            messages: [
                AgentMessage(role: .user, content: "ping"),
                AgentMessage(role: .assistant, content: "pong")
            ],
            didEditFiles: true,
            executionAgent: .codexCLI
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data    = try encoder.encode(original)
        let decoded = try JSONDecoder.iso8601Decoder.decode(AgentSession.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.title == original.title)
        #expect(decoded.messages.count == 2)
        #expect(decoded.didEditFiles == true)
        #expect(decoded.executionAgent == .codexCLI)
    }

    @Test
    func legacySessionDecodesDefaultExecutionAgent() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Legacy",
          "createdAt": "2026-06-19T00:00:00Z",
          "updatedAt": "2026-06-19T00:00:00Z",
          "messages": []
        }
        """

        let decoded = try JSONDecoder.iso8601Decoder.decode(AgentSession.self, from: Data(json.utf8))
        #expect(decoded.executionAgent == .willDeep)
    }

    @Test
    func lightweightSessionIndexKeepsUserMessagePresenceWithoutMaterializingTranscript() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Historical chat",
          "workspaceRootPath": "/tmp/proj",
          "createdAt": "2026-06-19T00:00:00Z",
          "updatedAt": "2026-06-19T01:00:00Z",
          "messages": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "role": "user",
              "content": "restore the sidebar history",
              "createdAt": "2026-06-19T00:10:00Z"
            }
          ]
        }
        """

        let indexed = try AgentSessionStore.decodeSessionIndexForTesting(Data(json.utf8))
        #expect(indexed.session.title == "Historical chat")
        #expect(indexed.session.messages.isEmpty)
        #expect(indexed.hasUserMessage)
        #expect(indexed.session.providerID == nil)
        #expect(indexed.session.providerDisplayName == nil)
    }

    @Test
    func usageSnapshotRestoresStatsFromLightweightSessionJSON() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Historical chat",
          "modelID": "gpt-4.1",
          "providerID": "openai",
          "providerDisplayName": "OpenAI",
          "createdAt": "2026-06-19T00:00:00Z",
          "updatedAt": "2026-06-19T01:00:00Z",
          "messages": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "role": "user",
              "content": "restore usage stats",
              "createdAt": "2026-06-19T00:10:00Z",
              "images": [
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "mimeType": "image/png",
                  "dataBase64": "iVBORw0KGgo="
                }
              ]
            },
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "role": "assistant",
              "content": "done",
              "usageTokens": 120,
              "promptTokens": 80,
              "completionTokens": 40,
              "cachedPromptTokens": 20,
              "createdAt": "2026-06-19T00:11:00Z"
            }
          ]
        }
        """

        let snapshot = try AgentSessionStore.decodeUsageSnapshotForTesting(Data(json.utf8))
        let now = ISO8601DateFormatter().date(from: "2026-06-19T02:00:00Z")!
        let overview = AgentUsageStats.overview(for: [snapshot], now: now)
        let rows = AgentUsageStats.modelUsage(for: [snapshot])

        #expect(snapshot.messages.count == 2)
        #expect(overview.sessionCount == 1)
        #expect(overview.messageCount == 2)
        #expect(overview.totalTokens >= 720)
        #expect(overview.hasAnyRealUsage)
        #expect(overview.activeDays == 1)
        #expect(overview.currentStreak == 1)
        #expect(overview.favoriteModel == "gpt-4.1")
        #expect(rows.first?.providerID == "openai")
        #expect(rows.first?.modelID == "gpt-4.1")
        #expect(rows.first?.promptTokens == 80)
        #expect(rows.first?.completionTokens == 40)
        #expect(rows.first?.cachedPromptTokens == 20)
    }

    @Test
    func lightweightSessionIndexDetectsPlaceholderWithoutUserMessages() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "New Chat",
          "createdAt": "2026-06-19T00:00:00Z",
          "updatedAt": "2026-06-19T00:00:00Z",
          "messages": []
        }
        """

        let indexed = try AgentSessionStore.decodeSessionIndexForTesting(Data(json.utf8))
        #expect(indexed.session.messages.isEmpty)
        #expect(!indexed.hasUserMessage)
    }

    /// Corrupt JSON must throw a DecodingError — `loadAll` then catches
    /// and skips. Verifying the throw here means a single bad file
    /// cannot poison the in-memory session list.
    @Test
    func corruptJSONThrowsDecodingErrorWhichLoadAllSkips() {
        let garbage = Data("{ not valid json".utf8)
        #expect(throws: Error.self) {
            _ = try JSONDecoder.iso8601Decoder.decode(AgentSession.self, from: garbage)
        }
    }

    /// `loadAll` sorts by `updatedAt` descending. We replicate the sort
    /// here so a future refactor of the comparator surfaces in tests.
    @Test
    func sortsByUpdatedAtDescending() {
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let newDate = Date(timeIntervalSince1970: 2_000_000)
        let older = AgentSession(title: "older", updatedAt: oldDate)
        let newer = AgentSession(title: "newer", updatedAt: newDate)

        let sorted = [older, newer].sorted { $0.updatedAt > $1.updatedAt }
        #expect(sorted.first?.title == "newer")
        #expect(sorted.last?.title == "older")
    }

    /// The on-disk directory name is stable and lives under Application
    /// Support — this catches accidental directory renames that would
    /// orphan every user's existing sessions.
    @Test
    func directoryLivesUnderApplicationSupportWillDeep() {
        let path = AgentSessionStore.directory.path
        #expect(path.contains("Application Support"))
        #expect(path.contains("WillDeep"))
        #expect(path.hasSuffix("agent-sessions"))
    }

    @Test
    func legacyDirectoryImportRestoresSessionAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-legacy-import-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("VeilWriter/agent-sessions", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("WillDeep/agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = AgentSession(
            title: "Thirty day history",
            messages: [
                AgentMessage(role: .user, content: "keep my usage history"),
                AgentMessage(role: .assistant, content: "kept", usageTokens: 123)
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sourceURL = legacyDirectory.appendingPathComponent("\(session.id.uuidString).json")
        try encoder.encode(session).write(to: sourceURL)

        let firstImportCount = try AgentSessionStore.importLegacySessions(
            from: legacyDirectory,
            into: currentDirectory
        )
        let secondImportCount = try AgentSessionStore.importLegacySessions(
            from: legacyDirectory,
            into: currentDirectory
        )

        let destinationURL = currentDirectory.appendingPathComponent("\(session.id.uuidString).json")
        let restored = try JSONDecoder.iso8601Decoder.decode(
            AgentSession.self,
            from: Data(contentsOf: destinationURL)
        )
        #expect(firstImportCount == 1)
        #expect(secondImportCount == 0)
        #expect(restored.title == session.title)
        #expect(restored.messages.last?.usageTokens == 123)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func legacyDirectoryImportNeverOverwritesCurrentSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-legacy-conflict-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("VeilWriter/agent-sessions", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("WillDeep/agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let legacy = AgentSession(id: id, title: "Legacy copy")
        let current = AgentSession(id: id, title: "Current copy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(
            to: legacyDirectory.appendingPathComponent("\(id.uuidString).json")
        )
        let destinationURL = currentDirectory.appendingPathComponent("\(id.uuidString).json")
        try encoder.encode(current).write(to: destinationURL)

        let importCount = try AgentSessionStore.importLegacySessions(
            from: legacyDirectory,
            into: currentDirectory
        )
        let preserved = try JSONDecoder.iso8601Decoder.decode(
            AgentSession.self,
            from: Data(contentsOf: destinationURL)
        )

        #expect(importCount == 0)
        #expect(preserved.title == "Current copy")
    }

    @Test
    func legacyDirectoryImportSkipsCorruptJSONWithoutBlockingValidSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-legacy-corrupt-\(UUID().uuidString)", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("VeilWriter/agent-sessions", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("WillDeep/agent-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("not-json".utf8).write(to: legacyDirectory.appendingPathComponent("broken.json"))
        let valid = AgentSession(title: "Recoverable")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(valid).write(
            to: legacyDirectory.appendingPathComponent("\(valid.id.uuidString).json")
        )

        let importCount = try AgentSessionStore.importLegacySessions(
            from: legacyDirectory,
            into: currentDirectory
        )

        #expect(importCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: currentDirectory.appendingPathComponent("\(valid.id.uuidString).json").path
        ))
    }

    // MARK: - compact updated timestamp

    @Test
    func compactRelativeTimestampUsesMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(AgentRelativeTimestamp.compactString(since: now, now: now) == "0m")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-3 * 60 * 60), now: now) == "3h")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-2 * 24 * 60 * 60), now: now) == "2d")
    }

    @Test
    func compactRelativeTimestampUsesLargerUnitsAndClampsFutureDates() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-14 * 24 * 60 * 60), now: now) == "2w")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-60 * 24 * 60 * 60), now: now) == "2mo")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(-730 * 24 * 60 * 60), now: now) == "2y")
        #expect(AgentRelativeTimestamp.compactString(since: now.addingTimeInterval(60), now: now) == "0m")
    }

    // MARK: - lastActivityAt (sidebar timestamp source)

    /// The sidebar timestamp must reflect when the AI last replied, NOT
    /// `updatedAt` (which gets bumped on persist/switch and would read "0m"
    /// for old chats). A session persisted "now" but whose last assistant
    /// reply was 2h ago should report the 2h-ago time.
    @Test
    func lastActivityUsesLastAssistantMessageNotUpdatedAt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let twoHoursAgo = now.addingTimeInterval(-2 * 60 * 60)
        let threeHoursAgo = now.addingTimeInterval(-3 * 60 * 60)
        let session = AgentSession(
            updatedAt: now, // persisted "just now"
            messages: [
                AgentMessage(role: .user, content: "hi", createdAt: threeHoursAgo),
                AgentMessage(role: .assistant, content: "hello", createdAt: twoHoursAgo)
            ]
        )
        #expect(session.lastActivityAt == twoHoursAgo)
    }

    /// Empty assistant turns (placeholder rows before streaming starts) are
    /// skipped — we want the last turn that actually said something.
    @Test
    func lastActivitySkipsEmptyAssistantMessages() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let realReply = now.addingTimeInterval(-30 * 60)
        let emptyPlaceholder = now.addingTimeInterval(-1 * 60)
        let session = AgentSession(
            updatedAt: now,
            messages: [
                AgentMessage(role: .assistant, content: "the real answer", createdAt: realReply),
                AgentMessage(role: .assistant, content: "", createdAt: emptyPlaceholder)
            ]
        )
        #expect(session.lastActivityAt == realReply)
    }

    /// Before the first AI reply, fall back to the last message of any role
    /// (the user's prompt) so a brand-new chat still shows a real time.
    @Test
    func lastActivityFallsBackToLastMessageThenUpdatedAt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let userTime = now.addingTimeInterval(-10 * 60)
        let userOnly = AgentSession(
            updatedAt: now,
            messages: [AgentMessage(role: .user, content: "do a thing", createdAt: userTime)]
        )
        #expect(userOnly.lastActivityAt == userTime)

        // Truly empty session → updatedAt is the only signal available.
        let empty = AgentSession(updatedAt: now, messages: [])
        #expect(empty.lastActivityAt == now)
    }

    // MARK: - titleIsUserSet (LLM auto-summarizer guard)

    /// Default for a freshly-constructed session must be `false` so the
    /// per-persist deriveTitle path can keep working until either the
    /// user renames or the LLM summarizer locks the title.
    @Test
    func newSessionStartsWithTitleNotUserSet() {
        let session = AgentSession()
        #expect(session.titleIsUserSet == false)
    }

    /// Decoded JSON that predates the field must default to `false` so
    /// pre-rc6 sessions on disk don't start mysteriously refusing to
    /// retitle.
    @Test
    func decodingLegacySessionJSONDefaultsTitleIsUserSetToFalse() throws {
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "old chat",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "messages": []
        }
        """
        let data = Data(legacy.utf8)
        let session = try JSONDecoder.iso8601Decoder.decode(AgentSession.self, from: data)
        #expect(session.titleIsUserSet == false)
    }

    /// Once `titleIsUserSet` is true the field round-trips intact —
    /// without this we'd lose the user's rename on the next app launch.
    @Test
    func titleIsUserSetSurvivesEncodeDecodeRoundTrip() throws {
        var session = AgentSession(title: "Custom Name")
        session.titleIsUserSet = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder.iso8601Decoder.decode(AgentSession.self, from: data)
        #expect(decoded.titleIsUserSet == true)
        #expect(decoded.title == "Custom Name")
    }

    // MARK: - sanitizeAutoTitle (LLM output cleanup)

    /// The model often wraps its output in quotes — strip them.
    @Test
    func sanitizeStripsSurroundingDoubleQuotes() {
        #expect(AppState.sanitizeAutoTitle("\"排查 CPU 负载\"") == "排查 CPU 负载")
    }

    /// "标题：" / "Title:" prefixes leak through — strip them.
    @Test
    func sanitizeStripsLeadingTitlePrefix() {
        #expect(AppState.sanitizeAutoTitle("标题：配置 SSH") == "配置 SSH")
        #expect(AppState.sanitizeAutoTitle("Title: Fix login bug") == "Fix login bug")
    }

    /// Trailing punctuation noise drops away. Useful because Chinese
    /// titles often pick up an unwanted "。" at the end.
    @Test
    func sanitizeDropsTrailingPunctuation() {
        #expect(AppState.sanitizeAutoTitle("配置 SSH 登录。") == "配置 SSH 登录")
        #expect(AppState.sanitizeAutoTitle("Fix login bug.") == "Fix login bug")
    }

    /// Multi-line model output: keep only line 1.
    @Test
    func sanitizeKeepsOnlyFirstLine() {
        let raw = "排查 CPU 负载\n(基于用户描述总结)"
        #expect(AppState.sanitizeAutoTitle(raw) == "排查 CPU 负载")
    }

    /// Empty or whitespace-only model output should be rejected so the
    /// caller leaves the existing title in place.
    @Test
    func sanitizeReturnsNilForEmptyInput() {
        #expect(AppState.sanitizeAutoTitle("") == nil)
        #expect(AppState.sanitizeAutoTitle("   \n  ") == nil)
    }

    /// Hard char cap kicks in if the model ignores the prompt. 24 is
    /// the implementation's defensive ceiling (prompt asks for ≤12).
    @Test
    func sanitizeAppliesHardCharCap() {
        let raw = String(repeating: "字", count: 60)
        let cleaned = AppState.sanitizeAutoTitle(raw)
        #expect(cleaned != nil)
        // 24 chars + "…"
        #expect(cleaned!.count == 25)
        #expect(cleaned!.last == "…")
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
