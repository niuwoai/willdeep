import Foundation

extension L10n {
    nonisolated enum DelegatedTask {
        static let selfReview = String(localized: "delegated-task.self-review", defaultValue: "Self review")
        static let rework = String(localized: "delegated-task.rework", defaultValue: "Point rework")
        static let accepted = String(localized: "delegated-task.accepted", defaultValue: "Accepted")
        static let failed = String(localized: "delegated-task.failed", defaultValue: "Delegated task failed")
        static let noExecutionOutput = String(localized: "delegated-task.no-execution-output", defaultValue: "No executor output was captured.")
        static let acceptanceUnavailable = String(localized: "delegated-task.acceptance-unavailable", defaultValue: "No acceptance verdict is available.")
        static let rejected = String(localized: "delegated-task.rejected", defaultValue: "Rejected")
        static let interrupted = String(localized: "delegated-task.interrupted", defaultValue: "WillDeep restarted before this delegated task finished.")
        static let hostRerun = String(localized: "delegated-task.host-rerun", defaultValue: "WillDeep verification rerun")
        static let noSafeVerificationCommand = String(localized: "delegated-task.no-safe-verification-command", defaultValue: "No safe verification command was supplied; structural acceptance still ran.")
        static let unsafeVerificationCommand = String(localized: "delegated-task.unsafe-verification-command", defaultValue: "WillDeep refused to rerun a command outside the safe verification boundary.")
        static let sectionTitle = String(localized: "delegated-task.section-title", defaultValue: "Delegated acceptance")
        static let noTasks = String(localized: "delegated-task.no-tasks", defaultValue: "No delegated task ledger yet")
        static let changedFiles = String(localized: "delegated-task.changed-files", defaultValue: "Changed files")
        static let findings = String(localized: "delegated-task.findings", defaultValue: "Findings")

        static func attempt(_ current: Int, _ maximum: Int) -> String {
            let template = String(localized: "delegated-task.attempt", defaultValue: "Attempt %1$d / %2$d")
            return String(format: template, current, maximum)
        }

        static func acceptancePassed(_ attempt: Int) -> String {
            let template = String(localized: "delegated-task.acceptance-passed-attempt", defaultValue: "Executor self-review and WillDeep acceptance passed on attempt %d.")
            return String(format: template, attempt)
        }

        static func changedFileCount(_ count: Int) -> String {
            let template = String(localized: "delegated-task.changed-file-count", defaultValue: "%d changed file(s)")
            return String(format: template, count)
        }

        static func findingCount(_ count: Int) -> String {
            let template = String(localized: "delegated-task.finding-count", defaultValue: "%d acceptance finding(s)")
            return String(format: template, count)
        }

        static func phase(_ phase: AgentDelegatedTaskPhase) -> String {
            switch phase {
            case .contracted:
                return String(localized: "delegated-task.phase.contracted", defaultValue: "Contracted")
            case .executing:
                return String(localized: "delegated-task.phase.executing", defaultValue: "Executing")
            case .selfVerifying:
                return String(localized: "delegated-task.phase.self-verifying", defaultValue: "Executor reviewing")
            case .willDeepVerifying:
                return String(localized: "delegated-task.phase.willdeep-verifying", defaultValue: "WillDeep verifying")
            case .reworkRequired:
                return String(localized: "delegated-task.phase.rework-required", defaultValue: "Rework required")
            case .readyForDelivery:
                return String(localized: "delegated-task.phase.ready-for-delivery", defaultValue: "Accepted")
            case .failed:
                return String(localized: "delegated-task.phase.failed", defaultValue: "Failed")
            case .cancelled:
                return String(localized: "delegated-task.phase.cancelled", defaultValue: "Cancelled")
            }
        }
    }
}
