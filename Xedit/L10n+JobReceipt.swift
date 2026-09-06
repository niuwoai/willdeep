import Foundation

extension L10n {
    enum JobReceipt {
        static let deadlineUnsupported = String(localized: "job-receipt.deadline-unsupported", defaultValue: "This runtime cannot enforce the Goal deadline. Update the daemon before starting this task; no command was launched.")
        static let command = String(localized: "job-receipt.command", defaultValue: "Remote command")
        static let notStarted = String(localized: "job-receipt.not-started", defaultValue: "The server confirmed that this request did not start a process.")
        static let recoveryUnavailable = String(localized: "job-receipt.recovery-unavailable", defaultValue: "A previous remote task could not be safely reconciled. Its recovery receipt is retained; do not repeat the execution.")
        static let reconnecting = String(localized: "job-receipt.reconnecting", defaultValue: "Recovering connection automatically")
        static let outputGap = String(localized: "job-receipt.output-gap", defaultValue: "Some remote output is unavailable. The displayed output is incomplete; verify artifacts before accepting the result.")
        static let stopping = String(localized: "job-receipt.stopping", defaultValue: "Awaiting exit confirmation")
        static let unknown = String(localized: "job-receipt.unknown", defaultValue: "Exit unconfirmed")
        static let unconfirmed = String(localized: "job-receipt.unconfirmed", defaultValue: "The remote process may still be running. Its job record is retained; do not launch a duplicate task.")
    }
}
