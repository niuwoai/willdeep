import Foundation

extension L10n {
    /// Banner copy for the turn watchdog (AgentTurnWatchdog.swift). Both
    /// notices use the mild `.notice` severity: they describe a turn that
    /// went quiet or broke, not a failure the user caused.
    enum TurnWatchdog {
        /// One line naming what the turn is waiting on and for how long.
        /// The four subjects read differently on purpose: the user's first
        /// question when a turn goes quiet is "谁没动静" — 模型、工具，还是
        /// 派出去的 Worker。
        static func stalled(subject: AgentTurnWatchdogPolicy.StallSubject, idle: TimeInterval) -> String {
            let duration = AgentTurnWatchdogPolicy.formatIdle(idle)
            switch subject {
            case .worker(let name):
                let template = String(
                    localized: "turn-watchdog.stalled-worker",
                    defaultValue: "Worker %1$@ has sent nothing back for %2$@. The turn is waiting on it, not on the model."
                )
                return String(format: template, name, duration)
            case .tool(let name):
                let template = String(
                    localized: "turn-watchdog.stalled-tool",
                    defaultValue: "The %1$@ tool has not returned for %2$@."
                )
                return String(format: template, name, duration)
            case .modelFirstToken:
                let template = String(
                    localized: "turn-watchdog.stalled-model-first-token",
                    defaultValue: "Nothing from the model for %@; the request is still open."
                )
                return String(format: template, duration)
            case .modelMidStream:
                let template = String(
                    localized: "turn-watchdog.stalled-model-mid-stream",
                    defaultValue: "The reply stopped mid-stream %@ ago; the connection is probably dead."
                )
                return String(format: template, duration)
            }
        }

        static func durationSeconds(_ seconds: Int) -> String {
            let template = String(localized: "turn-watchdog.duration-seconds", defaultValue: "%d s")
            return String(format: template, seconds)
        }

        static func durationMinutes(_ minutes: Int, _ seconds: Int) -> String {
            let template = String(
                localized: "turn-watchdog.duration-minutes",
                defaultValue: "%1$d min %2$d s"
            )
            return String(format: template, minutes, seconds)
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
