//
//  AgentLearningReviewActionPlannerTests.swift
//  WillDeepTests
//
//  Covers actionable shortcuts surfaced in the learning-review queue.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentLearningReviewActionPlannerTests {
    @Test
    func mcpSuggestionWithSearchQueryOffersTabAndCopyActions() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .mcpSuggestion,
                status: .suggested,
                title: "Suggest GitHub MCP",
                detail: "Need PR review thread access.",
                createdAt: Date(),
                action: AgentLearningAction(
                    kind: .suggestMCPInstall,
                    commandName: "suggest_mcp_server",
                    searchQuery: "GitHub PR review MCP server",
                    requiresUserConfirmation: true
                )
            )
        )

        #expect(
            AgentLearningReviewActionPlanner.actions(for: item)
            == [.openMCPTab, .copySearchQuery]
        )
    }

    @Test
    func proposedSkillOffersSettingsAndFolderShortcuts() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .skill,
                status: .suggested,
                title: "Skill candidate",
                detail: "Reusable workflow candidate.",
                createdAt: Date(),
                action: AgentLearningAction(
                    kind: .proposeSkill,
                    commandName: "create_user_skill",
                    target: "release-checklist"
                )
            )
        )

        #expect(
            AgentLearningReviewActionPlanner.actions(for: item)
            == [.openSkillsTab, .openSkillsFolder]
        )
    }

    @Test
    func plainMemoryEventDoesNotSurfaceExtraQuickActions() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .memory,
                status: .saved,
                title: "Saved memory",
                detail: "Use yarn by default.",
                createdAt: Date()
            )
        )

        #expect(AgentLearningReviewActionPlanner.actions(for: item).isEmpty)
    }
}
