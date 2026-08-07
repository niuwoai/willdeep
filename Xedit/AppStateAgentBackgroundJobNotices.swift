//
//  AppStateAgentBackgroundJobNotices.swift
//  WillDeep
//
//  Split out of AppStateAgentLoop.swift to keep files under the repository
//  size limit. The nonisolated builder for the notice injected back into the
//  conversation when a backgrounded run_command job finishes. The media-task
//  counterpart lives with its siblings in AppStateAgentMediaTaskNotices.swift.
//

import Foundation

extension AppState {
    /// Build the `<background-task-notification>` body the agent loop
    /// pushes into the model when a backgrounded `run_command` job
    /// finishes. Kept short and unambiguous: the model should react to
    /// it (summarize, follow up, kick off next steps) or quietly note
    /// it depending on the originating user intent.
    ///
    /// `recentOutput` is an already-tailed, already-secret-redacted slice
    /// the caller inlines for jobs that need attention (failed / timed out
    /// / launch failed). Surfacing *why* a job failed in the notice itself
    /// saves the model a `get_job_output` round-trip before it can react —
    /// without it, a backgrounded `docker build` that fails just reads as
    /// "exit=1, 5 KB captured" and the model has to fetch the log to learn
    /// anything. Pass `nil` (the default) for success / killed jobs, which
    /// keep the lighter byte-count hint.
    nonisolated static func backgroundJobCompletionNotice(
        for job: AgentBackgroundJob,
        recentOutput: String? = nil
    ) -> String {
        let durationText: String = {
            let total = Int(job.duration.rounded())
            if total < 60 { return "\(total)s" }
            let m = total / 60, s = total % 60
            if m < 60 { return "\(m)m\(s)s" }
            let h = m / 60, mm = m % 60
            return "\(h)h\(mm)m"
        }()
        let exitText = job.exitCode.map { "exit=\($0)" } ?? "exit=?"
        let trimmedCommand = job.command.count > 200
            ? String(job.command.prefix(200)) + "…"
            : job.command
        let outputHint = job.outputByteCount > 0
            ? "\(job.outputByteCount) bytes of output captured — call `get_job_output(job_id: \"\(job.displayHandle)\")` to read."
            : "no output captured."

        var lines = [
            "<background-task-notification>",
            "Background job \(job.displayHandle) finished while you were not in this turn.",
            "Command: \(trimmedCommand)",
            "Status: \(job.status.rawValue) (\(exitText)), duration \(durationText).",
            outputHint
        ]
        if let executor = job.executor, let sessionID = job.executorSessionID {
            lines.append(
                "Reusable session: executor=\(executor.rawValue), session_id=\(sessionID)."
            )
        }
        if let recentOutput, !recentOutput.isEmpty {
            lines.append("Recent output (tail, secrets redacted):")
            lines.append("```")
            lines.append(recentOutput)
            lines.append("```")
        }
        lines.append("</background-task-notification>")
        return lines.joined(separator: "\n")
    }
}
