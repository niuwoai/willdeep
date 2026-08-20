import Foundation
import SwiftUI
import Testing
@testable import WillDeep

/// The Automations page could say a routine had *started* and nothing else.
/// A run that died on a dead network and a run that produced a full report
/// rendered identically, so the only way to tell them apart was to open every
/// conversation by hand.
///
/// These pin the record that now carries the verdict, the reconciliation that
/// stops a dead run from reading as live forever, and how each outcome reads
/// in the list.
@Suite
@MainActor
struct AgentRoutineRunOutcomeTests {
    private func record(
        outcome: AgentRoutineRunOutcome = .running,
        startedAt: Date = Date(timeIntervalSince1970: 1_787_000_000),
        finishedAt: Date? = nil,
        failureMessage: String? = nil
    ) -> AgentRoutineRunRecord {
        AgentRoutineRunRecord(
            routineID: UUID(),
            routineName: "检查 some.im 线上日志",
            sessionID: UUID(),
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            failureMessage: failureMessage
        )
    }

    // MARK: - Persistence

    @Test("a new run starts out marked running")
    func newRunDefaultsToRunning() {
        let fresh = AgentRoutineRunRecord(
            routineID: UUID(),
            routineName: "每日简报",
            sessionID: UUID()
        )

        #expect(fresh.outcome == .running)
        #expect(fresh.finishedAt == nil)
        #expect(fresh.failureMessage == nil)
    }

    @Test("outcome survives an encode/decode round trip")
    func outcomeRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let original = record(
            outcome: .failed,
            finishedAt: Date(timeIntervalSince1970: 1_787_000_300),
            failureMessage: "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。"
        )
        let restored = try decoder.decode(
            AgentRoutineRunRecord.self,
            from: try encoder.encode(original)
        )

        #expect(restored == original)
    }

    @Test("run history written before outcomes decodes as unknown, not as success")
    func legacyRecordDecodesAsUnknown() throws {
        // Exactly the shape already on disk: no finishedAt, no outcome.
        let json = """
        [{
          "id": "\(UUID().uuidString)",
          "routineID": "\(UUID().uuidString)",
          "routineName": "检查 some.im 线上日志",
          "sessionID": "\(UUID().uuidString)",
          "startedAt": "2026-08-19T14:00:20Z"
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode([AgentRoutineRunRecord].self, from: Data(json.utf8))

        #expect(restored.count == 1)
        #expect(restored[0].outcome == .unknown, "history must not invent a verdict it never observed")
        #expect(restored[0].finishedAt == nil)
    }

    // MARK: - Reconciliation

    @Test("a run left running by a dead process is settled as interrupted")
    func orphanedRunIsReconciled() {
        let orphan = record(outcome: .running)
        let succeeded = record(
            outcome: .succeeded,
            finishedAt: Date(timeIntervalSince1970: 1_787_000_120)
        )
        let legacy = record(outcome: .unknown)

        let reconciled = AgentRoutineRunHistory
            .reconcilingRunsOrphanedByPreviousLaunch([orphan, succeeded, legacy])

        #expect(reconciled[0].outcome == .interrupted, "a three-day-old run must not still read as in progress")
        #expect(reconciled[0].finishedAt == orphan.startedAt)
        // Everything already settled is left exactly as it was.
        #expect(reconciled[1] == succeeded)
        #expect(reconciled[2] == legacy)
    }

    @Test("reconciliation is idempotent")
    func reconciliationIsIdempotent() {
        let once = AgentRoutineRunHistory
            .reconcilingRunsOrphanedByPreviousLaunch([record(outcome: .running)])
        let twice = AgentRoutineRunHistory
            .reconcilingRunsOrphanedByPreviousLaunch(once)

        #expect(once == twice)
    }

    // MARK: - Presentation

    @Test("only a failed run takes emphasis, and it says why")
    func outcomePresentation() {
        let failed = AgentRoutineRunOutcomePresentation(outcome: .failed)
        #expect(failed.emphasized)
        #expect(failed.label == L10n.Automation.runOutcomeFailed)

        for outcome in [AgentRoutineRunOutcome.running, .succeeded, .interrupted, .unknown] {
            #expect(
                !AgentRoutineRunOutcomePresentation(outcome: outcome).emphasized,
                "\(outcome) must stay muted so the failed row is the one thing that stands out"
            )
        }

        // Legacy rows keep the old neutral glyph and claim nothing.
        #expect(AgentRoutineRunOutcomePresentation(outcome: .unknown).label == nil)
        #expect(AgentRoutineRunOutcomePresentation(outcome: .succeeded).label != nil)
    }

    // MARK: - Settling a real run

    @Test("a failed routine run is recorded as failed, with its reason")
    func failedRunIsSettled() {
        let appState = AppState()
        let routineID = UUID()
        var session = AgentSession.forRoutineRun(
            routineID: routineID,
            workspaceRootPath: "/Users/rocky/Sites/muchtoken",
            modelID: "glm-5",
            providerEntryID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im"
        )
        session.messages = [AgentMessage(role: .user, content: "检查线上日志")]
        let runtime = AgentRuntime(session: session)
        runtime.lastTurnFailure = AgentTurnFailure(message: "当前似乎没有网络。")
        appState.agentRoutineRuns = [
            AgentRoutineRunRecord(
                routineID: routineID,
                routineName: "检查 some.im 线上日志",
                sessionID: session.id
            )
        ]

        appState.recordRoutineRunCompletionIfNeeded(for: runtime)

        #expect(appState.agentRoutineRuns[0].outcome == .failed)
        #expect(appState.agentRoutineRuns[0].failureMessage == "当前似乎没有网络。")
        #expect(appState.agentRoutineRuns[0].finishedAt != nil)
    }

    @Test("a run that produced a reply is recorded as succeeded")
    func succeededRunIsSettled() {
        let appState = AppState()
        let routineID = UUID()
        var session = AgentSession.forRoutineRun(
            routineID: routineID,
            workspaceRootPath: nil,
            modelID: nil,
            providerEntryID: nil,
            providerID: nil,
            providerDisplayName: nil
        )
        session.messages = [
            AgentMessage(role: .user, content: "检查线上日志"),
            AgentMessage(role: .assistant, content: "两个服务都正常，24 小时内没有 err 级日志。"),
        ]
        let runtime = AgentRuntime(session: session)
        appState.agentRoutineRuns = [
            AgentRoutineRunRecord(
                routineID: routineID,
                routineName: "检查 some.im 线上日志",
                sessionID: session.id
            )
        ]

        appState.recordRoutineRunCompletionIfNeeded(for: runtime)

        #expect(appState.agentRoutineRuns[0].outcome == .succeeded)
        #expect(appState.agentRoutineRuns[0].failureMessage == nil)
    }

    @Test("no error and no reply is interrupted, never success")
    func silentRunIsNotCountedAsSuccess() {
        let appState = AppState()
        let routineID = UUID()
        var session = AgentSession.forRoutineRun(
            routineID: routineID,
            workspaceRootPath: nil,
            modelID: nil,
            providerEntryID: nil,
            providerID: nil,
            providerDisplayName: nil
        )
        // Exactly the shape the reported bug left behind: the user message
        // went out and nothing ever came back.
        session.messages = [AgentMessage(role: .user, content: "检查线上日志")]
        let runtime = AgentRuntime(session: session)
        appState.agentRoutineRuns = [
            AgentRoutineRunRecord(
                routineID: routineID,
                routineName: "检查 some.im 线上日志",
                sessionID: session.id
            )
        ]

        appState.recordRoutineRunCompletionIfNeeded(for: runtime)

        #expect(appState.agentRoutineRuns[0].outcome == .interrupted)
    }

    @Test("a later turn does not rewrite how the scheduled run went")
    func settlingHappensOncePerRun() {
        let appState = AppState()
        let routineID = UUID()
        var session = AgentSession.forRoutineRun(
            routineID: routineID,
            workspaceRootPath: nil,
            modelID: nil,
            providerEntryID: nil,
            providerID: nil,
            providerDisplayName: nil
        )
        session.messages = [AgentMessage(role: .user, content: "检查线上日志")]
        let runtime = AgentRuntime(session: session)
        runtime.lastTurnFailure = AgentTurnFailure(message: "当前似乎没有网络。")
        appState.agentRoutineRuns = [
            AgentRoutineRunRecord(
                routineID: routineID,
                routineName: "检查 some.im 线上日志",
                sessionID: session.id
            )
        ]
        appState.recordRoutineRunCompletionIfNeeded(for: runtime)
        let settled = appState.agentRoutineRuns[0]

        // The user opens the conversation the next morning and clicks 重试.
        runtime.clearTurnError()
        runtime.messages.append(AgentMessage(role: .assistant, content: "补跑完成。"))
        appState.recordRoutineRunCompletionIfNeeded(for: runtime)

        #expect(appState.agentRoutineRuns[0] == settled, "the 22:00 run still failed; a manual rerun is not that run")
    }

    @Test("conversations a human started are left out of run history")
    func interactiveSessionIsIgnored() {
        let appState = AppState()
        let session = AgentSession(
            workspaceRootPath: nil,
            messages: [AgentMessage(role: .user, content: "帮我看下这个")]
        )
        let runtime = AgentRuntime(session: session)
        runtime.lastTurnFailure = AgentTurnFailure(message: "当前似乎没有网络。")
        let untouched = AgentRoutineRunRecord(
            routineID: UUID(),
            routineName: "检查 some.im 线上日志",
            sessionID: session.id
        )
        appState.agentRoutineRuns = [untouched]

        appState.recordRoutineRunCompletionIfNeeded(for: runtime)

        #expect(appState.agentRoutineRuns[0] == untouched)
    }
}

/// Side-panel rail glyphs. A misspelled SF Symbol does not fail to build and
/// does not throw — it renders as nothing, leaving a blank slot in the rail.
@Suite
struct AgentSidePanelIconTests {
    @Test("every side-panel kind names a real SF Symbol")
    func everyKindResolvesToASymbol() {
        for kind in AgentSidePanelKind.allCases {
            #expect(
                NSImage(systemSymbolName: kind.systemImage, accessibilityDescription: nil) != nil,
                "\(kind) points at \"\(kind.systemImage)\", which macOS does not have — the rail slot renders empty"
            )
        }
    }

    @Test("background tasks uses a recognizable progress-clock glyph")
    func backgroundTasksIconReadsAsBackgroundWork() {
        #expect(AgentSidePanelKind.backgroundTasks.systemImage == "clock.arrow.circlepath")
        #expect(
            AgentSidePanelKind.allCases.filter {
                $0.systemImage == AgentSidePanelKind.backgroundTasks.systemImage
            }.count == 1,
            "two rail entries sharing a glyph makes both of them unreadable"
        )
    }
}

/// The stdout console opened scrolled into the middle of its longest line.
@Suite
struct AgentBackgroundTaskLogScrollTests {
    @Test("following the tail must not drag the log off its left edge")
    func followAnchorPinsTheLeftEdge() {
        // `scrollTo` applies its anchor on BOTH axes. `.bottom` carries
        // x == 0.5, which is what centred the content horizontally.
        #expect(AgentBackgroundTaskLogScroll.followAnchor.x == 0)
        #expect(AgentBackgroundTaskLogScroll.followAnchor.y == 1, "vertical follow still has to land on the newest line")
        #expect(AgentBackgroundTaskLogScroll.followAnchor != .bottom)
    }
}
