import Foundation
import SQLite3
import Testing
@testable import WillDeep

@Suite("模型请求原子预留", .timeLimit(.minutes(1)))
struct AgentModelRequestAdmissionTests {
    private func fixture() throws -> AgentModelRequestLedger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AgentModelRequestLedger(directory: root, ownerID: UUID())
    }

    private func cleanup(_ ledger: AgentModelRequestLedger) {
        do { try FileManager.default.removeItem(at: ledger.directory) }
        catch { Issue.record("Admission fixture cleanup: \(error)") }
    }

    private func receipt(_ total: Int) -> AgentModelRequestLedger.Receipt {
        .init(outcome: .failed, usage: .init(prompt: total, completion: 0, total: total,
                                          cachedPrompt: nil, cacheWritePrompt: nil, reasoning: 0))
    }

    @Test("并发竞争只允许剩余额度容纳的请求，重开保留预约")
    func concurrentAdmission() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        let admitted = try await withThrowingTaskGroup(of: UUID?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let id = UUID()
                    do {
                        try ledger.begin(id: id, providerID: "test", modelID: "test", reservedTokens: 30)
                        return id
                    } catch AgentModelRequestLedger.Failure.budgetExceeded { return nil }
                }
            }
            var ids: [UUID] = []
            for try await id in group { if let id { ids.append(id) } }
            return ids
        }
        #expect(admitted.count == 3)
        let reopened = AgentModelRequestLedger(directory: ledger.directory, ownerID: ledger.ownerID)
        #expect(try reopened.exposure() == .init(accountedTokens: 0, estimatedTokens: 90, unquantifiedAttempts: 0))
        #expect(try reopened.summary().attempts == 3)
        for id in admitted { try reopened.finish(id: id, receipt: receipt(0)) }
        try reopened.begin(id: UUID(), providerID: "test", modelID: "test", reservedTokens: 100)
    }

    @Test("未知终态不退还预约，实际失败超额成为后续债务")
    func failedAndUnknownReceiptsRetainExposure() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        let unknown = UUID(), failed = UUID()
        try ledger.begin(id: unknown, providerID: "test", modelID: "test", reservedTokens: 40)
        try ledger.finish(id: unknown, receipt: .init(outcome: .cancelled, usage: nil))
        try ledger.begin(id: failed, providerID: "test", modelID: "test", reservedTokens: 50)
        try ledger.finish(id: failed, receipt: receipt(80))
        try ledger.finish(id: failed, receipt: receipt(80))
        #expect(try ledger.exposure() == .init(accountedTokens: 80, estimatedTokens: 40, unquantifiedAttempts: 0))
        #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            try ledger.begin(id: UUID(), providerID: "test", modelID: "test", reservedTokens: 1)
        }
    }

    @Test("旧未知请求和无上限请求不能以零消耗通过有限准入")
    func unknownAttemptsBlockBoundedAdmission() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let id = UUID()
        try ledger.begin(id: id, providerID: "test", modelID: "test")
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            try ledger.begin(id: UUID(), providerID: "test", modelID: "test", reservedTokens: 10)
        }
        try ledger.finish(id: id, receipt: receipt(0))
        #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            try ledger.begin(id: UUID(), providerID: "test", modelID: "test")
        }
        #expect(try ledger.summary().attempts == 1)
    }

    @Test("变更上限使用持久版本且不重置消耗")
    func revisionAndSpendSurviveLimitChanges() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        #expect(try ledger.admissionPolicy() == .init(tokenLimit: nil, revision: 0))
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        let id = UUID()
        try ledger.begin(id: id, providerID: "test", modelID: "test", reservedTokens: 80)
        try ledger.setAdmissionLimit(10, expectedRevision: 1)
        #expect(throws: AgentModelRequestLedger.Failure.stalePolicy) {
            try ledger.setAdmissionLimit(nil, expectedRevision: 1)
        }
        #expect(try ledger.exposure().estimatedTokens == 80)
        #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            try ledger.begin(id: UUID(), providerID: "test", modelID: "test", reservedTokens: 1)
        }
        try ledger.setAdmissionLimit(nil, expectedRevision: 2)
        #expect(try ledger.exposure().estimatedTokens == 80)
        #expect(throws: AgentModelRequestLedger.Failure.invalidReservation) {
            try ledger.setAdmissionLimit(0, expectedRevision: 3)
        }
    }

    @Test("迁移 v1 保留旧回执并让未知请求阻止有限预算")
    func migratesVersionOneWithoutFreeingUnknown() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        var db: OpaquePointer?
        #expect(sqlite3_open(ledger.databaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE requests (id TEXT PRIMARY KEY NOT NULL, provider_id TEXT NOT NULL,
                model_id TEXT NOT NULL, receipt_json TEXT, total_tokens INTEGER,
                created_at TEXT DEFAULT '', updated_at TEXT DEFAULT '');
            INSERT INTO requests (id, provider_id, model_id) VALUES ('legacy', 'test', 'test');
            PRAGMA user_version = 1;
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        #expect(try ledger.summary().attempts == 1)
        #expect(try ledger.exposure().unquantifiedAttempts == 1)
        #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            try ledger.begin(id: UUID(), providerID: "test", modelID: "test", reservedTokens: 1)
        }
    }

    @Test("改名成另一个 owner 的数据库不能获得新额度")
    func copiedOwnerIsRejected() throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        let other = AgentModelRequestLedger(directory: ledger.directory, ownerID: UUID())
        try FileManager.default.copyItem(at: ledger.databaseURL, to: other.databaseURL)
        #expect(throws: AgentModelRequestLedger.Failure.ownerMismatch) { try other.admissionPolicy() }
    }

    @MainActor @Test("准入发生在实际传输回调前，重复请求不会越过余额")
    func accountingPreventsTransport() async throws {
        let ledger = try fixture(); defer { cleanup(ledger) }
        let body = Data(#"{"messages":[],"max_tokens":8}"#.utf8)
        let amount = try #require(AgentModelRequestReservation.tokens(for: body))
        try ledger.setAdmissionLimit(amount, expectedRevision: 0)
        var transports = 0
        try await AgentModelRequestAccounting.run(ledger: ledger, configuration: .default, requestBody: body, onEvent: { _ in }) { _ in
            transports += 1
            let exposure = try ledger.exposure()
            #expect(exposure.estimatedTokens == amount)
        }
        await #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
            try await AgentModelRequestAccounting.run(ledger: ledger, configuration: .default, requestBody: body, onEvent: { _ in }) { _ in
                transports += 1
            }
        }
        #expect(transports == 1)
        #expect(try ledger.summary().unknownUsage == 1)
    }

    @Test("只有明确输出上限和可见文本输入才能生成预留估算")
    func boundedTextReservation() throws {
        for key in ["max_tokens", "max_output_tokens", "max_completion_tokens"] {
            let body = try JSONSerialization.data(withJSONObject: [key: 32, "input": "hello"])
            #expect(AgentModelRequestReservation.tokens(for: body) == body.count + 4_096 + 32)
        }
        let gemini = Data(#"{"generationConfig":{"maxOutputTokens":32},"contents":[]}"#.utf8)
        #expect(AgentModelRequestReservation.tokens(for: gemini) != nil)
        for json in [#"{"max_tokens":true}"#, #"{"max_tokens":-1}"#, #"{"max_tokens":1.5}"#,
                     #"{"input":"hello"}"#, #"{"max_tokens":32,"previous_response_id":"prior"}"#,
                     #"{"max_tokens":32,"content":[{"type":"image"}]}"#,
                     #"{"max_tokens":32,"tools":[{"googleSearch":{}}]}"#,
                     #"{"max_tokens":32,"tools":[{"type":"web_search"}]}"#] {
            #expect(AgentModelRequestReservation.tokens(for: Data(json.utf8)) == nil)
        }
    }
}
