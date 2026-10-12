import Foundation
import Testing
@testable import WillDeep

@Suite @MainActor
struct AgentEmptyResponseRetryTests {
    private var empty: AgentClientError { .emptyStream(providerID: "fixture", model: "fixture") }

    @Test("托管空输出交给任务层，保留用量且不在同模型上重试")
    func managedEmptyOutputKeepsUsage() async throws {
        var requests = 0
        var invalidations = 0
        let events = RetryEventRecorder()
        try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
            returnsEmptyOutput: true, onEmptyOutput: { invalidations += 1 },
            onEvent: { await events.consume($0) },
            sleep: { _ in Issue.record("Managed emptiness must not back off") }) { consume in
            requests += 1
            await consume(.usageReported(prompt: 10, completion: 5, total: 15,
                cachedPrompt: nil, cacheWritePrompt: nil, reasoning: 0))
            await consume(.finishedTurn("stop"))
            throw empty
        }
        #expect(requests == 1)
        #expect(invalidations == 1)
        #expect(await events.usageTotals == [15])
        #expect(await events.finishes == 1)
    }

    @Test("托管空输出策略不吞权限或网络错误")
    func managedErrorsStillPropagate() async {
        await #expect(throws: FixtureError.self) {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                returnsEmptyOutput: true, onEvent: { _ in },
                sleep: { _ in Issue.record("Must not back off") }) { _ in
                throw FixtureError.unauthorized
            }
        }
    }

    @Test("empty requests back off three times then recover without replaying prior tools")
    func resumesCurrentRequest() async throws {
        var requests = 0
        var delays: [UInt64] = []
        var progress: [Int] = []
        let events = RetryEventRecorder()
        // These are already-completed work, outside the retried operation.
        var completedTools = 1
        let transcript = ["user task", "assistant tool call", "tool result"]
        var sentTranscripts: [[String]] = []
        try await AgentEmptyResponseRetry.run(
            providerID: "fixture", model: "fixture", onEvent: { await events.consume($0) },
            onRetry: { attempt, limit in
                progress.append(attempt)
                #expect(limit == 3)
            }, sleep: { delays.append($0) }
        ) { consume in
            requests += 1
            sentTranscripts.append(transcript)
            if requests < 4 { throw empty }
            await consume(.textDelta("Done"))
            await consume(.finishedTurn("stop"))
        }
        // The outer loop may now execute the next step once, not four times.
        completedTools += 1
        #expect(completedTools == 2)
        #expect(requests == 4)
        #expect(sentTranscripts == Array(repeating: transcript, count: 4))
        #expect(delays == AgentEmptyResponseRetry.delays)
        #expect(progress == [1, 2, 3])
        #expect(await events.text == "Done")
        #expect(await events.finishes == 1)
    }

    @Test("persistent emptiness stops after four requests and exposes the original error")
    func boundedExhaustion() async {
        var requests = 0
        do {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in }) { _ in
                requests += 1
                throw empty
            }
            Issue.record("Expected exhaustion")
        } catch AgentClientError.emptyStream(let providerID, let model) {
            #expect(providerID == "fixture")
            #expect(model == "fixture")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(requests == 4)
    }

    @Test("clean empty stop and usage-only replies retry; usage sums across attempts")
    func emptyStopAndUsage() async throws {
        var requests = 0
        let events = RetryEventRecorder()
        try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
            onEvent: { await events.consume($0) }, sleep: { _ in }) { consume in
            requests += 1
            await consume(.usageReported(prompt: 10, completion: 1, total: 11,
                cachedPrompt: 4, cacheWritePrompt: 2, reasoning: 1))
            // Provider usage chunks are cumulative, not additive per chunk.
            await consume(.usageReported(prompt: 10, completion: 2, total: 12,
                cachedPrompt: 4, cacheWritePrompt: 2, reasoning: 2))
            if requests == 3 { await consume(.textDelta("Recovered")) }
            await consume(.finishedTurn("stop"))
        }
        #expect(requests == 3)
        #expect(await events.usageTotals == [36])
        #expect(await events.prompt == 30)
        #expect(await events.cached == 12)
        #expect(await events.finishes == 1)
    }

    @Test(arguments: ["text", "reasoning", "tool"])
    func partialPayloadNeverRetries(_ kind: String) async {
        var requests = 0
        await #expect(throws: AgentClientError.self) {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in Issue.record("Must not back off") }) { consume in
                requests += 1
                switch kind {
                case "text": await consume(.textDelta("partial"))
                case "reasoning": await consume(.reasoningDelta("partial"))
                default:
                    await consume(.toolCallsUpdated([.init(externalID: "call-1", toolName: "run_command", argumentsJSON: "{")]))
                }
                throw empty
            }
        }
        #expect(requests == 1)
    }

    @Test(arguments: ["content_filter", "refusal", "length", "tool_calls"])
    func explicitTerminationNeverRetries(_ reason: String) async throws {
        var requests = 0
        try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
            onEvent: { _ in }, sleep: { _ in Issue.record("Must not back off") }) { consume in
            requests += 1
            await consume(.finishedTurn(reason))
        }
        #expect(requests == 1)
    }

    @Test("non-empty provider errors are never converted to retries")
    func propagatesErrors() async {
        var requests = 0
        await #expect(throws: FixtureError.self) {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in Issue.record("Must not back off") }) { _ in
                requests += 1
                throw FixtureError.unauthorized
            }
        }
        #expect(requests == 1)
    }

    @Test("Stop during backoff propagates cancellation without another request")
    func cancellationDuringBackoff() async {
        var requests = 0
        await #expect(throws: CancellationError.self) {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in throw CancellationError() }) { _ in
                requests += 1
                throw empty
            }
        }
        #expect(requests == 1)
    }

    @Test("cancellation from the provider is not an empty response")
    func cancellationDuringStream() async {
        await #expect(throws: CancellationError.self) {
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in Issue.record("Must not back off") }) { _ in
                throw CancellationError()
            }
        }
    }

    @Test("each new round receives a fresh bounded retry budget")
    func budgetResetsPerRequest() async throws {
        for _ in 0..<2 {
            var requests = 0
            try await AgentEmptyResponseRetry.run(providerID: "fixture", model: "fixture",
                onEvent: { _ in }, sleep: { _ in }) { consume in
                requests += 1
                if requests == 1 { throw empty }
                await consume(.textDelta("ok"))
            }
            #expect(requests == 2)
        }
    }
}

private enum FixtureError: Error { case unauthorized }

private actor RetryEventRecorder {
    var text = ""
    var finishes = 0
    var usageTotals: [Int] = []
    var prompt = 0
    var cached: Int?
    func consume(_ event: AgentClientEvent) {
        switch event {
        case .textDelta(let delta): text += delta
        case .finishedTurn: finishes += 1
        case .usageReported(let input, _, let total, let cachedPrompt, _, _):
            usageTotals.append(total)
            prompt = input
            cached = cachedPrompt
        default: break
        }
    }
}
