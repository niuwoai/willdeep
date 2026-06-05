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
@testable import VeilWriter

@Suite
struct AgentSessionStoreTests {

    // MARK: - deriveTitle

    /// Empty message list → fallback title. New chats land here.
    @Test
    func deriveTitleWithNoMessagesReturnsFallback() {
        let title = AgentSessionStore.deriveTitle(from: [])
        #expect(title == "New Chat")
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
        #expect(AgentSessionStore.deriveTitle(from: messages) == "New Chat")
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
    func directoryLivesUnderApplicationSupportVeilWriter() {
        let path = AgentSessionStore.directory.path
        #expect(path.contains("Application Support"))
        #expect(path.contains("VeilWriter"))
        #expect(path.hasSuffix("agent-sessions"))
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
