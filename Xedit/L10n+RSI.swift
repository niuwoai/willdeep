import Foundation

extension L10n {
    enum RSI {
        static let feedbackTitle = String(localized: "rsi.feedback.title", defaultValue: "Was this result useful?")
        static let accepted = String(localized: "rsi.feedback.accepted", defaultValue: "Meets expectations")
        static let needsChanges = String(localized: "rsi.feedback.needs-changes", defaultValue: "Needs changes")
        static let skip = String(localized: "rsi.feedback.skip", defaultValue: "Skip")
        static let assess = String(localized: "rsi.feedback.assess", defaultValue: "Ask model to review")
        static let assessing = String(localized: "rsi.feedback.assessing", defaultValue: "Reviewing runtime evidence…")
        static let modelNeedsReview = String(localized: "rsi.feedback.model-needs-review", defaultValue: "Model suggestion: review this run. Your judgment is recorded separately.")
        static let modelUnknown = String(localized: "rsi.feedback.model-unknown", defaultValue: "Model suggestion: insufficient evidence. Your judgment is recorded separately.")
        static let assessmentFailed = String(localized: "rsi.feedback.assessment-failed", defaultValue: "Model review was unavailable. You can still give feedback.")
        static let runtimeConfiguration = String(localized: "rsi.runtime.configuration", defaultValue: "Runtime configuration")
        static let copyConfiguration = String(localized: "rsi.runtime.copy", defaultValue: "Copy configuration")
        static let exportConfiguration = String(localized: "rsi.runtime.export", defaultValue: "Export configuration")
        static let exportFailed = String(localized: "rsi.runtime.export-failed", defaultValue: "Could not export the runtime configuration.")
        static func evidence(successes: Int, failures: Int) -> String {
            String(format: String(localized: "rsi.feedback.evidence", defaultValue: "Tools: %d succeeded, %d failed. No independent verification."), successes, failures)
        }
    }
}
