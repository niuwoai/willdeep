//
//  AgentSubagentStreamingTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSubagentStreamingTests {
    @Test("free-text pipeline keeps visible text and reasoning separate")
    func separatesTextAndReasoning() async throws {
        let events = StreamingEventRecorder()
        let outcome = try await AgentSubagentTextStreamPipeline.run(
            onEvent: { event in
                await events.record(event)
            },
            stream: { consume in
                await consume(.reasoningDelta("private "))
                await consume(.textDelta("公开"))
                await consume(.reasoningDelta("thought"))
                await consume(.textDelta("发言"))
                await consume(.finishedTurn("stop"))
                await consume(.usageReported(
                    prompt: 10,
                    completion: 6,
                    total: 16,
                    cachedPrompt: 4,
                    cacheWritePrompt: 2,
                    reasoning: 3
                ))
            }
        )

        #expect(outcome.text == "公开发言")
        #expect(outcome.reasoning == "private thought")
        #expect(outcome.finishReason == "stop")
        #expect(outcome.didFinish)
        #expect(outcome.usage.total == 16)
        #expect(outcome.usage.cachedPrompt == 4)
        #expect(outcome.usage.cacheWritePrompt == 2)
        #expect(outcome.usage.reasoning == 3)
        #expect(outcome.usage.wasReported)

        let recorded = await events.snapshot()
        #expect(recorded == [
            .reasoningDelta("private "),
            .textDelta("公开"),
            .reasoningDelta("thought"),
            .textDelta("发言"),
            .finished(reason: "stop"),
            .usage(AgentSubagentStreamingUsage(
                prompt: 10,
                completion: 6,
                total: 16,
                cachedPrompt: 4,
                cacheWritePrompt: 2,
                reasoning: 3,
                wasReported: true
            )),
        ])
    }

    @Test("free-text pipeline ignores tool snapshots and empty deltas")
    func ignoresNonTextNoise() async throws {
        let events = StreamingEventRecorder()
        let outcome = try await AgentSubagentTextStreamPipeline.run(
            onEvent: { event in
                await events.record(event)
            },
            stream: { consume in
                await consume(.textDelta(""))
                await consume(.reasoningDelta(""))
                await consume(.toolCallsUpdated([]))
                await consume(.textDelta("可见内容"))
            }
        )

        #expect(outcome.text == "可见内容")
        #expect(outcome.reasoning.isEmpty)
        #expect(!outcome.didFinish)
        #expect(await events.snapshot() == [.textDelta("可见内容")])
    }

    @Test("free-text pipeline propagates provider errors")
    func propagatesProviderError() async {
        await #expect(throws: StreamingFixtureError.self) {
            _ = try await AgentSubagentTextStreamPipeline.run(
                onEvent: nil,
                stream: { _ in
                    throw StreamingFixtureError.providerFailed
                }
            )
        }
    }

    @Test("free-text pipeline propagates cancellation")
    func propagatesCancellation() async {
        await #expect(throws: CancellationError.self) {
            _ = try await AgentSubagentTextStreamPipeline.run(
                onEvent: nil,
                stream: { _ in
                    throw CancellationError()
                }
            )
        }
    }

    @Test("free-text pipeline rejects a reasoning-only response")
    func rejectsReasoningOnlyResponse() async {
        await #expect(throws: AgentSubagentError.self) {
            _ = try await AgentSubagentTextStreamPipeline.run(
                onEvent: nil,
                stream: { consume in
                    await consume(.reasoningDelta("not user-visible"))
                    await consume(.finishedTurn("stop"))
                }
            )
        }
    }

    @Test("draft buffer refreshes fast, checkpoints slowly, and flushes")
    func draftBufferThrottleAndFlush() async {
        let buffer = RoundtableStreamingDraftBuffer(
            uiInterval: .milliseconds(80),
            checkpointInterval: .seconds(1)
        )
        let start = ContinuousClock().now

        let first = await buffer.append("甲", now: start)
        #expect(first?.text == "甲")
        #expect(first?.shouldRefreshUI == true)
        #expect(first?.shouldCheckpoint == false)

        let suppressed = await buffer.append(
            "乙",
            now: start.advanced(by: .milliseconds(20))
        )
        #expect(suppressed == nil)

        let uiRefresh = await buffer.append(
            "丙",
            now: start.advanced(by: .milliseconds(90))
        )
        #expect(uiRefresh?.text == "甲乙丙")
        #expect(uiRefresh?.shouldRefreshUI == true)
        #expect(uiRefresh?.shouldCheckpoint == false)

        let checkpoint = await buffer.append(
            "丁",
            now: start.advanced(by: .milliseconds(1_050))
        )
        #expect(checkpoint?.text == "甲乙丙丁")
        #expect(checkpoint?.shouldRefreshUI == true)
        #expect(checkpoint?.shouldCheckpoint == true)

        let final = await buffer.finish()
        #expect(final.text == "甲乙丙丁")
        #expect(final.shouldRefreshUI)
        #expect(final.shouldCheckpoint)
        #expect(final.isFinal)
        #expect(!final.isReset)
    }

    @Test("draft buffer reset clears an abandoned stream")
    func draftBufferReset() async {
        let buffer = RoundtableStreamingDraftBuffer()
        _ = await buffer.append("未完成")

        let reset = await buffer.reset()

        #expect(reset.text.isEmpty)
        #expect(reset.shouldRefreshUI)
        #expect(reset.shouldCheckpoint)
        #expect(reset.isReset)
        #expect(await buffer.snapshot().isEmpty)
    }
}

private actor StreamingEventRecorder {
    private var events: [AgentSubagentStreamingTextEvent] = []

    func record(_ event: AgentSubagentStreamingTextEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentSubagentStreamingTextEvent] {
        events
    }
}

private enum StreamingFixtureError: Error {
    case providerFailed
}
