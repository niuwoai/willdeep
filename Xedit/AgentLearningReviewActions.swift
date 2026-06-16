//
//  AgentLearningReviewActions.swift
//  WillDeep
//
//  Action planning and execution helpers for the learning-review queue.
//

import AppKit
import Foundation

enum AgentLearningReviewQuickAction: String, Equatable, CaseIterable, Identifiable {
    case openSkillsTab
    case openSkillsFolder
    case openMCPTab
    case copySearchQuery

    var id: String { rawValue }
}

enum AgentLearningReviewActionPlanner {
    static func actions(for item: AgentLearningReviewItem) -> [AgentLearningReviewQuickAction] {
        guard let action = item.event.action else {
            switch item.event.kind {
            case .skill:
                return [.openSkillsTab]
            case .mcpSuggestion:
                return [.openMCPTab]
            case .memory:
                return []
            }
        }

        var planned: [AgentLearningReviewQuickAction] = []
        switch action.kind {
        case .saveMemory:
            break
        case .createSkill, .proposeSkill:
            planned.append(.openSkillsTab)
            planned.append(.openSkillsFolder)
        case .searchMCP, .suggestMCPInstall:
            planned.append(.openMCPTab)
            if compact(action.searchQuery) != nil {
                planned.append(.copySearchQuery)
            }
        }
        return deduplicated(planned)
    }

    @discardableResult
    @MainActor
    static func perform(_ quickAction: AgentLearningReviewQuickAction, for item: AgentLearningReviewItem) -> Bool {
        switch quickAction {
        case .openSkillsTab:
            EditorSettingsNavigation.shared.open(.skills)
            return true
        case .openSkillsFolder:
            do {
                try FileManager.default.createDirectory(
                    at: AgentSkillDirectory.userSkillsRoot,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(AgentSkillDirectory.userSkillsRoot)
                return true
            } catch {
                return false
            }
        case .openMCPTab:
            EditorSettingsNavigation.shared.open(.mcp)
            return true
        case .copySearchQuery:
            guard let query = compact(item.event.action?.searchQuery) else { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(query, forType: .string)
            return true
        }
    }

    private static func compact(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func deduplicated(_ actions: [AgentLearningReviewQuickAction]) -> [AgentLearningReviewQuickAction] {
        var seen = Set<AgentLearningReviewQuickAction>()
        return actions.filter { seen.insert($0).inserted }
    }
}
