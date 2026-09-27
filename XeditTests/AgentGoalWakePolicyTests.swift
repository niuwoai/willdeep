//
//  AgentGoalWakePolicyTests.swift
//  WillDeepTests
//
//  Pure rules behind a Goal that waits instead of stopping: the 1 / 5 / 15
//  minute ladder, which failures are worth waiting out, who may wait, and how
//  a wait is re-derived after the Mac slept.
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Goal 定时续推的纯规则")
@MainActor
struct AgentGoalWakePolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func http(_ status: Int, body: String = "") -> Error {
        AgentClientError.serverStatus(AgentProviderHTTPError(
            statusCode: status, method: "POST", url: "https://fixture.invalid/v1",
            providerID: "openai", model: "fixture", requestSummary: "-",
            requestBody: "-", responseBody: body
        ))
    }

    private func goal(
        done: Bool = false,
        budget: AgentGoalContinuationBudget? = nil
    ) -> AgentGoal {
        AgentGoal(
            statement: "Ship overnight",
            checklist: [.init(text: "Verified", done: done)],
            continuationBudget: budget
        )
    }

    // MARK: - Ladder

    @Test("退避序列是 1 / 5 / 15 分钟，之后一直 15 分钟")
    func ladderIsOneFiveFifteenThenFlat() {
        let delays = (1...7).map { AgentGoalWakePolicy.delay(forAttempt: $0) }
        #expect(delays == [60, 300, 900, 900, 900, 900, 900])
        #expect(AgentGoalWakePolicy.delay(forAttempt: 0) == 60)
        #expect(AgentGoalWakePolicy.maximumRetryDelay == 15 * 60)
    }

    @Test("第 5 轮无进展是第 1 次退避，之前的轮次不等待")
    func backoffAttemptStartsAtTheFifthRound() {
        let attempts = [5, 6, 7, 12].map { AgentGoalWakePolicy.backoffAttempt(forRoundsWithoutProgress: $0) }
        #expect(attempts == [1, 2, 3, 8])
        #expect(AgentGoalWakePolicy.delay(forAttempt: AgentGoalWakePolicy.backoffAttempt(forRoundsWithoutProgress: 5)) == 60)
        #expect(AgentGoalWakePolicy.delay(forAttempt: AgentGoalWakePolicy.backoffAttempt(forRoundsWithoutProgress: 12)) == 900)
    }

    // MARK: - Classification

    @Test("瞬时故障值得等：断网、超时、408/429/5xx、空流、停流、TLS")
    func transientFailuresAreGoalRetryable() {
        let retryable: [Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.networkConnectionLost),
            URLError(.cannotConnectToHost), URLError(.secureConnectionFailed),
            http(408), http(429), http(500), http(502), http(503), http(504),
            AgentClientError.emptyStream(providerID: "openai", model: "fixture"),
            AgentClientError.streamStalled(idleSeconds: 90),
        ]
        for error in retryable {
            #expect(AgentGoalWakePolicy.isGoalRetryable(error), "\(error)")
        }
    }

    @Test("非瞬时故障照旧停下：鉴权、余额、请求错误、上下文超限、审核拒绝、取消")
    func terminalFailuresAreNotRetried() {
        let terminal: [Error] = [
            http(400), http(401), http(403), http(404), http(402),
            http(400, body: #"{"error":{"message":"This model's maximum context length is 128000 tokens"}}"#),
            http(429, body: #"{"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}"#),
            http(503, body: #"{"message":"账户余额不足"}"#),
            http(500, body: #"{"error":{"code":"data_inspection_failed"}}"#),
            AgentClientError.missingAPIKey,
            AgentClientError.invalidResponse,
            CancellationError(),
        ]
        for error in terminal {
            #expect(!AgentGoalWakePolicy.isGoalRetryable(error), "\(error)")
        }
    }

    @Test("Goal 级分类复用回合内的瞬时分类，不另起一套")
    func goalClassificationSharesTheTurnClassification() {
        #expect(AppState.isTransientProviderError(http(503)))
        #expect(!AppState.isTransientProviderError(http(401)))
        #expect(AppState.isTLSHandshakeError(URLError(.serverCertificateUntrusted)))
    }

    // MARK: - Eligibility

    @Test("只有执行中、未完成、预算有余的原生 Goal 才能挂起等待")
    func eligibilityRequiresARunningNativeGoalWithRunway() {
        func eligible(
            mode: AgentInteractionMode = .goal,
            agent: AgentExecutionAgent = .willDeep,
            dispatch: Bool = false,
            goal: AgentGoal?
        ) -> Bool {
            AgentGoalWakePolicy.canScheduleWake(
                interactionMode: mode, executionAgent: agent,
                isUnattendedDispatchTask: dispatch, goal: goal, now: now
            )
        }
        #expect(eligible(goal: goal()))
        #expect(!eligible(mode: .normal, goal: goal()))
        #expect(!eligible(agent: .codexCLI, goal: goal()))
        #expect(!eligible(dispatch: true, goal: goal()))
        #expect(!eligible(goal: nil))
        #expect(!eligible(goal: goal(done: true)))
        #expect(!eligible(goal: goal(budget: .init(wallClockLimit: 60, wrapUpDispatched: true))))
        #expect(!eligible(goal: goal(budget: .init(modelAdmissionPaused: true))))
        // Only the wall clock ends a waiting Goal.
        let spent = AgentGoalContinuationBudget(wallClockLimit: 60, segmentStartedAt: now.addingTimeInterval(-61))
        let running = AgentGoalContinuationBudget(wallClockLimit: 60, segmentStartedAt: now.addingTimeInterval(-59))
        #expect(!eligible(goal: goal(budget: spent)))
        #expect(eligible(goal: goal(budget: running)))
        #expect(AgentGoalWakePolicy.hasWallClockRunway(.init(wallClockLimit: 60), now: now))
        #expect(AgentGoalWakePolicy.hasWallClockRunway(.init(wallClockLimit: nil, segmentStartedAt: .distantPast), now: now))
    }

    @Test("等待中也算执行中：持有防睡眠；完成或非 Goal 不持有")
    func sleepInhibitionFollowsGoalExecution() {
        var waiting = goal()
        waiting.scheduledWake = AgentGoalWakePolicy.makeWake(reason: .providerOutage, attempt: 1, now: now, instruction: "x")
        func holds(_ goal: AgentGoal?, mode: AgentInteractionMode = .goal, responding: Bool = false,
                   slot: Bool = false, compressing: Bool = false) -> Bool {
            AgentGoalWakePolicy.holdsSleepInhibition(
                interactionMode: mode, goal: goal, isResponding: responding,
                isAwaitingProviderSlot: slot, isCompressingContext: compressing
            )
        }
        #expect(holds(waiting))
        #expect(holds(goal(), responding: true))
        #expect(holds(goal(), slot: true))
        #expect(holds(goal(), compressing: true))
        #expect(!holds(goal()))
        #expect(!holds(goal(done: true), responding: true))
        #expect(!holds(waiting, mode: .normal))
        #expect(!holds(nil, responding: true))
    }

    // MARK: - Catch-up

    @Test("睡眠醒来：到期的立即触发，未到期的按墙钟余量重新挂起")
    func catchUpUsesTheWallClockDueDate() {
        let wake = AgentGoalWakePolicy.makeWake(reason: .noProgressBackoff, attempt: 2, now: now, instruction: "x")
        #expect(wake.dueAt == now.addingTimeInterval(300))
        #expect(AgentGoalWakePolicy.catchUp(for: wake, now: now.addingTimeInterval(299)) == .wait(1))
        #expect(AgentGoalWakePolicy.catchUp(for: wake, now: now.addingTimeInterval(300)) == .fireNow)
        #expect(AgentGoalWakePolicy.catchUp(for: wake, now: now.addingTimeInterval(7_200)) == .fireNow)
    }

    @Test("界面显示的剩余分钟向上取整，最少 1 分钟")
    func displayedMinutesRoundUp() {
        let due = now.addingTimeInterval(900)
        #expect(AgentGoalWakePolicy.displayedMinutesRemaining(until: due, now: now) == 15)
        #expect(AgentGoalWakePolicy.displayedMinutesRemaining(until: due, now: now.addingTimeInterval(1)) == 15)
        #expect(AgentGoalWakePolicy.displayedMinutesRemaining(until: due, now: now.addingTimeInterval(841)) == 1)
        #expect(AgentGoalWakePolicy.displayedMinutesRemaining(until: due, now: now.addingTimeInterval(9_999)) == 1)
    }

    // MARK: - Persistence

    @Test("等待记录随 Goal 落盘往返；旧会话没有这两个字段也能解码")
    func wakeRoundTripsAndLegacyGoalsDecode() throws {
        var original = goal()
        original.scheduledWake = AgentGoalWakePolicy.makeWake(
            reason: .providerOutage, attempt: 3, now: now, instruction: "resume", failureSummary: "HTTP 503"
        )
        original.consecutiveTransientFailures = 3
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentGoal.self, from: data)
        #expect(decoded == original)

        let legacy = Data(#"{"statement":"Old goal","checklist":[]}"#.utf8)
        let legacyGoal = try JSONDecoder().decode(AgentGoal.self, from: legacy)
        #expect(legacyGoal.scheduledWake == nil)
        #expect(legacyGoal.consecutiveTransientFailures == nil)
    }

    @Test("新版本写入的未知等待原因不会让整个会话解码失败")
    func unknownReasonDegradesInsteadOfFailing() throws {
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AgentGoalWakePolicy.makeWake(reason: .noProgressBackoff, attempt: 1, now: now, instruction: "go")
        )) as? [String: Any] ?? [:]
        encoded["reason"] = "someFutureReason"
        let wake = try JSONDecoder().decode(
            AgentGoalScheduledWake.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        #expect(wake.reason == .providerOutage)
        #expect(wake.instruction == "go")
    }
}
