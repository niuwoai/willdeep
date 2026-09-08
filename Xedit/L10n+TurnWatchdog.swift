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

        /// Tier one, composer strip. Only the model subjects get a line: a
        /// running tool or Worker already shows its own name and clock.
        static func reassurance(subject: AgentTurnWatchdogPolicy.StallSubject, isOverdue: Bool = false) -> String? {
            if isOverdue, subject == .modelFirstToken || subject == .modelMidStream {
                return String(
                    localized: "turn-watchdog.response-completion-unconfirmed",
                    defaultValue: "No new output for a while; response completion has not been confirmed"
                )
            }
            switch subject {
            case .modelFirstToken:
                return String(
                    localized: "turn-watchdog.reassure-model-first-token",
                    defaultValue: "Waiting for a response; no text received yet"
                )
            case .modelMidStream:
                return String(
                    localized: "turn-watchdog.reassure-model-mid-stream",
                    defaultValue: "No new text received; waiting for more output"
                )
            case .worker, .tool:
                return nil
            }
        }

        /// Tier two, second sentence of the banner: what the host will do
        /// if the silence continues, so the user knows they need not act.
        static func nextStep(subject: AgentTurnWatchdogPolicy.StallSubject, idle: TimeInterval) -> String {
            switch subject {
            case .modelFirstToken, .modelMidStream:
                let remaining = max(0, Int((AgentTurnWatchdogPolicy.automaticReconnectAt - idle).rounded()))
                let template = String(
                    localized: "turn-watchdog.next-auto-reconnect",
                    defaultValue: "If nothing arrives in the next %@ the connection is dropped and retried automatically."
                )
                return String(format: template, AgentTurnWatchdogPolicy.formatIdle(TimeInterval(remaining)))
            case .worker:
                return String(
                    localized: "turn-watchdog.next-worker",
                    defaultValue: "A Worker that stays silent is cut off by its own timeout and the result is reported back to the model."
                )
            case .tool:
                return String(
                    localized: "turn-watchdog.next-tool",
                    defaultValue: "Stop interrupts the tool call."
                )
            }
        }

        /// Tier three: the transient ladder is reconnecting.
        static func reconnecting(attempt: Int, maximum: Int) -> String {
            let template = String(
                localized: "turn-watchdog.reconnecting",
                defaultValue: "Connection dropped; reconnecting (attempt %1$d of %2$d)."
            )
            return String(format: template, attempt, maximum)
        }

        static let retryNow = String(localized: "turn-watchdog.retry-now", defaultValue: "Retry now")
        static let retryNowHelp = String(
            localized: "turn-watchdog.retry-now-help",
            defaultValue: "Stop this turn and send it again immediately"
        )

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
