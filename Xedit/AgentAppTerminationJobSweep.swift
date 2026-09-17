//
//  AgentAppTerminationJobSweep.swift
//  WillDeep
//
//  Background jobs are children of this process. Quitting used to leave them
//  running: launchd adopts the orphans, and nothing in the app can reach them
//  again — a dev server keeps its port, a watcher keeps rebuilding, a test run
//  keeps burning CPU, and the only handle the user ever had (the jobs drawer)
//  went away with the window. Quit now ends what this app started.
//

import Darwin
import Foundation

enum AgentAppTerminationJobSweep {
    /// How long a job gets to honor SIGTERM before the sweep escalates.
    /// Same budget as `AgentProcessSupport.terminateProcessTree`; the only
    /// difference is that here the app itself waits it out.
    nonisolated static let gracePeriod: TimeInterval = 2

    /// Quit ends every alive job this app spawned in-process, whatever its
    /// lifetime. Lifetime answers "does this outlive the turn / phase / goal";
    /// only a *detached* job outlives the app, because only it is re-adopted
    /// by the next launch (own process group, output on disk, `exit` file —
    /// see `AgentDetachedJob.swift`). A `.persistent` job that could not
    /// detach (e.g. it carries injected secrets) is still swept: sparing it
    /// would strand it. The user has already been asked once —
    /// `AppTerminationGuard` counts in-process alive jobs as
    /// termination-sensitive activity — so the sweep adds no second dialog.
    ///
    /// Remote daemon work is the other exception. It does not run on this
    /// machine, quitting does not orphan it, and its exit receipt is what lets
    /// the next launch recover the result. Cancelling it here would destroy
    /// that evidence for work this app does not own.
    nonisolated static func shouldTerminateOnQuit(_ job: AgentBackgroundJob) -> Bool {
        guard job.isAlive, !job.isDetached else { return false }
        return job.remoteRuntimeID == nil && !job.requiresExitReceipt
    }

    /// Terminate the alive local jobs of every app state that may still own
    /// Agent work, and return the signaled process identities for escalation.
    /// Two app states can share one registry; sweep each registry once so a
    /// second pass cannot mistake a pid recycled in between for a survivor.
    @MainActor
    static func terminateJobs(in appStates: [AppState]) -> [AgentProcessSupport.ProcessIdentity] {
        var visited: Set<ObjectIdentifier> = []
        var identities: [AgentProcessSupport.ProcessIdentity] = []
        for appState in appStates {
            let registry = appState.agentJobRegistry
            guard visited.insert(ObjectIdentifier(registry)).inserted else { continue }
            identities.append(contentsOf: registry.terminateAliveJobsForAppTermination())
        }
        return identities
    }

    /// SIGKILL whatever ignored SIGTERM, once the grace period measured from
    /// `startedAt` has elapsed. Work the caller does in between — the session
    /// and kernel-event flushes — counts toward that grace, so the common case
    /// where every child is already gone costs the quit nothing.
    nonisolated static func escalate(
        _ identities: [AgentProcessSupport.ProcessIdentity],
        startedAt: Date,
        now: Date = Date(),
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        guard !identities.isEmpty else { return }
        let remaining = remainingGrace(startedAt: startedAt, now: now)
        if remaining > 0 {
            sleep(remaining)
        }
        for identity in identities where identity.stillMatchesCurrentProcess {
            _ = Darwin.kill(identity.pid, SIGKILL)
        }
    }

    /// Clamped on both ends: a clock that jumped backwards must not stretch
    /// the wait past one grace period, and a slow flush must not make it
    /// negative.
    nonisolated static func remainingGrace(startedAt: Date, now: Date) -> TimeInterval {
        min(gracePeriod, max(0, gracePeriod - now.timeIntervalSince(startedAt)))
    }
}
