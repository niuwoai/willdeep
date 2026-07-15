//
//  L10n+PlanModeSuggestion.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum PlanModeSuggestion {
        static let title = String(
            localized: "plan-mode-suggestion.title",
            defaultValue: "This task looks complex"
        )
        static let subtitle = String(
            localized: "plan-mode-suggestion.subtitle",
            defaultValue: "Switch to Plan mode before starting?"
        )
        static let enterPlanButton = String(
            localized: "plan-mode-suggestion.enter-plan",
            defaultValue: "Enter Plan"
        )
        static let continueNormallyButton = String(
            localized: "plan-mode-suggestion.continue-normally",
            defaultValue: "Continue normally"
        )
        static let countdownHint = String(
            localized: "plan-mode-suggestion.countdown-hint",
            defaultValue: "Entering Plan mode in %ds…"
        )

        static func countdownText(secondsRemaining: Int) -> String {
            String(format: countdownHint, secondsRemaining)
        }
    }
}
