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

    private func session(title: String, userText: String? = nil) -> AgentSession {
        AgentSession(
            title: title,
            messages: userText.map { [AgentMessage(role: .user, content: $0)] } ?? []
        )
    }

    // MARK: - Selection

    @Test
    func entriesCollectOnlySessionsBlockedOnTheUser() {
        let waiting = session(title: "Needs an answer", userText: "Needs an answer")
        let busy = session(title: "Still running", userText: "Still running")
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
        let waiting = session(title: "Needs an answer", userText: "Needs an answer")
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
        let sessions = (0..<5).map {
            session(title: "Session \($0)", userText: "Session \($0)")
        }
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

    @Test
    func pendingEntryShowsOnlyLatestUserTextFromAnAttachedPrompt() {
        let attachedPrompt = [
            AgentAttachedPromptProtocol.preludeHeader,
            "",
            "### File: screenshot.png",
            "host generated file body",
            "",
            AgentAttachedPromptProtocol.userTextBoundary,
            "请确认是否继续",
        ].joined(separator: "\n")
        let blocked = session(title: "The user attached the following…", userText: attachedPrompt)
        let runtime = waitingRuntime(for: blocked, turnStartedAt: Date())

        let entry = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: [blocked],
            runtimes: [blocked.id: runtime]
        ).first

        #expect(entry?.title == "请确认是否继续")
        #expect(entry?.title.contains("The user attached") == false)
        #expect(entry?.title.contains("### File:") == false)
    }

    @Test
    func pendingEntryRejectsForeignAttachmentPreludeWithoutAUserBoundary() {
        let foreignPrelude = """
        The user attached the following file for this turn:
        screenshot.png
        """
        let blocked = session(title: "Leaked attachment header", userText: foreignPrelude)
        let runtime = waitingRuntime(for: blocked, turnStartedAt: Date())

        let entry = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: [blocked],
            runtimes: [blocked.id: runtime]
        ).first

        #expect(entry?.title == "")
        #expect(entry?.title.contains("The user attached") == false)
    }

    @Test
    func pendingEntryKeepsUserTextAfterAForeignAttachmentPreludeBoundary() {
        let foreignPrelude = [
            "The user attached the following files:",
            "screenshot.png",
            AgentAttachedPromptProtocol.userTextBoundary,
            "这是我真正输入的内容",
        ].joined(separator: "\n")
        let blocked = session(title: "Leaked attachment header", userText: foreignPrelude)
        let runtime = waitingRuntime(for: blocked, turnStartedAt: Date())

        let entry = AgentSessionApprovalBadgeLogic.pendingApprovalEntries(
            sessions: [blocked],
            runtimes: [blocked.id: runtime]
        ).first

        #expect(entry?.title == "这是我真正输入的内容")
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

    @Test("插件等独立页面保留当前位置，不参与 Dock 连点跳会话")
    func dockReopenPreservesDedicatedPages() {
        for destination in [
            AgentPrimaryDestination.plugin("demo.panel"), .pluginCenter,
            .scheduledTasks, .dispatchBoard, .roundtable
        ] {
            #expect(!AgentDockReopenGesture.canRevealPendingSession(from: destination))
        }
        #expect(!AgentDockReopenGesture.canRevealPendingSession(from: nil))
        #expect(AgentDockReopenGesture.canRevealPendingSession(from: .conversation))
    }

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

    @Test
    func dockMenuBuildsAttentionRecentAndMoreSections() {
        let now = Date()
        let recent = (0..<6).map { index in
            AgentDockSessionEntry(
                sessionID: UUID(),
                title: "Recent \(index)",
                lastActivityAt: now.addingTimeInterval(Double(-index))
            )
        }
        let pendingOnly = AgentPendingApprovalEntry(
            sessionID: UUID(),
            title: "Needs approval",
            waitingSince: now.addingTimeInterval(10)
        )

        let snapshot = AgentDockMenuLogic.snapshot(
            recentEntries: recent,
            pendingEntries: [pendingOnly],
            unreadSessionIDs: [recent[1].sessionID]
        )

        #expect(snapshot.attention.map(\.title) == ["Needs approval", "Recent 1"])
        #expect(snapshot.recent.map(\.title) == ["Recent 0", "Recent 1", "Recent 2"])
        #expect(snapshot.more.map(\.title) == ["Recent 3", "Recent 4", "Recent 5"])
    }

    @Test
    func dockMenuDeduplicatesSessionsAndKeepsTheNewestCopy() {
        let sessionID = UUID()
        let older = AgentDockSessionEntry(
            sessionID: sessionID,
            title: "Old title",
            lastActivityAt: Date(timeIntervalSince1970: 1)
        )
        let newer = AgentDockSessionEntry(
            sessionID: sessionID,
            title: "New title",
            lastActivityAt: Date(timeIntervalSince1970: 2)
        )

        let ranked = AgentDockMenuLogic.rankAndDeduplicate([older, newer, older])

        #expect(ranked == [newer])
    }

    @Test
    func dockMenuLimitsCanHideEverySectionWithoutCrashing() {
        let entry = AgentDockSessionEntry(
            sessionID: UUID(),
            title: "One",
            lastActivityAt: Date()
        )

        let snapshot = AgentDockMenuLogic.snapshot(
            recentEntries: [entry],
            pendingEntries: [],
            unreadSessionIDs: [entry.sessionID],
            attentionLimit: 0,
            recentLimit: 0,
            moreLimit: 0
        )

        #expect(snapshot.isEmpty)
    }
}
