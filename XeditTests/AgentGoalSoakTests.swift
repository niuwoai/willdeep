import Foundation
import Testing
@testable import WillDeep

/// One continuously owned Goal, not a loop that recreates short fixtures.
/// Default CI runs the identical scenario briefly; the runner verifies the
/// requested duration explicitly before calling an extended run a soak pass.
@MainActor
@Suite("Goal 持续运行证据", .serialized, .timeLimit(.minutes(300)))
struct AgentGoalSoakTests {
    private enum Failure: Error { case invalidDuration, stalled, invariant }
    private static let minimumReads = 257
    private static let maximumSeconds = 14_400
    private static let recordCount = 4_096

    @MainActor private final class Trace {
        let started = ContinuousClock.now
        var requests = 0
        var reads = 0
        var verifiedReads = 0
        var emptyResponses = 0
        var compressions = 0
        var handoffPending = false
        var lastFaultRead = -1
        var budgetStart: Date?
        var reachedDuration = false
        var ledgerAttempts = -1
        var unfinishedRequests = -1
        var failures: [String] = []
        var nextReport: Double = 0
        var elapsed: Double {
            let parts = started.duration(to: .now).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }
        func check(_ value: Bool, _ message: String) {
            if !value && !failures.contains(message) { failures.append(message) }
        }
        func emit(seconds: Int, final: Bool, runtime: AgentRuntime) throws {
            let record: [String: Any] = ["final": final, "requested_seconds": seconds,
                "runtime_id": runtime.id.uuidString,
                "elapsed_seconds": elapsed, "requests": requests, "verified_reads": verifiedReads,
                "empty_responses": emptyResponses, "compressions": compressions,
                "continuations": runtime.currentGoal?.continuationBudget?.continuationsUsed ?? 0,
                "retained_messages": runtime.messages.count, "retained_tool_receipts": runtime.toolCalls.count,
                "pending_user_decisions": runtime.pendingToolDecisions.count,
                "ledger_attempts": ledgerAttempts, "unfinished_requests": unfinishedRequests,
                "reached_duration": reachedDuration, "failures": failures]
            print("goal_soak_evidence " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: .sortedKeys), as: UTF8.self))
        }
    }

    @Test("单 Goal 持续读取、跨压缩与空响应恢复，不需要用户续跑")
    func continuousGoal() async throws {
        let raw = ProcessInfo.processInfo.environment["WILLDEEP_GOAL_SOAK_SECONDS"] ?? "3"
        guard let seconds = Int(raw), (1...Self.maximumSeconds).contains(seconds) else { throw Failure.invalidDuration }
        let f = try AgentGoalMainLoopTests().fixture(recordCount: Self.recordCount)
        defer { f.cleanup() }
        let trace = Trace()
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: Double(seconds + 120))
        f.app.contextCompressionSummaryOperation = { _, _ in
            trace.compressions += 1
            return "Continue inspecting numbered records; earlier reads are evidence, not completion."
        }
        GoalLoopURLProtocol.install(f.token) { _ in
            trace.requests += 1
            if trace.budgetStart == nil { trace.budgetStart = f.runtime.currentGoal?.continuationBudget?.segmentStartedAt }
            trace.check(trace.budgetStart != nil, "budget_not_started")
            trace.check(f.runtime.currentGoal?.continuationBudget?.segmentStartedAt == trace.budgetStart, "budget_start_changed")
            trace.check(f.runtime.currentGoal?.checklist.first?.done == false, "false_completion")
            trace.check(f.runtime.pendingToolDecisions.isEmpty, "unexpected_user_decision")
            trace.check(f.runtime.messages.filter(\.isOperatorInput).count <= 1, "synthetic_operator_input")
            if trace.reads > trace.verifiedReads {
                let call = f.runtime.toolCalls.last
                let line = trace.reads
                let validReceipt = call?.externalID == "soak-read-\(trace.reads)" && call?.status == .succeeded
                trace.check(validReceipt, "missing_tool_receipt")
                let expected = String(format: "%5d  record-%d", line, line)
                let lines = call?.result?.payload.split(separator: "\n").filter { !$0.hasPrefix("...[truncated:") }
                let validRead = lines?.map(String.init) == [expected]
                    && call?.arguments["offset"]?.intValue() == line && call?.arguments["limit"]?.intValue() == 1
                trace.check(validRead, "incorrect_file_read")
                if validReceipt && validRead { trace.verifiedReads = trace.reads }
            }
            guard trace.failures.isEmpty else {
                f.app.stopAgentResponse(for: f.runtime)
                throw Failure.invariant
            }
            if trace.elapsed >= Double(seconds), trace.verifiedReads >= Self.minimumReads {
                trace.reachedDuration = true
                f.app.stopAgentResponse(for: f.runtime)
                throw CancellationError()
            }
            if trace.elapsed >= trace.nextReport {
                try trace.emit(seconds: seconds, final: false, runtime: f.runtime)
                trace.nextReport = trace.elapsed + 60
            }
            if trace.handoffPending {
                trace.handoffPending = false
                let text = "PAUSE: context full. DONE: prior reads. ANCHORS: records.txt. REMAINING: keep inspecting. NEXT PROMPT: inspect next record."
                let chunk: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]
                return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
                    + "\n\ndata: [DONE]\n\n").utf8)
            }
            if trace.reads > 0, trace.reads.isMultiple(of: 47), trace.lastFaultRead != trace.reads {
                trace.lastFaultRead = trace.reads
                trace.emptyResponses += 1
                return Data("data: [DONE]\n\n".utf8)
            }
            try await Task.sleep(for: .milliseconds(seconds > 60 ? 5_000 : 10))
            trace.reads += 1
            guard trace.reads <= Self.recordCount else { throw Failure.invariant }
            let pressure = trace.reads.isMultiple(of: 64)
            trace.handoffPending = pressure
            return try AgentGoalMainLoopTests.toolResponse(trace.reads,
                content: pressure ? String(repeating: "fixture evidence details ", count: 2_000) : nil,
                promptTokens: pressure ? 920_000 : 100,
                externalID: "soak-read-\(trace.reads)")
        }
        f.start()
        while f.runtime.isResponding || f.runtime.isAwaitingProviderSlot || f.runtime.requestTask != nil || f.runtime.isCompressingContext {
            if trace.elapsed > Double(seconds + 120) { throw Failure.stalled }
            try await Task.sleep(for: .milliseconds(100))
        }
        trace.check(trace.reachedDuration, "ended_before_requested_duration")
        trace.check(trace.verifiedReads >= Self.minimumReads, "insufficient_reads")
        trace.check(trace.compressions >= 4 && trace.emptyResponses >= 5, "fault_or_compaction_not_exercised")
        trace.check(f.runtime.pendingToolDecisions.isEmpty && f.runtime.queuedMessages.isEmpty, "left_pending_user_work")
        trace.check(f.runtime.contextCheckpoint?.userInputs.first?.text == "Inspect numbered records.", "lost_original_constraint")
        let ledger = try #require(f.app.modelRequestLedger(for: f.runtime))
        let settlementDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var summary = try ledger.summary()
        while summary.unfinished > 0, ContinuousClock.now < settlementDeadline {
            try await Task.sleep(for: .milliseconds(20))
            summary = try ledger.summary()
        }
        trace.ledgerAttempts = summary.attempts
        trace.unfinishedRequests = summary.unfinished
        trace.check(summary.attempts == trace.requests && summary.unfinished == 0, "unsettled_or_unaccounted_requests")
        try trace.emit(seconds: seconds, final: true, runtime: f.runtime)
        #expect(trace.failures.isEmpty, "\(trace.failures.joined(separator: ","))")
    }
}
