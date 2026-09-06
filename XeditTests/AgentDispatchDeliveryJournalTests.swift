import Foundation
import Testing
@testable import WillDeep

@Suite("调度交付持久化与过期回调")
struct AgentDispatchDeliveryJournalTests {
    private func initialRecord() -> AgentDispatchDeliveryRecord {
        let goalID = UUID(), taskID = UUID()
        let snapshot = AgentDispatchArtifactSnapshot(taskID: taskID, baseRevision: "base", revision: "task", tree: "tree", paths: ["report.md"])
        let candidate = AgentDispatchIntegrationCandidate(goalID: goalID, snapshot: snapshot, expectedRefRevision: nil, previousRevision: "base", revision: "candidate")
        return .init(goalID: goalID, taskID: taskID, runtimeID: UUID(), generation: 0, phase: .prepared, candidate: candidate)
    }

    private func withJournal(_ body: (AgentDispatchDeliveryJournal) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-journal-test-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { Issue.record("Journal fixture cleanup failed: \(error)") }
        }
        try body(AgentDispatchDeliveryJournal(directory: directory))
    }

    @Test("日志拒绝跨交付代次读写，旧格式继续隔离使用")
    func revisionIdentityRejectsCrossScopeRecords() throws {
        try withJournal { legacy in
            let original = initialRecord()
            try legacy.save(original, expectedGeneration: nil)
            let wrongReader = AgentDispatchDeliveryJournal(directory: legacy.directory, revisionID: UUID())
            #expect(throws: AgentDispatchJournalError.corrupt) {
                try wrongReader.load(goalID: original.goalID, taskID: original.taskID)
            }
            var wrongRecord = original
            wrongRecord.deliveryRevisionID = UUID()
            #expect(throws: AgentDispatchJournalError.invalidTransition) {
                try legacy.save(wrongRecord, expectedGeneration: 0)
            }
            #expect(try legacy.load(goalID: original.goalID, taskID: original.taskID) == original)
        }
    }

    @Test("各交付阶段写入后可由新实例恢复")
    func phasesSurviveReopen() throws {
        try withJournal { journal in
            var record = initialRecord()
            try journal.save(record, expectedGeneration: nil)
            for phase in [AgentDispatchDeliveryRecord.Phase.verified, .published, .delivered] {
                let previous = record.generation
                record.generation += 1
                record.phase = phase
                if record.verificationID == nil {
                    let id = UUID()
                    record.verificationID = id
                    record.verificationReceipt = .init(id: id, revision: record.candidate.revision, commands: ["fixture verifier"], outputDigests: ["fixture digest"], operatorOverride: false, verifiedAt: Date())
                }
                if phase == .published {
                    record.receipt = .init(snapshot: record.candidate.snapshot, previousRevision: record.candidate.previousRevision, integratedRevision: record.candidate.revision)
                }
                try journal.save(record, expectedGeneration: previous)
                #expect(try AgentDispatchDeliveryJournal(directory: journal.directory).load(goalID: record.goalID, taskID: record.taskID) == record)
            }
        }
    }

    @Test("Stop 之后晚到的验收回调不能恢复交付")
    func stopRejectsStaleCompletion() throws {
        try withJournal { journal in
            var stopped = initialRecord()
            try journal.save(stopped, expectedGeneration: nil)
            var completion = stopped
            completion.generation = 1
            completion.phase = .verified
            completion.verificationID = UUID()
            stopped.generation = 1
            stopped.phase = .stopped
            try journal.save(stopped, expectedGeneration: 0)
            #expect(throws: AgentDispatchJournalError.staleGeneration) { try journal.save(completion, expectedGeneration: 0) }
            completion.generation = 2
            #expect(throws: AgentDispatchJournalError.invalidTransition) { try journal.save(completion, expectedGeneration: 1) }
            #expect(try journal.load(goalID: stopped.goalID, taskID: stopped.taskID) == stopped)
        }
    }

    @Test("没有验收记录和集成回执不能跳到 delivered")
    func noEvidenceCannotUnlockDependencies() throws {
        try withJournal { journal in
            var record = initialRecord()
            try journal.save(record, expectedGeneration: nil)
            record.generation = 1
            record.phase = .delivered
            #expect(throws: AgentDispatchJournalError.invalidTransition) { try journal.save(record, expectedGeneration: 0) }
            record.phase = .verified
            #expect(throws: AgentDispatchJournalError.invalidTransition) { try journal.save(record, expectedGeneration: 0) }
            #expect(try journal.load(goalID: record.goalID, taskID: record.taskID)?.phase == .prepared)
        }
    }

    @Test("只有独立显式重启操作能解除 Stop，且旧回调不能覆盖新一代")
    func explicitRestartDiscardsProofAndAdvancesGeneration() throws {
        try withJournal { journal in
            var record = initialRecord()
            try journal.save(record, expectedGeneration: nil)
            record.generation = 1
            record.phase = .stopped
            try journal.save(record, expectedGeneration: 0)
            var forbidden = record
            forbidden.generation = 2
            forbidden.phase = .prepared
            #expect(throws: AgentDispatchJournalError.invalidTransition) {
                try journal.save(forbidden, expectedGeneration: 1)
            }
            let newRuntime = UUID()
            try journal.restartStopped(record, runtimeID: newRuntime)
            let loaded = try journal.load(goalID: record.goalID, taskID: record.taskID)
            let restarted = try #require(loaded)
            #expect(restarted.phase == .prepared)
            #expect(restarted.generation == 2)
            #expect(restarted.runtimeID == newRuntime)
            #expect(restarted.verificationReceipt == nil)
            #expect(restarted.receipt == nil)
            #expect(throws: AgentDispatchJournalError.staleGeneration) {
                try journal.restartStopped(record, runtimeID: newRuntime)
            }
            #expect(throws: AgentDispatchJournalError.staleGeneration) {
                try journal.save(forbidden, expectedGeneration: 1)
            }
        }
    }

    @Test("损坏记录不会当作空记录覆盖")
    func corruptRecordIsPreserved() throws {
        try withJournal { journal in
            let record = initialRecord()
            try journal.save(record, expectedGeneration: nil)
            let file = journal.directory.appendingPathComponent("\(record.goalID.uuidString)-\(record.taskID.uuidString).json")
            let corruption = Data("{broken".utf8)
            try corruption.write(to: file)
            #expect(throws: AgentDispatchJournalError.corrupt) { try journal.save(record, expectedGeneration: nil) }
            #expect(try Data(contentsOf: file) == corruption)
        }
    }
}
