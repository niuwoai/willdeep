import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Daemon 终态宿主交付", .serialized)
struct AgentDaemonTerminalHandoffTests {
    @MainActor private struct Fixture {
        let session: AgentSession
        let receipt: AgentDaemonStartReceipt
        let app: AppState
        var journal: AgentDaemonStartJournal { app.agentJobRegistry.daemonStartJournal }
        func cleanup() {
            AgentKernelEventStore.flushPendingWrites(for: [session.id])
            for suffix in ["json", "terminal", "stop", "delivered"] {
                let url = journal.directory.appendingPathComponent("\(receipt.id.uuidString).\(suffix)")
                if FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { Issue.record("Receipt fixture cleanup failed: \(error)") }
                }
            }
            AgentKernelEventStore.deleteAsync(runtimeID: session.id)
            AgentKernelEventStore.flushPendingWrites(for: [session.id])
        }
    }

    private func fixture(publishes: Bool = true, status: String = "failed", code: Int32? = 17,
        persists: Bool = true) throws -> Fixture {
        var session = AgentSession()
        // No real model or network execution is permitted by this fixture.
        session.archivedAt = Date()
        let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: persists),
            loadSessionCatalog: false)
        app.agentSessions = [session]
        let created = Date().addingTimeInterval(-240)
        let receipt = AgentDaemonStartReceipt(id: UUID(), runtimeID: session.id, turnID: UUID(),
            remoteRuntimeID: UUID(), endpointFingerprint: String(repeating: "a", count: 64),
            workspaceFingerprint: String(repeating: "b", count: 64), instanceID: String(repeating: "c", count: 32),
            requestID: UUID().uuidString.lowercased(), executor: .codexCLI,
            createdAt: created, deadline: created.addingTimeInterval(60), publishesCompletion: publishes)
        let f = Fixture(session: session, receipt: receipt, app: app)
        try f.journal.prepare(receipt)
        try f.journal.finish(receipt, exitCode: code, disposition: status,
            finishedAt: created.addingTimeInterval(20), publishesCompletion: publishes)
        return f
    }

    @Test("终态后事件前崩溃，恢复只交付本地结果且不重新判定超时")
    func restartBetweenTerminalAndEvent() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var backends = 0
        await f.app.restoreDaemonStartReceipts(descriptors: [], backendFactory: { descriptor in
            backends += 1
            return DaemonRuntimeBackend(descriptor: descriptor)
        })
        let job = try #require(f.app.agentJobRegistry.job(id: f.receipt.id))
        #expect(job.status == .failed && job.exitCode == 17 && job.duration == 20)
        #expect(job.pid == -1 && job.workingDirectoryPath == nil)
        #expect(f.app.agentJobRegistry.output(id: job.id).contains(L10n.JobReceipt.outputGap))
        #expect(backends == 0)
        let events = f.app.agentRuntimeKernel.events.filter { $0.runtimeID == f.session.id }
        #expect(events.count == 1 && events.first?.resolvedDedupeScope == .journal)
        #expect(try f.journal.deliveries(runtimeID: f.session.id).isEmpty)
        #expect(f.app.runtime(for: f.session.id)?.requestTask == nil)
        await f.app.restoreDaemonStartReceipts(descriptors: [])
        #expect(f.app.agentRuntimeKernel.events.filter { $0.runtimeID == f.session.id }.count == 1)
        #expect(AgentKernelEventStore.loadAll().filter { $0.runtimeID == f.session.id }.count == 1)
    }

    @Test("事件已处理但 ACK 前崩溃，跨 kernel 重载不新增事件或复活模型交付")
    func restartAfterEventBeforeAcknowledgement() async throws {
        let f = try fixture(status: "completed", code: 0); defer { f.cleanup() }
        let delivery = try #require(try f.journal.delivery(id: f.receipt.id))
        let job = try f.app.agentJobRegistry.restoreDaemonTerminal(delivery)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        #expect(f.app.publishBackgroundJobKernelEvent(job, runtime: runtime, requiresDurableHandoff: true))
        let events = f.app.agentRuntimeKernel.consumePendingModelEvents(for: f.session.id)
        let event = try #require(events.first)
        f.app.agentRuntimeKernel.acknowledge([event.id])
        #expect(f.app.agentRuntimeKernel.confirmEventPersistenceForHandoff(event))
        let reloaded = AgentRuntimeKernel(loadPersisted: true)
        let restoredApp = AppState(runtimeKernel: reloaded, loadSessionCatalog: false)
        restoredApp.agentSessions = [f.session]
        await restoredApp.restoreDaemonStartReceipts(descriptors: [])
        let restored = reloaded.events.filter { $0.runtimeID == f.session.id }
        #expect(restored.count == 1 && restored.first?.id == event.id)
        #expect(restored.first?.resolvedModelDeliveryState == .handled)
        #expect(reloaded.consumePendingModelEvents(for: f.session.id).isEmpty)
        #expect(try f.journal.deliveries(runtimeID: f.session.id).isEmpty)
    }

    @Test("前台或停止后的终态恢复不自动唤醒", arguments: ["completed", "killed", "timedOut", "launchFailed"])
    func suppressedTerminalsStaySuppressed(status: String) async throws {
        let f = try fixture(publishes: false, status: status, code: status == "launchFailed" ? nil : 0)
        defer { f.cleanup() }
        await f.app.restoreDaemonStartReceipts(descriptors: [])
        #expect(f.app.agentJobRegistry.job(id: f.receipt.id)?.status.rawValue == status)
        #expect(f.app.agentRuntimeKernel.events.filter { $0.runtimeID == f.session.id }.isEmpty)
        #expect(f.app.agentJobRegistry.pendingCompletionCount(forRuntime: f.session.id) == 0)
        #expect(try f.journal.deliveries(runtimeID: f.session.id).count == 1)
    }

    @Test("事件队列写盘失败不 ACK，修复存储后重试仍只有一个事件")
    func failedEventWriteRetainsReceipt() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = AgentKernelEventStore.fileURL(for: f.session.id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let delivery = try #require(try f.journal.delivery(id: f.receipt.id))
        let job = try f.app.agentJobRegistry.restoreDaemonTerminal(delivery)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        f.app.deliverDaemonTerminalIfNeeded(job, runtime: runtime)
        #expect(try f.journal.delivery(id: f.receipt.id) != nil)
        #expect(runtime.errorMessage == L10n.JobReceipt.recoveryUnavailable)
        try FileManager.default.removeItem(at: target)
        f.app.deliverDaemonTerminalIfNeeded(job, runtime: runtime)
        #expect(try f.journal.delivery(id: f.receipt.id) == nil)
        #expect(f.app.agentRuntimeKernel.events.filter { $0.runtimeID == f.session.id }.count == 1)
    }

    @Test("内存 kernel 不得冒充持久交付")
    func ephemeralKernelCannotAcknowledge() async throws {
        let f = try fixture(persists: false); defer { f.cleanup() }
        await f.app.restoreDaemonStartReceipts(descriptors: [])
        #expect(try f.journal.delivery(id: f.receipt.id) != nil)
    }
}
