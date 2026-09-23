//
//  L10n+ContextRunwayHandoff.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum ContextRunwayHandoff {
        /// The word dropped into the composer by the "continue here" footer
        /// action. This one is not chrome — it is the text the operator is
        /// about to send to the model — so it follows the app language the
        /// same way the rest of the UI does. A Chinese user pressing the
        /// button should see 继续 in their own input box, not "Continue".
        static let resumeWord = String(
            localized: "context-runway-handoff.resume-word",
            defaultValue: "Continue"
        )
        static let resumeTooltip = String(
            localized: "context-runway-handoff.resume-tooltip",
            defaultValue: "Continue in this conversation"
        )
        static let newSessionTooltip = String(
            localized: "context-runway-handoff.new-session-tooltip",
            defaultValue: "Continue in a new session with the handover prompt"
        )
        /// Card title. Says *why* the turn stopped, because that is the one
        /// thing a handover is most often mistaken for ("did it give up?").
        static let cardTitle = String(
            localized: "context-runway-handoff.card-title",
            defaultValue: "Handover — the context window filled up"
        )
        /// Labels of the card's sections. The stored message keeps the
        /// model-facing English contract words; these are what a human reads.
        static func sectionTitle(for label: String) -> String {
            switch label {
            case "PAUSE": return sectionPause
            case "DONE": return sectionDone
            case "ANCHORS": return sectionAnchors
            case "REMAINING": return sectionRemaining
            // A label the contract grows later still has to render as
            // something: fall back to the model's own word rather than
            // dropping the section on the floor.
            default: return label
            }
        }
        static let sectionPause = String(
            localized: "context-runway-handoff.section.pause",
            defaultValue: "Why it stopped"
        )
        static let sectionDone = String(
            localized: "context-runway-handoff.section.done",
            defaultValue: "Verified so far"
        )
        static let sectionAnchors = String(
            localized: "context-runway-handoff.section.anchors",
            defaultValue: "Anchors"
        )
        static let sectionRemaining = String(
            localized: "context-runway-handoff.section.remaining",
            defaultValue: "Still to do"
        )
        static let sectionNextPrompt = String(
            localized: "context-runway-handoff.section.next-prompt",
            defaultValue: "What continuing will send"
        )
        /// Card action buttons. Unlike the old footer icons these carry text:
        /// an icon whose whole meaning is "which conversation does this
        /// continue in" cannot be guessed from a glyph.
        static let resumeAction = String(
            localized: "context-runway-handoff.resume-action",
            defaultValue: "Continue here"
        )
        static let newSessionAction = String(
            localized: "context-runway-handoff.new-session-action",
            defaultValue: "Continue in a new session"
        )
        /// Sidebar title of the session a handover was carried into.
        static func relaySessionTitle(_ sourceTitle: String) -> String {
            let template = String(
                localized: "context-runway-handoff.relay-session-title",
                defaultValue: "Continued: %@"
            )
            return String(format: template, sourceTitle)
        }
        /// Line left in the original session after compression failed and
        /// the work moved on.
        static func relayedNotice(_ relayTitle: String) -> String {
            let template = String(
                localized: "context-runway-handoff.relayed-notice",
                defaultValue: "Context compression failed, so the work continued in a new session with the handover: %@"
            )
            return String(format: template, relayTitle)
        }
    }
}
