import WillDeepCore
import Combine
import Foundation

nonisolated enum AgentDaemonRecoveryPolicy {
    static let fastDelays: [Duration] = [.zero, .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)]
    static let slowDelay: Duration = .seconds(30)
    static let minimumSlowDelay: Duration = .milliseconds(1)
    static let progressObservationWindow: Duration = .seconds(30)
    static let cleanupWindow: Duration = .seconds(60)
}

nonisolated enum AgentDaemonStartResolutionError: Error { case notStarted }

/// Owns the only status/cancellation loop for one accepted remote job.
/// Transport recovery never creates another remote process or model turn.
@MainActor
final class AgentDaemonJobMonitor {
    typealias Stream = @Sendable (AgentDaemonEventCursorStore) async throws -> Int32
    typealias Lookup = @Sendable () async throws -> Int32?
    typealias Cancel = @Sendable () async throws -> Bool
    private weak var registry: AgentJobRegistry?
    private let jobID: UUID
    private let stream: Stream
    private let lookup: Lookup
    private let cancelRemote: Cancel
    private let describeError: @Sendable (Error) -> String
    private let persistTerminal: @MainActor (Int32?) throws -> Void
    private let fastDelays: [Duration]
    private let slowDelay: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async throws -> Void
    private var deadline: ContinuousClock.Instant
    private let cursor = AgentDaemonEventCursorStore()
    private var observer: AnyCancellable?
    private var streamTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Error>?
    private var started = false
    private var stopped = false
    private var blocked = false
    private var wantsCancellation = false
    private var cancellationAcknowledged = false
    private var streamProtocolFailed = false
    private var recoveryAttempt = 0

    init(registry: AgentJobRegistry, jobID: UUID, monitoringDuration: Duration,
        fastDelays: [Duration], slowDelay: Duration = AgentDaemonRecoveryPolicy.slowDelay,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        stream: @escaping Stream, lookup: @escaping Lookup, cancel: @escaping Cancel,
        describeError: @escaping @Sendable (Error) -> String,
        persistTerminal: @escaping @MainActor (Int32?) throws -> Void = { _ in }) {
        self.registry = registry; self.jobID = jobID
        self.stream = stream; self.lookup = lookup; self.cancelRemote = cancel
        self.describeError = describeError; self.fastDelays = fastDelays
        self.slowDelay = max(AgentDaemonRecoveryPolicy.minimumSlowDelay, slowDelay)
        self.now = now; self.sleep = sleep
        self.deadline = now().advanced(by: monitoringDuration)
        self.persistTerminal = persistTerminal
    }

    func start() {
        guard !started, !stopped, let registry else { return }
        started = true
        let token = registry.$jobs.sink { [weak self] jobs in
            guard let self else { return }
            if jobs.first(where: { $0.id == self.jobID })?.isAlive != true { self.stop() }
        }
        if stopped { token.cancel(); return }
        observer = token
        launchStream()
        if wantsCancellation { startRecovery() }
    }

    func requestCancellation() {
        guard !stopped else { return }
        wantsCancellation = true
        if blocked {
            // An explicit retry can reopen cleanup, not the command itself.
            blocked = false
            recoveryAttempt = 0
            deadline = now().advanced(by: AgentDaemonRecoveryPolicy.cleanupWindow)
        }
        sleepTask?.cancel() // Wake the existing owner; never fork another loop.
        if started { startRecovery() }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        observer?.cancel(); observer = nil
        sleepTask?.cancel()
        recoveryTask?.cancel()
        streamTask?.cancel()
    }

    private func launchStream() {
        guard !stopped, !blocked, streamTask == nil else { return }
        let began = now(), initialCursor = cursor.load().after
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await stream(cursor)
                guard !stopped, !Task.isCancelled else { return }
                finish(code: code, outputMayBeMissing: false)
            } catch {
                streamTask = nil
                guard !stopped, !Task.isCancelled else { return }
                if error is AgentDaemonEventCursor.ProtocolFailure { streamProtocolFailed = true }
                // A 200/empty stream must not reset backoff indefinitely.
                if began.duration(to: now()) >= AgentDaemonRecoveryPolicy.progressObservationWindow,
                   cursor.load().after > initialCursor {
                    recoveryAttempt = 0
                }
                startRecovery()
            }
        }
    }

    private func startRecovery() {
        guard started, !stopped, !blocked, recoveryTask == nil else { return }
        registry?.recordRemoteRecovery(id: jobID, recovering: true)
        recoveryTask = Task { [weak self] in await self?.recover() }
    }

    private func recover() async {
        defer { recoveryTask = nil }
        while !stopped, !blocked, !Task.isCancelled {
            guard registry?.job(id: jobID)?.isAlive == true else { stop(); return }
            guard now() < deadline else { fail(L10n.JobReceipt.unconfirmed); return }
            let delay = recoveryAttempt < fastDelays.count ? fastDelays[recoveryAttempt] : slowDelay
            await wait(min(delay, now().duration(to: deadline)))
            guard !stopped, !blocked, !Task.isCancelled else { return }
            guard now() < deadline else { fail(L10n.JobReceipt.unconfirmed); return }
            recoveryAttempt += 1
            do {
                let code = try await lookup()
                try Task.checkCancellation()
                if let code { finish(code: code, outputMayBeMissing: true); return }
                if wantsCancellation, !cancellationAcknowledged {
                    cancellationAcknowledged = try await cancelRemote()
                    try Task.checkCancellation()
                }
                if !wantsCancellation, !streamProtocolFailed,
                   streamTask == nil, cursor.load().canResume {
                    launchStream()
                    return
                }
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                if case AgentDaemonStartResolutionError.notStarted = error {
                    do {
                        try persistTerminal(nil)
                        registry?.finishManagedExecutorWithoutLaunch(id: jobID)
                        stop()
                    } catch { fail(describeError(error)) }
                    return
                }
                if Self.isPermanent(error) { fail(describeError(error)); return }
            }
            registry?.recordRemoteRecovery(id: jobID, recovering: true)
        }
    }

    private func wait(_ delay: Duration) async {
        let task = Task { try await sleep(delay) }
        sleepTask = task
        defer { sleepTask = nil }
        do { try await task.value }
        catch {
            // Only cancellation is an expected wake-up, never a sleep failure.
            if !(error is CancellationError), !stopped, !Task.isCancelled { fail(describeError(error)) }
        }
    }

    private func finish(code: Int32, outputMayBeMissing: Bool) {
        guard !stopped, let registry, registry.job(id: jobID)?.isAlive == true else { stop(); return }
        do { try persistTerminal(code) }
        catch { fail(describeError(error)); return }
        if outputMayBeMissing {
            registry.recordManagedExecutorEvents(id: jobID,
                events: [AgentExecutorEvent(kind: .warning, detail: L10n.JobReceipt.outputGap, status: .running)])
        }
        registry.finishManagedExecutor(id: jobID, status: code == 0 ? .completed : .failed,
            exitCode: code, exitConfirmed: true)
        stop()
    }

    private func fail(_ detail: String) {
        blocked = true
        registry?.recordRemoteMonitoringFailure(id: jobID, detail: detail)
    }

    private static func isPermanent(_ error: Error) -> Bool {
        if error is AgentDaemonEventCursor.ProtocolFailure { return true }
        if case AgentJobError.jobNotFound = error { return true }
        if case AgentToolError.httpFailed(let code, _) = error {
            return (400..<500).contains(code) && code != 408 && code != 429
        }
        guard let urlError = error as? URLError else { return false }
        return [.badURL, .unsupportedURL, .userAuthenticationRequired,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection].contains(urlError.code)
    }
}
