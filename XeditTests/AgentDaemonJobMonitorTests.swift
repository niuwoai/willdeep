import Combine
import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("Daemon 单负责人自动恢复", .serialized, .timeLimit(.minutes(1)))
struct AgentDaemonJobMonitorTests {
    enum FixtureError: Error { case timeout }
    @MainActor private final class State {
        var time = ContinuousClock.now
        var delays: [Duration] = []
        var reads = 0, deletes = 0, activeReads = 0, maxActiveReads = 0
        var sleepStarted = false, streamStarted = false, streamEnded = false, lookupEnded = false
    }
    @MainActor private struct Fixture {
        let registry: AgentJobRegistry
        let id: UUID
        let runtime: UUID
        let monitor: AgentDaemonJobMonitor
        func cleanup() { registry.finishManagedExecutor(id: id, status: .failed, exitCode: -1, exitConfirmed: true) }
        func wait() async throws -> AgentBackgroundJob { try await registry.waitForTerminal(id: id, forRuntime: runtime) }
    }

    private func fixture(duration: Duration = .seconds(300),
        fast: [Duration] = [.zero, .seconds(1)],
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in },
        stream: @escaping AgentDaemonJobMonitor.Stream = { _ in throw URLError(.networkConnectionLost) },
        lookup: @escaping AgentDaemonJobMonitor.Lookup,
        cancel: @escaping AgentDaemonJobMonitor.Cancel = { true }) -> Fixture {
        let registry = AgentJobRegistry(), id = UUID(), runtime = UUID()
        let monitor = AgentDaemonJobMonitor(registry: registry, jobID: id, monitoringDuration: duration,
            fastDelays: fast, now: now, sleep: sleep, stream: stream, lookup: lookup,
            cancel: cancel, describeError: { $0.localizedDescription })
        _ = registry.registerManagedExecutor(id: id, executor: .codexCLI, displayCommand: "monitor fixture",
            workingDirectory: URL(fileURLWithPath: "/workspace"), runtimeID: runtime, timeoutSeconds: nil, publishesCompletion: true,
            requiresExitReceipt: true, cancellation: { Task { @MainActor in monitor.requestCancellation() } })
        monitor.start()
        return Fixture(registry: registry, id: id, runtime: runtime, monitor: monitor)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
        if !condition() { throw FixtureError.timeout }
    }

    @Test("未变化的恢复状态不重复发布，故障清除保持原子转换")
    func recoveryStatePublishesOnlyChanges() {
        let registry = AgentJobRegistry(), id = UUID(), runtime = UUID()
        _ = registry.registerManagedExecutor(id: id, executor: .codexCLI, displayCommand: "recovery state fixture",
            workingDirectory: URL(fileURLWithPath: "/workspace"), runtimeID: runtime,
            timeoutSeconds: nil, publishesCompletion: true, requiresExitReceipt: true, cancellation: {})
        defer { registry.finishManagedExecutor(id: id, status: .failed, exitCode: -1, exitConfirmed: true) }
        var snapshots: [AgentBackgroundJob] = []
        let observation = registry.$jobs.dropFirst().sink { jobs in
            if let job = jobs.first(where: { $0.id == id }) { snapshots.append(job) }
        }
        defer { observation.cancel() }
        for _ in 0..<10 { registry.recordRemoteRecovery(id: id, recovering: false) }
        #expect(snapshots.isEmpty)
        for _ in 0..<10 { registry.recordRemoteRecovery(id: id, recovering: true) }
        #expect(snapshots.count == 1 && snapshots[0].isReconnecting)
        for _ in 0..<10 { registry.recordRemoteRecovery(id: id, recovering: false) }
        #expect(snapshots.count == 2 && !snapshots[1].isReconnecting)
        registry.recordRemoteMonitoringFailure(id: id, detail: "fixture failure")
        snapshots.removeAll()
        for _ in 0..<10 { registry.recordRemoteRecovery(id: id, recovering: false) }
        #expect(snapshots.isEmpty)
        #expect(registry.job(id: id)?.monitoringFailure == "fixture failure")
        for _ in 0..<10 { registry.recordRemoteRecovery(id: id, recovering: true) }
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isReconnecting == true && snapshots.first?.monitoringFailure == nil)
        #expect(registry.pendingCompletionCount(forRuntime: runtime) == 0)
    }

    @Test("短重试耗尽自动转为低频对账，前台仍等待真实退出")
    func slowRecoveryDoesNotBecomeUserFailure() async throws {
        let state = State()
        let f = fixture(now: { state.time }, sleep: { delay in
            state.delays.append(delay)
            state.time = state.time.advanced(by: delay)
        }, lookup: { @MainActor in
            state.reads += 1
            if state.reads < 8 { throw URLError(.cannotConnectToHost) }
            return 0
        })
        defer { f.cleanup() }
        let receipt = try await f.wait()
        #expect(receipt.status == .completed && receipt.exitCode == 0)
        #expect(state.reads == 8)
        #expect(state.delays == [.zero, .seconds(1)] + Array(repeating: .seconds(30), count: 6))
        #expect(receipt.monitoringFailure == nil && !receipt.isReconnecting)
        #expect(f.registry.terminalWaiterCount == 0)
    }

    @Test("停止唤醒正在休眠的唯一负责人，不重复 DELETE")
    func cancellationInterruptsSlowDelay() async throws {
        let state = State()
        let f = fixture(fast: [.zero], sleep: { delay in
            state.delays.append(delay)
            if state.delays.count == 2 {
                state.sleepStarted = true
                try await Task.sleep(for: .seconds(3600))
            }
        }, lookup: { @MainActor in
            state.reads += 1
            if state.reads == 1 { throw URLError(.networkConnectionLost) }
            return state.deletes == 0 ? nil : 143
        }, cancel: { @MainActor in state.deletes += 1; return true })
        defer { f.cleanup() }
        try await eventually { state.sleepStarted }
        #expect(f.registry.job(id: f.id)?.isReconnecting == true)
        #expect(f.registry.job(id: f.id)?.monitoringFailure == nil)
        #expect(f.registry.job(id: f.id)?.needsAttention == false)
        #expect(f.registry.pendingCompletionCount(forRuntime: f.runtime) == 0)
        #expect(f.registry.killForStoppedTurn(id: f.id))
        #expect(!f.registry.killForStoppedTurn(id: f.id))
        let receipt = try await f.wait()
        #expect(receipt.status == .killed && receipt.exitCode == 143)
        #expect(state.reads == 3 && state.deletes == 1)
        #expect(f.registry.pendingCompletionCount(forRuntime: f.runtime) == 0)
    }

    @Test("对账在途遇到 Stop 仍共用一个请求，完成后不再发送取消")
    func cancellationDoesNotForkActiveLookup() async throws {
        let state = State(), release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let f = fixture(lookup: { @MainActor in
            state.reads += 1; state.activeReads += 1
            state.maxActiveReads = max(state.maxActiveReads, state.activeReads)
            defer { state.activeReads -= 1 }
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return 0
        }, cancel: { @MainActor in state.deletes += 1; return true })
        defer { f.cleanup() }
        try await eventually { state.activeReads == 1 }
        #expect(f.registry.killForStoppedTurn(id: f.id))
        #expect(!f.registry.killForStoppedTurn(id: f.id))
        release.continuation.yield(())
        let receipt = try await f.wait()
        #expect(receipt.status == .killed && receipt.exitCode == 0)
        #expect(state.reads == 1 && state.maxActiveReads == 1 && state.deletes == 0)
    }

    @Test("恢复窗口到期保留未知记录，显式重试只重新确认原任务")
    func deadlineRetainsRecordAndAllowsExplicitCleanup() async throws {
        let state = State()
        let f = fixture(duration: .seconds(5), now: { state.time }, sleep: { delay in
            state.delays.append(delay); state.time = state.time.advanced(by: delay)
        }, lookup: { @MainActor in
            state.reads += 1
            if state.reads <= 2 { throw URLError(.cannotConnectToHost) }
            return 143
        })
        defer { f.cleanup() }
        await #expect(throws: AgentJobError.self) { try await f.wait() }
        let unknown = try #require(f.registry.job(id: f.id))
        #expect(unknown.isAlive && unknown.exitCode == nil && unknown.finishedAt == nil)
        #expect(unknown.needsAttention && !unknown.isReconnecting)
        #expect(state.reads == 2 && state.delays == [.zero, .seconds(1), .seconds(4)])
        #expect(f.registry.killForStoppedTurn(id: f.id))
        let receipt = try await f.wait()
        #expect(receipt.status == .killed && receipt.exitCode == 143)
        #expect(receipt.startedAt == unknown.startedAt && state.reads == 3)
    }

    nonisolated enum PermanentFailure: CaseIterable, Sendable { case denied, identity, certificate }
    @Test("权限、身份与证书问题不进入低频无限重试", arguments: PermanentFailure.allCases)
    func permanentFailureIsExplicit(kind: PermanentFailure) async throws {
        let state = State()
        let f = fixture(lookup: { @MainActor in
            state.reads += 1
            switch kind {
            case .denied: throw AgentToolError.httpFailed(403, "fixture denied")
            case .identity: throw AgentJobError.jobNotFound("fixture")
            case .certificate: throw URLError(.serverCertificateUntrusted)
            }
        })
        defer { f.cleanup() }
        await #expect(throws: AgentJobError.self) { try await f.wait() }
        #expect(state.reads == 1)
        #expect(f.registry.job(id: f.id)?.isAlive == true)
        #expect(f.registry.job(id: f.id)?.needsAttention == true)
    }

    @Test("外部终态取消事件流及在途对账，不留下后台恢复循环")
    func terminalReceiptCancelsAllObservers() async throws {
        let state = State()
        let f = fixture(stream: { @MainActor _ in
            state.streamStarted = true
            defer { state.streamEnded = true }
            try await Task.sleep(for: .seconds(3600))
            return 0
        }, lookup: { @MainActor in
            state.reads += 1
            defer { state.lookupEnded = true }
            try await Task.sleep(for: .seconds(3600))
            return nil
        })
        defer { f.cleanup() }
        f.monitor.requestCancellation()
        try await eventually { state.reads == 1 && state.streamStarted }
        f.cleanup()
        try await eventually { state.streamEnded && state.lookupEnded }
        #expect(f.registry.job(id: f.id)?.status == .failed)
        #expect(f.registry.job(id: f.id)?.monitoringFailure == nil)
        #expect(state.reads == 1)
    }
}
