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
@MainActor
struct AgentLearningReviewActionPlannerTests {
    @Test
    func mcpSuggestionWithSearchQueryOffersTabAndCopyActions() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .mcpSuggestion,
                status: .suggested,
                title: "Suggest GitHub MCP",
                detail: "Need PR review thread access.",
                action: AgentLearningAction(
                    kind: .suggestMCPInstall,
                    commandName: "suggest_mcp_server",
                    searchQuery: "GitHub PR review MCP server",
                    mcpDraft: AgentLearningMCPDraft(
                        capability: "GitHub",
                        serverName: "github-mcp",
                        installHint: "Review GitHub MCP candidates before adding credentials.",
                        searchQuery: "GitHub PR review MCP server",
                        reason: "No configured GitHub review integration is available."
                    ),
                    reason: "No configured GitHub review integration is available.",
                    requiresUserConfirmation: true
                ),
                createdAt: Date()
            )
        )

        #expect(
            AgentLearningReviewActionPlanner.actions(for: item)
            == [.configureMCPFromDraft, .openMCPTab, .copySearchQuery]
        )
    }

    @Test
    func configureMCPFromDraftPublishesCoordinatorDraft() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .mcpSuggestion,
                status: .suggested,
                title: "Suggested MCP discovery for GitHub",
                detail: "Search query: GitHub PR review MCP server",
                action: AgentLearningAction(
                    kind: .suggestMCPInstall,
                    commandName: "suggest_mcp_server",
                    searchQuery: "GitHub PR review MCP server",
                    mcpDraft: AgentLearningMCPDraft(
                        capability: "GitHub",
                        serverName: "github-mcp",
                        installHint: "https://example.com/mcp/github",
                        searchQuery: "GitHub PR review MCP server",
                        reason: "No configured GitHub review integration is available."
                    ),
                    reason: "No configured GitHub review integration is available.",
                    requiresUserConfirmation: true
                )
            )
        )

        let opened = AgentLearningReviewActionPlanner.perform(.configureMCPFromDraft, for: item)
        let draft = AgentMCPServerCreationCoordinator.shared.consumeDraft()
        let reviewItemID = AgentMCPServerCreationCoordinator.shared.reviewItemID

        #expect(opened)
        #expect(draft?.serverName == "github-mcp")
        #expect(draft?.capability == "GitHub")
        #expect(reviewItemID == item.id)
        AgentMCPServerCreationCoordinator.shared.clearPendingReviewItem()
    }

    @Test
    func proposedSkillOffersSettingsAndFolderShortcuts() {
        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .skill,
                status: .suggested,
                title: "Skill candidate",
                detail: "Reusable workflow candidate.",
                action: AgentLearningAction(
                    kind: .proposeSkill,
                    commandName: "create_user_skill",
                    target: "release-checklist",
                    skillDraft: AgentLearningSkillDraft(
                        name: "release-checklist",
                        description: "Use before shipping a release.",
                        body: "Run tests and verify artifacts."
                    ),
                    reason: "The workflow repeated across multiple tool calls."
                ),
                createdAt: Date()
            )
        )

        #expect(
            AgentLearningReviewActionPlanner.actions(for: item)
            == [.editSkillDraft, .createSkillFromDraft, .openSkillsTab, .openSkillsFolder]
        )
    }

    @Test
    func createSkillFromDraftWritesUserSkillFile() throws {
        let root = try temporarySkillRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let item = AgentLearningReviewItem(
            event: AgentLearningEvent(
                kind: .skill,
                status: .skipped,
                title: "Skipped automatic skill extraction",
                detail: "Draft skill: release-checklist",
                action: AgentLearningAction(
                    kind: .proposeSkill,
                    commandName: "create_user_skill",
                    target: "release-checklist",
                    skillDraft: AgentLearningSkillDraft(
                        name: "release-checklist",
                        description: "Use before shipping a release.",
                        body: "Run tests and verify artifacts."
                    ),
                    reason: "Automatic extraction was disabled."
                )
            )
        )

        let created = AgentLearningReviewActionPlanner.perform(
            .createSkillFromDraft,
            for: item,
            skillRoot: root
        )

        let skillURL = root
            .appendingPathComponent("release-checklist")
            .appendingPathComponent("SKILL.md")
        let body = try String(contentsOf: skillURL, encoding: .utf8)

        #expect(created)
        #expect(body.contains("name: release-checklist"))
        #expect(body.contains("Use before shipping a release."))
        #expect(body.contains("Run tests and verify artifacts."))
    }

    private func temporarySkillRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
