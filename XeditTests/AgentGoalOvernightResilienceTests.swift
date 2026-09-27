//
//  AgentGoalOvernightResilienceTests.swift
//  WillDeepTests
//
//  A real AppState, real dispatch, real turn loop, real provider slots; only
//  the HTTP provider is substituted. Covers the overnight path end to end:
//  a provider that keeps failing parks the Goal on a wait instead of ending
//  it, the wait resumes the Goal when due, Stop and a new message cancel it,
//  the no-progress backoff really waits, a relaunch picks the wait back up,
//  and the Mac is kept from idle-sleeping for exactly as long as all that.
//

import AppKit
import Foundation
import Testing

@testable import WillDeep

/// Like `GoalLoopURLProtocol`, but the handler chooses the HTTP status.
nonisolated final class GoalOutageURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (URLRequest) async throws -> (status: Int, body: Data)
    static let tokenHeader = "X-Goal-Outage-Fixture"
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private var work: Task<Void, Never>?
    private var stopped = false

    static func install(_ token: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = handler
    }

    static func remove(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: Self.tokenHeader).flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let task = Task { @MainActor in
            do {
                let (status, body) = try await handler(request)
                try Task.checkCancellation()
                let contentType = status == 200 ? "text/event-stream" : "application/json"
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": contentType]) else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        Self.lock.lock()
        if stopped { task.cancel() } else { work = task }
        Self.lock.unlock()
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        stopped = true
        work?.cancel()
        work = nil
    }
}

@MainActor
@Suite("Goal 通宵运行：故障等待、退避、防睡眠", .serialized, .timeLimit(.minutes(3)))
struct AgentGoalOvernightResilienceTests {
    /// URLProtocol callbacks do not inherit Swift Testing's task-local test,
    /// so they record here and the test asserts afterwards.
    @MainActor final class Provider {
        private(set) var requests = 0
        var turnIDs: [UUID?] = []
        var lastUserTexts: [String] = []
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func noteRequest() {
            requests += 1
            let ready = waiters.filter { $0.count <= requests }
            waiters.removeAll { $0.count <= requests }
            ready.forEach { $0.continuation.resume() }
        }

        /// Resumes once the provider has seen `count` requests in total —
        /// a turn started by a background Task is awaited through the one
        /// event it must produce, not by watching flags that may flip back
        /// before anyone looks.
        func awaitRequests(_ count: Int) async {
            guard requests < count else { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    static let unavailable = (status: 503, body: Data(#"{"error":{"message":"upstream overloaded"}}"#.utf8))
    static let unauthorized = (status: 401, body: Data(#"{"error":{"message":"invalid api key"}}"#.utf8))

    @MainActor struct Fixture {
        let app: AppState
        let runtime: AgentRuntime
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let token: String
        let session: URLSession
        let activity: AgentGoalActivityCounter
        let provider = Provider()

        func cleanup() {
            app.stopAgentResponse(for: runtime)
            app.agentGoalWakeCoordinator.disarm(runtimeID: runtime.id)
            app.dispatchDecisionResumptionTask?.cancel()
            session.invalidateAndCancel()
            GoalOutageURLProtocol.remove(token)
            app.contextCompressionSummaryOperation = nil
            app.agentLoopInferenceEnvironment = nil
            AgentSessionStore.delete(id: runtime.id)
            TestDefaultsHygiene.cleanup(suite: defaults, named: suite)
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Overnight fixture cleanup failed: \(error)") }
        }

        /// Every fixture turn runs with the in-turn retry delay at zero; the
        /// Goal-level wait is what is under test, not 15 real seconds of 3s
        /// sleeps. Turn Tasks started inside inherit the task-local.
        func withoutInTurnDelay<T>(_ body: () throws -> T) rethrows -> T {
            try AgentTransientRetryLane.$testDelayOverrideNanoseconds.withValue(0, operation: body)
        }

        /// Starts a Goal turn the way the host continues one, then awaits
        /// that exact turn Task — no polling.
        func runHostTurn() async throws {
            withoutInTurnDelay {
                app.dispatchAgentMessage(for: runtime, text: "Continue the Goal.", images: [], source: .hostInstruction)
            }
            try await awaitCurrentTurn()
        }

        func awaitCurrentTurn() async throws {
            let turn = try #require(runtime.requestTask, "no turn was started")
            await turn.value
        }

        /// A turn's finish may hand the runtime straight to a queued host
        /// instruction (e.g. the budget wrap-up). Await each concrete turn
        /// Task in turn until none is left.
        func awaitAllTurns() async {
            var previous: Task<Void, Never>?
            while let turn = runtime.requestTask, turn != previous {
                previous = turn
                await turn.value
            }
        }

        func install(_ respond: @escaping @MainActor @Sendable (Int) throws -> (status: Int, body: Data)) {
            let provider = provider
            let runtime = runtime
            GoalOutageURLProtocol.install(token) { _ in
                provider.noteRequest()
                provider.turnIDs.append(runtime.activeTurnID)
                // Skip hidden context carriers (empty user-role messages).
                let latest = runtime.messages.last { $0.role == .user && !$0.content.isEmpty }
                provider.lastUserTexts.append(latest?.content ?? "")
                return try respond(provider.requests)
            }
        }

        /// Ends the turn that made this request the way a person would.
        func stopFromProvider() throws -> (status: Int, body: Data) {
            app.stopAgentResponse(for: runtime)
            throw CancellationError()
        }

        var wake: AgentGoalScheduledWake? { runtime.currentGoal?.scheduledWake }
    }

    func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-overnight-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "com.willdeep.agent.test.defaults.goal-overnight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let activity = AgentGoalActivityCounter()
        app.agentGoalWakeCoordinator.sleepInhibitor = activity.makeInhibitor()
        // Timers park for real durations; tests drive the due moment through
        // the catch-up path, which is exactly what a system wake does.
        app.configureAgentGoalWakes(systemWakeCenter: NotificationCenter())
        let created = app.startNewAgentSession(inWorkspaceAt: root.path)
        let runtime = try #require(app.runtime(for: created.id))
        runtime.session.titleIsUserSet = true
        runtime.interactionMode = .goal
        runtime.executionAgent = .willDeep
        runtime.managedRouting = nil
        runtime.currentGoal = .init(statement: "Finish the overnight task", checklist: [.init(text: "All records done")])
        runtime.currentPlan = .init(status: .executing, steps: [.init(text: "Process records", status: .inProgress)])
        runtime.messages = [.init(role: .user, content: "Finish the overnight task.", source: .operatorInput)]
        let token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalOutageURLProtocol.self]
        configuration.httpAdditionalHeaders = [GoalOutageURLProtocol.tokenHeader: token]
        let session = URLSession(configuration: configuration)
        app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://goal-outage.invalid/v1",
                                                  model: "gpt-4.1", apiKey: "test-placeholder"), session)
        return .init(app: app, runtime: runtime, root: root, defaults: defaults, suite: suite,
                     token: token, session: session, activity: activity)
    }

    /// One failing turn = the first request plus the Goal lane's in-turn retries.
    static let requestsPerFailingTurn = 1 + AgentTransientRetryLane.goal.maximumRetries

    // MARK: - A1 + A2

    @Test("provider 连续 503：Goal 进入等待而不是结束；到期后重新发起回合")
    func outageParksTheGoalAndResumesWhenDue() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { request in
            if request <= Self.requestsPerFailingTurn { return Self.unavailable }
            return try f.stopFromProvider()
        }

        try await f.runHostTurn()
        let firstTurn = f.provider.turnIDs.first ?? nil

        #expect(f.provider.requests == Self.requestsPerFailingTurn)
        let wake = try #require(f.wake)
        #expect(wake.reason == .providerOutage)
        #expect(wake.attempt == 1)
        #expect(wake.dueAt.timeIntervalSince(wake.scheduledAt) == AgentGoalWakePolicy.firstRetryDelay)
        #expect(wake.failureSummary?.contains("503") == true)
        #expect(f.runtime.currentGoal?.consecutiveTransientFailures == 1)
        // Not an error card, not a stop: a Goal that is still running.
        #expect(f.runtime.lastTurnFailure == nil)
        #expect(!f.runtime.isResponding)
        #expect(f.runtime.goalTurnRecoveryCheckpoint != nil)
        #expect(f.app.isAgentGoalExecutionActive)
        // The wait holds no provider slot, and a timer stands behind it.
        #expect(f.app.inFlightCountByProvider["openai"] == nil)
        #expect(f.runtime.currentProviderSlotClaim == nil)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == wake.id)
        // The Mac stays awake through the wait.
        #expect(f.activity.begins == 1)
        #expect(f.activity.ends == 0)
        #expect(f.app.agentGoalWakeCoordinator.inhibitingRuntimeIDs == [f.runtime.id])
        // Persisted with the Goal, so a relaunch sees the wait. The store
        // encodes dates as ISO 8601 without fractional seconds: once the async
        // write has reached the file, the decoded dates are whole seconds, so
        // compare identity exactly and time to the second.
        let persistedWake = try #require(AgentSessionStore.peekStoredSession(id: f.runtime.id)?.currentGoal?.scheduledWake)
        #expect(persistedWake.id == wake.id)
        #expect(persistedWake.reason == wake.reason)
        #expect(persistedWake.attempt == wake.attempt)
        #expect(persistedWake.instruction == wake.instruction)
        #expect(abs(persistedWake.dueAt.timeIntervalSince(wake.dueAt)) < 1)
        #expect(abs(persistedWake.scheduledAt.timeIntervalSince(wake.scheduledAt)) < 1)

        f.withoutInTurnDelay {
            f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt.addingTimeInterval(1))
        }
        try await f.awaitCurrentTurn()

        #expect(f.provider.requests == Self.requestsPerFailingTurn + 1)
        let retryTurn = f.provider.turnIDs.last ?? nil
        #expect(retryTurn != nil && retryTurn != firstTurn)
        #expect(f.provider.lastUserTexts.last == AgentGoalWakePolicy.providerOutageInstruction)
        #expect(f.runtime.messages.filter(\.isOperatorInput).count == 1)
        #expect(f.wake == nil)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == nil)
        // Stopped by the fixture from inside the retry turn: the Mac may sleep.
        #expect(f.activity.ends == 1)
    }

    @Test("每次重试仍失败时沿 1 / 5 / 15 / 15 分钟升级，直到有回应才归零")
    func repeatedOutageWalksTheLadder() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in Self.unavailable }

        try await f.runHostTurn()
        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            let wake = try #require(f.wake)
            delays.append(wake.dueAt.timeIntervalSince(wake.scheduledAt))
            f.withoutInTurnDelay {
                f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt)
            }
            try await f.awaitCurrentTurn()
        }
        let last = try #require(f.wake)
        delays.append(last.dueAt.timeIntervalSince(last.scheduledAt))

        #expect(delays == [60, 300, 900, 900])
        #expect(last.attempt == 4)
        #expect(f.runtime.currentGoal?.consecutiveTransientFailures == 4)
        #expect(f.provider.requests == 4 * Self.requestsPerFailingTurn)
        #expect(f.runtime.lastTurnFailure == nil)
        #expect(f.runtime.goalTurnRecoveryCheckpoint != nil)
        // One activity for the whole night, never dropped between attempts.
        #expect(f.activity.begins == 1)
        #expect(f.activity.ends == 0)
    }

    @Test("Stop 立即取消等待：不再自动重启，释放防睡眠，并在记录里留下停止")
    func stopCancelsTheWait() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in Self.unavailable }
        try await f.runHostTurn()
        let wake = try #require(f.wake)

        f.app.togglePinnedAgentGoalExecution()

        #expect(f.wake == nil)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == nil)
        #expect(f.runtime.goalTurnRecoveryCheckpoint == nil)
        #expect(f.runtime.messages.last?.transcriptEvent == .responseStopped)
        #expect(!f.app.isAgentGoalExecutionActive)
        #expect(f.activity.ends == 1)
        #expect(AgentSessionStore.peekStoredSession(id: f.runtime.id)?.currentGoal?.scheduledWake == nil)

        // Neither the timer's moment nor a system wake brings it back.
        let requestsAfterStop = f.provider.requests
        f.app.catchUpGoalWakes(rearmPending: true, now: wake.dueAt.addingTimeInterval(3_600))
        f.app.fireGoalWake(runtimeID: f.runtime.id, wakeID: wake.id)
        #expect(f.runtime.requestTask == nil)
        #expect(!f.runtime.isResponding && !f.runtime.isAwaitingProviderSlot)
        #expect(f.provider.requests == requestsAfterStop)
    }

    @Test("用户发新消息取消等待，按正常用户回合走")
    func userMessageCancelsTheWait() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { request in
            if request <= Self.requestsPerFailingTurn { return Self.unavailable }
            return try f.stopFromProvider()
        }
        try await f.runHostTurn()
        #expect(f.wake != nil)

        f.withoutInTurnDelay {
            f.app.dispatchAgentMessage(for: f.runtime, text: "Try the other mirror.", images: [])
        }
        // Cancelled synchronously, before the user's turn reaches the network.
        #expect(f.wake == nil)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == nil)
        try await f.awaitCurrentTurn()

        #expect(f.provider.requests > Self.requestsPerFailingTurn)
        #expect(f.provider.lastUserTexts.last == "Try the other mirror.")
        #expect(f.runtime.messages.filter(\.isOperatorInput).count == 2)
        #expect(!f.runtime.messages.contains { $0.content == AgentGoalWakePolicy.providerOutageInstruction })
    }

    @Test("鉴权失败等非瞬时错误照旧停下，不进入等待")
    func terminalFailureStillStops() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in Self.unauthorized }

        try await f.runHostTurn()

        #expect(f.provider.requests == 1)
        #expect(f.wake == nil)
        #expect(f.runtime.lastTurnFailure != nil)
        #expect(f.runtime.goalTurnRecoveryCheckpoint == nil)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == nil)
        #expect(f.activity.begins == 1)
        #expect(f.activity.ends == 1)
    }

    @Test("墙钟预算已耗尽时不再等待，照旧报错")
    func spentWallClockDoesNotWait() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in Self.unavailable }
        f.runtime.currentGoal?.continuationBudget = .init(wallClockLimit: 1, segmentStartedAt: .distantPast)

        try await f.runHostTurn()
        await f.awaitAllTurns()

        #expect(f.wake == nil)
        #expect(f.runtime.currentGoal?.continuationBudget?.wrapUpDispatched == true)
        #expect(f.activity.ends == f.activity.begins)
    }

    // MARK: - A3

    @Test("第 5 轮无进展真的等 1 分钟再续推；等待期不发请求、不占槽；新回合开始即取消")
    func backoffRungReallyWaits() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in try f.stopFromProvider() }
        f.runtime.currentPlan = .init(status: .done, steps: [.init(text: "Process records", status: .done)])
        // A done Plan inside an executing Goal always carries its planning
        // ledger; without it the resumed turn would restart Goal Teams.
        let goal = try #require(f.runtime.currentGoal)
        f.runtime.goalPlanningState = AgentGoalPlanningState(
            goalFingerprint: AgentGoalPlanningState.fingerprint(for: goal), phase: .executing, members: []
        )
        f.runtime.consecutiveGoalRoundsWithoutChecklistProgress = AgentGoalContinuationPolicy.reconcileRounds

        f.app.prepareNextAgentGoalPlanningCycleIfNeeded(for: f.runtime, didAdvanceChecklist: false)

        let wake = try #require(f.wake)
        #expect(wake.reason == .noProgressBackoff)
        #expect(wake.attempt == 1)
        #expect(wake.dueAt.timeIntervalSince(wake.scheduledAt) == AgentGoalWakePolicy.firstRetryDelay)
        #expect(wake.instruction.contains("Goal acceptance is still incomplete"))
        #expect(f.provider.requests == 0)
        #expect(f.runtime.requestTask == nil && f.runtime.queuedMessages.isEmpty)
        #expect(f.app.inFlightCountByProvider["openai"] == nil)
        #expect(f.activity.begins == 1)

        // Due: the stored continuation goes out as a host instruction.
        f.app.catchUpGoalWakes(rearmPending: false, now: wake.dueAt)
        try await f.awaitCurrentTurn()
        #expect(f.provider.requests == 1)
        #expect(f.provider.lastUserTexts.last == wake.instruction)
        #expect(f.wake == nil)

        // Round 7: backoff 3 = 15 minutes; a turn starting any other way
        // (here Retry, the same entry a background completion uses) cancels it.
        f.runtime.consecutiveGoalRoundsWithoutChecklistProgress = AgentGoalContinuationPolicy.reconcileRounds + 2
        f.app.prepareNextAgentGoalPlanningCycleIfNeeded(for: f.runtime, didAdvanceChecklist: false)
        let third = try #require(f.wake)
        #expect(third.attempt == 3)
        #expect(third.dueAt.timeIntervalSince(third.scheduledAt) == AgentGoalWakePolicy.maximumRetryDelay)
        f.app.retryLastAgentTurn()
        try await f.awaitCurrentTurn()
        #expect(f.wake == nil)
        #expect(f.provider.requests == 2)
    }

    // MARK: - Relaunch and system wake

    @Test("系统唤醒：已到期的等待立即补跑且只补一次，未到期的按余量重挂")
    func systemWakeCatchUpFiresOnce() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.install { _ in try f.stopFromProvider() }
        let center = NotificationCenter()
        f.app.configureAgentGoalWakes(systemWakeCenter: center)
        let gate = AgentGoalTestSleepGate()
        f.app.agentGoalWakeCoordinator.sleeper = { await gate.sleep($0) }

        // Not due yet: re-armed on what is actually left, nothing dispatched.
        let later = AgentGoalWakePolicy.makeWake(
            reason: .noProgressBackoff, attempt: 3, now: Date(), instruction: "Resume after backoff."
        )
        f.app.scheduleGoalWake(later, for: f.runtime)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(f.wake == later)
        #expect(f.app.agentGoalWakeCoordinator.armedWakeID(for: f.runtime.id) == later.id)
        #expect(f.runtime.requestTask == nil)

        // Slept past the due time: fires on wake, exactly once.
        let overdue = AgentGoalWakePolicy.makeWake(
            reason: .providerOutage, attempt: 2, now: Date().addingTimeInterval(-3_600),
            instruction: AgentGoalWakePolicy.providerOutageInstruction
        )
        f.app.scheduleGoalWake(overdue, for: f.runtime)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let turn = try #require(f.runtime.requestTask)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(f.runtime.requestTask == turn)
        await turn.value
        #expect(f.provider.requests == 1)
        #expect(f.wake == nil)
        await gate.release(4)
    }

    @Test("重启恢复：等待中的 Goal 不当异常处理——未到期重新挂起，已到期恢复续推")
    func launchRestoresTheWait() throws {
        let goal = AgentGoal(statement: "Recover overnight", checklist: [.init(text: "Verified")])
        let plan = AgentPlan(status: .executing, steps: [.init(text: "Existing work", status: .inProgress)], summary: "")
        func session(dueIn seconds: TimeInterval) -> AgentSession {
            var waiting = goal
            waiting.scheduledWake = AgentGoalScheduledWake(
                reason: .providerOutage, attempt: 2, scheduledAt: Date().addingTimeInterval(seconds - 300),
                dueAt: Date().addingTimeInterval(seconds), instruction: AgentGoalWakePolicy.providerOutageInstruction
            )
            return AgentSession(interactionMode: .goal, currentPlan: plan, currentGoal: waiting,
                                goalTurnRecoveryCheckpoint: AgentGoalTurnRecoveryCheckpoint())
        }

        // The wait outranks the checkpoint it keeps as a crash backstop.
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: session(dueIn: 60)) == .restoreScheduledWake)
        var completed = session(dueIn: 60)
        completed.currentGoal?.checklist[0].done = true
        #expect(AgentGoalLaunchRecoveryPolicy.action(for: completed) == .discardStaleCheckpoint)

        for (dueIn, expectsDispatch) in [(TimeInterval(600), false), (-60, true)] {
            let app = AppState(runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
                               loadSessionCatalog: false)
            let activity = AgentGoalActivityCounter()
            app.agentGoalWakeCoordinator.sleepInhibitor = activity.makeInhibitor()
            let catalog = session(dueIn: dueIn)
            app.agentSessions = [catalog]
            app.markSessionCatalogLoadedForTesting()
            let network = URLSession(configuration: .ephemeral)
            app.agentLoopInferenceEnvironment = (.init(providerID: "openai", baseURL: "https://goal-launch.invalid/v1",
                model: "fixture", apiKey: "test-placeholder"), network)
            // Recovery must land in the real dispatch queue, never on the network.
            app.inFlightCountByProvider["openai"] = app.perProviderConcurrencyLimit + 1
            let runtime = try #require(app.runtime(for: catalog.id))
            defer {
                app.cancelPendingGoalLaunchRecovery(for: runtime)
                app.agentGoalWakeCoordinator.disarm(runtimeID: runtime.id)
                app.pendingDispatchQueue.removeAll()
                network.invalidateAndCancel()
                AgentSessionStore.delete(id: runtime.id)
            }

            let resumed = app.resumeInterruptedGoalSessionsAfterLaunch()

            if expectsDispatch {
                #expect(resumed == [runtime.id])
                #expect(runtime.currentGoal?.scheduledWake == nil)
                #expect(app.pendingDispatchQueue.count == 1)
                #expect(app.pendingDispatchQueue.first?.text == AgentGoalWakePolicy.providerOutageInstruction)
            } else {
                #expect(resumed.isEmpty)
                #expect(runtime.currentGoal?.scheduledWake == catalog.currentGoal?.scheduledWake)
                #expect(app.agentGoalWakeCoordinator.armedWakeID(for: runtime.id) == catalog.currentGoal?.scheduledWake?.id)
                #expect(app.pendingDispatchQueue.isEmpty)
                #expect(runtime.goalTurnRecoveryCheckpoint != nil)
            }
            #expect(activity.begins == 1)
        }
    }
}
