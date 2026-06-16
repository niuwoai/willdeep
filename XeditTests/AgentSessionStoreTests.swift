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
            didEditFiles: true
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
