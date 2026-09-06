import Foundation
import Testing
@testable import WillDeep

/// Fails every request it is given, with no network and no waiting.
///
/// A `.invalid` hostname is the usual shortcut for "make this request fail",
/// but this machine runs a system-wide proxy, and a proxy may accept the
/// connection and take its own time to give up. A protocol stub fails on the
/// spot and fails the same way on every machine.
nonisolated final class IdleResumeFailingURLProtocol: URLProtocol, @unchecked Sendable {
    static let tokenHeader = "X-Idle-Resume-Fixture"
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func install(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        counts[token] = 0
    }

    static func remove(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        counts[token] = nil
    }

    static func requestCount(_ token: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[token] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let token = request.value(forHTTPHeaderField: Self.tokenHeader) {
            Self.lock.lock()
            Self.counts[token, default: 0] += 1
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

    override func stopLoading() {}
}

/// Two claims from the runtime kernel's CHANGELOG that had no end-to-end cover.
///
/// The first is that a turn which dies on a transport failure — not a
/// cancellation, the other half of the promise — puts its leased events back.
/// The second is that every idle-resume path consults one automatic wake
/// policy, rather than each call site deciding for itself whether to start a
/// turn. Both were held only by tests that called the kernel directly, which
/// cannot show that anything in the app calls it.
@Suite(.serialized)
struct AgentKernelIdleResumeTests {
    @MainActor
    private struct Fixture {
        let app: AppState
        let kernel: AgentRuntimeKernel
        let runtime: AgentRuntime
        let sessionID: UUID
        let token: String
        let session: URLSession

        func cleanup() {
            app.stopAgentResponse(for: runtime)
            session.invalidateAndCancel()
            IdleResumeFailingURLProtocol.remove(token)
            app.agentLoopInferenceEnvironment = nil
            AgentSessionStore.delete(id: sessionID)
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let app = AppState(runtimeKernel: kernel, loadSessionCatalog: false)
        let session = app.startNewAgentSession()
        let runtime = try #require(app.agentRuntimes[session.id])

        let token = UUID().uuidString
        IdleResumeFailingURLProtocol.install(token)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IdleResumeFailingURLProtocol.self]
        sessionConfiguration.httpAdditionalHeaders = [
            IdleResumeFailingURLProtocol.tokenHeader: token
        ]
        let urlSession = URLSession(configuration: sessionConfiguration)
        app.agentLoopInferenceEnvironment = (
            AgentConfiguration(
                providerID: "openai",
                baseURL: "https://idle-resume.invalid/v1",
                model: "gpt-4.1",
                apiKey: "test-placeholder"
            ),
            urlSession
        )
        return Fixture(
            app: app,
            kernel: kernel,
            runtime: runtime,
            sessionID: session.id,
            token: token,
            session: urlSession
        )
    }

    /// The cancellation half of this promise is covered in
    /// `AgentRuntimeKernelTests`. This is the transport half: the provider
    /// request fails, the turn unwinds through a different path, and the lease
    /// still has to come back — otherwise the event stays invisible to every
    /// wake-up probe until the app restarts.
    @Test("a turn that dies on a transport failure puts its leased events back")
    @MainActor
    func transportFailureReleasesLeaseThroughRunAgentLoop() async throws {
        let f = try makeFixture()
        defer { f.cleanup() }

        // Busy first, then publish: a host event on an idle runtime is what the
        // automatic wake policy is for, and it would start a turn of its own.
        let turnID = UUID()
        f.runtime.isResponding = true
        f.runtime.activeTurnID = turnID
        f.app.publishHostAgentEvent(
            runtimeID: f.sessionID,
            kind: .hostNotice,
            title: "leased across a failed request",
            payload: "the transport dropped"
        )
        f.runtime.messages.append(
            AgentMessage(role: .user, content: "go", source: .operatorInput)
        )
        let publishedAt = try #require(
            f.kernel.events.first { $0.runtimeID == f.sessionID }?.updatedAt
        )

        await f.app.runAgentLoop(
            for: f.runtime,
            configuration: AgentConfiguration(
                providerID: "openai",
                baseURL: "https://idle-resume.invalid/v1",
                model: "gpt-4.1",
                apiKey: "test-placeholder"
            ),
            providerSlotClaimID: UUID(),
            turnID: turnID
        )
        f.runtime.isResponding = false
        f.runtime.requestTask = nil

        #expect(
            IdleResumeFailingURLProtocol.requestCount(f.token) > 0,
            "no request was attempted, so no transport could have failed"
        )
        #expect(f.kernel.leasedModelEventIDs(for: f.sessionID).isEmpty)
        #expect(f.kernel.pendingModelEventCount(for: f.sessionID) == 1)
        let restored = try #require(f.kernel.events.first { $0.runtimeID == f.sessionID })
        #expect(restored.deliveredAt == nil)
        // Without this the test would also pass if the turn never leased the
        // event at all: an untouched event is pending and undelivered too.
        #expect(
            restored.updatedAt > publishedAt,
            "the turn never leased the event, so nothing was released"
        )
    }

    /// Slot release is one of the three idle-resume call sites. An untrusted
    /// event must never buy a turn there: unauthenticated senders would
    /// otherwise be able to spend the user's provider quota by arriving at the
    /// moment a slot frees up.
    @Test("releasing a provider slot does not wake an idle runtime for an untrusted event")
    @MainActor
    func slotReleaseHonoursTheWakePolicy() throws {
        let f = try makeFixture()
        defer { f.cleanup() }

        _ = f.app.receiveExternalAgentEvent(
            AgentExternalEventIngress(
                runtimeID: f.sessionID,
                source: .webhook,
                kind: "push",
                title: "untrusted",
                body: "nobody authenticated this",
                authenticated: false
            )
        )
        #expect(f.kernel.pendingModelEventCount(for: f.sessionID) == 1)

        f.app.releaseProviderSlot(providerID: "openai")

        #expect(!f.runtime.isResponding, "an untrusted event started a turn")
        #expect(f.runtime.requestTask == nil)
        #expect(f.kernel.pendingModelEventCount(for: f.sessionID) == 1)
    }

    /// The compression site calls exactly this function once compression
    /// resolves. Driving the whole compression flow would need a provider and
    /// a full context window; what has to hold either way is that the resume
    /// itself asks the policy rather than starting a turn on sight.
    @Test("the post-compression resume does not wake an idle runtime for an untrusted event")
    @MainActor
    func compressionResumeHonoursTheWakePolicy() throws {
        let f = try makeFixture()
        defer { f.cleanup() }

        _ = f.app.receiveExternalAgentEvent(
            AgentExternalEventIngress(
                runtimeID: f.sessionID,
                source: .email,
                kind: "message",
                title: "untrusted mail",
                body: "no credentials were presented",
                authenticated: false
            )
        )

        f.app.resumeAgentLoopForPendingBackgroundCompletions(for: f.runtime)

        #expect(!f.runtime.isResponding)
        #expect(f.kernel.pendingModelEventCount(for: f.sessionID) == 1)
    }

    /// The negative tests above would all pass if idle resume were simply
    /// broken. This is the control: the same paths, a host-trust event, and a
    /// turn that does start.
    @Test("a host event still wakes an idle runtime through the same path")
    @MainActor
    func hostEventStillWakesTheRuntime() async throws {
        let f = try makeFixture()
        defer { f.cleanup() }

        f.app.publishHostAgentEvent(
            runtimeID: f.sessionID,
            kind: .workerCompleted,
            title: "worker done",
            payload: "report"
        )

        var woke = f.runtime.isResponding
        for _ in 0..<200 where !woke {
            await Task.yield()
            woke = f.runtime.isResponding || f.runtime.requestTask != nil
        }
        #expect(woke, "a host event no longer wakes an idle runtime")

        if let task = f.runtime.requestTask {
            task.cancel()
            await task.value
        }
        f.runtime.isResponding = false
        f.runtime.requestTask = nil
    }
}
