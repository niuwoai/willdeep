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
            if let turnID = receipt.turnID {
                let marker = journal.revocationURL(runtimeID: session.id, turnID: turnID)
                if FileManager.default.fileExists(atPath: marker.path) {
                    do { try FileManager.default.removeItem(at: marker) }
                    catch { Issue.record("Owner fixture cleanup failed: \(error)") }
                }
            }
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

    @Test("原轮次已撤销时不补交，即使临时停止标记已被收尾清空")
    func revokedOwnerCannotBeReactivatedByDeferredDelivery() async throws {
        let f = try fixture(status: "completed", code: 0)
        defer { f.cleanup() }
        let delivery = try #require(try f.journal.delivery(id: f.receipt.id))
        _ = try f.app.agentJobRegistry.restoreDaemonTerminal(delivery)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        runtime.session.archivedAt = nil
        runtime.isResponding = true
        defer { runtime.isResponding = false }
        let turnID = try #require(f.receipt.turnID)
        f.app.agentJobRegistry.revokeTurn(runtimeID: f.session.id, turnID: turnID)
        runtime.userStoppedTurnID = nil
        f.app.agentRuntimeKernel.deferDurableDelivery(for: f.session.id)
        await f.app.retryDeferredDaemonTerminalDeliveries()
        #expect(try f.journal.delivery(id: f.receipt.id) != nil)
        #expect(!f.app.agentRuntimeKernel.events.contains {
            $0.metadata["resource_id"] == f.receipt.id.uuidString
        })
        #expect(runtime.requestTask == nil)
        var retained = f.receipt
        retained.lifetime = .persistent
        retained.survivesTurnStop = true
        #expect(f.app.agentJobRegistry.allowsDaemonTerminalDelivery(retained))
    }

    @Test("终态等待交付时停止，新的 App 注册表恢复不唤醒模型", arguments: [false, true])
    func stoppedTerminalSurvivesRegistryRestart(directCancellation: Bool) async throws {
        let f = try fixture(status: "completed", code: 0)
        defer { f.cleanup() }
        if directCancellation {
            try f.journal.requestCancellation(f.receipt)
        } else {
            // No job has been restored into the registry yet: disk ownership
            // must be sufficient to find a completion awaiting delivery.
            let turn = try #require(f.receipt.turnID)
            #expect(f.app.agentJobRegistry.revokeTurn(runtimeID: f.session.id, turnID: turn))
        }
        let restored = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false), loadSessionCatalog: false)
        restored.agentSessions = [f.session]
        var backendCalls = 0
        await restored.restoreDaemonStartReceipts(descriptors: [], backendFactory: { descriptor in
            backendCalls += 1
            return DaemonRuntimeBackend(descriptor: descriptor)
        })
        #expect(restored.agentJobRegistry.job(id: f.receipt.id)?.status == .completed)
        #expect(restored.agentRuntimeKernel.events.filter { $0.runtimeID == f.session.id }.isEmpty)
        #expect(restored.agentJobRegistry.pendingCompletionCount(forRuntime: f.session.id) == 0)
        #expect(restored.runtime(for: f.session.id)?.requestTask == nil)
        #expect(backendCalls == 0)
        #expect(try f.journal.delivery(id: f.receipt.id)?.cancellationRequested == true)
    }

    @Test("容量满保留回执，模型消费释放空间后自动补交而不重跑任务")
    func capacityDeferredDeliveryRetriesAfterConsumption() async throws {
        let f = try fixture(status: "completed", code: 0)
        defer { f.cleanup() }
        let kernel = f.app.agentRuntimeKernel
        for index in 0..<AgentKernelEventPolicy.maximumEventsPerRuntime {
            let event = kernel.publish(AgentKernelEvent(runtimeID: f.session.id,
                source: .backgroundJob, kind: .backgroundJobCompleted,
                title: "held", payload: "result", dedupeKey: "held-\(index)", dedupeScope: .journal))
            #expect(kernel.confirmEventPersistenceForHandoff(event))
        }
        let delivery = try #require(try f.journal.delivery(id: f.receipt.id))
        let job = try f.app.agentJobRegistry.restoreDaemonTerminal(delivery)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        f.app.deliverDaemonTerminalIfNeeded(job, runtime: runtime)
        #expect(try f.journal.delivery(id: f.receipt.id) != nil)
        #expect(runtime.errorMessage == nil)
        let lease = UUID()
        let consumed = kernel.consumePendingModelEvents(for: f.session.id, limit: 1, leaseID: lease)
        kernel.acknowledge(consumed.map(\.id), leaseID: lease)
        // Exercise the live retry path without permitting a provider request.
        runtime.session.archivedAt = nil
        runtime.isResponding = true
        defer { runtime.isResponding = false }
        await f.app.retryDeferredDaemonTerminalDeliveries()
        #expect(try f.journal.delivery(id: f.receipt.id) == nil)
        #expect(kernel.events.contains {
            $0.metadata["resource_id"] == f.receipt.id.uuidString && $0.hasOutstandingDurableDelivery
        })
        #expect(kernel.events.count == AgentKernelEventPolicy.maximumEventsPerRuntime)
        #expect(runtime.requestTask == nil)
    }
}
