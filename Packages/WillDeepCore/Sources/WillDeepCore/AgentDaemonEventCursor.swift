import Foundation

/// One owner per remote stream. Cursors are job-scoped, absolute, and
/// advanced only after validation; equal output text is never a dedup key.
public nonisolated struct AgentDaemonEventCursor: Sendable {
    public enum ProtocolFailure: Error { case wrongJob, invalidSequence, capabilityLost }
    public enum Admission: Equatable { case duplicate, deliver(hasGap: Bool) }
    public private(set) var after: Int64 = 0
    public private(set) var supportsResume = false
    private var hasLegacyOutput = false
    public var canResume: Bool { supportsResume || (!hasLegacyOutput && after == 0) }

    public mutating func negotiate(resumable: Bool) throws {
        if supportsResume && !resumable { throw ProtocolFailure.capabilityLost }
        supportsResume = resumable
    }

    public mutating func accept(jobID: String?, expectedJobID: String,
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

    // 存储成员全是 private(set)，外部只读。这里只需要一个无参构造器——
    // struct 不写 init 时合成的那个是 internal，跨模块用不到。
    public init() {}
}

/// A completed stream hands its cursor back before the owner starts another.
public nonisolated final class AgentDaemonEventCursorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = AgentDaemonEventCursor()

    // class 不写 init 时编译器合成的那个是 internal，跨模块构造不到。
    public init() {}

    public func load() -> AgentDaemonEventCursor { lock.withLock { cursor } }
    public func save(_ value: AgentDaemonEventCursor) { lock.withLock { cursor = value } }
}
