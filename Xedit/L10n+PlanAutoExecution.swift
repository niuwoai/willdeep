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
            defaultValue: "Plan mode only plans. Approve to switch back to Normal mode and execute."
        )
        static let confirmButton = String(
            localized: "plan-auto-execution-banner.confirm",
            defaultValue: "Approve & Execute"
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
        static let manualConfirmHint = String(
            localized: "plan-auto-execution-banner.manual-confirm-hint",
            defaultValue: "Plans never auto-run — waiting for your confirmation."
        )
        static let dangerScanDisabledHint = String(
            localized: "plan-auto-execution-banner.danger-scan-disabled-hint",
            defaultValue: "Destructive-keyword guard is off."
        )
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
            defaultValue: "When on, the banner highlights plans that mention rm -rf, git push --force, dd, reboot, etc. so you review them extra carefully before approving."
        )
        static let clearSilentButton = String(
            localized: "plan-auto-execution-settings.clear-silent-button",
            defaultValue: "Re-enable Plan prompt for this workspace"
        )
        static let clearSilentHelp = String(
            localized: "plan-auto-execution-settings.clear-silent-help",
            defaultValue: "You previously chose to silently auto-execute plans in this workspace. Click to bring back the confirmation banner."
        )
        static let clearSilentEmpty = String(
            localized: "plan-auto-execution-settings.clear-silent-empty",
            defaultValue: "No silent-execution preference saved for the current workspace."
        )
        static let noWorkspace = String(
            localized: "plan-auto-execution-settings.no-workspace",
            defaultValue: "Open a workspace to manage its Plan auto-execution preference."
        )
    }
}
