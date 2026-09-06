import Foundation

/// One owner per remote stream. Cursors are job-scoped, absolute, and
/// advanced only after validation; equal output text is never a dedup key.
nonisolated struct AgentDaemonEventCursor: Sendable {
    enum ProtocolFailure: Error { case wrongJob, invalidSequence, capabilityLost }
    enum Admission: Equatable { case duplicate, deliver(hasGap: Bool) }
    private(set) var after: Int64 = 0
    private(set) var supportsResume = false
    private var hasLegacyOutput = false
    var canResume: Bool { supportsResume || (!hasLegacyOutput && after == 0) }

    mutating func negotiate(resumable: Bool) throws {
        if supportsResume && !resumable { throw ProtocolFailure.capabilityLost }
        supportsResume = resumable
    }

    mutating func accept(jobID: String?, expectedJobID: String,
        sequence: Int64?, isGap: Bool) throws -> Admission {
        if let jobID, jobID != expectedJobID { throw ProtocolFailure.wrongJob }
        guard let sequence else {
            if supportsResume || isGap { throw ProtocolFailure.invalidSequence }
            hasLegacyOutput = true
            return .deliver(hasGap: false) // Old daemons cannot safely replay.
        }
        guard sequence > 0, jobID == expectedJobID else { throw ProtocolFailure.invalidSequence }
        guard sequence > after else { return .duplicate }
        let hasGap = isGap || sequence - after > 1
        after = sequence
        return .deliver(hasGap: hasGap)
    }
}

/// A completed stream hands its cursor back before the owner starts another.
nonisolated final class AgentDaemonEventCursorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = AgentDaemonEventCursor()
    func load() -> AgentDaemonEventCursor { lock.withLock { cursor } }
    func save(_ value: AgentDaemonEventCursor) { lock.withLock { cursor = value } }
}
