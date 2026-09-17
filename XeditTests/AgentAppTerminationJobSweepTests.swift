//
//  AgentAppTerminationJobSweepTests.swift
//  XeditTests
//
//  Quitting the app must not leave its background jobs running. Before this
//  sweep existed, `applicationShouldTerminate` only flushed stores, so every
//  alive `run_command` child was reparented to launchd and kept its port, its
//  rebuild loop and its CPU — invisible, because the only UI that listed them
//  died with the app.
//
//  Two things are worth locking down here and they fail differently: the
//  *policy* (which jobs the sweep claims) is pure and cheap to assert, while
//  the *mechanics* (SIGTERM, then SIGKILL for whatever ignored it) only mean
//  anything against real processes. Both are covered below, the second with
//  real `/bin/sh` children like the rest of the job-registry suite.
//

import Darwin
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentAppTerminationJobSweepTests {

    // MARK: - Policy

    /// An in-process job is swept whatever its lifetime — `.persistent`
    /// included. Lifetime means "outlives the turn"; only a job that actually
    /// detached is re-adopted by the next launch, so sparing any other one
    /// strands it forever.
    @Test
    func everyAliveLocalLifetimeIsSweptIncludingPersistent() {
        for lifetime in AgentBackgroundJobLifetime.allCases {
            let job = makeStubJob(status: .running, lifetime: lifetime)
            #expect(
                AgentAppTerminationJobSweep.shouldTerminateOnQuit(job),
                "lifetime \(lifetime.rawValue) was skipped by the quit sweep"
            )
        }
    }

    /// Contract「C·三」: a detached `.persistent` job keeps running after quit
    /// and is re-adopted on the next launch; the sweep must leave it alone.
    @Test
    func detachedPersistentJobIsNotSwept() {
        var detached = makeStubJob(status: .running, lifetime: .persistent)
        detached.isDetached = true
        #expect(!AgentAppTerminationJobSweep.shouldTerminateOnQuit(detached))
    }

    @Test
    func finishedJobsAreNotSwept() {
        for status in [
            AgentBackgroundJob.Status.completed,
            .failed,
            .killed,
            .timedOut,
            .launchFailed,
        ] {
            let job = makeStubJob(status: status)
            #expect(!AgentAppTerminationJobSweep.shouldTerminateOnQuit(job))
        }
    }

    /// Remote daemon work does not run on this machine, so quitting orphans
    /// nothing — and its exit receipt is how the next launch recovers the
    /// result. Cancelling it on quit would throw that evidence away.
    @Test
    func remoteDaemonJobsSurviveTheQuitSweep() {
        let remote = makeStubJob(status: .running, remoteRuntimeID: UUID())
        #expect(!AgentAppTerminationJobSweep.shouldTerminateOnQuit(remote))

        let awaitingReceipt = makeStubJob(status: .running, requiresExitReceipt: true)
        #expect(!AgentAppTerminationJobSweep.shouldTerminateOnQuit(awaitingReceipt))
    }

    // MARK: - Grace accounting

    /// The flush and the grace period run concurrently: whatever the flush
    /// already spent is deducted, so a quit whose disk work outlasted the
    /// grace period waits no further.
    @Test
    func graceIsMeasuredFromTheSignalNotFromTheEscalation() {
        let signaled = Date(timeIntervalSinceReferenceDate: 1_000)
        let grace = AgentAppTerminationJobSweep.gracePeriod

        #expect(
            AgentAppTerminationJobSweep.remainingGrace(startedAt: signaled, now: signaled) == grace
        )
        #expect(
            AgentAppTerminationJobSweep.remainingGrace(
                startedAt: signaled,
                now: signaled.addingTimeInterval(grace * 0.25)
            ) == grace * 0.75
        )
        #expect(
            AgentAppTerminationJobSweep.remainingGrace(
                startedAt: signaled,
                now: signaled.addingTimeInterval(grace + 30)
            ) == 0
        )
        // A backwards clock jump must not stretch the quit past one grace
        // period; the wait is clamped, not extrapolated.
        #expect(
            AgentAppTerminationJobSweep.remainingGrace(
                startedAt: signaled,
                now: signaled.addingTimeInterval(-3_600)
            ) == grace
        )
    }

    // MARK: - Mechanics

    /// The whole point: a job still running when the user quits is signaled,
    /// and it is signaled quietly. A finish notification or a queued
    /// completion event at this moment would be addressed to a model turn
    /// that can never run.
    @Test
    func quitSweepKillsAliveJobsWithoutQueueingCompletions() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        var notifiedJobIDs: [UUID] = []
        registry.onJobFinished = { notifiedJobIDs.append($0.id) }

        let turnJob = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        let persistentJob = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let signaled = registry.terminateAliveJobsForAppTermination()
        #expect(!signaled.isEmpty)

        #expect(await waitUntilFinished(registry: registry, id: turnJob.id))
        #expect(await waitUntilFinished(registry: registry, id: persistentJob.id))
        #expect(registry.job(id: turnJob.id)?.status == .killed)
        #expect(registry.job(id: persistentJob.id)?.status == .killed)
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).isEmpty)
        #expect(notifiedJobIDs.isEmpty)
    }

    /// With detaching enabled, the persistent job survives the sweep while the
    /// turn job beside it is still killed.
    @Test
    func quitSweepSparesDetachedPersistentJobsOnly() async throws {
        let logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-sweep-detached-\(UUID().uuidString)", isDirectory: true)
        let registry = AgentJobRegistry(outputLogRootDirectory: logRoot)
        defer { try? FileManager.default.removeItem(at: logRoot) }
        let runtimeID = UUID()
        let turnJob = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        let persistentJob = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent
        )
        defer { _ = killpg(persistentJob.pid, SIGKILL) }
        #expect(persistentJob.isDetached)
        #expect(!turnJob.isDetached)
        try await Task.sleep(nanoseconds: 50_000_000)

        let signaled = registry.terminateAliveJobsForAppTermination()
        #expect(signaled.allSatisfy { $0.pid != persistentJob.pid })

        #expect(await waitUntilFinished(registry: registry, id: turnJob.id))
        #expect(registry.job(id: turnJob.id)?.status == .killed)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(registry.job(id: persistentJob.id)?.isAlive == true)
        #expect(Darwin.kill(persistentJob.pid, 0) == 0)
    }

    /// A shell that ignores SIGTERM is exactly the case the old code lost:
    /// the registry's SIGKILL fallback is scheduled on a queue inside this
    /// process, so an app that exits first never delivers it. Escalation has
    /// to be the caller's job, and it has to actually land.
    @Test
    func escalationKillsChildrenThatIgnoreSIGTERM() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: AgentJobFixtureCommand.idleIgnoringTerm(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let signaled = registry.terminateAliveJobsForAppTermination()
        #expect(!signaled.isEmpty)

        // Skip the real wait — the assertion is about SIGKILL being delivered
        // to survivors, not about how long the sweep is willing to wait.
        AgentAppTerminationJobSweep.escalate(
            signaled,
            startedAt: Date(),
            sleep: { _ in }
        )

        #expect(await waitUntilFinished(registry: registry, id: job.id))
        for identity in signaled {
            #expect(!identity.stillMatchesCurrentProcess)
        }
    }

    @Test
    func escalationWithNothingSignaledNeverWaits() {
        var sleepCalls = 0
        AgentAppTerminationJobSweep.escalate(
            [],
            startedAt: Date.distantPast,
            sleep: { _ in sleepCalls += 1 }
        )
        #expect(sleepCalls == 0)
    }

    // MARK: - Helpers

    /// Same budget and cadence as `AgentBackgroundJobsTests`: generous enough
    /// that a full-load parallel run cannot turn process spawn latency into a
    /// failure.
    private func waitUntilFinished(
        registry: AgentJobRegistry,
        id: UUID,
        timeoutMs: Int = 60_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let job = registry.job(id: id), !job.isAlive {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func makeStubJob(
        status: AgentBackgroundJob.Status = .running,
        lifetime: AgentBackgroundJobLifetime = .turn,
        remoteRuntimeID: UUID? = nil,
        requiresExitReceipt: Bool = false
    ) -> AgentBackgroundJob {
        let id = UUID()
        return AgentBackgroundJob(
            id: id,
            shortID: String(id.uuidString.prefix(6)).lowercased(),
            command: "echo stub",
            workingDirectoryPath: nil,
            runtimeID: UUID(),
            remoteRuntimeID: remoteRuntimeID,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            pid: 12_345,
            status: status,
            outputByteCount: 0,
            lifetime: lifetime,
            requiresExitReceipt: requiresExitReceipt
        )
    }
}
