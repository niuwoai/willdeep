import Foundation

// Kept outside the generated façade so L10n.swift remains below the
// repository's 3,000-line hard limit.
extension L10n {
    enum AgentTaskMonitor {
        static func moreBackgroundJobs(_ n: Int) -> String {
            String(
                format: String(
                    localized: "agent-task-monitor.more-background-jobs",
                    defaultValue: "%d more background tasks"
                ),
                n
            )
        }
    }
}
