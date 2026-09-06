import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("事件驱动任务终态与远端确认", .timeLimit(.minutes(1)))
struct AgentJobTerminalWaitTests {
    private func job(_ registry: AgentJobRegistry, runtime: UUID, receipt: Bool = false,
                     timeout: Double? = nil, cancellation: @escaping @Sendable () -> Void = {}) -> AgentBackgroundJob {
        registry.registerManagedExecutor(executor: .codexCLI, displayCommand: "receipt fixture",
            workingDirectory: FileManager.default.temporaryDirectory, runtimeID: runtime,
            timeoutSeconds: timeout, publishesCompletion: false, requiresExitReceipt: receipt,
            cancellation: cancellation)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test("已结束任务立即返回，未知句柄和其他会话不能订阅")
    func terminalAndUnknownJobs() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = job(registry, runtime: runtime)
        registry.finishManagedExecutor(id: original.id, status: .completed, exitCode: 0)
        let result = try await registry.waitForTerminal(id: original.id, forRuntime: runtime)
        #expect(result.status == .completed)
        await #expect(throws: AgentJobError.self) { try await registry.waitForTerminal(id: UUID(), forRuntime: runtime) }
        await #expect(throws: AgentJobError.self) { try await registry.waitForTerminal(id: original.id, forRuntime: UUID()) }
        #expect(registry.terminalWaiterCount == 0)
    }

    @Test("静默退出唤醒多个等待者，历史裁剪后仍返回捕获的回执")
    func quietCompletionSurvivesPruning() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = job(registry, runtime: runtime)
        let waits = (0..<8).map { _ in Task { try await registry.waitForTerminal(id: original.id, forRuntime: runtime) } }
        defer { waits.forEach { $0.cancel() } }
        try await eventually { registry.terminalWaiterCount == waits.count }
        registry.finishManagedExecutor(id: original.id, status: .completed, exitCode: 17)
        for _ in 0..<55 {
            let extra = job(registry, runtime: runtime)
            registry.finishManagedExecutor(id: extra.id, status: .completed, exitCode: 0)
        }
        #expect(registry.job(id: original.id) == nil)
        for wait in waits {
            let result = try await wait.value
            #expect(result.id == original.id)
            #expect(result.exitCode == 17)
        }
        #expect(registry.terminalWaiterCount == 0)
        #expect(registry.pendingCompletionCount(forRuntime: runtime) == 0)
    }

    @Test("取消等待不取消任务，不干扰其他等待者", arguments: [false, true])
    func cancellationIsLocal(beforeSubscribe: Bool) async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = job(registry, runtime: runtime)
        let waiter = Task { try await registry.waitForTerminal(id: original.id, forRuntime: runtime) }
        if !beforeSubscribe { try await eventually { registry.terminalWaiterCount == 1 } }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(registry.terminalWaiterCount == 0)
        #expect(registry.job(id: original.id)?.isAlive == true)
        let survivor = Task { try await registry.waitForTerminal(id: original.id, forRuntime: runtime) }
        registry.finishManagedExecutor(id: original.id, status: .completed, exitCode: 0)
        #expect(try await survivor.value.status == .completed)
        #expect(registry.terminalWaiterCount == 0)
    }

    @Test("真实本机进程通过事件返回终态")
    func nativeProcessReceipt() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = try registry.start(command: "exit 0", workingDirectory: FileManager.default.temporaryDirectory,
            runtimeID: runtime, timeoutSeconds: 30, sandboxMode: .escalated)
        defer { registry.killAllAlive(forRuntime: runtime) }
        #expect(try await registry.waitForTerminal(id: original.id, forRuntime: runtime).exitCode == 0)
        #expect(registry.terminalWaiterCount == 0)
    }

    @Test("远端取消不伪造终态，重复停止不恢复完成通知")
    func remoteCancellationNeedsReceipt() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let signals = DispatchSemaphore(value: 0)
        let original = job(registry, runtime: runtime, receipt: true, cancellation: { signals.signal() })
        let waiter = Task { try await registry.waitForTerminal(id: original.id, forRuntime: runtime) }
        defer { waiter.cancel() }
        try await eventually { registry.terminalWaiterCount == 1 }
        #expect(registry.killForStoppedTurn(id: original.id))
        #expect(!registry.killForStoppedTurn(id: original.id))
        #expect(signals.wait(timeout: .now()) == .success)
        #expect(signals.wait(timeout: .now()) == .timedOut)
        #expect(registry.job(id: original.id)?.isAlive == true)
        #expect(registry.job(id: original.id)?.finishedAt == nil)
        #expect(registry.terminalWaiterCount == 1)
        registry.finishManagedExecutor(id: original.id, status: .failed, exitCode: 143, exitConfirmed: true)
        #expect(try await waiter.value.status == .killed)
        #expect(registry.pendingCompletionCount(forRuntime: runtime) == 0)
    }

    @Test("无法确认时保留资源和句柄，晚到回执仍可结算")
    func unconfirmedRemoteStaysTracked() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = job(registry, runtime: runtime, receipt: true)
        registry.finishManagedExecutor(id: original.id, status: .killed, exitCode: 15)
        #expect(registry.job(id: original.id)?.isAlive == true)
        #expect(registry.job(id: original.id)?.needsAttention == true)
        await #expect(throws: AgentJobError.self) { try await registry.waitForTerminal(id: original.id, forRuntime: runtime) }
        #expect(registry.terminalWaiterCount == 0)
        #expect(registry.kill(id: original.id))
        registry.finishManagedExecutor(id: original.id, status: .completed, exitCode: 0, exitConfirmed: true)
        #expect(registry.job(id: original.id)?.isAlive == false)
        #expect(registry.job(id: original.id)?.monitoringFailure == nil)
    }

    @Test("远端超时也必须等回执后才释放任务")
    func remoteTimeoutNeedsReceipt() async throws {
        let registry = AgentJobRegistry(), runtime = UUID()
        let original = job(registry, runtime: runtime, receipt: true, timeout: 0.005)
        try await eventually { registry.job(id: original.id)?.cancellationRequestedAt != nil }
        #expect(registry.job(id: original.id)?.isAlive == true)
        registry.finishManagedExecutor(id: original.id, status: .failed, exitCode: 143, exitConfirmed: true)
        #expect(try await registry.waitForTerminal(id: original.id, forRuntime: runtime).status == .timedOut)
    }
}
