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
    }
}
