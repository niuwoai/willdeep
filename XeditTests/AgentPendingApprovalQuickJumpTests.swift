//
//  AgentPendingApprovalQuickJumpTests.swift
//  XeditTests
//
//  Covers the sidebar quick-jump strip and the Dock icon menu that surface
//  sessions blocked on the user. Both read the same predicate as the Dock
//  badge count, so what these lock down is the *selection*: which sessions
//  qualify, in what order, and how the entries are labeled.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentPendingApprovalQuickJumpTests {

    private func waitingRuntime(
        for session: AgentSession,
        turnStartedAt: Date?
    ) -> AgentRuntime {
        let runtime = AgentRuntime(session: session)
        runtime.turnStartedAt = turnStartedAt
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
        return runtime
    }

    // MARK: - Selection

    @Test
    func entriesCollectOnlySessionsBlockedOnTheUser() {
        let waiting = AgentSession(title: "Needs an answer")
        let busy = AgentSession(title: "Still running")
        let runtimes = [
            waiting.id: waitingRuntime(for: waiting, turnStartedAt: Date()),
            busy.id: AgentRuntime(session: busy)
        ]

        let entries = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: [waiting, busy],
            runtimes: runtimes
        )

        #expect(entries.map(\.sessionID) == [waiting.id])
        #expect(entries.first?.title == "Needs an answer")
    }

    /// A session restored from disk with a proposed plan has no runtime, and
    /// is exactly the case the Dock badge already counts.
    @Test
    func entriesIncludeRuntimelessSessionsWithAProposedPlan() {
        var restored = AgentSession(title: "Review this plan")
        restored.currentPlan = AgentPlan(status: .proposed, steps: [], summary: "Review")

        let entries = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(sessions: [restored])

        #expect(entries.map(\.sessionID) == [restored.id])
    }

    @Test
    func entriesSkipArchivedSessions() {
        var archived = AgentSession(title: "Archived plan")
        archived.archivedAt = Date()
        archived.currentPlan = AgentPlan(status: .proposed, steps: [], summary: "Review")

        let entries = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(sessions: [archived])

        #expect(entries.isEmpty)
    }

    /// The strip and the badge must never disagree — same input, same verdict.
    @Test
    func entryCountMatchesTheDockBadgeCount() {
        let waiting = AgentSession(title: "Needs an answer")
        var archived = AgentSession(title: "Archived plan")
        archived.archivedAt = Date()
        archived.currentPlan = AgentPlan(status: .proposed, steps: [], summary: "Review")
        let runtimes = [waiting.id: waitingRuntime(for: waiting, turnStartedAt: Date())]

        let entries = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: [waiting, archived],
            runtimes: runtimes,
            limit: .max
        )
        let count = AgentSessionApprovalBadgeLogic.pendingApprovalSessionCount(
            sessions: [waiting, archived],
            runtimes: runtimes
        )

        #expect(entries.count == count)
    }

    // MARK: - Ordering and capping

    @Test
    func entriesAreNewestFirstAndCappedAtTheLimit() {
        let now = Date()
        let sessions = (0..<5).map { AgentSession(title: "Session \($0)") }
        // Session 0 blocked longest ago, session 4 most recently.
        let runtimes = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { index, session in
            (session.id, waitingRuntime(for: session, turnStartedAt: now.addingTimeInterval(Double(index))))
        })

        let entries = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: sessions,
            runtimes: runtimes,
            limit: AgentSessionApprovalBadgeLogic.quickJumpLimit
        )

        #expect(entries.count == AgentSessionApprovalBadgeLogic.quickJumpLimit)
        #expect(entries.map(\.title) == ["Session 4", "Session 3", "Session 2"])
    }

    /// Swift's sort is not stable; equal timestamps must still produce one
    /// fixed order or the strip reshuffles under the account footer.
    @Test
    func rankingBreaksTimestampTiesDeterministically() {
        let sameInstant = Date()
        let entries = (0..<6).map { index in
            AgentPendingApprovalEntry(
                sessionID: UUID(),
                title: "Session \(index)",
                waitingSince: sameInstant
            )
        }

        let first = AgentSessionApprovalBadgeLogic.rankMostRecentFirst(entries)
        let second = AgentSessionApprovalBadgeLogic.rankMostRecentFirst(entries.reversed())

        #expect(first == second)
        #expect(first.map(\.sessionID) == entries.map(\.sessionID).sorted { $0.uuidString < $1.uuidString })
    }

    @Test
    func rankingWithANonPositiveLimitReturnsNothing() {
        let entries = [
            AgentPendingApprovalEntry(sessionID: UUID(), title: "One", waitingSince: Date())
        ]

        #expect(AgentSessionApprovalBadgeLogic.rankMostRecentFirst(entries, limit: 0).isEmpty)
    }

    // MARK: - Dock gesture

    @Test
    func dockDoubleClickNeedsTwoClicksInsideTheWindow() {
        let first = Date()

        #expect(!AgentDockReopenGesture.isDoubleClick(previousClick: nil, currentClick: first))
        #expect(AgentDockReopenGesture.isDoubleClick(
            previousClick: first,
            currentClick: first.addingTimeInterval(0.2)
        ))
        #expect(!AgentDockReopenGesture.isDoubleClick(
            previousClick: first,
            currentClick: first.addingTimeInterval(1.5)
        ))
    }

    /// Clock changes must not turn a stale timestamp into a phantom jump.
    @Test
    func dockDoubleClickIgnoresClicksThatWentBackwardsInTime() {
        let now = Date()

        #expect(!AgentDockReopenGesture.isDoubleClick(
            previousClick: now,
            currentClick: now.addingTimeInterval(-0.2)
        ))
    }

    // MARK: - Dock menu titles

    @Test
    func dockMenuTitleTruncatesLongSessionTitles() {
        let entry = AgentPendingApprovalEntry(
            sessionID: UUID(),
            title: String(repeating: "长", count: 80),
            waitingSince: Date()
        )

        let title = AgentDockAttentionController.menuTitle(for: entry, maximumLength: 12)

        #expect(title.count == 12)
        #expect(title.hasSuffix("…"))
    }

    @Test
    func dockMenuTitleFallsBackWhenTheSessionHasNoTitle() {
        let entry = AgentPendingApprovalEntry(sessionID: UUID(), title: "   ", waitingSince: Date())

        #expect(AgentDockAttentionController.menuTitle(for: entry) == L10n.Sidebar.sessionRowWaitingApproval)
    }
}
