import Foundation
import Testing
@testable import WillDeep

@Suite("工具执行预算硬边界")
struct AgentToolExecutionBudgetTests {
    @MainActor
    @Test("宿主截止信号取消已启动操作，并等待其清理完成", .timeLimit(.minutes(1)))
    func deadlineCancelsAndJoinsOperation() async {
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 3_600, segmentStartedAt: Date()))
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        var began = false
        var cleanedUp = false
        await #expect(throws: AgentToolExecutionBudgetError.deadlineReached) {
            // Drive the deadline event only after operation entry. A 100ms
            // wall timer measured MainActor contention in the full suite,
            // not cancellation of an in-flight request. Real HTTP wall-clock
            // cancellation remains covered by AgentGoalMainLoopTests.
            try await envelope.runModelRequest(waitUntilDeadline: { deadline in
                #expect(deadline == envelope.deadline)
                var iterator = started.makeAsyncIterator()
                _ = await iterator.next()
            }) {
                began = true
                signal.yield(()); signal.finish()
                defer { cleanedUp = true }
                try await Task.sleep(for: .seconds(30))
                Issue.record("Operation escaped its deadline")
            }
        }
        #expect(began)
        #expect(cleanedUp)
    }

    @MainActor
    @Test("到期前完成不等待计时器，取消覆盖同时产生的截止错误", .timeLimit(.minutes(1)), arguments: [false, true])
    func earlyCompletionAndCancellation(simultaneousDeadline: Bool) async throws {
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 3_600, segmentStartedAt: Date()))
        var completed = false
        try await envelope.runModelRequest { completed = true }
        #expect(completed)
        let (started, sink) = AsyncStream<Void>.makeStream()
        var cleanedUp = false
        let task = Task {
            try await envelope.runModelRequest {
                sink.yield(()); sink.finish()
                defer { cleanedUp = true }
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    if simultaneousDeadline { throw AgentToolExecutionBudgetError.deadlineReached }
                    throw error
                }
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cleanedUp)
    }

    @MainActor
    @Test("已过期的真实 Client 在校验配置或发送请求前拒绝")
    func expiredClientNeverCallsProvider() async {
        let client = AgentClient(configuration: .init(providerID: "openai",
            baseURL: "https://budget.invalid/v1", model: "fixture", apiKey: ""))
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            try await client.streamChat(messages: [], executionBudget: envelope) { _ in
                Issue.record("Expired request emitted a provider event")
            }
        }
    }

    @Test("执行截止时间前允许，到期立刻拒绝")
    func deadlineIsHardBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: 10, segmentStartedAt: start))
        try envelope.check(now: start.addingTimeInterval(9))
        #expect(throws: AgentToolExecutionBudgetError.exhausted) { try envelope.check(now: start.addingTimeInterval(10)) }
        #expect(throws: AgentToolExecutionBudgetError.exhausted) { try envelope.check(now: start.addingTimeInterval(11)) }
    }

    @Test("收尾阶段无论剩余时间多少都拒绝新工具")
    func wrapUpIsNotAnInstructionOnly() {
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: nil, wrapUpDispatched: true))
        #expect(throws: AgentToolExecutionBudgetError.exhausted) { try envelope.check() }
    }

    @Test("无时间上限且未收尾时不制造新限制")
    func unboundedBudgetRemainsUnbounded() throws {
        let envelope = AgentToolExecutionBudget(budget: .init(wallClockLimit: nil))
        try envelope.check(now: .distantFuture)
    }
}
