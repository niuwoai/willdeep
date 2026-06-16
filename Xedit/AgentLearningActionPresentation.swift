//
//  AgentLearningActionPresentation.swift
//  WillDeep
//
//  Shared display helpers for structured Agent learning actions.
//

import Foundation

enum AgentLearningActionPresentation {
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

    static func copyText(for event: AgentLearningEvent) -> String {
        var sections = [event.title]
        let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            sections.append(detail)
        }
        if let action = event.action {
            sections.append(summaryLines(for: action).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func compact(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
