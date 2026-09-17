//
//  AgentBackgroundJobsDetached.swift
//  WillDeep
//
//  Registry side of detached `.persistent` shell jobs (contract「C·三」):
//  launch, adoption on the next launch, completion routing with the
//  create-new `delivered` claim. File mechanics live in AgentDetachedJob.swift.
//

import Darwin
import Foundation

extension AgentJobRegistry {
    func jobDirectory(handle: String) -> URL {
        outputLogRootDirectory.appendingPathComponent(handle, isDirectory: true)
    }

    /// A handle whose directory holds a detached job record, or is being
    /// written in this process, cannot be handed to a new job.
    func detachedJobDirectoryIsTaken(handle: String) -> Bool {
        AgentJobOutputLogSink.isActiveDirectory(handle)
            || FileManager.default.fileExists(
                atPath: jobDirectory(handle: handle)
                    .appendingPathComponent(AgentDetachedJobFiles.metaFileName).path
            )
    }

    // MARK: - Launch

    /// Returns nil when the detached launch could not be set up; the caller
    /// then falls back to the in-process path so the job still runs.
    func startDetached(
        id: UUID,
        launch: AgentSandboxLaunch,
        environment: [String: String],
        workingDirectory: URL?,
        runtimeID: UUID,
        runtimeDisplayName: String?,
        timeoutSeconds: Double?,
        visibleCommand: String,
        visibleLabel: String?,
        lifetime: AgentBackgroundJobLifetime,
        goalPhaseID: String?,
        survivesTurnStop: Bool
    ) -> AgentBackgroundJob? {
        let shortID = String(id.uuidString.prefix(6)).lowercased()
        let handle = "job_\(shortID)"
        let directory = jobDirectory(handle: handle)
        let logURL = directory.appendingPathComponent(AgentJobOutputLogSink.logFileName)
        let fileManager = FileManager.default
        guard AgentDetachedJobFiles.claimOwnership(handle: handle) else { return nil }
        let createdAt = Date()
        var spawnedPID: Int32?
        do {
            // Only a finished, unowned directory can reach here (see
            // `detachedJobDirectoryIsTaken`); its old output must not mix in.
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard fileManager.createFile(atPath: logURL.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
            }
            let pid = try AgentDetachedJobLauncher.spawn(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                jobDirectory: directory,
                logURL: logURL
            )
            spawnedPID = pid
            let marker = AgentDetachedProcessProbe.startMarker(pid: pid)
            let record = AgentDetachedJobRecord(
                version: AgentDetachedJobRecord.currentVersion,
                id: id,
                handle: handle,
                pid: pid,
                processStartSeconds: marker?.seconds ?? 0,
                processStartMicroseconds: marker?.microseconds ?? 0,
                ownerRuntimeID: runtimeID,
                label: visibleLabel,
                command: visibleCommand,
                workingDirectory: workingDirectory?.path,
                lifetime: lifetime,
                goalPhaseID: goalPhaseID,
                survivesTurnStop: survivesTurnStop,
                deadline: timeoutSeconds.flatMap { $0 > 0 ? createdAt.addingTimeInterval($0) : nil },
                createdAt: createdAt
            )
            // Without a record no later launch could find this process.
            try AgentDetachedJobFiles.writeRecord(record, directory: directory)

            let monitor = AgentDetachedJobMonitor(
                record: record,
                directory: directory,
                collectorLimit: Self.maxOutputBytes,
                startFromTail: false
            )
            detachedMonitors[id] = monitor
            let job = AgentBackgroundJob(
                id: id,
                shortID: shortID,
                command: visibleCommand,
                workingDirectoryPath: workingDirectory?.path,
                runtimeID: runtimeID,
                runtimeDisplayName: runtimeDisplayName,
                startedAt: createdAt,
                pid: pid,
                status: .running,
                exitCode: nil,
                finishedAt: nil,
                outputByteCount: 0,
                lifetime: lifetime,
                goalPhaseID: goalPhaseID,
                survivesTurnStop: survivesTurnStop,
                label: visibleLabel,
                isDetached: true
            )
            insertOrUpdate(job)
            watchDetached(monitor: monitor)
            return job
        } catch {
            if let spawnedPID { _ = killpg(spawnedPID, SIGKILL) }
            detachedMonitors.removeValue(forKey: id)
            try? fileManager.removeItem(at: directory)
            AgentDetachedJobFiles.releaseOwnership(handle: handle)
            NSLog("Detached launch unavailable for %@, running in-process instead: %@",
                  handle, error.localizedDescription)
            return nil
        }
    }

    private func watchDetached(monitor: AgentDetachedJobMonitor) {
        let id = monitor.record.id
        monitor.start { [weak self] outcome in
            Task { @MainActor [weak self] in
                self?.finishDetached(id: id, outcome: outcome)
            }
        }
        guard let deadline = monitor.record.deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            monitor.requestKill(.timedOut)
        } else {
            monitor.scheduleTimeout(after: remaining)
        }
    }

    // MARK: - Adoption

    /// Scan job records left by an earlier launch. Alive (same pid + start
    /// time) → running again; `exit` present → finished, notice delivered once
    /// after `releaseAdoptedDetachedCompletions`; neither → vanished.
    /// Returns the handles still running, for retention to skip.
    func adoptDetachedJobs() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: outputLogRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var alive: Set<String> = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let record = AgentDetachedJobFiles.readRecord(directory: directory),
                  !AgentDetachedJobFiles.isDelivered(directory: directory),
                  job(id: record.id) == nil,
                  AgentDetachedJobFiles.claimOwnership(handle: record.handle) else { continue }
            // Same spelling as the launch that wrote it (the enumerated URL
            // may resolve /var → /private/var), so `output_path` stays stable.
            let monitor = AgentDetachedJobMonitor(
                record: record,
                directory: jobDirectory(handle: record.handle),
                collectorLimit: Self.maxOutputBytes,
                startFromTail: true
            )
            detachedMonitors[record.id] = monitor
            adoptedDetachedJobIDs.insert(record.id)
            insertOrUpdate(AgentBackgroundJob(
                id: record.id,
                shortID: String(record.id.uuidString.prefix(6)).lowercased(),
                command: record.command,
                workingDirectoryPath: record.workingDirectory,
                runtimeID: record.ownerRuntimeID,
                startedAt: record.createdAt,
                pid: record.pid,
                status: .running,
                outputByteCount: 0,
                lifetime: record.lifetime,
                goalPhaseID: record.goalPhaseID,
                survivesTurnStop: record.survivesTurnStop,
                label: record.label,
                isDetached: true
            ))
            if let outcome = monitor.currentOutcome() {
                finishDetached(id: record.id, outcome: outcome)
                continue
            }
            alive.insert(record.handle)
            watchDetached(monitor: monitor)
        }
        return alive
    }

    /// Called once the session catalog is loaded. Completions of adopted jobs
    /// are delivered only to owners that still exist; the others stay listed
    /// in the jobs UI and never wake anything.
    func releaseAdoptedDetachedCompletions(ownerExists: @escaping (UUID) -> Bool) {
        adoptedDetachedCompletionsReleased = true
        adoptedDetachedOwnerExists = ownerExists
        let waiting = awaitingAdoptedDeliveryIDs
        awaitingAdoptedDeliveryIDs = []
        for id in waiting {
            guard let job = job(id: id), !job.isAlive else { continue }
            deliverDetachedCompletion(job, suppressed: false)
        }
    }

    // MARK: - Completion

    func finishDetached(id: UUID, outcome: AgentDetachedJobMonitor.Outcome) {
        guard let monitor = detachedMonitors[id], let job = job(id: id), job.isAlive else { return }
        switch outcome {
        case .exited(let code):
            let disposition = monitor.disposition
            markFinished(
                id: id,
                exitCode: code,
                didTimeOut: disposition == .timedOut,
                wasKilled: disposition == .killed
            )
        case .vanished:
            var updated = job
            updated.status = .failed
            updated.exitCode = nil
            updated.vanished = true
            updated.finishedAt = Date()
            updated.outputByteCount = monitor.collector.byteCount
            insertOrUpdate(updated)
            let suppressed = suppressedCompletionJobIDs.remove(id) != nil
            deliverDetachedCompletion(updated, suppressed: suppressed)
        }
        do {
            try AgentDetachedJobFiles.writePrivateAtomically(
                monitor.collector.combinedTail,
                to: monitor.directory.appendingPathComponent(AgentJobOutputLogSink.tailSidecarName)
            )
        } catch {
            NSLog("Detached job tail sidecar write failed at %@: %@",
                  monitor.directory.path, error.localizedDescription)
        }
        AgentJobOutputLogSink.releaseActiveDirectory(monitor.record.handle)
    }

    /// The single exit for a finished detached job's notice. The `delivered`
    /// claim is taken even when suppressed, so no later launch re-announces a
    /// job the user already stopped.
    func deliverDetachedCompletion(_ job: AgentBackgroundJob, suppressed: Bool) {
        if suppressed {
            _ = claimDetachedDelivery(id: job.id)
            return
        }
        if adoptedDetachedJobIDs.contains(job.id) {
            guard adoptedDetachedCompletionsReleased else {
                if !awaitingAdoptedDeliveryIDs.contains(job.id) { awaitingAdoptedDeliveryIDs.append(job.id) }
                return
            }
            guard adoptedDetachedOwnerExists?(job.runtimeID) ?? true else { return }
        }
        guard claimDetachedDelivery(id: job.id) else { return }
        pendingCompletionEvents[job.runtimeID, default: []].append(job.id)
        AgentToolApprovalNotifier.notifyJobFinished(job: job)
        onJobFinished?(job)
    }

    @discardableResult
    func claimDetachedDelivery(id: UUID) -> Bool {
        guard let job = job(id: id) else { return false }
        let directory = detachedMonitors[id]?.directory ?? jobDirectory(handle: job.displayHandle)
        return AgentDetachedJobFiles.claimDelivery(directory: directory)
    }

    /// Alive detached jobs: these keep running after quit.
    var aliveDetachedJobs: [AgentBackgroundJob] {
        jobs.filter { $0.isAlive && $0.isDetached }
    }

    #if DEBUG
    /// Simulates this registry going away with the app: stop watching and
    /// release ownership, touching no process or file.
    func relinquishDetachedJobsForTesting() {
        detachedMonitors.removeAll()
        adoptedDetachedJobIDs.removeAll()
    }
    #endif
}
