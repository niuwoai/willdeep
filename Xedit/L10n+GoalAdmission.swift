import Foundation

extension L10n {
    enum GoalAdmission {
        static let unavailable = String(localized: "goal-admission.unavailable", defaultValue: "The Goal request ledger cannot be verified safely. Automatic work is paused; no fallback model will bypass accounting.")
        static let executionExhausted = String(localized: "goal-admission.execution-exhausted", defaultValue: "The Goal execution segment has ended. Auxiliary model work is paused without another paid handover.")
        static let exhausted = String(localized: "goal-admission.exhausted", defaultValue: "The remaining Goal admission budget cannot fit another model request. Automatic work is paused.")
        static let unknown = String(localized: "goal-admission.unknown", defaultValue: "Model usage cannot be quantified safely for this budget. Automatic work is paused; unknown usage was not treated as zero.")
        static let handover = String(localized: "goal-admission.handover", defaultValue: "This is a host-generated handover, not proof of completion. Existing work, receipts and queued input are preserved. No extra model request was made to produce this notice. Remaining acceptance items:")
    }
}
