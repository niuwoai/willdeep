import Foundation
import Testing
@testable import WillDeep

@Suite("模型请求持久账本")
nonisolated struct AgentModelRequestLedgerTests {
    private func fixture() throws -> AgentModelRequestLedger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return .init(directory: root, ownerID: UUID())
    }

    private func cleanup(_ ledger: AgentModelRequestLedger) {
        do { try FileManager.default.removeItem(at: ledger.directory) }
        catch { Issue.record("Ledger fixture cleanup failed: \(error)") }
    }

    private func usage(_ total: Int) -> AgentModelRequestLedger.Usage {
        .init(prompt: total, completion: 0, total: total, cachedPrompt: nil, cacheWritePrompt: 0, reasoning: 0)
    }

    @Test("重新打开保留未知、零、失败消耗及未完成请求")
    func receiptsSurviveReopening() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { try ledger.begin(id: id, providerID: "fixture", modelID: "fixture") }
        try ledger.finish(id: ids[0], receipt: .init(outcome: .failed, usage: usage(17)))
        try ledger.finish(id: ids[1], receipt: .init(outcome: .succeeded, usage: usage(0)))
        try ledger.finish(id: ids[2], receipt: .init(outcome: .cancelled, usage: nil))
        let reopened = AgentModelRequestLedger(directory: ledger.directory, ownerID: ledger.ownerID)
        #expect(try reopened.summary() == .init(attempts: 4, unfinished: 1, unknownUsage: 2, reportedTokens: 17))
        #expect(try reopened.receipt(id: ids[0])?.outcome == .failed)
        #expect(try reopened.receipt(id: ids[1])?.usage?.total == 0)
        #expect(try reopened.receipt(id: ids[2])?.usage == nil)
        #expect(try reopened.receipt(id: ids[3]) == nil)
    }

    @Test("相同回执幂等，重复请求和冲突回执拒绝")
    func duplicateAndConflictingDelivery() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let id = UUID()
        try ledger.begin(id: id, providerID: "fixture", modelID: "fixture")
        #expect(throws: AgentModelRequestLedger.Failure.duplicateRequest) {
            try ledger.begin(id: id, providerID: "fixture", modelID: "fixture")
        }
        let receipt = AgentModelRequestLedger.Receipt(outcome: .failed, usage: usage(20))
        try ledger.finish(id: id, receipt: receipt)
        try ledger.finish(id: id, receipt: receipt)
        #expect(throws: AgentModelRequestLedger.Failure.conflictingReceipt) {
            try ledger.finish(id: id, receipt: .init(outcome: .succeeded, usage: usage(0)))
        }
        #expect(try ledger.receipt(id: id) == receipt)
        #expect(try ledger.summary().reportedTokens == 20)
        #expect(throws: AgentModelRequestLedger.Failure.missingRequest) {
            try ledger.finish(id: UUID(), receipt: receipt)
        }
    }

    @Test("负数用量拒绝且保留未知，不产生免费记录")
    func invalidUsageRemainsUnfinished() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let id = UUID()
        try ledger.begin(id: id, providerID: "fixture", modelID: "fixture")
        #expect(throws: AgentModelRequestLedger.Failure.invalidUsage) {
            try ledger.finish(id: id, receipt: .init(outcome: .succeeded, usage: usage(-1)))
        }
        #expect(try ledger.summary() == .init(attempts: 1, unfinished: 1, unknownUsage: 1, reportedTokens: 0))
    }

    @Test("多个连接并发记账，不重复累计且不同任务隔离")
    func concurrentConnectionsAndOwners() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let connection = AgentModelRequestLedger(directory: ledger.directory, ownerID: ledger.ownerID)
                    let id = UUID()
                    try connection.begin(id: id, providerID: "fixture", modelID: "fixture")
                    let receipt = AgentModelRequestLedger.Receipt(outcome: .succeeded, usage: usage(7))
                    try connection.finish(id: id, receipt: receipt)
                    try connection.finish(id: id, receipt: receipt)
                }
            }
            try await group.waitForAll()
        }
        #expect(try ledger.summary() == .init(attempts: 12, unfinished: 0, unknownUsage: 0, reportedTokens: 84))
        let other = AgentModelRequestLedger(directory: ledger.directory, ownerID: UUID())
        #expect(try other.summary().attempts == 0)
    }

    @Test("超过展示历史上限仍保留全部累计用量", .timeLimit(.minutes(1)))
    func accountingIsNotPrunedLikeDisplayHistory() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        for _ in 0..<501 {
            let id = UUID()
            try ledger.begin(id: id, providerID: "fixture", modelID: "fixture")
            try ledger.finish(id: id, receipt: .init(outcome: .succeeded, usage: usage(1)))
        }
        #expect(try ledger.summary() == .init(attempts: 501, unfinished: 0, unknownUsage: 0, reportedTokens: 501))
    }

    @MainActor @Test("传输前确认落盘，失败仍保留最新累计回执")
    func accountingWrapsTransportFailure() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        enum FixtureFailure: Error { case transport }
        await #expect(throws: FixtureFailure.self) {
            try await AgentModelRequestAccounting.run(ledger: ledger, configuration: .default, onEvent: { _ in }) { consume in
                #expect(try ledger.summary() == .init(attempts: 1, unfinished: 1, unknownUsage: 1, reportedTokens: 0))
                await consume(.usageReported(prompt: 5, completion: 1, total: 6, cachedPrompt: 2, cacheWritePrompt: nil, reasoning: 0))
                await consume(.usageReported(prompt: 5, completion: 3, total: 8, cachedPrompt: 2, cacheWritePrompt: nil, reasoning: 1))
                throw FixtureFailure.transport
            }
        }
        #expect(try ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: 0, reportedTokens: 8))
    }

    @MainActor @Test("取消仍提交终态，未知用量不变成零", .timeLimit(.minutes(1)))
    func cancellationFinalizesBeforeReturning() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            defer { signal.finish() }
            try await AgentModelRequestAccounting.run(ledger: ledger, configuration: .default, onEvent: { _ in }) { _ in
                signal.yield(()); signal.finish()
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { task.cancel() }
        var iterator = started.makeAsyncIterator()
        guard await iterator.next() != nil else {
            try await task.value
            Issue.record("Accounting finished without entering the transport operation")
            return
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try ledger.summary() == .init(attempts: 1, unfinished: 0, unknownUsage: 1, reportedTokens: 0))
    }

    @MainActor @Test("落盘失败时传输操作不得启动")
    func storageFailurePreventsTransport() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let file = ledger.directory.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: file)
        let blocked = AgentModelRequestLedger(directory: file, ownerID: ledger.ownerID)
        var called = false
        await #expect(throws: (any Error).self) {
            try await AgentModelRequestAccounting.run(ledger: blocked, configuration: .default, onEvent: { _ in }) { _ in
                called = true
            }
        }
        #expect(!called)
    }

    @Test("系统路径别名规范化后仍拒绝账本目录或数据库的符号链接")
    func storageSymlinksAreRejected() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let real = ledger.directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = ledger.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let unsafe = AgentModelRequestLedger(directory: alias, ownerID: UUID())
        #expect(throws: AgentModelRequestLedger.Failure.unsafeStorage) {
            try unsafe.begin(id: UUID(), providerID: "fixture", modelID: "fixture")
        }
        let target = ledger.directory.appendingPathComponent("untouched")
        let original = Data("not a database".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: ledger.databaseURL, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try ledger.begin(id: UUID(), providerID: "fixture", modelID: "fixture")
        }
        #expect(try Data(contentsOf: target) == original)
    }
}
