import Foundation

// Kept outside the generated façade so L10n.swift remains below the
// repository's 3,000-line hard limit.
extension L10n {
    enum AgentTaskMonitor {
        static let structuredSession = String(
            localized: "agent-task-monitor.structured-session",
            defaultValue: "Session"
        )
        static let eventStarted = String(
            localized: "agent-task-monitor.event.started",
            defaultValue: "Session started"
        )
        static let eventMessage = String(
            localized: "agent-task-monitor.event.message",
            defaultValue: "Agent message"
        )
        static let eventThinking = String(
            localized: "agent-task-monitor.event.thinking",
            defaultValue: "Thinking"
        )
        static let eventTool = String(
            localized: "agent-task-monitor.event.tool",
            defaultValue: "Tool"
        )
        static let eventFileChanged = String(
            localized: "agent-task-monitor.event.file-changed",
            defaultValue: "File changed"
        )
        static let eventPermission = String(
            localized: "agent-task-monitor.event.permission",
            defaultValue: "Permission requested"
        )
        static let eventUsage = String(
            localized: "agent-task-monitor.event.usage",
            defaultValue: "Usage updated"
        )
        static let eventWarning = String(
            localized: "agent-task-monitor.event.warning",
            defaultValue: "Warning"
        )
        static let eventFinished = String(
            localized: "agent-task-monitor.event.finished",
            defaultValue: "Finished"
        )
        static let eventRaw = String(
            localized: "agent-task-monitor.event.raw",
            defaultValue: "Provider event"
        )

        static func structuredUsage(input: String, output: String) -> String {
            String(
                format: String(
                    localized: "agent-task-monitor.structured-usage",
                    defaultValue: "%1$@ in · %2$@ out"
                ),
                input,
                output
            )
        }

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
