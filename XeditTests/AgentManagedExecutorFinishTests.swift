//
//  AgentManagedExecutorFinishTests.swift
//  XeditTests
//
//  收尾一个失败的托管执行器时，用户此前只看到 "Command exited with status
//  -1: exit -1"，真实原因被合成的 .finished 事件遮蔽。这里验证真实原因（记在
//  .warning 里）会被透出，而没有原因时才回落到 exit 码。

import Foundation
import Testing
@testable import WillDeep

@Suite("Managed executor finish")
struct AgentManagedExecutorFinishTests {
    @MainActor
    private func makeJob(_ registry: AgentJobRegistry) -> AgentBackgroundJob {
        registry.registerManagedExecutor(
            executor: .claudeCode,
            displayCommand: "claude-code-acp",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            runtimeID: UUID(),
            timeoutSeconds: nil,
            publishesCompletion: false,
            cancellation: {}
        )
    }

    @Test("失败收尾透出 warning 里的真实原因，而不是 exit -1")
    @MainActor
    func failedExecutorSurfacesTheRealReason() {
        let registry = AgentJobRegistry()
        let job = makeJob(registry)
        registry.recordManagedExecutorEvents(id: job.id, events: [
            AgentExecutorEvent(
                kind: .warning,
                detail: "claude-code-acp adapter failed to launch",
                status: .failed
            )
        ])
        registry.finishManagedExecutor(id: job.id, status: .failed, exitCode: -1)
        // 修复前这里会是 "exit -1"。
        #expect(registry.executorResultText(id: job.id) == "claude-code-acp adapter failed to launch")
    }

    @Test("没有原因时失败收尾仍回落到 exit 码")
    @MainActor
    func failedExecutorWithoutReasonFallsBackToExitCode() {
        let registry = AgentJobRegistry()
        let job = makeJob(registry)
        registry.finishManagedExecutor(id: job.id, status: .failed, exitCode: 42)
        #expect(registry.executorResultText(id: job.id) == "exit 42")
    }

    @Test("成功收尾不会去捡 warning 当结果")
    @MainActor
    func completedExecutorIgnoresWarningsForResult() {
        let registry = AgentJobRegistry()
        let job = makeJob(registry)
        // 成功路径里即便早先有过一条 warning，也不该被当成最终结果原因。
        registry.recordManagedExecutorEvents(id: job.id, events: [
            AgentExecutorEvent(kind: .warning, detail: "transient retry", status: .failed)
        ])
        registry.finishManagedExecutor(id: job.id, status: .completed, exitCode: 0)
        #expect(registry.executorResultText(id: job.id) != "transient retry")
    }
}
