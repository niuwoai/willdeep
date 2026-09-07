import Foundation

extension L10n {
    /// Banner copy for the turn watchdog (AgentTurnWatchdog.swift). Both
    /// notices use the mild `.notice` severity: they describe a turn that
    /// went quiet or broke, not a failure the user caused.
    enum TurnWatchdog {
        static func stalled(seconds: Int, waitingOn: String) -> String {
            let template = String(
                localized: "turn-watchdog.stalled",
                defaultValue: "No activity for %1$d s — waiting on %2$@."
            )
            return String(format: template, seconds, waitingOn)
        }

        static let waitingOnModel = String(
            localized: "turn-watchdog.waiting-on-model",
            defaultValue: "the model's response"
        )

        static func waitingOnTool(_ toolName: String) -> String {
            let template = String(
                localized: "turn-watchdog.waiting-on-tool",
                defaultValue: "the %@ tool"
            )
            return String(format: template, toolName)
        }

        static func waitingOnWorker(_ workerName: String) -> String {
            let template = String(
                localized: "turn-watchdog.waiting-on-worker",
                defaultValue: "Worker %@"
            )
            return String(format: template, workerName)
        }

        static func interrupted(toolNames: [String]) -> String {
            if toolNames.isEmpty {
                return String(
                    localized: "turn-watchdog.interrupted",
                    defaultValue: "The turn ended before its last tool call ran. Resuming automatically; use Retry if it does not continue."
                )
            }
            let template = String(
                localized: "turn-watchdog.interrupted-named",
                defaultValue: "The turn ended before %@ ran. Resuming automatically; use Retry if it does not continue."
            )
            return String(format: template, toolNames.joined(separator: ", "))
        }
    }
}
