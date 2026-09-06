import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Daemon 启动恢复持久化", .serialized)
struct AgentDaemonStartJournalTests {
    private func receipt(id: UUID = UUID(), runtimeID: UUID = UUID(), turnID: UUID = UUID()) -> AgentDaemonStartReceipt {
        let now = Date()
        return .init(id: id, runtimeID: runtimeID, turnID: turnID, remoteRuntimeID: UUID(),
            endpointFingerprint: AgentDaemonStartReceipt.fingerprint("https://fixture.invalid"),
            workspaceFingerprint: AgentDaemonStartReceipt.fingerprint("/workspace"),
            instanceID: String(repeating: "a", count: 32), requestID: UUID().uuidString.lowercased(),
            executor: .codexCLI, createdAt: now, deadline: now.addingTimeInterval(60), publishesCompletion: true)
    }

    private func withJournal(_ body: (AgentDaemonStartJournal) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-journal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Journal fixture cleanup failed: \(error)") }
        }
        try body(.init(directory: directory))
    }

    @Test("轮次撤销跨重载覆盖未完成和已完成回执，隔离兄弟及显式独立任务")
    func revokedPreparedReceiptsRemainStoppedAfterReload() throws {
        try withJournal { journal in
            let runtime = UUID(), turn = UUID()
            let pending = receipt(runtimeID: runtime, turnID: turn)
            let terminal = receipt(runtimeID: runtime, turnID: turn)
            let sibling = receipt(runtimeID: runtime)
            let other = receipt(turnID: turn)
            var independent = receipt(runtimeID: runtime, turnID: turn)
            independent.lifetime = .persistent
            independent.survivesTurnStop = true
            for record in [pending, terminal, sibling, other, independent] { try journal.prepare(record) }
            try journal.finish(terminal, exitCode: 0, disposition: "completed",
                finishedAt: Date(), publishesCompletion: true)
            try journal.revokeTurn(runtimeID: runtime, turnID: turn)
            try journal.revokeTurn(runtimeID: runtime, turnID: turn)
            let reloaded = AgentDaemonStartJournal(directory: journal.directory)
            let restored = try reloaded.pending()
            #expect(restored.first { $0.receipt.id == pending.id }?.cancellationRequested == true)
            for record in [sibling, other, independent] {
                #expect(restored.first { $0.receipt.id == record.id }?.cancellationRequested == false)
            }
            let delivery = try #require(try reloaded.delivery(id: terminal.id))
            #expect(delivery.cancellationRequested)
            #expect(delivery.terminal.disposition == "completed" && delivery.terminal.exitCode == 0)
            #expect(try reloaded.deliveries() == [delivery])
            var laterIndependent = receipt(runtimeID: runtime, turnID: turn)
            laterIndependent.lifetime = .persistent
            laterIndependent.survivesTurnStop = true
            try reloaded.prepare(laterIndependent)
            #expect(try FileManager.default.contentsOfDirectory(atPath: journal.directory.path)
                .filter { $0.hasSuffix(".revoked") }.count == 1)
        }
    }

    @Test("停止写盘失败必须报告失败，但本进程仍拒绝原轮次新动作")
    func failedRevocationKeepsInMemoryAdmissionClosed() throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            let turn = try #require(record.turnID)
            let stop = journal.revocationURL(runtimeID: record.runtimeID, turnID: turn)
            try FileManager.default.createDirectory(at: stop, withIntermediateDirectories: false)
            let registry = AgentJobRegistry(daemonStartDirectory: journal.directory)
            #expect(!registry.revokeTurn(runtimeID: record.runtimeID, turnID: turn))
            #expect(throws: CancellationError.self) {
                try registry.checkTurnAdmission(runtimeID: record.runtimeID, turnID: turn)
            }
        }
    }

    @Test("持久轮次撤销无需扫描历史，重启后拒绝迟到准备与动作")
    func ownerMarkerRejectsLatePreparationWithoutScanningHistory() throws {
        try withJournal { journal in
            let runtime = UUID(), turn = UUID()
            // Unrelated damaged history must not delay or prevent this Stop.
            try Data("unrelated damaged fixture".utf8).write(to:
                journal.directory.appendingPathComponent("\(UUID().uuidString).json"))
            try journal.revokeTurn(runtimeID: runtime, turnID: turn)
            let reloaded = AgentDaemonStartJournal(directory: journal.directory)
            #expect(try reloaded.isTurnRevoked(runtimeID: runtime, turnID: turn))
            #expect(throws: CancellationError.self) {
                try reloaded.prepare(receipt(runtimeID: runtime, turnID: turn))
            }
            let registry = AgentJobRegistry(daemonStartDirectory: journal.directory)
            #expect(throws: CancellationError.self) {
                try registry.checkTurnAdmission(runtimeID: runtime, turnID: turn)
            }
            try registry.checkTurnAdmission(runtimeID: runtime, turnID: UUID())
        }
    }

    @Test("损坏、链接或归属不匹配的撤销标记不能被当作允许执行", arguments: ["corrupt", "symlink", "wrongOwner"])
    func invalidOwnerMarkerFailsClosed(kind: String) throws {
        try withJournal { journal in
            let record = receipt(), turn = try #require(record.turnID)
            try journal.prepare(record)
            let marker = journal.revocationURL(runtimeID: record.runtimeID, turnID: turn)
            if kind == "corrupt" {
                try Data("incomplete".utf8).write(to: marker)
            } else {
                let other = UUID()
                try journal.revokeTurn(runtimeID: other, turnID: turn)
                let source = journal.revocationURL(runtimeID: other, turnID: turn)
                if kind == "symlink" {
                    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: source)
                } else {
                    try FileManager.default.copyItem(at: source, to: marker)
                }
            }
            #expect(throws: AgentDaemonStartJournalError.self) {
                try journal.isTurnRevoked(runtimeID: record.runtimeID, turnID: turn)
            }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.pending() }
            let registry = AgentJobRegistry(daemonStartDirectory: journal.directory)
            #expect(throws: CancellationError.self) {
                try registry.checkTurnAdmission(runtimeID: record.runtimeID, turnID: turn)
            }
        }
    }

    @Test("准备、停止、终态回执重载保持一致，冲突不能覆盖")
    func immutableReceiptsPreserveCancellationAndTerminal() throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            try journal.prepare(record)
            try journal.requestCancellation(record)
            try journal.requestCancellation(record)
            let reloaded = AgentDaemonStartJournal(directory: journal.directory)
            #expect(try reloaded.pending() == [.init(receipt: record, cancellationRequested: true)])
            try journal.finish(record, exitCode: 143)
            try journal.finish(record, exitCode: 143)
            #expect(try reloaded.pending().isEmpty)
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.finish(record, exitCode: 0) }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.finish(record, exitCode: nil) }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.prepare(receipt(id: record.id)) }
        }
    }

    @Test("回执不保存执行输入、端点明文或工作区路径")
    func receiptContainsOnlyRecoveryMetadata() throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            let data = try Data(contentsOf: journal.directory.appendingPathComponent("\(record.id.uuidString).json"))
            let envelopeObject = try JSONSerialization.jsonObject(with: data)
            let envelope = try #require(envelopeObject as? [String: Any])
            let encoded = try #require(envelope["payload"] as? String)
            let payload = try #require(Data(base64Encoded: encoded))
            let decoded = String(decoding: payload, as: UTF8.self)
            #expect(!decoded.contains("fixture.invalid") && !decoded.contains("/workspace"))
            let object = try JSONSerialization.jsonObject(with: payload)
            let fields = try #require(object as? [String: Any])
            #expect(Set(fields.keys) == ["id", "runtimeID", "turnID", "remoteRuntimeID", "endpointFingerprint",
                "workspaceFingerprint", "instanceID", "requestID", "executor", "createdAt", "deadline", "publishesCompletion"])
        }
    }

    @Test("终态与宿主交付分离，重试保留首次完成时间")
    func terminalRequiresSeparateAcknowledgement() throws {
        try withJournal { journal in
            let record = receipt(), finished = Date()
            try journal.prepare(record)
            try journal.finish(record, exitCode: 0, disposition: "timedOut", finishedAt: finished,
                publishesCompletion: true)
            try journal.finish(record, exitCode: 0, disposition: "timedOut", finishedAt: finished.addingTimeInterval(40),
                publishesCompletion: true)
            #expect(try journal.pending().isEmpty)
            let delivery = try #require(try journal.delivery(id: record.id))
            #expect(delivery.terminal.finishedAt == finished)
            #expect(delivery.terminal.disposition == "timedOut")
            #expect(try journal.deliveries() == [delivery])
            try journal.acknowledge(delivery)
            try journal.acknowledge(delivery)
            #expect(try journal.deliveries().isEmpty)
            #expect(try journal.delivery(id: record.id) == nil)
            #expect(throws: AgentDaemonStartJournalError.self) {
                try journal.finish(record, exitCode: 0, disposition: "completed", finishedAt: finished,
                    publishesCompletion: true)
            }
        }
    }

    @Test("损坏或链接交付 ACK 不被当成已经交付", arguments: [false, true])
    func invalidAcknowledgementRetainsEvidence(link: Bool) throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            try journal.finish(record, exitCode: 1, disposition: "failed", finishedAt: Date(), publishesCompletion: true)
            let terminalURL = journal.directory.appendingPathComponent("\(record.id.uuidString).terminal")
            let original = try Data(contentsOf: terminalURL)
            let ack = journal.directory.appendingPathComponent("\(record.id.uuidString).delivered")
            if link {
                try FileManager.default.createSymbolicLink(at: ack, withDestinationURL: terminalURL)
            } else {
                try Data("interrupted".utf8).write(to: ack)
            }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.deliveries() }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.delivery(id: record.id) }
            #expect(try Data(contentsOf: terminalURL) == original)
        }
    }

    @Test("损坏终态不当成任务已结束，也不允许新启动覆盖")
    func corruptTerminalRetainsEvidenceAndRejectsPrepare() throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            let terminal = journal.directory.appendingPathComponent("\(record.id.uuidString).terminal")
            let corrupt = Data("interrupted write".utf8)
            try corrupt.write(to: terminal)
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.pending() }
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.prepare(receipt(runtimeID: record.runtimeID)) }
            let unrelated = receipt()
            try journal.prepare(unrelated)
            #expect(try journal.pending(runtimeID: unrelated.runtimeID).map(\.receipt) == [unrelated])
            #expect(try Data(contentsOf: terminal) == corrupt)
        }
    }

    @Test("准备和停止回执符号链接被拒绝，不读取外部内容", arguments: ["json", "stop", "terminal"])
    func symlinkReceiptsAreRejected(suffix: String) throws {
        try withJournal { journal in
            let record = receipt()
            try journal.prepare(record)
            let target = journal.directory.appendingPathComponent("outside-fixture")
            try Data("must remain unchanged".utf8).write(to: target)
            let link = journal.directory.appendingPathComponent("\(record.id.uuidString).\(suffix)")
            if suffix == "json" { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: AgentDaemonStartJournalError.self) { try journal.pending() }
            #expect(try String(contentsOf: target, encoding: .utf8) == "must remain unchanged")
        }
    }

    @Test("会话过滤与中断临时文件不制造新任务")
    func ownerIsolationAndUnpublishedTemporaryFile() throws {
        try withJournal { journal in
            let first = receipt(), second = receipt()
            try journal.prepare(first)
            try journal.prepare(second)
            try Data("partial".utf8).write(to: journal.directory.appendingPathComponent(".receipt-interrupted.tmp"))
            #expect(try journal.pending(runtimeID: first.runtimeID).map(\.receipt) == [first])
            #expect(try journal.pending(runtimeID: UUID()).isEmpty)
            #expect(try journal.pending().count == 2)
        }
    }

    @Test("断链存储目录不是空恢复队列")
    func danglingDirectoryIsNotMissingHistory() throws {
        try withJournal { journal in
            let link = journal.directory.appendingPathComponent("recovery-link")
            let missing = journal.directory.appendingPathComponent("missing-target")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
            let unsafe = AgentDaemonStartJournal(directory: link)
            #expect(throws: AgentDaemonStartJournalError.self) { try unsafe.pending() }
            #expect(throws: AgentDaemonStartJournalError.self) { try unsafe.prepare(receipt()) }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    @Test("停止回执写失败保留可见错误，不阻止已授权的取消请求")
    func failedStopReceiptRemainsVisible() {
        let registry = AgentJobRegistry()
        let id = UUID(), runtime = UUID()
        let calls = JournalCancellationCounter()
        _ = registry.registerManagedExecutor(id: id, executor: .codexCLI, displayCommand: "fixture",
            workingDirectory: FileManager.default.temporaryDirectory, runtimeID: runtime,
            timeoutSeconds: nil, publishesCompletion: false, requiresExitReceipt: true,
            beforeCancellation: { throw AgentDaemonStartJournalError.unsafeStorage },
            cancellation: { calls.increment() })
        #expect(registry.kill(id: id))
        #expect(calls.count == 1)
        #expect(registry.job(id: id)?.monitoringFailure != nil)
        #expect(registry.job(id: id)?.isAlive == true)
        registry.finishManagedExecutor(id: id, status: .killed, exitCode: 143, exitConfirmed: true)
    }
}

private nonisolated final class JournalCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
