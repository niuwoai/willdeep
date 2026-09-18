//
//  AgentRoundtableHistoryLoaderTests.swift
//  XeditTests
//
//  Guards the roundtable history read that used to decode the whole session
//  catalog on the main thread: only `.roundtable`-scoped sessions are read,
//  resident runtimes win over disk, and the off-main disk read leaves the
//  metadata-only tracker alone.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentRoundtableHistoryLoaderTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func report(id: UUID = UUID(), topic: String, updatedAt: Date) -> AgentRoundtableReport {
        AgentRoundtableReport(id: id, topic: topic, updatedAt: updatedAt)
    }

    private func messages(carrying report: AgentRoundtableReport) -> [AgentMessage] {
        [
            AgentMessage(role: .user, content: report.topic),
            AgentMessage(
                role: .workflowReport,
                content: "",
                workflowReport: WorkflowReport(
                    workflowName: "expert-roundtable",
                    displayTitle: report.topic,
                    args: report.topic,
                    status: .done,
                    roundtable: report
                )
            )
        ]
    }

    @Test
    func itemsPickOnlyRoundtableReportsAndCarryTheSessionID() {
        let sessionID = UUID()
        let rt = report(topic: "topic", updatedAt: t0)
        let items = AgentRoundtableHistoryLoader.items(
            sessionID: sessionID,
            messages: messages(carrying: rt) + [AgentMessage(role: .assistant, content: "hi")]
        )
        #expect(items == [AgentRoundtableHistoryItem(sessionID: sessionID, report: rt)])
    }

    /// The old path scanned every session in the catalog. Only roundtable-scoped
    /// ones can hold a roundtable report, and resident runtimes are read from
    /// memory, so neither needs a disk decode.
    @Test
    func onlyNonResidentRoundtableSessionsAreDiskCandidates() {
        let workspace = AgentSession(title: "code")
        let dispatch = AgentSession(title: "dispatch", presentationScope: .dispatchBoard)
        let storedRoundtable = AgentSession(title: "stored", presentationScope: .roundtable)
        let residentRoundtable = AgentSession(title: "resident", presentationScope: .roundtable)

        let candidates = AgentRoundtableHistoryLoader.storedCandidateIDs(
            catalog: [workspace, dispatch, storedRoundtable, residentRoundtable],
            excluding: [residentRoundtable.id]
        )
        #expect(candidates == [storedRoundtable.id])
    }

    @Test
    func loadStoredReadsEachCandidateAndSkipsMissingOnes() {
        let rt = report(topic: "stored", updatedAt: t0)
        let stored = AgentSession(presentationScope: .roundtable, messages: messages(carrying: rt))
        let missing = UUID()
        var requested: [UUID] = []
        let items = AgentRoundtableHistoryLoader.loadStored(candidateIDs: [stored.id, missing]) { id in
            requested.append(id)
            return id == stored.id ? stored : nil
        }
        #expect(requested == [stored.id, missing])
        #expect(items == [AgentRoundtableHistoryItem(sessionID: stored.id, report: rt)])
    }

    @Test
    func mergePrefersResidentStateAndSortsNewestFirst() {
        let sharedID = UUID()
        let sessionA = UUID()
        let sessionB = UUID()
        let residentCopy = report(id: sharedID, topic: "live", updatedAt: t0.addingTimeInterval(10))
        let staleCopy = report(id: sharedID, topic: "stale", updatedAt: t0)
        let older = report(topic: "older", updatedAt: t0.addingTimeInterval(-100))
        let newest = report(topic: "newest", updatedAt: t0.addingTimeInterval(100))

        let merged = AgentRoundtableHistoryLoader.merge(
            resident: [AgentRoundtableHistoryItem(sessionID: sessionA, report: residentCopy)],
            stored: [
                AgentRoundtableHistoryItem(sessionID: sessionA, report: staleCopy),
                AgentRoundtableHistoryItem(sessionID: sessionB, report: older),
                AgentRoundtableHistoryItem(sessionID: sessionB, report: newest)
            ]
        )
        #expect(merged.map(\.report.topic) == ["newest", "live", "older"])
    }

    /// The history scan runs off the main actor and never hands the session to
    /// an AppState catalog, so it must not flip the process-wide skeleton flag
    /// the way `load(id:)` (a real materialization) does.
    @Test
    func peekStoredSessionReadsFullTranscriptWithoutClearingMetadataOnlyFlag() {
        let rt = report(topic: "on disk", updatedAt: t0)
        let session = AgentSession(presentationScope: .roundtable, messages: messages(carrying: rt))
        #expect(AgentSessionStore.save(session))
        defer {
            AgentSessionStore.clearMetadataOnlyForTesting(session.id)
            _ = AgentSessionStore.delete(id: session.id)
        }
        AgentSessionStore.markMetadataOnlyForTesting(session.id, hasUserMessage: true)

        let peeked = AgentSessionStore.peekStoredSession(id: session.id)

        // Compared by identity, not `==`: `createdAt` defaults to `Date()` and
        // its sub-second part does not survive the JSON round-trip.
        let roundtables = peeked?.messages.compactMap { $0.workflowReport?.roundtable } ?? []
        #expect(roundtables.map(\.id) == [rt.id])
        #expect(roundtables.map(\.topic) == ["on disk"])
        #expect(AgentSessionStore.isMetadataOnly(session.id))
    }
}
