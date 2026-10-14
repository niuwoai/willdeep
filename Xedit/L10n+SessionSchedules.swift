import Foundation

extension L10n {
    enum SessionSchedules {
        static let inherit = String(localized: "session-schedules.inherit", defaultValue: "Continue the source conversation using its workspace, model and permissions.", table: "SessionSchedules")
        static let title = String(localized: "session-schedules.title", defaultValue: "Conversation schedules", table: "SessionSchedules")
        static let enabled = String(localized: "session-schedules.enabled", defaultValue: "Enabled", table: "SessionSchedules")
        static let paused = String(localized: "session-schedules.paused", defaultValue: "Paused", table: "SessionSchedules")
        static let pause = String(localized: "session-schedules.pause", defaultValue: "Pause schedule", table: "SessionSchedules")
        static let resume = String(localized: "session-schedules.resume", defaultValue: "Resume schedule", table: "SessionSchedules")
        static let sourceBusy = String(localized: "session-schedules.source-busy", defaultValue: "Source conversation is busy or archived; this run was skipped.", table: "SessionSchedules")
        static let sourceMissing = String(localized: "session-schedules.source-missing", defaultValue: "Source conversation no longer exists; this run was skipped.", table: "SessionSchedules")
        static func outcome(_ value: AgentRoutineRunOutcome) -> String {
            switch value {
            case .running: return String(localized: "session-schedules.running", defaultValue: "Running", table: "SessionSchedules")
            case .succeeded: return String(localized: "session-schedules.completed", defaultValue: "Execution completed · unverified", table: "SessionSchedules")
            case .failed: return String(localized: "session-schedules.failed", defaultValue: "Failed", table: "SessionSchedules")
            case .interrupted: return String(localized: "session-schedules.interrupted", defaultValue: "Interrupted", table: "SessionSchedules")
            case .unknown: return String(localized: "session-schedules.unknown", defaultValue: "Unknown", table: "SessionSchedules")
            case .skipped: return String(localized: "session-schedules.skipped", defaultValue: "Skipped", table: "SessionSchedules")
            }
        }
    }
}
