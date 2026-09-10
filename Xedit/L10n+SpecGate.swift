//
//  L10n+SpecGate.swift
//  WillDeep
//
//  L10n strings for the design gate (transcript card + settings toggles).
//  Separate file to keep L10n.swift under the split threshold.
//

import Foundation

extension L10n {
    enum SpecGateCard {
        static let title = String(
            localized: "spec-gate-card.title",
            defaultValue: "Design written first"
        )
        static let accept = String(
            localized: "spec-gate-card.accept",
            defaultValue: "Build from this"
        )
        static let openDocument = String(
            localized: "spec-gate-card.open-document",
            defaultValue: "Open document"
        )
        static let dismiss = String(
            localized: "spec-gate-card.dismiss",
            defaultValue: "Skip it, just build"
        )
        static let accepted = String(
            localized: "spec-gate-card.accepted",
            defaultValue: "Building from this design"
        )
        static let dismissed = String(
            localized: "spec-gate-card.dismissed",
            defaultValue: "Skipped"
        )

        static func moreSignals(_ count: Int) -> String {
            String(
                format: String(
                    localized: "spec-gate-card.more-signals",
                    defaultValue: "and %lld more"
                ),
                count
            )
        }
    }

    enum SpecGateSettings {
        static let sectionTitle = String(
            localized: "spec-gate-settings.section-title",
            defaultValue: "Design before code"
        )
        static let detectionToggle = String(
            localized: "spec-gate-settings.detection-toggle",
            defaultValue: "Notice requests that want a design first"
        )
        static let detectionFootnote = String(
            localized: "spec-gate-settings.detection-footnote",
            defaultValue: "Records what it would have caught, without interrupting."
        )
        static let enforcementToggle = String(
            localized: "spec-gate-settings.enforcement-toggle",
            defaultValue: "Pause and write the design before making changes"
        )
        static let enforcementFootnote = String(
            localized: "spec-gate-settings.enforcement-footnote",
            defaultValue: "The agent writes a document under docs/ and waits for you. You can skip it on any card."
        )
    }
}
