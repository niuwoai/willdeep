//
//  AgentDetachedJobTests.swift
//  XeditTests
//
//  Contract「C·三」: a local `lifetime: persistent` shell job survives the
//  app (simulated by tearing its registry down), keeps writing its log, and a
//  new registry re-adopts it — running, finished-while-away (notice exactly
//  once), vanished, or past its deadline. Real `/bin/sh` children, 1–3 s each,
//  every one cleaned up by process group.
//

import Darwin
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDetachedJobTests {

    // MARK: - Survives teardown, adopted as running

    @Test
    func detachedJobOutlivesItsRegistryAndIsAdoptedAsRunning() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let runtimeID = UUID()
        var first: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try #require(first).start(
            command: "i=0; while [ $i -lt 15 ]; do echo tick$i; i=$((i+1)); sleep 0.1; done; echo DETACHED_DONE",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent,
            label: "ticker"
        )
        #expect(job.isDetached)
        #expect(job.lifetime == .persistent)
        let directory = root.appendingPathComponent(job.displayHandle)
        let record = try #require(AgentDetachedJobFiles.readRecord(directory: directory))
        #expect(record.ownerRuntimeID == runtimeID)
        #expect(record.label == "ticker")
        #expect(permissions(directory.appendingPathComponent("meta.json")) == 0o600)
        #expect(getpgid(job.pid) == job.pid, "detached job must lead its own process group")

        let logURL = directory.appendingPathComponent("output.log")
        #expect(await waitUntil { fileSize(logURL) > 0 })
        first?.relinquishDetachedJobsForTesting()
        first = nil

        let sizeAfterTeardown = fileSize(logURL)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(fileSize(logURL) > sizeAfterTeardown, "log must keep growing with no registry attached")
        #expect(Darwin.kill(job.pid, 0) == 0)

        let second = AgentJobRegistry(outputLogRootDirectory: root)
        var notified: [UUID] = []
        second.onJobFinished = { notified.append($0.id) }
        let adopted = try #require(second.job(id: job.id))
        #expect(adopted.isAlive)
        #expect(adopted.isDetached)
        #expect(adopted.displayHandle == job.displayHandle)
        #expect(second.outputLogURL(id: job.id)?.path == logURL.path)

        #expect(await waitUntil { second.job(id: job.id)?.isAlive == false })
        let finished = try #require(second.job(id: job.id))
        #expect(finished.status == .completed)
        #expect(finished.exitCode == 0)
        #expect(second.output(id: job.id).contains("DETACHED_DONE"))
        // Adopted completions wait for the session catalog.
        #expect(notified.isEmpty)
        second.releaseAdoptedDetachedCompletions { $0 == runtimeID }
        #expect(notified == [job.id])
        #expect(second.consumePendingCompletions(forRuntime: runtimeID).map(\.id) == [job.id])
        second.releaseAdoptedDetachedCompletions { _ in true }
        #expect(notified == [job.id])
        #expect(AgentDetachedJobFiles.isDelivered(directory: directory))
    }

    // MARK: - Finished while away

    @Test
    func finishedWhileAwayDeliversExactlyOnceAndOnlyToAnExistingOwner() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let runtimeID = UUID()
        var first: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try #require(first).start(
            command: "echo AWAY_RESULT; exit 3",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent
        )
        #expect(job.isDetached)
        first?.relinquishDetachedJobsForTesting()
        first = nil
        let directory = root.appendingPathComponent(job.displayHandle)
        #expect(await waitUntil { AgentDetachedJobFiles.exitCode(directory: directory) != nil })

        // Owner session is gone: listed, never delivered, never claimed.
        var orphanRegistry: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        var orphanNotices = 0
        orphanRegistry?.onJobFinished = { _ in orphanNotices += 1 }
        let listed = try #require(orphanRegistry?.job(id: job.id))
        #expect(listed.status == .failed)
        #expect(listed.exitCode == 3)
        orphanRegistry?.releaseAdoptedDetachedCompletions { _ in false }
        #expect(orphanNotices == 0)
        #expect(!AgentDetachedJobFiles.isDelivered(directory: directory))
        orphanRegistry?.relinquishDetachedJobsForTesting()
        orphanRegistry = nil

        var owner: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        var notices: [AgentBackgroundJob] = []
        owner?.onJobFinished = { notices.append($0) }
        owner?.releaseAdoptedDetachedCompletions { $0 == runtimeID }
        #expect(notices.map(\.id) == [job.id])
        #expect(notices.first?.status == .failed)
        #expect(owner?.output(id: job.id).contains("AWAY_RESULT") == true)
        owner?.relinquishDetachedJobsForTesting()
        owner = nil

        let later = AgentJobRegistry(outputLogRootDirectory: root)
        var laterNotices = 0
        later.onJobFinished = { _ in laterNotices += 1 }
        later.releaseAdoptedDetachedCompletions { _ in true }
        #expect(later.job(id: job.id) == nil, "a delivered job is not adopted again")
        #expect(laterNotices == 0)
    }

    // MARK: - Vanished

    @Test
    func recordWithNoProcessAndNoExitIsVanished() throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let runtimeID = UUID()
        let id = UUID()
        let handle = "job_\(String(id.uuidString.prefix(6)).lowercased())"
        let directory = root.appendingPathComponent(handle)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial output\n".utf8).write(to: directory.appendingPathComponent("output.log"))
        try AgentDetachedJobFiles.writeRecord(AgentDetachedJobRecord(
            version: AgentDetachedJobRecord.currentVersion, id: id, handle: handle,
            pid: Int32.max, processStartSeconds: 1, processStartMicroseconds: 2,
            ownerRuntimeID: runtimeID, label: "gone", command: "sleep 600",
            workingDirectory: nil, lifetime: .persistent, goalPhaseID: nil,
            survivesTurnStop: true, deadline: nil, createdAt: Date(timeIntervalSinceNow: -60)
        ), directory: directory)

        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        var notices = 0
        registry.onJobFinished = { _ in notices += 1 }
        let job = try #require(registry.job(id: id))
        #expect(!job.isAlive)
        #expect(job.vanished)
        #expect(job.exitCode == nil)
        #expect(AppState.backgroundNoticeStatus(for: job) == .vanished)
        #expect(registry.output(id: id).contains("partial output"))
        registry.releaseAdoptedDetachedCompletions { _ in true }
        registry.releaseAdoptedDetachedCompletions { _ in true }
        #expect(notices == 1)
    }

    // MARK: - Deadline

    @Test
    func deadlinePassedWhileAwayKillsTheGroupAsTimedOut() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        var first: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try #require(first).start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: UUID(),
            timeoutSeconds: 1,
            lifetime: .persistent
        )
        #expect(job.isDetached)
        // The away registry's timer dies with it; nobody enforces the deadline.
        first?.relinquishDetachedJobsForTesting()
        first = nil
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(Darwin.kill(job.pid, 0) == 0)

        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        #expect(await waitUntil { registry.job(id: job.id)?.isAlive == false })
        #expect(registry.job(id: job.id)?.status == .timedOut)
        let directory = root.appendingPathComponent(job.displayHandle)
        #expect(AgentDetachedJobFiles.disposition(directory: directory) == .timedOut)
        #expect(await waitUntil { killpg(job.pid, 0) != 0 })
    }

    @Test
    func unexpiredDeadlineIsRearmedOnAdoption() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        var first: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try #require(first).start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: UUID(),
            timeoutSeconds: 2,
            lifetime: .persistent
        )
        first?.relinquishDetachedJobsForTesting()
        first = nil

        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        #expect(registry.job(id: job.id)?.isAlive == true)
        #expect(await waitUntil { registry.job(id: job.id)?.isAlive == false })
        #expect(registry.job(id: job.id)?.status == .timedOut)
    }

    // MARK: - Kill

    @Test
    func killSignalsTheProcessGroupAndRecordsKilled() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        let runtimeID = UUID()
        var notices = 0
        registry.onJobFinished = { _ in notices += 1 }
        let job = try registry.start(
            command: AgentJobFixtureCommand.idle(prefix: "echo started; "),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent
        )
        #expect(job.isDetached)
        #expect(registry.hasLocalProcessExitReceipt(id: job.id))
        #expect(await waitUntil { registry.output(id: job.id).contains("started") })

        #expect(registry.kill(id: job.id))
        #expect(await waitUntil { registry.job(id: job.id)?.isAlive == false })
        #expect(registry.job(id: job.id)?.status == .killed)
        #expect(await waitUntil { killpg(job.pid, 0) != 0 })
        let directory = root.appendingPathComponent(job.displayHandle)
        #expect(AgentDetachedJobFiles.exitCode(directory: directory) != nil)
        #expect(AgentDetachedJobFiles.isDelivered(directory: directory))
        #expect(notices == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output.log.tail").path))
    }

    // MARK: - Fallbacks

    /// Injected secret values are replaced before bytes reach the log only on
    /// the in-process path, so such a job must not detach.
    @Test
    func persistentJobCarryingInjectedSecretsStaysInProcess() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try registry.start(
            command: "echo s3cr3t-value",
            workingDirectory: nil,
            runtimeID: UUID(),
            timeoutSeconds: nil,
            secretRedactionValues: ["s3cr3t-value"],
            lifetime: .persistent
        )
        #expect(!job.isDetached)
        #expect(await waitUntil { registry.job(id: job.id)?.isAlive == false })
        let log = try String(contentsOf: try #require(registry.outputLogURL(id: job.id)), encoding: .utf8)
        #expect(!log.contains("s3cr3t-value"))
    }

    @Test
    func nonPersistentLifetimesNeverDetach() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        for lifetime in [AgentBackgroundJobLifetime.turn, .phase, .goal] {
            let job = try registry.start(command: "true", workingDirectory: nil, runtimeID: UUID(),
                                         timeoutSeconds: nil, lifetime: lifetime)
            #expect(!job.isDetached, "lifetime \(lifetime.rawValue) detached")
            #expect(await waitUntil { registry.job(id: job.id)?.isAlive == false })
        }
    }

    @Test
    func retentionSkipsDirectoryOfAnAliveDetachedJob() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        var first: AgentJobRegistry? = AgentJobRegistry(outputLogRootDirectory: root)
        let job = try #require(first).start(command: AgentJobFixtureCommand.idle(), workingDirectory: nil,
                                            runtimeID: UUID(), timeoutSeconds: nil, lifetime: .persistent)
        first?.relinquishDetachedJobsForTesting()
        first = nil
        let directory = root.appendingPathComponent(job.displayHandle)
        let removed = AgentJobOutputLogSink.prune(rootDirectory: root, now: Date().addingTimeInterval(30 * 86_400))
        #expect(removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        // A plain sink must not truncate the adopted job's log either.
        #expect(AgentJobOutputLogSink(rootDirectory: root, jobHandle: job.displayHandle) == nil)
    }

    // MARK: - Quit guard

    @Test
    func quitConfirmationListsJobsThatKeepRunning() {
        #expect(AppTerminationGuard.confirmationMessage(keepRunningLabels: []) == L10n.AppTermination.message)
        let message = AppTerminationGuard.confirmationMessage(keepRunningLabels: ["dev server", "watcher"])
        #expect(message.hasPrefix(L10n.AppTermination.message))
        #expect(message.contains("• dev server\n• watcher"))
    }

    @Test
    func aliveDetachedJobAloneDoesNotBlockQuit() async throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let registry = AgentJobRegistry(outputLogRootDirectory: root)
        let appState = AppState(backgroundJobRegistry: registry, loadSessionCatalog: false)
        let session = appState.startNewAgentSession()
        let job = try registry.start(command: AgentJobFixtureCommand.idle(), workingDirectory: nil,
                                     runtimeID: session.id, timeoutSeconds: nil, lifetime: .persistent,
                                     label: "dev server")
        defer { registry.kill(id: job.id) }
        #expect(job.isDetached)
        var confirmations = 0
        #expect(AppTerminationGuard.shouldAllowTermination(appStates: [appState], confirmation: {
            confirmations += 1
            return false
        }))
        #expect(confirmations == 0)
        #expect(AppTerminationGuard.jobsSurvivingTermination(appStates: [appState, appState]).map(\.id) == [job.id])
    }

    // MARK: - Helpers

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-detached-jobs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Kill every recorded process group under `root`, then remove it.
    private func cleanUp(_ root: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in entries {
            if let record = AgentDetachedJobFiles.readRecord(directory: directory), record.pid > 0 {
                _ = killpg(record.pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(timeoutSeconds: Double = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private func fileSize(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
}
