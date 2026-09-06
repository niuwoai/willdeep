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
        persists: Bool = true, independent: Bool = false) throws -> Fixture {
        var session = AgentSession()
        // No real model or network execution is permitted by this fixture.
        session.archivedAt = Date()
        let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: persists),
            loadSessionCatalog: false)
        app.agentSessions = [session]
        let created = Date().addingTimeInterval(-240)
        var receipt = AgentDaemonStartReceipt(id: UUID(), runtimeID: session.id, turnID: UUID(),
            remoteRuntimeID: UUID(), endpointFingerprint: String(repeating: "a", count: 64),
            workspaceFingerprint: String(repeating: "b", count: 64), instanceID: String(repeating: "c", count: 32),
            requestID: UUID().uuidString.lowercased(), executor: .codexCLI,
            createdAt: created, deadline: created.addingTimeInterval(60), publishesCompletion: publishes)
        if independent {
            receipt.lifetime = .persistent
            receipt.survivesTurnStop = true
        }
        let f = Fixture(session: session, receipt: receipt, app: app)
        try f.journal.prepare(receipt)
        try f.journal.finish(receipt, exitCode: code, disposition: status,
            finishedAt: created.addingTimeInterval(20), publishesCompletion: publishes)
        return f
    }

    private func acceptIntoKernel(_ f: Fixture) throws -> AgentKernelEvent {
        let delivery = try #require(try f.journal.delivery(id: f.receipt.id))
        let job = try f.app.agentJobRegistry.restoreDaemonTerminal(delivery)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        #expect(f.app.publishBackgroundJobKernelEvent(job, runtime: runtime, requiresDurableHandoff: true))
        try f.journal.acknowledge(delivery)
        #expect(try f.journal.delivery(id: f.receipt.id) == nil)
        return try #require(f.app.agentRuntimeKernel.events.first { $0.metadata["resource_id"] == f.receipt.id.uuidString })
    }

    private func denyProviderNetwork(_ app: AppState) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        // No registered handler: any unexpected request fails locally.
        let session = URLSession(configuration: configuration)
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://kernel-stop.invalid/v1",
            model: "fixture", apiKey: "test-placeholder"), session)
        return session
    }

    @Test("真实 Stop 撤销已接收结果，不把它记成模型消费")
    func stopResolvesAcceptedResultAtSource() throws {
        let f = try fixture(); defer { f.cleanup(); AgentSessionStore.delete(id: f.session.id) }
        let original = try acceptIntoKernel(f)
        let runtime = try #require(f.app.runtime(for: f.session.id))
        runtime.activeTurnID = f.receipt.turnID
        runtime.isResponding = true
        defer { runtime.isResponding = false; runtime.requestTask?.cancel() }
        f.app.stopAgentResponse(for: runtime)
        let event = try #require(f.app.agentRuntimeKernel.events.first { $0.id == original.id })
        #expect(event.resolutionActor == .host && event.resolutionOutcome == .resolvedAtSource)
        #expect(!event.hasOutstandingDurableDelivery && event.acknowledgedAt == nil)
    }

    @Test("队列接收 ACK 后停止并重载，不复活 pending 或 leased 结果", arguments: [false, true])
    func acknowledgedResultRespectsStopAfterReload(leased: Bool) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let original = try acceptIntoKernel(f)
        if leased { _ = f.app.agentRuntimeKernel.consumePendingModelEvents(for: f.session.id, leaseID: UUID()) }
        #expect(f.app.agentJobRegistry.revokeTurn(runtimeID: f.session.id, turnID: try #require(f.receipt.turnID)))
        #expect(AgentKernelEventStore.flushPendingWrites(for: [f.session.id]).isEmpty)
        let app = AppState(runtimeKernel: AgentRuntimeKernel(), loadSessionCatalog: false)
        let network = denyProviderNetwork(app)
        defer { network.invalidateAndCancel() }
        app.agentSessions = [f.session]
        let runtime = try #require(app.runtime(for: f.session.id))
        defer { runtime.requestTask?.cancel() }
        runtime.session.archivedAt = nil
        // The real automatic wake entry must refuse the old event before
        // selecting credentials or starting a provider request.
        app.resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        #expect(runtime.requestTask == nil && !runtime.isResponding)
        #expect(app.consumeAdmittedKernelEvents(for: runtime, leaseID: UUID()).isEmpty)
        let retained = try #require(app.agentRuntimeKernel.events.first { $0.id == original.id })
        #expect(retained.payload == original.payload)
        #expect(retained.resolutionActor == .host && retained.resolutionOutcome == .resolvedAtSource)
        #expect(!retained.hasOutstandingDurableDelivery && retained.acknowledgedAt == nil)
    }

    @Test("已 ACK 独立任务不被 owner 停止抑制")
    func acceptedIndependentResultRemainsDeliverable() throws {
        let f = try fixture(independent: true); defer { f.cleanup() }
        let original = try acceptIntoKernel(f)
        #expect(f.app.agentJobRegistry.revokeTurn(runtimeID: f.session.id, turnID: try #require(f.receipt.turnID)))
        let runtime = try #require(f.app.runtime(for: f.session.id))
        let events = f.app.consumeAdmittedKernelEvents(for: runtime, leaseID: UUID())
        #expect(events.map(\.id) == [original.id])
    }

    @Test("已接管事件的回执损坏或缺失时不唤醒、不消费、不丢弃", arguments: [false, true])
    func unreadableOwnershipDefersAcceptedEvent(missing: Bool) throws {
        let f = try fixture(); defer { f.cleanup() }
        let network = denyProviderNetwork(f.app)
        defer { network.invalidateAndCancel() }
        f.app.agentJobRegistry.onJobFinished = nil
        _ = f.app.agentJobRegistry.registerManagedExecutor(id: f.receipt.id, executor: .codexCLI,
            displayCommand: "fixture", workingDirectory: FileManager.default.temporaryDirectory,
            runtimeID: f.session.id, turnID: f.receipt.turnID, timeoutSeconds: nil,
            publishesCompletion: true, remoteRuntimeID: f.receipt.remoteRuntimeID,
            requiresExitReceipt: true, cancellation: {})
        f.app.agentJobRegistry.finishManagedExecutor(id: f.receipt.id, status: .failed, exitCode: 17, exitConfirmed: true)
        #expect(f.app.agentJobRegistry.pendingCompletionCount(forRuntime: f.session.id) == 1)
        let original = try acceptIntoKernel(f)
        let path = f.journal.directory.appendingPathComponent("\(f.receipt.id.uuidString).json")
        let saved = try Data(contentsOf: path)
        if missing { try FileManager.default.removeItem(at: path) }
        else { try Data("corrupt fixture".utf8).write(to: path) }
        defer {
            do { try saved.write(to: path, options: .atomic) }
            catch { Issue.record("Could not restore receipt fixture: \(error)") }
        }
        let runtime = try #require(f.app.runtime(for: f.session.id))
        defer { runtime.requestTask?.cancel() }
        runtime.session.archivedAt = nil
        f.app.resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        #expect(runtime.requestTask == nil && !runtime.isResponding)
        #expect(f.app.agentJobRegistry.pendingCompletionCount(forRuntime: f.session.id) == 0)
        #expect(f.app.consumeAdmittedKernelEvents(for: runtime, leaseID: UUID()).isEmpty)
        #expect(f.app.agentRuntimeKernel.events.first { $0.id == original.id }?.hasOutstandingDurableDelivery == true)
        #expect(runtime.errorMessage == L10n.JobReceipt.recoveryUnavailable)
        try saved.write(to: path, options: .atomic)
        #expect(f.app.consumeAdmittedKernelEvents(for: runtime, leaseID: UUID()).map(\.id) == [original.id])
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
