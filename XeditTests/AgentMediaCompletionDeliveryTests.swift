import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite(.serialized)
struct AgentMediaCompletionDeliveryTests {
    @MainActor private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let app: AppState
        let runtime: AgentRuntime
        let token: String
        let session: URLSession

        var store: AgentMediaCompletionStore { app.agentMediaTaskRegistry.completionStore }
        var kernel: AgentRuntimeKernel { app.agentRuntimeKernel }

        func terminal() -> AgentMediaTask {
            app.agentMediaTaskRegistry.create(provider: .local, kind: .imageGeneration,
                title: "fixture", runtimeID: runtime.id, ownerTurnID: runtime.activeTurnID, status: .succeeded)
        }

        func cleanup() {
            app.agentMediaTaskPoller.stop()
            app.stopAgentResponse(for: runtime)
            app.dispatchDecisionResumptionTask?.cancel()
            session.invalidateAndCancel()
            GoalLoopURLProtocol.remove(token)
            kernel.removeEvents(for: runtime.id)
            _ = AgentKernelEventStore.flushPendingWrites(for: [runtime.id])
            AgentSessionStore.delete(id: runtime.id)
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Media fixture cleanup failed: \(error)") }
        }
    }

    private func fixture(persistsEvents: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "media-handoff-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let media = AgentMediaTaskRegistry(fileURL: root.appendingPathComponent("tasks.json"))
        let jobs = AgentJobRegistry(daemonStartDirectory: root.appendingPathComponent("owners", isDirectory: true))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: persistsEvents),
            backgroundJobRegistry: jobs, mediaTaskRegistry: media,
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        app.agentMediaTaskPoller.stop()
        // Tests explicitly choose each crash boundary before invoking handoff.
        media.onTaskFinished = nil
        let created = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: created.id))
        runtime.activeTurnID = UUID()
        runtime.isCompressingContext = true
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalLoopURLProtocol.self]
        configuration.httpAdditionalHeaders = [GoalLoopURLProtocol.tokenHeader: token]
        let session = URLSession(configuration: configuration)
        GoalLoopURLProtocol.install(token) { _ in throw URLError(.cancelled) }
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai",
            baseURL: "https://media-handoff.invalid/v1", model: "fixture", apiKey: "test-placeholder"), session)
        return Fixture(root: root, defaults: defaults, suite: suite, app: app,
            runtime: runtime, token: token, session: session)
    }

    @Test("内核持久化及生产者 ACK 后才能消费，重复交接只产生一个事件")
    func durableHandoffAndConsumption() throws {
        let f = try fixture(); defer { f.cleanup() }
        let task = f.terminal()
        f.app.deliverMediaCompletion(task)
        f.app.deliverMediaCompletion(task)
        #expect(try f.store.delivery(id: task.id)?.handedOff == true)
        #expect(f.kernel.events.count == 1)
        #expect(f.kernel.events.first?.hasOutstandingDurableDelivery == true)
        let lease = UUID()
        let events = f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: lease)
        #expect(events.count == 1)
        f.kernel.acknowledge(events.map(\.id), leaseID: lease)
        f.app.deliverMediaCompletion(task)
        #expect(try f.store.delivery(id: task.id)?.settled == true)
        #expect(f.kernel.events.count == 1)
        #expect(f.runtime.requestTask == nil)
    }

    @Test("只有内核持久记录而生产者未 ACK 时禁止消费")
    func publicationBeforeProducerAcknowledgement() throws {
        let f = try fixture(); defer { f.cleanup() }
        let task = f.terminal()
        let event = try #require(f.app.publishMediaTaskKernelEvent(task,
            runtime: f.runtime, requiresDurableHandoff: true))
        #expect(f.app.reconcileRevokedKernelDeliveries(for: f.runtime).contains(event.id))
        #expect(f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: UUID()).isEmpty)
        #expect(try f.store.delivery(id: task.id)?.handedOff == false)
        f.app.deliverMediaCompletion(task)
        #expect(f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: UUID()).count == 1)
    }

    @Test("交接确认损坏时空闲会话不唤醒，修复后复用已持久化事件")
    func corruptAcknowledgementDoesNotWake() throws {
        let f = try fixture(); defer { f.cleanup() }
        let task = f.terminal()
        let published = try #require(f.app.publishMediaTaskKernelEvent(task,
            runtime: f.runtime, requiresDurableHandoff: true))
        let ack = f.store.directory.appendingPathComponent("\(task.id.uuidString).ack")
        try FileManager.default.createDirectory(at: ack, withIntermediateDirectories: false)
        f.runtime.isCompressingContext = false
        f.app.deliverMediaCompletion(task)
        let id = try #require(f.kernel.events.first?.id)
        #expect(id == published.id)
        f.app.resumeAgentLoopForPendingBackgroundCompletions(for: f.runtime)
        #expect(f.runtime.requestTask == nil && !f.runtime.isResponding)
        #expect(f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: UUID()).isEmpty)
        try FileManager.default.removeItem(at: ack)
        f.runtime.isCompressingContext = true
        f.app.deliverMediaCompletion(task)
        #expect(f.kernel.events.map(\.id) == [id])
        #expect(try f.store.delivery(id: task.id)?.handedOff == true)
    }

    @Test("真实 Stop 在交接后撤销原轮次，新轮次不能复活晚到媒体结果")
    func stopAfterHandoffCannotBeBypassedByNewTurn() throws {
        let f = try fixture(); defer { f.cleanup() }
        let task = f.terminal()
        f.app.deliverMediaCompletion(task)
        f.app.stopAgentResponse(for: f.runtime)
        f.runtime.activeTurnID = UUID()
        f.app.deliverMediaCompletion(task)
        #expect(try f.store.delivery(id: task.id)?.settled == true)
        #expect(f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: UUID()).isEmpty)
        #expect(f.kernel.events.allSatisfy { $0.resolvedModelDeliveryState == .handled })
        #expect(f.runtime.requestTask == nil && !f.runtime.isResponding)
    }

    @Test("不持久化的内核不能授权生产者 ACK")
    func nonpersistentKernelCannotTakeOwnership() throws {
        let f = try fixture(persistsEvents: false); defer { f.cleanup() }
        let task = f.terminal()
        f.app.deliverMediaCompletion(task)
        let delivery = try #require(try f.store.delivery(id: task.id))
        #expect(!delivery.handedOff && !delivery.settled)
        #expect(f.app.consumeAdmittedKernelEvents(for: f.runtime, leaseID: UUID()).isEmpty)
    }
}
