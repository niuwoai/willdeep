//
//  AgentTranscriptSearchScrollTests.swift
//  WillDeepTests
//
//  Locks the invariant that a transcript rebuild must not move the
//  viewport during a conversation search. Only a real search navigation —
//  a new query, next/previous, a theme change — jumps to the active match.
//
//  The bug this guards: `renderCurrentMessages()` called the highlighter
//  unconditionally, and the highlighter scrolled. Hovering, streaming,
//  expanding a tool group, and resizing all rebuild the body, so scrolling
//  to the bottom mid-search bounced the reader straight back to match #1.
//

import Testing
import AppKit
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentTranscriptSearchScrollTests {

    @Test
    func searchNavigationScrollsToTheMatch() {
        let view = Self.makeView(messages: Self.messages(count: 3))
        #expect(view.searchScrollRequestCount == 0)

        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        #expect(view.searchScrollRequestCount == 1)
    }

    @Test
    func steppingToTheNextMatchScrollsAgain() {
        let view = Self.makeView(messages: Self.messages(count: 3))
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        view.applySearch(query: "needle", activeMatchIndex: 1, isDark: false)
        #expect(view.searchScrollRequestCount == 2)
    }

    @Test
    func repeatingTheSameSearchDoesNotScrollAgain() {
        let view = Self.makeView(messages: Self.messages(count: 3))
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        #expect(view.searchScrollRequestCount == 1)
    }

    @Test
    func rebuildingTheTranscriptDoesNotScroll() {
        // The regression: new content arriving mid-search used to yank the
        // viewport back to the active match.
        let view = Self.makeView(messages: Self.messages(count: 3))
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        let afterNavigation = view.searchScrollRequestCount

        view.applyMessages(Self.messages(count: 6), isDark: false)
        #expect(view.searchScrollRequestCount == afterNavigation)
    }

    @Test
    func repeatedRebuildsNeverAccumulateScrolls() {
        // Scrolling to the bottom fires a burst of rebuilds (one per hover
        // change). None of them may move the viewport.
        let view = Self.makeView(messages: Self.messages(count: 3))
        view.applySearch(query: "needle", activeMatchIndex: 2, isDark: false)
        let afterNavigation = view.searchScrollRequestCount

        for count in 4...12 {
            view.applyMessages(Self.messages(count: count), isDark: false)
        }
        #expect(view.searchScrollRequestCount == afterNavigation)
    }

    @Test
    func rebuildBeforeAnySearchNeverScrolls() {
        let view = Self.makeView(messages: Self.messages(count: 2))
        view.applyMessages(Self.messages(count: 5), isDark: false)
        #expect(view.searchScrollRequestCount == 0)
    }

    @Test
    func clearingTheQueryDoesNotScroll() {
        // With no matches there is nothing to scroll to; the reader keeps
        // whatever position they had.
        let view = Self.makeView(messages: Self.messages(count: 3))
        view.applySearch(query: "needle", activeMatchIndex: 0, isDark: false)
        let afterNavigation = view.searchScrollRequestCount

        view.applySearch(query: "", activeMatchIndex: nil, isDark: false)
        #expect(view.searchScrollRequestCount == afterNavigation)
    }

    // MARK: - Helpers

    private static func makeView(messages: [AgentMessage]) -> AgentChatHistoryNSTextView {
        let view = AgentChatHistoryNSTextView()
        view.setFrameSize(NSSize(width: 600, height: 400))
        view.applyMessages(messages, isDark: false)
        return view
    }

    private static func messages(count: Int) -> [AgentMessage] {
        (0..<count).map { index in
            AgentMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message \(index) with a needle in it"
            )
        }
    }
}
