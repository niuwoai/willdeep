import Testing
@testable import WillDeep

@Suite("Daemon 稳定事件游标")
struct AgentDaemonEventCursorTests {
    @Test("按位置去重而非按输出文字去重，缺失范围明确标记")
    func absoluteCursor() throws {
        var cursor = AgentDaemonEventCursor()
        try cursor.negotiate(resumable: true)
        #expect(try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 1, isGap: false) == .deliver(hasGap: false))
        #expect(try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 1, isGap: false) == .duplicate)
        #expect(try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 2, isGap: false) == .deliver(hasGap: false))
        #expect(try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 8, isGap: false) == .deliver(hasGap: true))
        #expect(try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 9, isGap: true) == .deliver(hasGap: true))
        #expect(cursor.after == 9)
    }

    @Test("非法或缺失序号不推进游标", arguments: [Int64?.none, .some(0), .some(-1)])
    func invalidSequence(sequence: Int64?) throws {
        var cursor = AgentDaemonEventCursor()
        try cursor.negotiate(resumable: true)
        #expect(throws: AgentDaemonEventCursor.ProtocolFailure.self) {
            try cursor.accept(jobID: "a", expectedJobID: "a", sequence: sequence, isGap: false)
        }
        #expect(cursor.after == 0)
    }

    @Test("其他任务的重复事件也拒绝，不接受能力降级")
    func identityAndCapability() throws {
        var cursor = AgentDaemonEventCursor()
        try cursor.negotiate(resumable: true)
        _ = try cursor.accept(jobID: "a", expectedJobID: "a", sequence: 1, isGap: false)
        #expect(throws: AgentDaemonEventCursor.ProtocolFailure.self) {
            try cursor.accept(jobID: "b", expectedJobID: "a", sequence: 1, isGap: false)
        }
        #expect(throws: AgentDaemonEventCursor.ProtocolFailure.self) { try cursor.negotiate(resumable: false) }
        #expect(cursor.after == 1 && cursor.supportsResume)
    }

    @Test("旧 daemon 单次流兼容，不假装具有安全重放能力")
    func legacy() throws {
        var cursor = AgentDaemonEventCursor()
        try cursor.negotiate(resumable: false)
        for _ in 0..<2 {
            #expect(try cursor.accept(jobID: nil, expectedJobID: "a", sequence: nil, isGap: false) == .deliver(hasGap: false))
        }
        #expect(cursor.after == 0 && !cursor.supportsResume)
    }
}
