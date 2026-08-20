import Foundation
import Testing
@testable import WillDeep

/// The reported path: a daily routine fired at 22:00 into a dead network, the
/// provider request failed in 3ms, and the next morning the conversation read
/// as one user message with no reply at all — no error, no spinner, nothing.
///
/// Two defects produced that silence and both are pinned here.
///
///   1. The failure lived only on `AgentRuntime` (`@Published` state) while the
///      turn loop deleted the empty assistant message, so the persisted session
///      kept no evidence whatsoever. Restarting the app erased the only record.
///   2. Transient-network self-recovery was gated on Goal mode, so an
///      unattended routine got exactly one attempt and no retry.
@Suite
@MainActor
struct AgentUnattendedTurnFailureTests {
    private let workspace = "/Users/rocky/Sites/muchtoken"

    private func routineSession(
        messages: [AgentMessage] = [AgentMessage(role: .user, content: "检查线上日志")]
    ) -> AgentSession {
        var session = AgentSession.forRoutineRun(
            routineID: UUID(),
            workspaceRootPath: workspace,
            modelID: "glm-5",
            providerEntryID: UUID(),
            providerID: "some-im",
            providerDisplayName: "some.im"
        )
        session.messages = messages
        return session
    }

    private func interactiveSession(
        interactionMode: AgentInteractionMode = .normal,
        messages: [AgentMessage] = [AgentMessage(role: .user, content: "检查线上日志")]
    ) -> AgentSession {
        AgentSession(
            workspaceRootPath: workspace,
            messages: messages,
            interactionMode: interactionMode
        )
    }

    // MARK: - 1. The failure has to reach disk

    @Test("a routine run is born marked unattended")
    func routineRunIsMarkedUnattended() {
        let routineID = UUID()
        let session = AgentSession.forRoutineRun(
            routineID: routineID,
            workspaceRootPath: workspace,
            modelID: nil,
            providerEntryID: nil,
            providerID: nil,
            providerDisplayName: nil
        )

        #expect(session.originRoutineID == routineID)
        #expect(AgentRuntime(session: session).isUnattendedRun)
        // A conversation the user started themselves must not inherit the
        // unattended behaviour — the human is right there to click 重试.
        #expect(!AgentRuntime(session: interactiveSession()).isUnattendedRun)
    }

    @Test("a persisted failure survives an encode/decode round trip")
    func failureRoundTripsThroughSessionJSON() throws {
        var session = routineSession()
        session.lastTurnFailure = AgentTurnFailure(
            message: "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。",
            detailSections: [.init(title: "Request", text: "Provider: some-im")],
            requiresSomeIMLogin: false,
            occurredAt: Date(timeIntervalSince1970: 1_787_000_000)
        )

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)

        #expect(restored.lastTurnFailure == session.lastTurnFailure)
        #expect(restored.originRoutineID == session.originRoutineID)
    }

    @Test("sessions written before this feature still decode")
    func legacySessionJSONStillDecodes() throws {
        // Neither key exists in any file on disk today. A session that cannot
        // be read is a conversation the user loses, so this is the one
        // compatibility case that must never regress.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "旧会话",
          "createdAt": 770000000,
          "updatedAt": 770000000,
          "messages": []
        }
        """
        let decoder = JSONDecoder()
        let restored = try decoder.decode(AgentSession.self, from: Data(json.utf8))

        #expect(restored.originRoutineID == nil)
        #expect(restored.lastTurnFailure == nil)
    }

    @Test("a malformed failure snapshot never costs the user the transcript")
    func malformedFailureSnapshotIsToleratedNotFatal() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "坏快照",
          "createdAt": 770000000,
          "updatedAt": 770000000,
          "messages": [],
          "lastTurnFailure": { "unexpected": true }
        }
        """
        let restored = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))

        #expect(restored.lastTurnFailure == nil)
        #expect(restored.title == "坏快照")
    }

    @Test("reopening a failed conversation restores its error card")
    func runtimeRestoresBannerFromPersistedFailure() {
        var session = routineSession()
        session.lastTurnFailure = AgentTurnFailure(
            message: "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。",
            detailSections: [.init(title: "Request", text: "Provider: some-im")]
        )

        let runtime = AgentRuntime(session: session)

        #expect(runtime.errorMessage == "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。")
        #expect(runtime.errorSeverity == .error)
        #expect(runtime.errorDetails?.sections.first?.title == "Request")
        #expect(!runtime.errorRequiresSomeIMLogin)
    }

    @Test("a restored some.im gate keeps its login affordance")
    func runtimeRestoresSomeIMLoginFlag() {
        var session = routineSession()
        session.lastTurnFailure = AgentTurnFailure(
            message: "some.im 未登录",
            requiresSomeIMLogin: true
        )

        let runtime = AgentRuntime(session: session)

        #expect(runtime.errorRequiresSomeIMLogin)
        #expect(runtime.errorDetails == nil, "a failure with no sections must not fabricate an empty 详情 disclosure")
    }

    @Test("a healthy conversation restores with no banner")
    func runtimeWithoutFailureRestoresClean() {
        let runtime = AgentRuntime(session: routineSession())

        #expect(runtime.errorMessage == nil)
        #expect(runtime.lastTurnFailure == nil)
    }

    @Test("setAgentError records a durable failure, and clearing removes it")
    func setAgentErrorPersistsAndClears() {
        let appState = AppState()
        let runtime = AgentRuntime(session: routineSession())

        appState.setAgentError(URLError(.notConnectedToInternet), for: runtime)
        #expect(runtime.lastTurnFailure != nil)
        #expect(runtime.lastTurnFailure?.message == runtime.errorMessage)

        // Persisting has to carry it onto the session, or the whole mechanism
        // stops at the runtime it was trying to outlive.
        runtime.persist()
        #expect(runtime.session.lastTurnFailure?.message == runtime.errorMessage)

        runtime.clearTurnError()
        runtime.persist()
        #expect(runtime.errorMessage == nil)
        #expect(runtime.lastTurnFailure == nil)
        #expect(runtime.session.lastTurnFailure == nil)
    }

    @Test("persisted details are trimmed to banner size")
    func persistedDetailSectionsAreTruncated() {
        // A real provider error carries the whole request body. Persisting it
        // verbatim would re-encode megabytes into the session file on every
        // later persist.
        let huge = String(repeating: "x", count: 200_000)
        let details = AgentErrorDetails(sections: [
            .init(title: "Request Body", text: huge)
        ])

        let persisted = AppState.persistableDetailSections(from: details)

        #expect(persisted.count == 1)
        #expect(persisted[0].title == "Request Body")
        #expect(persisted[0].text.count <= AppState.persistedDetailSectionCharacterLimit)
        #expect(AppState.persistableDetailSections(from: nil).isEmpty)
    }

    // MARK: - 2. Unattended runs recover on their own

    @Test("retry lanes follow who is watching the conversation")
    func retryLaneSelection() {
        let appState = AppState()

        #expect(appState.transientNetworkRetryLane(
            for: AgentRuntime(session: routineSession())
        ) == .unattended)

        var dispatchSession = interactiveSession()
        dispatchSession.dispatchTaskID = UUID()
        #expect(appState.transientNetworkRetryLane(
            for: AgentRuntime(session: dispatchSession)
        ) == .unattended)

        #expect(appState.transientNetworkRetryLane(
            for: AgentRuntime(session: interactiveSession(interactionMode: .goal))
        ) == .goal)

        // The regression that made the report possible: an ordinary chat is
        // the only lane with a human on it, and it stays retry-free on purpose.
        #expect(appState.transientNetworkRetryLane(
            for: AgentRuntime(session: interactiveSession())
        ) == nil)
    }

    @Test("an offline routine turn retries instead of going quiet")
    func offlineRoutineTurnIsRetried() {
        let appState = AppState()
        let assistant = AgentMessage(role: .assistant, content: "")
        let runtime = AgentRuntime(session: routineSession(messages: [
            AgentMessage(role: .user, content: "检查线上日志"),
            assistant,
        ]))

        #expect(appState.shouldRetryTransientNetworkError(
            URLError(.notConnectedToInternet),
            for: runtime,
            assistantID: assistant.id,
            retryCount: 0
        ), "the 22:00 run got exactly one attempt against a dead network and then went silent")
    }

    @Test("an ordinary chat still surfaces the error immediately")
    func interactiveTurnIsNotRetried() {
        let appState = AppState()
        let assistant = AgentMessage(role: .assistant, content: "")
        let runtime = AgentRuntime(session: interactiveSession(messages: [
            AgentMessage(role: .user, content: "检查线上日志"),
            assistant,
        ]))

        #expect(!appState.shouldRetryTransientNetworkError(
            URLError(.notConnectedToInternet),
            for: runtime,
            assistantID: assistant.id,
            retryCount: 0
        ))
    }

    @Test("a turn that already produced output is never replayed")
    func partiallyStreamedTurnIsNotRetried() {
        let appState = AppState()
        let assistant = AgentMessage(role: .assistant, content: "已经登陆服务器，开始看 journalctl")
        let runtime = AgentRuntime(session: routineSession(messages: [
            AgentMessage(role: .user, content: "检查线上日志"),
            assistant,
        ]))

        #expect(!appState.shouldRetryTransientNetworkError(
            URLError(.networkConnectionLost),
            for: runtime,
            assistantID: assistant.id,
            retryCount: 0
        ), "replaying a turn whose side effects already started would run them twice")
    }

    @Test("unattended retries are bounded")
    func unattendedRetriesStopAtTheLaneLimit() {
        let appState = AppState()
        let assistant = AgentMessage(role: .assistant, content: "")
        let runtime = AgentRuntime(session: routineSession(messages: [
            AgentMessage(role: .user, content: "检查线上日志"),
            assistant,
        ]))
        let limit = AgentTransientRetryLane.unattended.maximumRetries

        #expect(appState.shouldRetryTransientNetworkError(
            URLError(.notConnectedToInternet),
            for: runtime,
            assistantID: assistant.id,
            retryCount: limit - 1
        ))
        #expect(!appState.shouldRetryTransientNetworkError(
            URLError(.notConnectedToInternet),
            for: runtime,
            assistantID: assistant.id,
            retryCount: limit
        ))
    }

    @Test("a non-transient failure is reported, not retried")
    func permanentFailureIsNotRetried() {
        let appState = AppState()
        let assistant = AgentMessage(role: .assistant, content: "")
        let runtime = AgentRuntime(session: routineSession(messages: [
            AgentMessage(role: .user, content: "检查线上日志"),
            assistant,
        ]))

        #expect(!appState.shouldRetryTransientNetworkError(
            AgentClientError.missingAPIKey,
            for: runtime,
            assistantID: assistant.id,
            retryCount: 0
        ))
    }

    @Test("the unattended backoff grows and covers minutes, not seconds")
    func unattendedBackoffSchedule() {
        let lane = AgentTransientRetryLane.unattended
        let delays = (1...lane.maximumRetries).map { lane.delayNanoseconds(attempt: $0) }

        #expect(delays == delays.sorted(), "backoff must never shrink between attempts")
        #expect(delays.first == 5_000_000_000, "the first retry should be cheap enough to catch a Wi-Fi roam")

        let totalSeconds = delays.reduce(0, +) / 1_000_000_000
        #expect(totalSeconds >= 240, "a schedule shorter than ~4 minutes misses the common proxy/VPN restart")
        // The turn holds a provider concurrency slot while it sleeps, so the
        // window is deliberately capped rather than open-ended.
        #expect(totalSeconds <= 420)

        // Out-of-range attempts clamp instead of trapping.
        #expect(lane.delayNanoseconds(attempt: 0) == delays.first)
        #expect(lane.delayNanoseconds(attempt: 99) == delays.last)

        // Goal mode keeps its original seconds-scale flat delay.
        #expect(AgentTransientRetryLane.goal.delayNanoseconds(attempt: 1) == 3_000_000_000)
        #expect(AgentTransientRetryLane.goal.delayNanoseconds(attempt: 4) == 3_000_000_000)
    }

    @Test("TLS flapping keeps its own delay regardless of lane")
    func tlsHandshakeKeepsItsOwnDelay() {
        let appState = AppState()
        let runtime = AgentRuntime(session: routineSession())

        #expect(appState.transientRetryDelayNanoseconds(
            for: URLError(.secureConnectionFailed),
            runtime: runtime,
            attempt: 3
        ) == AppState.tlsHandshakeRetryDelayNanoseconds)

        #expect(appState.transientRetryDelayNanoseconds(
            for: URLError(.notConnectedToInternet),
            runtime: runtime,
            attempt: 3
        ) == AgentTransientRetryLane.unattended.delayNanoseconds(attempt: 3))
    }
}
