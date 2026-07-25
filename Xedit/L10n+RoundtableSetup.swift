//
//  L10n+RoundtableSetup.swift
//  WillDeep
//
//  圆桌准备室与专家组队文案。单独拆出，避免继续膨胀主 L10n.swift。
//

import Foundation

extension L10n {
    enum RoundtableSetup {
        static let preparationTitle = String(
            localized: "roundtable.setup.preparation-title",
            defaultValue: "Shape the question before the discussion"
        )
        static let preparationSubtitle = String(
            localized: "roundtable.setup.preparation-subtitle",
            defaultValue: "WillDeep will clarify the decision, propose a framework, and suggest a panel. You stay in control before anyone speaks."
        )
        static let originalTopic = String(
            localized: "roundtable.setup.original-topic",
            defaultValue: "Your original question"
        )
        static let refinedTopic = String(
            localized: "roundtable.setup.refined-topic",
            defaultValue: "Question to decide"
        )
        static let frameworkTitle = String(
            localized: "roundtable.setup.framework-title",
            defaultValue: "Discussion framework"
        )
        static let clarificationTitle = String(
            localized: "roundtable.setup.clarification-title",
            defaultValue: "Worth clarifying"
        )
        static let recommendationTitle = String(
            localized: "roundtable.setup.recommendation-title",
            defaultValue: "Suggested panel"
        )
        static let recommendationHint = String(
            localized: "roundtable.setup.recommendation-hint",
            defaultValue: "These are suggestions, not a fixed lineup. You can add or remove experts next."
        )
        static let refinePlaceholder = String(
            localized: "roundtable.setup.refine-placeholder",
            defaultValue: "Add context, correct an assumption, or change the discussion focus…"
        )
        static let refineAction = String(
            localized: "roundtable.setup.refine-action",
            defaultValue: "Refine again"
        )
        static let refining = String(
            localized: "roundtable.setup.refining",
            defaultValue: "Reframing the question…"
        )
        static let chooseExpertsAction = String(
            localized: "roundtable.setup.choose-experts-action",
            defaultValue: "Review the expert panel"
        )
        static let preparing = String(
            localized: "roundtable.setup.preparing",
            defaultValue: "Preparing the discussion framework…"
        )
        static let assistantName = String(
            localized: "roundtable.setup.assistant-name",
            defaultValue: "WillDeep · Meeting prep"
        )
        static let userName = String(
            localized: "roundtable.setup.user-name",
            defaultValue: "You"
        )
        static let backAction = String(
            localized: "roundtable.setup.back-action",
            defaultValue: "Back"
        )
        static let retryHint = String(
            localized: "roundtable.setup.retry-hint",
            defaultValue: "Your current framework is preserved. Add context and try again."
        )
        static let selectionTitle = String(
            localized: "roundtable.setup.selection-title",
            defaultValue: "Choose who joins the discussion"
        )
        static let selectionSubtitle = String(
            localized: "roundtable.setup.selection-subtitle",
            defaultValue: "Start with the suggested panel, then add the perspectives you want. A focused group usually reaches a better conclusion."
        )
        static let aiRecommended = String(
            localized: "roundtable.setup.ai-recommended",
            defaultValue: "AI suggested"
        )
        static let allExperts = String(
            localized: "roundtable.setup.all-experts",
            defaultValue: "All built-in experts"
        )
        static let selected = String(
            localized: "roundtable.setup.selected",
            defaultValue: "Selected"
        )
        static let available = String(
            localized: "roundtable.setup.available",
            defaultValue: "Available"
        )
        static let editFrameworkAction = String(
            localized: "roundtable.setup.edit-framework-action",
            defaultValue: "Edit the framework"
        )
        static let confirmPanelAction = String(
            localized: "roundtable.setup.confirm-panel-action",
            defaultValue: "Confirm panel and start"
        )
        static let startingDiscussion = String(
            localized: "roundtable.setup.starting-discussion",
            defaultValue: "Inviting the experts…"
        )
        static let tooFewExperts = String(
            localized: "roundtable.setup.too-few-experts",
            defaultValue: "Choose at least 2 experts to create a real discussion."
        )
        static let maximumExpertsReached = String(
            localized: "roundtable.setup.maximum-experts-reached",
            defaultValue: "The panel can include up to 6 experts."
        )
        static let expertSpeakingDetail = String(
            localized: "roundtable.setup.expert-speaking-detail",
            defaultValue: "The response is appearing live as it is generated."
        )
        static let liveSpeaking = String(
            localized: "roundtable.setup.live-speaking",
            defaultValue: "Speaking live"
        )
        static let analyzingStance = String(
            localized: "roundtable.setup.analyzing-stance",
            defaultValue: "Organizing the stance"
        )
        static let analyzingStanceDetail = String(
            localized: "roundtable.setup.analyzing-stance-detail",
            defaultValue: "The speech is complete. Updating the stance board…"
        )

        static func selectionCount(_ count: Int) -> String {
            let template = String(
                localized: "roundtable.setup.selection-count",
                defaultValue: "%d of 6 selected"
            )
            return String(format: template, count)
        }

        static func recommendedForTopic(_ expert: String) -> String {
            let template = String(
                localized: "roundtable.setup.recommended-for-topic",
                defaultValue: "Why %@ is suggested"
            )
            return String(format: template, expert)
        }

        static func expertSpeaking(_ expert: String) -> String {
            let template = String(
                localized: "roundtable.setup.expert-speaking-format",
                defaultValue: "%@ is speaking"
            )
            return String(format: template, expert)
        }

        static func expertFinishedSpeaking(_ expert: String) -> String {
            let template = String(
                localized: "roundtable.setup.expert-finished-speaking-format",
                defaultValue: "%@ has finished speaking"
            )
            return String(format: template, expert)
        }
    }
}
