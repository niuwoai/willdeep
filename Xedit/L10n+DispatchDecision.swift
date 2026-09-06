import Foundation

extension L10n {
    enum DispatchDecision {
        static let resourcesBusy = String(localized: "dispatch-decision.resources-busy", defaultValue: "Waiting for dependencies, an execution slot, or shared resources.")
        static let waiting = String(localized: "dispatch-decision.waiting", defaultValue: "Waiting for a decision")
        static let explanation = String(localized: "dispatch-decision.explanation", defaultValue: "Answer once for the tasks listed below. Independent work may continue. Answers do not grant additional tool permissions.")
        static let assumptions = String(localized: "dispatch-decision.assumptions", defaultValue: "Proposed assumptions")
        static let answerPlaceholder = String(localized: "dispatch-decision.answer", defaultValue: "Your answer")
        static let submit = String(localized: "dispatch-decision.submit", defaultValue: "Save answer and continue")
        static let recorded = String(localized: "dispatch-decision.recorded", defaultValue: "Answer saved. Resumption still requires a valid task contract, workspace and execution budget.")
    }
}
