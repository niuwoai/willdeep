//
//  L10n+ToolCard.swift
//  WillDeep
//
//  Sandbox-escalation copy for tool authorization cards. Kept out of the main
//  L10n.swift file so the complexity guard hard limit stays green.
//

import Foundation

extension L10n.ToolCard {
    static let askUserEyebrow = String(
        localized: "tool-card.ask-user.eyebrow",
        defaultValue: "Agent wants to know"
    )
    static let askUserSingleHint = String(
        localized: "tool-card.ask-user.single-hint",
        defaultValue: "Choose an answer or enter your own."
    )
    static let askUserMultipleHint = String(
        localized: "tool-card.ask-user.multiple-hint",
        defaultValue: "Choose one or more answers, or add your own."
    )
    static let askUserDefaultTitle = String(
        localized: "tool-card.ask-user.default-title",
        defaultValue: "Information needed"
    )
    static let askUserRequestedInformation = String(
        localized: "tool-card.ask-user.requested-information",
        defaultValue: "Please provide"
    )
    static let askUserDefaultAssumptions = String(
        localized: "tool-card.ask-user.default-assumptions",
        defaultValue: "Continue with these defaults"
    )
    static let askUserFooterTitle = String(
        localized: "tool-card.ask-user.footer-title",
        defaultValue: "Submit answer"
    )
    static let askUserFooterHint = String(
        localized: "tool-card.ask-user.footer-hint",
        defaultValue: "Agent will continue the current task using your answer."
    )

    static let sandboxEscalationTitle = String(
        localized: "tool-card.authorization.sandbox-escalation.title",
        defaultValue: "Sandbox blocked this command"
    )
    static let sandboxEscalationSubtitle = String(
        localized: "tool-card.authorization.sandbox-escalation.subtitle",
        defaultValue: "WillDeep can re-run the same command outside the sandbox if you approve."
    )
    static let sandboxEscalationMetadata = String(
        localized: "tool-card.authorization.sandbox-escalation.metadata",
        defaultValue: "Re-run leaves the default sandbox boundary"
    )
    static let sandboxEscalationExplanation = String(
        localized: "tool-card.authorization.sandbox-escalation.explanation",
        defaultValue: "Why this prompt"
    )
    static let sandboxEscalationDecisionTitle = String(
        localized: "tool-card.authorization.sandbox-escalation.decision-title",
        defaultValue: "Allow running outside the sandbox?"
    )
    static let sandboxEscalationDecisionSubtitle = String(
        localized: "tool-card.authorization.sandbox-escalation.decision-subtitle",
        defaultValue: "Use this when the sandbox denial is blocking routine work the Agent will retry."
    )
    static let sandboxEscalationDecline = String(
        localized: "tool-card.authorization.sandbox-escalation.decline",
        defaultValue: "Keep sandboxed"
    )
    static let sandboxEscalationApprove = String(
        localized: "tool-card.authorization.sandbox-escalation.approve",
        defaultValue: "Run without sandbox"
    )
    static let sandboxEscalationApprovalReason = String(
        localized: "tool-card.authorization.sandbox-escalation.approval-reason",
        defaultValue: "User approved re-running outside the sandbox after a sandbox denial."
    )
    static let sandboxEscalationAutomaticApprovalReason = String(
        localized: "tool-card.authorization.sandbox-escalation.automatic-approval-reason",
        defaultValue: "The active approval policy automatically authorized re-running the same command outside the sandbox."
    )
}
