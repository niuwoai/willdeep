import Foundation

/// Preserve host admission failures across a background runner's display
/// report. These are not provider failures and must not buy a fallback call.
nonisolated enum AgentAuxiliaryRequestStop: Equatable {
    case admission(AgentModelRequestLedger.Failure)
    case executionBudget

    init?(_ error: Error) {
        if let failure = error as? AgentModelRequestLedger.Failure {
            self = .admission(failure)
        } else if error is AgentToolExecutionBudgetError {
            self = .executionBudget
        } else {
            return nil
        }
    }

    @MainActor var notice: String {
        switch self {
        case .admission(.budgetExceeded): L10n.GoalAdmission.exhausted
        case .admission(.unknownExposure): L10n.GoalAdmission.unknown
        case .admission: L10n.GoalAdmission.unavailable
        case .executionBudget: L10n.GoalAdmission.executionExhausted
        }
    }
}
