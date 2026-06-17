//
//  L10n+PlanAutoExecution.swift
//  WillDeep
//
//  L10n strings for the Plan-mode auto-execution banner introduced in
//  1.79.0-rc1. Kept in a separate file to avoid bloating L10n.swift,
//  which is already approaching the 2000-line split threshold.
//

import Foundation

extension L10n {
    enum PlanAutoExecutionBanner {
        static let title = String(
            localized: "plan-auto-execution-banner.title",
            defaultValue: "Plan is ready"
        )
        static let subtitle = String(
            localized: "plan-auto-execution-banner.subtitle",
            defaultValue: "Switch to Agent mode and execute now?"
        )
        static let confirmButton = String(
            localized: "plan-auto-execution-banner.confirm",
            defaultValue: "Execute"
        )
        static let rejectButton = String(
            localized: "plan-auto-execution-banner.reject",
            defaultValue: "Stay in Plan"
        )
        static let rememberToggle = String(
            localized: "plan-auto-execution-banner.remember",
            defaultValue: "Don't ask again in this workspace"
        )
        static let dangerNotice = String(
            localized: "plan-auto-execution-banner.danger-notice",
            defaultValue: "Plan mentions destructive actions — confirm manually."
        )
        static let countdownHint = String(
            localized: "plan-auto-execution-banner.countdown-hint",
            defaultValue: "Auto-executing in %ds…"
        )
        static let dangerScanDisabledHint = String(
            localized: "plan-auto-execution-banner.danger-scan-disabled-hint",
            defaultValue: "Destructive-keyword guard is off."
        )

        static func countdownText(secondsRemaining: Int) -> String {
            String(format: countdownHint, secondsRemaining)
        }
    }

    enum PlanAutoExecutionSettings {
        static let sectionTitle = String(
            localized: "plan-auto-execution-settings.section",
            defaultValue: "Plan auto-execution"
        )
        static let dangerScanToggle = String(
            localized: "plan-auto-execution-settings.danger-scan",
            defaultValue: "Scan plan for destructive keywords"
        )
        static let dangerScanHelp = String(
            localized: "plan-auto-execution-settings.danger-scan-help",
            defaultValue: "When on, the Execute countdown disables itself if the plan mentions rm -rf, git push --force, dd, reboot, etc. You can still execute manually."
        )
    }
}
