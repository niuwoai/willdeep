import Foundation
import Testing
@testable import WillDeep

/// The event journal changed shape twice while the runtime kernel was being
/// built: rc14 wrote a bare array of events, rc15/rc16 wrapped them in a
/// `Journal` and split the single `contentTrust` flag into `trust` (may this
/// event wake the model) and `contentProvenance` (whose words are in the body).
/// `loadAll` still reads both, and the CHANGELOG promised as much — but nothing
/// held a byte of either format, so the promise rested on the reader's memory
/// of shapes no live install writes any more.
///
/// These are the fixtures. They are written as literal JSON on purpose: a
/// fixture produced by today's encoder proves only that today's encoder round
/// trips.
/// Serialized because `AgentKernelEventStore.directoryOverride` is one static
/// for the whole process: run in parallel, these tests hand each other their
/// temporary directories and the failures read like decoding bugs.
@Suite(.serialized)
struct AgentKernelLegacyJournalTests {
    private func withTemporaryJournalDirectory(
        _ body: (URL) throws -> Void
    ) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-kernel-legacy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        AgentKernelEventStore.directoryOverride = directory
        defer {
            AgentKernelEventStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    /// rc14's on-disk shape: no envelope, no schema number, one JSON array.
    private func legacyArrayJournal(runtimeID: UUID, eventID: UUID) -> String {
        """
        [
          {
            "id": "\(eventID.uuidString)",
            "runtimeID": "\(runtimeID.uuidString)",
            "source": "worker",
            "kind": "worker_completed",
            "priority": 10,
            "interruptPolicy": "yield_at_boundary",
            "trust": "host",
            "audience": "both",
            "title": "rc14 worker",
            "payload": "rc14 report",
            "metadata": { "resource_id": "abc" },
            "requiresUserAction": false,
            "state": "pending",
            "createdAt": 776000000,
            "updatedAt": 776000000,
            "coalescedCount": 1
          }
        ]
        """
    }

    /// rc15/rc16's shape: envelope with a schema number, and the pre-split
    /// `contentTrust` flag where `contentProvenance` now lives.
    private func legacySchemaTwoJournal(runtimeID: UUID, eventID: UUID) -> String {
        """
        {
          "schemaVersion": 2,
          "events": [
            {
              "id": "\(eventID.uuidString)",
              "runtimeID": "\(runtimeID.uuidString)",
              "source": "email",
              "kind": "email_received",
              "priority": 10,
              "interruptPolicy": "enqueue",
              "trust": "authenticated",
              "contentTrust": "untrusted",
              "audience": "both",
              "title": "rc15 mail",
              "payload": "rc15 body",
              "metadata": {},
              "dedupeKey": "external:email:mid-1",
              "requiresUserAction": true,
              "state": "pending",
              "createdAt": 776000000,
              "updatedAt": 776000000,
              "coalescedCount": 1
            }
          ]
        }
        """
    }

    @Test("an rc14 bare-array journal still loads")
    func legacyArrayFormatLoads() throws {
        try withTemporaryJournalDirectory { directory in
            let runtimeID = UUID()
            let eventID = UUID()
            try legacyArrayJournal(runtimeID: runtimeID, eventID: eventID).write(
                to: AgentKernelEventStore.fileURL(for: runtimeID),
                atomically: true,
                encoding: .utf8
            )

            let loaded = AgentKernelEventStore.loadAll()
            let event = try #require(loaded.first { $0.id == eventID })
            #expect(loaded.count == 1)
            #expect(event.payload == "rc14 report")
            #expect(event.trust == .host)
            #expect(event.metadata["resource_id"] == "abc")
        }
    }

    @Test("an rc15 schema-2 journal still loads")
    func legacySchemaTwoLoads() throws {
        try withTemporaryJournalDirectory { directory in
            let runtimeID = UUID()
            let eventID = UUID()
            try legacySchemaTwoJournal(runtimeID: runtimeID, eventID: eventID).write(
                to: AgentKernelEventStore.fileURL(for: runtimeID),
                atomically: true,
                encoding: .utf8
            )

            let loaded = AgentKernelEventStore.loadAll()
            let event = try #require(loaded.first { $0.id == eventID })
            #expect(event.title == "rc15 mail")
            #expect(event.requiresUserAction)
            #expect(event.dedupeKey == "external:email:mid-1")
        }
    }

    /// The split is the part most likely to rot: a reader that dropped the old
    /// flag would quietly promote a mail body to host provenance and stop
    /// sanitising it.
    @Test("a pre-split journal keeps untrusted bodies untrusted")
    func legacyContentTrustSurvivesTheSplit() throws {
        try withTemporaryJournalDirectory { directory in
            let runtimeID = UUID()
            let eventID = UUID()
            try legacySchemaTwoJournal(runtimeID: runtimeID, eventID: eventID).write(
                to: AgentKernelEventStore.fileURL(for: runtimeID),
                atomically: true,
                encoding: .utf8
            )

            let event = try #require(AgentKernelEventStore.loadAll().first { $0.id == eventID })
            #expect(event.resolvedContentTrust == .untrusted)
            #expect(event.resolvedContentProvenance != .host)
        }
    }

    /// A pending event from an old journal has to remain deliverable, otherwise
    /// "compatible" means only that the file parsed.
    @Test("a restored legacy event is still pending for the model")
    @MainActor
    func legacyEventRemainsDeliverable() throws {
        try withTemporaryJournalDirectory { directory in
            let runtimeID = UUID()
            let eventID = UUID()
            try legacyArrayJournal(runtimeID: runtimeID, eventID: eventID).write(
                to: AgentKernelEventStore.fileURL(for: runtimeID),
                atomically: true,
                encoding: .utf8
            )

            let kernel = AgentRuntimeKernel(loadPersisted: true, persistsEvents: false)
            #expect(kernel.pendingModelEventCount(for: runtimeID) == 1)
        }
    }

    /// The quarantine path is the other half of compatibility: a file that is
    /// neither shape must be moved aside, not re-read on every launch and not
    /// silently deleted.
    @Test("a journal in no known shape is quarantined rather than dropped")
    func unreadableJournalIsQuarantined() throws {
        try withTemporaryJournalDirectory { directory in
            let runtimeID = UUID()
            let url = AgentKernelEventStore.fileURL(for: runtimeID)
            try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)

            #expect(AgentKernelEventStore.loadAll().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            let remaining = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            #expect(remaining.contains { $0.lastPathComponent.contains("corrupt-") })
        }
    }
}
