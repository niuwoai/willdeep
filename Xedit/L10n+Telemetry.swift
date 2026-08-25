//
//  L10n+Telemetry.swift
//  WillDeep
//
//  隐私与产品遥测设置页的文案。
//

import Foundation

extension L10n {
    enum Telemetry {
        static let tabTitle = String(
            localized: "settings.privacy.tab",
            defaultValue: "Privacy"
        )
        static let sectionTitle = String(
            localized: "settings.privacy.section",
            defaultValue: "Product Analytics"
        )
        static let toggleTitle = String(
            localized: "settings.privacy.toggle",
            defaultValue: "Help improve WillDeep"
        )
        static let toggleHelp = String(
            localized: "settings.privacy.toggle-help",
            defaultValue: "Sends anonymous usage data so we can see which models and features people actually use, and where requests fail. You can turn this off at any time."
        )

        static let collectedTitle = String(
            localized: "settings.privacy.collected-title",
            defaultValue: "What is sent"
        )
        static let collectedBody = String(
            localized: "settings.privacy.collected-body",
            defaultValue: "App version, macOS major version, CPU architecture, interface language; which AI provider and model a request used, whether it succeeded, how long it took, token counts, and structured error codes; which features were used and how often."
        )

        static let notCollectedTitle = String(
            localized: "settings.privacy.not-collected-title",
            defaultValue: "What is never sent"
        )
        static let notCollectedBody = String(
            localized: "settings.privacy.not-collected-body",
            defaultValue: "Your prompts and the model's replies, file names or paths, file contents, terminal commands and output, screenshots, clipboard, API keys, your email or nickname, raw error text, and hardware identifiers. The server has no column that could store any of it."
        )

        static let identitySection = String(
            localized: "settings.privacy.identity-section",
            defaultValue: "Anonymous Identifier"
        )
        static let identityHelp = String(
            localized: "settings.privacy.identity-help",
            defaultValue: "A random ID generated on this Mac, not derived from any hardware identifier. Resetting it deletes the data reported under the old ID and starts a new one."
        )
        static let resetIdentity = String(
            localized: "settings.privacy.reset-identity",
            defaultValue: "Reset Identifier"
        )
        static let identityReset = String(
            localized: "settings.privacy.identity-reset",
            defaultValue: "A new anonymous identifier is in use. Data reported under the previous one has been deleted."
        )

        static let deleteSection = String(
            localized: "settings.privacy.delete-section",
            defaultValue: "Your Data"
        )
        static let deleteData = String(
            localized: "settings.privacy.delete-data",
            defaultValue: "Delete Reported Data"
        )
        static let deleteHelp = String(
            localized: "settings.privacy.delete-help",
            defaultValue: "Removes everything reported from this installation. Aggregate daily counts contain no identifiers and are not affected."
        )
        static let deleteRequested = String(
            localized: "settings.privacy.delete-requested",
            defaultValue: "Deletion requested."
        )

        static let endpointLabel = String(
            localized: "settings.privacy.endpoint",
            defaultValue: "Reporting endpoint"
        )
        static let identifierLabel = String(
            localized: "settings.privacy.identifier",
            defaultValue: "Identifier"
        )
        static let disabledNotice = String(
            localized: "settings.privacy.disabled-notice",
            defaultValue: "Analytics is off. Nothing is collected, and the local queue has been cleared."
        )
    }
}
