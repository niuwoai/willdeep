//
//  AgentGoalCompressionRetryTests.swift
//  WillDeepTests
//
//  A Goal whose runway compression fails used to park for good: a new
//  session cannot carry its Goal, checklist and budget, so the relay refuses
//  Goals, and the session just stopped. A transient failure now waits on the
//  same 1 / 5 / 15 minute ladder as a provider outage and compresses again;
//  a deterministic one (the checkpoint cannot hold the required task state)
//  still stops, with its reason on screen.
//

import Combine
import Foundation
import Testing

@testable import WillDeep

@Suite("Goal 压缩失败的等待重试", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct AgentGoalCompressionRetryTests {
    private func http(_ status: Int, body: String = "") -> Error {
        AgentClientError.serverStatus(AgentProviderHTTPError(
            statusCode: status, method: "POST", url: "https://fixture.invalid/v1",
            providerID: "openai", model: "fixture", requestSummary: "-",
            requestBody: "-", responseBody: body
        ))
    }

    // MARK: - Pure

    @Test("可重试：压缩模型瞬时故障、超时、空结果、转录在压缩中变化")
    func transientCompressionFailuresRetry() {
        let retryable: [Error] = [
            URLError(.timedOut), URLError(.notConnectedToInternet), http(503), http(429),
            http(502, body: "(empty)"),
            AgentClientError.emptyStream(providerID: "openai", model: "fixture"),
            AgentContextCheckpoint.Failure.stale,
        ]
        for error in retryable {
            #expect(AgentGoalWakePolicy.compressionFailureDisposition(error) == .retry, "\(error)")
        }
    }

    @Test("不可重试：检查点超上限、没有可用压缩模型、预算耗尽、取消、请求被拒")
    func deterministicCompressionFailuresStop() {
        let terminal: [Error?] = [
            AgentContextCheckpoint.Failure.tooLarge,
            AgentCompressionReclamationError(projectedTokens: 900_000, contextWindow: 1_000_000),
            nil,
            AgentToolExecutionBudgetError.deadlineReached,
            CancellationError(),
            http(400), http(401),
            http(429, body: #"{"error":{"code":"insufficient_quota"}}"#),
        ]
        for error in terminal {
            #expect(AgentGoalWakePolicy.compressionFailureDisposition(error) == .stop, "\(String(describing: error))")
        }
    }

    // MARK: - Real AppState

    private func compressionFixture() throws -> AgentGoalOvernightResilienceTests.Fixture {
        let f = try AgentGoalOvernightResilienceTests().fixture()
        // Long assistant evidence so a real summary reclaims the window —
        // compression that saves nothing is refused (and that refusal is a
        // deterministic stop, not something a wait could fix).
        let evidence = String(repeating: "Record batch evidence details. ", count: 1_500)
        f.runtime.messages = (1...8).map { index in
            index.isMultiple(of: 2)
                ? AgentMessage(role: .assistant, content: "Batch \(index): \(evidence)")
                : AgentMessage(role: .user, content: "Process batch \(index).", source: .operatorInput)
        }
        return f
    }

    /// The runway stop's between-turns compression, awaited directly instead
    /// of through the fire-and-forget `compressAgentContext`.
    private func runRunwayCompression(_ f: AgentGoalOvernightResilienceTests.Fixture) async throws {
        f.runtime.pendingContextRunwayResume = true
        let plan = try #require(f.app.compressionPlan(
            for: f.runtime, keepRecent: AppState.goalWakeCompressionKeepRecentMessages
        ))
        f.runtime.isCompressingContext = true
        await f.app.runContextCompression(
            for: f.runtime, head: plan.head, tail: plan.tail, priorSummary: plan.priorSummary,
            configurations: f.app.contextCompressionConfigurationCandidates()
        )
    }

    /// Checks the live Goal on every published change. The published value
    /// itself can lag: a burst of synchronous updates outruns the async
    /// sequence's demand, but the live state after any delivery is final.
    private func awaitGoal(_ runtime: AgentRuntime, where predicate: (AgentGoal?) -> Bool) async {
        for await _ in runtime.$currentGoal.values where predicate(runtime.currentGoal) { return }
    }

    @Test("瞬时失败：Goal 等 1 分钟而不是停住；到期先重试压缩，成功后按原路径续跑")
    func transientFailureWaitsThenCompressesAndResumes() async throws {
        let f = try compressionFixture(); defer { f.cleanup() }
        f.install { _ in try f.stopFromProvider() }
        var compressions = 0
        f.app.contextCompressionSummaryOperation = { _, _ in
            compressions += 1
            if compressions == 1 { throw URLError(.timedOut) }
            return "Batches 1-6 processed and verified; continue with the rest."
        }
        let runtimesBefore = f.app.agentRuntimes.count

        try await runRunwayCompression(f)

        let wake = try #require(f.wake)
        #expect(wake.reason == .compressionRetry)
        #expect(wake.attempt == 1)
        #expect(wake.dueAt.timeIntervalSince(wake.scheduledAt) == AgentGoalWakePolicy.firstRetryDelay)
        #expect(f.runtime.errorMessage == nil)
        #expect(!f.runtime.pendingContextRunwayResume)
        #expect(f.app.agentRuntimes.count == runtimesBefore)
        #expect(f.provider.requests == 0)
        #expect(f.activity.begins == 1)

        f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt)
        #expect(f.runtime.isCompressingContext)
        await f.provider.awaitRequests(1)
        await f.awaitAllTurns()

        #expect(compressions == 2)
        #expect(f.runtime.contextSummary?.contains("continue with the rest") == true)
        #expect(f.provider.requests == 1)
        #expect(f.provider.lastUserTexts.last?.contains(AgentGoalRunBoundary.contextCompaction.instruction) == true)
        #expect(f.wake == nil)
    }

    @Test("压缩重试仍失败时沿阶梯升级到 5 分钟，不发主模型请求")
    func repeatedFailureWalksTheLadder() async throws {
        let f = try compressionFixture(); defer { f.cleanup() }
        f.install { _ in try f.stopFromProvider() }
        var compressions = 0
        f.app.contextCompressionSummaryOperation = { _, _ in
            compressions += 1
            throw URLError(.networkConnectionLost)
        }

        try await runRunwayCompression(f)
        let first = try #require(f.wake)
        f.app.catchUpGoalWakes(rearmPending: false, now: first.dueAt)
        await awaitGoal(f.runtime) { $0?.scheduledWake?.attempt == 2 }

        let second = try #require(f.wake)
        #expect(second.reason == .compressionRetry)
        #expect(second.dueAt.timeIntervalSince(second.scheduledAt) == AgentGoalWakePolicy.secondRetryDelay)
        #expect(f.runtime.currentGoal?.consecutiveTransientFailures == 2)
        #expect(compressions == 2)
        #expect(f.provider.requests == 0)
        #expect(f.runtime.errorMessage == nil)
    }

    @Test("检查点超上限这类确定性失败照旧停下，并给出明确原因")
    func deterministicFailureStillStops() async throws {
        let f = try compressionFixture(); defer { f.cleanup() }
        f.app.contextCompressionSummaryOperation = { _, _ in
            throw AgentContextCheckpoint.Failure.tooLarge
        }
        let runtimesBefore = f.app.agentRuntimes.count

        try await runRunwayCompression(f)

        #expect(f.wake == nil)
        let reason = try #require(AgentContextCheckpoint.Failure.tooLarge.errorDescription)
        #expect(f.runtime.errorMessage?.contains(reason) == true)
        #expect(!f.runtime.pendingContextRunwayResume)
        // Goals are still never relayed to a new session.
        #expect(f.app.agentRuntimes.count == runtimesBefore)
        #expect(f.activity.begins == f.activity.ends)
    }

    @Test("等待期间墙钟耗尽：到期不再压缩，按预算耗尽有序停下")
    func spentBudgetDuringTheWaitStopsInOrder() async throws {
        let f = try compressionFixture(); defer { f.cleanup() }
        var compressions = 0
        f.app.contextCompressionSummaryOperation = { _, _ in
            compressions += 1
            throw URLError(.timedOut)
        }
        try await runRunwayCompression(f)
        let wake = try #require(f.wake)
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 60, segmentStartedAt: wake.scheduledAt.addingTimeInterval(-3_600))

        f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt)

        #expect(compressions == 1)
        #expect(!f.runtime.isCompressingContext)
        #expect(f.wake == nil)
        #expect(f.runtime.errorMessage == L10n.GoalPlanning.budgetExhausted)
        #expect(f.runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
        #expect(f.activity.begins == f.activity.ends)
    }
}
