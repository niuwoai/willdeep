//
//  AppStateAgentBackgroundJobNotices.swift
//  WillDeep
//
//  Split out of AppStateAgentLoop.swift to keep files under the repository
//  size limit. Builds the notice injected back into the conversation when a
//  backgrounded run_command job finishes, in the shared v1 format
//  (docs/BACKGROUND_TASK_CONTRACT.md). The media-task counterpart lives with
//  its siblings in AppStateAgentMediaTaskNotices.swift.
//

import Foundation

private enum BackgroundJobNoticeLimits {
    /// Enough for the renderer's longest tail (failure: 40 lines); the
    /// renderer itself cuts completed shell jobs down to 10.
    static let tailLines = AgentBackgroundNotice.failureTailLines
}

extension AppState {
    /// Render the `<background-task-notification>` v1 body for a finished
    /// background job.
    ///
    /// `recentOutput` is an already-tailed, already-scrubbed slice; the
    /// renderer applies the contract's own tail length and per-line
    /// redaction on top. `outputPath` is the full log on disk (nil when it
    /// was never written) and `omittedBytes` the bytes the log's size cap
    /// dropped.
    nonisolated static func backgroundJobCompletionNotice(
        for job: AgentBackgroundJob,
        recentOutput: String? = nil,
        outputPath: String? = nil,
        omittedBytes: UInt64 = 0
    ) -> String {
        let session = job.executor.flatMap { executor in
            job.executorSessionID.map { "\(executor.rawValue) \($0)" }
        }
        let status = backgroundNoticeStatus(for: job)
        return AgentBackgroundNotice.render(AgentBackgroundNotice.Notice(
            id: job.displayHandle,
            kind: job.executor == nil ? .shell : .executor,
            label: job.label ?? job.command,
            status: status,
            // A launch failure never produced a process; its stored -1 is a
            // placeholder, not an exit status.
            exitCode: status == .launchFailed ? nil : job.exitCode,
            durationSeconds: job.finishedAt.map { finishedAt in
                UInt64(max(0, finishedAt.timeIntervalSince(job.startedAt)).rounded(.down))
            },
            outputPath: outputPath,
            stderrPath: nil,
            omittedBytes: omittedBytes,
            output: recentOutput ?? "",
            executorSession: session
        ))
    }

    /// Contract status for a registry job. A lost monitoring channel is
    /// reported as a failure: the host could not confirm the outcome.
    nonisolated static func backgroundNoticeStatus(for job: AgentBackgroundJob) -> AgentBackgroundNotice.Status {
        if job.monitoringFailure != nil { return .failed }
        switch job.status {
        case .completed: return .completed
        case .failed: return .failed
        case .killed: return .killed
        case .timedOut: return .timedOut
        case .launchFailed: return .launchFailed
        // A "finished" job that is still marked running left no exit status.
        case .running: return .vanished
        }
    }

    /// The single place both delivery paths (next-turn system message and
    /// runtime-kernel event) build a finished job's notice from: every
    /// finished job carries its scrubbed tail, log path and dropped bytes.
    func renderBackgroundJobCompletionNotice(for job: AgentBackgroundJob) -> String {
        Self.backgroundJobCompletionNotice(
            for: job,
            recentOutput: backgroundJobNoticeTail(job),
            outputPath: agentJobRegistry.outputLogURL(id: job.id)?.path,
            omittedBytes: agentJobRegistry.outputLogDroppedBytes(id: job.id)
        )
    }

    private func backgroundJobNoticeTail(_ job: AgentBackgroundJob) -> String? {
        let tail = agentJobRegistry.output(id: job.id, tailLines: BackgroundJobNoticeLimits.tailLines)
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentSandboxPolicy.scrub(tail)
    }
}
