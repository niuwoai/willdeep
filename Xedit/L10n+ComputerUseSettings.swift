//
//  L10n+ComputerUseSettings.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum ComputerUseSettings {
        static let sectionTitle = String(
            localized: "settings.computer-use.section-title",
            defaultValue: "Computer Use Permissions"
        )
        static let helperName = String(
            localized: "settings.computer-use.helper-name",
            defaultValue: "WillDeep Computer Use"
        )
        static let accessibilityTitle = String(
            localized: "settings.computer-use.accessibility-title",
            defaultValue: "Accessibility"
        )
        static let accessibilityDetail = String(
            localized: "settings.computer-use.accessibility-detail",
            defaultValue: "Required to click, type, scroll, and inspect app controls."
        )
        static let screenCaptureTitle = String(
            localized: "settings.computer-use.screen-capture-title",
            defaultValue: "Screen & System Audio Recording"
        )
        static let screenCaptureDetail = String(
            localized: "settings.computer-use.screen-capture-detail",
            defaultValue: "Required to capture the visible interface and verify Computer Use results."
        )
        static let statusChecking = String(
            localized: "settings.computer-use.status.checking",
            defaultValue: "Checking Accessibility permission…"
        )
        static let statusGranted = String(
            localized: "settings.computer-use.status.granted",
            defaultValue: "Granted"
        )
        static let statusNotGranted = String(
            localized: "settings.computer-use.status.not-granted",
            defaultValue: "Not granted"
        )
        static func statusFailed(_ message: String) -> String {
            let template = String(
                localized: "settings.computer-use.status.failed",
                defaultValue: "Could not read permission status: %@"
            )
            return String(format: template, message)
        }
        static let requestButton = String(
            localized: "settings.computer-use.request-button",
            defaultValue: "Request Permission"
        )
        static let refreshButtonHelp = String(
            localized: "settings.computer-use.refresh-button-help",
            defaultValue: "Refresh permission status"
        )
        static let explanation = String(
            localized: "settings.computer-use.explanation",
            defaultValue: "These permissions belong to the separately signed WillDeep Computer Use helper. Granting them to the main WillDeep app does not grant them to the helper. System audio is not recorded or saved by Computer Use."
        )
    }
}
