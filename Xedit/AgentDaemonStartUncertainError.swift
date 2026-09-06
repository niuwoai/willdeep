import Foundation

/// An ambiguous start is neither a confirmed failure nor permission to run
/// the command again. The stable ID permits lookup without a new execution.
nonisolated struct AgentDaemonStartUncertainError: Error, LocalizedError {
    let jobID: String
    var errorDescription: String? {
        "Daemon start outcome is unconfirmed for job \(jobID). Do not repeat execution with a new request. Inspect this job ID after connectivity recovers; no terminal outcome has been confirmed."
    }
}
