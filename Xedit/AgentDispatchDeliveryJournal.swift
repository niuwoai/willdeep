import CryptoKit
import Darwin
import Foundation

nonisolated struct AgentDispatchDeliveryRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, verified, published, delivered, stopped
    }

    let goalID: UUID
    let taskID: UUID
    let runtimeID: UUID
    var deliveryRevisionID: UUID? = nil
    var generation: Int
    var phase: Phase
    let candidate: AgentDispatchIntegrationCandidate
    var verificationID: UUID?
    var verificationReceipt: AgentDispatchVerificationReceipt? = nil
    var receipt: AgentDispatchIntegrationReceipt?
}

nonisolated enum AgentDispatchJournalError: Error, Equatable {
    case busy
    case corrupt
    case staleGeneration
    case invalidTransition
    case io(operation: String, code: Int32)
}

/// A small crash-recovery ledger separate from the UserDefaults board cache.
/// Each update is checksummed, atomically replaced and synced before returning.
/// Cross-process locks and generations reject stale completion callbacks.
nonisolated struct AgentDispatchDeliveryJournal: Sendable {
    let directory: URL
    let revisionID: UUID?
    private static let maximumRecordBytes = 4 * 1_024 * 1_024

    init(directory: URL, revisionID: UUID? = nil) {
        self.directory = directory
        self.revisionID = revisionID
    }

    private struct Envelope: Codable {
        let version: Int
        let checksum: String
        let payload: Data
    }

    func load(goalID: UUID, taskID: UUID) throws -> AgentDispatchDeliveryRecord? {
        let url = recordURL(goalID: goalID, taskID: taskID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumRecordBytes else {
            throw AgentDispatchJournalError.corrupt
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1, Self.checksum(envelope.payload) == envelope.checksum else {
                throw AgentDispatchJournalError.corrupt
            }
            let record = try JSONDecoder().decode(AgentDispatchDeliveryRecord.self, from: envelope.payload)
            guard record.goalID == goalID, record.taskID == taskID, record.deliveryRevisionID == revisionID,
                  record.candidate.goalID == goalID, record.candidate.snapshot.taskID == taskID else {
                throw AgentDispatchJournalError.corrupt
            }
            return record
        } catch let error as AgentDispatchJournalError { throw error }
        catch { throw AgentDispatchJournalError.corrupt }
    }

    /// Creation requires expectedGeneration=nil and generation=0. Updates
    /// advance exactly one generation; Stop cannot be overwritten by a late
    /// verification/publish callback or a newly opened app process.
    func save(_ record: AgentDispatchDeliveryRecord, expectedGeneration: Int?) throws {
        try save(record, expectedGeneration: expectedGeneration, restartingStopped: false)
    }

    /// A distinct host operation, not an allowed ordinary phase transition.
    /// CAS binds explicit restart to the exact stopped generation observed.
    func restartStopped(_ stopped: AgentDispatchDeliveryRecord, runtimeID: UUID) throws {
        guard stopped.phase == .stopped else { throw AgentDispatchJournalError.invalidTransition }
        let prepared = AgentDispatchDeliveryRecord(
            goalID: stopped.goalID, taskID: stopped.taskID, runtimeID: runtimeID,
            deliveryRevisionID: stopped.deliveryRevisionID,
            generation: stopped.generation + 1, phase: .prepared, candidate: stopped.candidate
        )
        try save(prepared, expectedGeneration: stopped.generation, restartingStopped: true)
    }

    private func save(_ record: AgentDispatchDeliveryRecord, expectedGeneration: Int?, restartingStopped: Bool) throws {
        guard record.deliveryRevisionID == revisionID else { throw AgentDispatchJournalError.invalidTransition }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(record.goalID.uuidString)-\(record.taskID.uuidString).lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentDispatchJournalError.io(operation: "open-lock", code: errno) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AgentDispatchJournalError.busy }
        defer { flock(descriptor, LOCK_UN) }
        let previous = try load(goalID: record.goalID, taskID: record.taskID)
        guard previous?.generation == expectedGeneration,
              record.generation == (expectedGeneration.map { $0 + 1 } ?? 0) else {
            throw AgentDispatchJournalError.staleGeneration
        }
        if restartingStopped {
            guard previous?.phase == .stopped, record.phase == .prepared,
                  record.candidate == previous?.candidate,
                  record.verificationID == nil, record.verificationReceipt == nil, record.receipt == nil else {
                throw AgentDispatchJournalError.invalidTransition
            }
        } else {
            try validate(record, previous: previous)
        }
        let payload = try JSONEncoder().encode(record)
        let data = try JSONEncoder().encode(Envelope(version: 1, checksum: Self.checksum(payload), payload: payload))
        guard data.count <= Self.maximumRecordBytes else { throw AgentDispatchJournalError.corrupt }
        try writeDurably(data, to: recordURL(goalID: record.goalID, taskID: record.taskID))
    }

    private func validate(_ record: AgentDispatchDeliveryRecord, previous: AgentDispatchDeliveryRecord?) throws {
        guard record.candidate.goalID == record.goalID,
              record.candidate.snapshot.taskID == record.taskID else {
            throw AgentDispatchJournalError.invalidTransition
        }
        if let previous {
            // Failed verification may return the worker to editing. Replacing
            // an unpublished candidate discards every old verification token.
            if (previous.phase == .prepared || previous.phase == .verified), record.phase == .prepared,
               record.verificationID == nil, record.verificationReceipt == nil, record.receipt == nil {
                return
            }
            guard record.runtimeID == previous.runtimeID, record.candidate == previous.candidate else {
                throw AgentDispatchJournalError.invalidTransition
            }
            let allowed: [AgentDispatchDeliveryRecord.Phase: Set<AgentDispatchDeliveryRecord.Phase>] = [
                .prepared: [.verified, .stopped], .verified: [.published, .stopped],
                .published: [.delivered, .stopped], .delivered: [], .stopped: [],
            ]
            guard allowed[previous.phase, default: []].contains(record.phase) else {
                throw AgentDispatchJournalError.invalidTransition
            }
        } else if record.phase != .prepared {
            throw AgentDispatchJournalError.invalidTransition
        }
        if [.verified, .published, .delivered].contains(record.phase) {
            guard let verification = record.verificationReceipt, verification.isValid,
                  verification.id == record.verificationID, verification.revision == record.candidate.revision else {
                throw AgentDispatchJournalError.invalidTransition
            }
        }
        if [.published, .delivered].contains(record.phase) {
            guard let receipt = record.receipt, receipt.snapshot == record.candidate.snapshot,
                  receipt.previousRevision == record.candidate.previousRevision,
                  receipt.integratedRevision == record.candidate.revision else {
                throw AgentDispatchJournalError.invalidTransition
            }
        }
        if let previous, previous.verificationID != nil, record.verificationID != previous.verificationID {
            throw AgentDispatchJournalError.invalidTransition
        }
        if let previous, previous.verificationReceipt != nil, record.verificationReceipt != previous.verificationReceipt {
            throw AgentDispatchJournalError.invalidTransition
        }
    }

    private func recordURL(goalID: UUID, taskID: UUID) -> URL {
        directory.appendingPathComponent("\(goalID.uuidString)-\(taskID.uuidString).json")
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeDurably(_ data: Data, to target: URL) throws {
        let temporary = directory.appendingPathComponent(".delivery-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentDispatchJournalError.io(operation: "open-record", code: errno) }
        defer { Darwin.close(descriptor); Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AgentDispatchJournalError.io(operation: "write-record", code: errno) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw AgentDispatchJournalError.io(operation: "sync-record", code: errno) }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw AgentDispatchJournalError.io(operation: "replace-record", code: errno)
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw AgentDispatchJournalError.io(operation: "open-directory", code: errno) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw AgentDispatchJournalError.io(operation: "sync-directory", code: errno) }
    }
}
