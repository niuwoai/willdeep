//
//  AgentLearningActionPresentation.swift
//  WillDeep
//
//  Shared display helpers for structured Agent learning actions.
//

import Foundation

enum AgentLearningActionPresentation {
    enum Confidence: String {
        case low
        case medium
        case high

        var label: String {
            switch self {
            case .low:
                return L10n.Transcript.learningConfidenceLow
            case .medium:
                return L10n.Transcript.learningConfidenceMedium
            case .high:
                return L10n.Transcript.learningConfidenceHigh
            }
        }
    }

    static func label(for kind: AgentLearningActionKind) -> String {
        switch kind {
        case .saveMemory:
            return L10n.Transcript.learningActionSaveMemory
        case .createSkill:
            return L10n.Transcript.learningActionCreateSkill
        case .proposeSkill:
            return L10n.Transcript.learningActionProposeSkill
        case .searchMCP:
            return L10n.Transcript.learningActionSearchMCP
        case .suggestMCPInstall:
            return L10n.Transcript.learningActionSuggestMCPInstall
        }
    }

    static func summaryLines(for action: AgentLearningAction) -> [String] {
        var lines = [label(for: action.kind)]
        if let commandName = compact(action.commandName) {
            lines.append(L10n.Transcript.learningActionCommand(commandName))
        }
        if let target = compact(action.target) {
            lines.append(L10n.Transcript.learningActionTarget(target))
        }
        if let searchQuery = compact(action.searchQuery) {
            lines.append(L10n.Transcript.learningActionSearchQuery(searchQuery))
        }
        if action.requiresUserConfirmation {
            lines.append(L10n.Transcript.learningActionNeedsConfirmation)
        }
        if let nextStep = compact(action.nextStep) {
            lines.append(L10n.Transcript.learningActionNextStep(nextStep))
        }
        return lines
    }

    static func summaryLines(for event: AgentLearningEvent) -> [String] {
        guard let action = event.action else { return [] }

        var lines = summaryLines(for: action)
        if let reason = compact(action.reason) {
            lines.append(L10n.Transcript.learningActionReason(reason))
        }
        let explanation = explanation(for: event)
        lines.append(L10n.Transcript.learningActionConfidence(explanation.confidence.label))
        lines.append(L10n.Transcript.learningActionWhy(explanation.rationale))
        return lines
    }

    static func confidence(for event: AgentLearningEvent) -> Confidence {
        explanation(for: event).confidence
    }

    static func copyText(for event: AgentLearningEvent) -> String {
        var sections = [event.title]
        let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            sections.append(detail)
        }
        let actionLines = summaryLines(for: event)
        if !actionLines.isEmpty {
            sections.append(actionLines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    static func explanation(for event: AgentLearningEvent) -> (confidence: Confidence, rationale: String) {
        guard let action = event.action else {
            switch event.status {
            case .saved, .created:
                return (.high, L10n.Transcript.learningExplanationCompleted)
            case .suggested:
                return (.medium, L10n.Transcript.learningExplanationNeedsReview)
            case .skipped, .failed:
                return (.low, L10n.Transcript.learningExplanationCouldNotFinish)
            }
        }

        if event.status == .failed {
            return (.low, L10n.Transcript.learningExplanationAutomaticStepFailed)
        }

        if let reason = compact(action.reason)?.lowercased(),
           reason.contains("not enough executed tool evidence") {
            return (.low, L10n.Transcript.learningExplanationNotEnoughEvidence)
        }

        switch action.kind {
        case .saveMemory, .createSkill:
            return (.high, L10n.Transcript.learningExplanationCompletedFromDirectEvidence)
        case .proposeSkill:
            if action.skillDraft != nil {
                return (.medium, L10n.Transcript.learningExplanationDraftNeedsReview)
            }
            return (.low, L10n.Transcript.learningExplanationSignalTooThin)
        case .searchMCP, .suggestMCPInstall:
            return (.medium, L10n.Transcript.learningExplanationMCPNeedsConfirmation)
        }
    }

    private static func compact(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
