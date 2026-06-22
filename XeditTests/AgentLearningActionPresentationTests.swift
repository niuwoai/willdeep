//
//  AgentLearningActionPresentationTests.swift
//  WillDeepTests
//
//  Covers explanation and confidence rendering for learning events.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentLearningActionPresentationTests {
    @Test
    func skillDraftSuggestionShowsMediumConfidenceAndReason() {
        let event = AgentLearningEvent(
            kind: .skill,
            status: .suggested,
            title: "Skill candidate",
            detail: """
            Reusable workflow candidate.
            Source: explicit user request to create/save a skill; relevant tools: search_files, run_command (3 calls).
            """,
            action: AgentLearningAction(
                kind: .proposeSkill,
                commandName: "create_user_skill",
                target: "release-checklist",
                skillDraft: AgentLearningSkillDraft(
                    name: "release-checklist",
                    description: "Use before shipping a release.",
                    body: "Run tests and verify artifacts."
                ),
                reason: "The workflow repeated across multiple tool calls.",
                nextStep: "Review and save the draft skill."
            )
        )

        let lines = AgentLearningActionPresentation.summaryLines(for: event)
        let conciseLines = AgentLearningActionPresentation.conciseSummaryLines(for: event)

        #expect(lines.contains(L10n.Transcript.learningActionReason("The workflow repeated across multiple tool calls.")))
        #expect(lines.contains(L10n.Transcript.learningActionConfidence(L10n.Transcript.learningConfidenceMedium)))
        #expect(lines.contains(L10n.Transcript.learningActionWhy(L10n.Transcript.learningExplanationDraftNeedsReview)))
        #expect(!conciseLines.contains(L10n.Transcript.learningActionReason("The workflow repeated across multiple tool calls.")))
        #expect(!conciseLines.contains(L10n.Transcript.learningActionConfidence(L10n.Transcript.learningConfidenceMedium)))
        #expect(!conciseLines.contains(L10n.Transcript.learningActionWhy(L10n.Transcript.learningExplanationDraftNeedsReview)))
        #expect(AgentLearningActionPresentation.Confidence.medium.shortLabel == L10n.Transcript.learningConfidenceMediumShort)
        #expect(AgentLearningActionPresentation.copyText(for: event).contains("Source: explicit user request"))
    }

    @Test
    func skippedLightEvidenceShowsLowConfidenceExplanation() {
        let event = AgentLearningEvent(
            kind: .skill,
            status: .skipped,
            title: "Skipped automatic skill creation",
            detail: "Reusable-workflow signal was present, but this turn only had 1 relevant tool call.",
            action: AgentLearningAction(
                kind: .proposeSkill,
                commandName: "create_user_skill",
                reason: "The turn mentioned reusable skills, but there was not enough executed tool evidence to safely create one.",
                nextStep: "Wait for a completed multi-tool workflow."
            )
        )

        let explanation = AgentLearningActionPresentation.explanation(for: event)

        #expect(explanation.confidence == .low)
        #expect(explanation.rationale == L10n.Transcript.learningExplanationNotEnoughEvidence)
    }

    @Test
    func successfulMemorySaveShowsHighConfidenceInCopyText() {
        let event = AgentLearningEvent(
            kind: .memory,
            status: .saved,
            title: "Saved 1 automatic learning memory",
            detail: "- User prefers yarn.",
            action: AgentLearningAction(
                kind: .saveMemory,
                commandName: "add_memory",
                target: "project memory",
                reason: "The turn contained durable self-learning policy or integration guidance.",
                nextStep: "Retrieve this memory before future turns."
            )
        )

        let text = AgentLearningActionPresentation.copyText(for: event)

        #expect(text.contains(L10n.Transcript.learningActionReason("The turn contained durable self-learning policy or integration guidance.")))
        #expect(text.contains(L10n.Transcript.learningActionConfidence(L10n.Transcript.learningConfidenceHigh)))
        #expect(text.contains(L10n.Transcript.learningExplanationCompletedFromDirectEvidence))
    }

    @Test
    func memorySuggestionDetailShowsOnlyContentUseAndAction() {
        let detail = AgentLearningActionPresentation.memorySuggestionDetail(for: [
            AgentMemoryDraft(
                content: "k3s 自带 traefik，如需 Let’s Encrypt 自动证书，可安装 cert-manager",
                scopeRaw: AgentMemoryScope.project.rawValue,
                lifetimeRaw: AgentMemoryLifetime.longTerm.rawValue,
                rootDirectoryPath: "/tmp/project"
            )
        ])

        #expect(detail.contains("`k3s 自带 traefik"))
        #expect(detail.contains(L10n.Transcript.learningMemorySuggestionUse))
        #expect(detail.contains(L10n.Transcript.learningMemorySuggestionAction))
        #expect(!detail.contains(L10n.Transcript.learningActionConfidence(L10n.Transcript.learningConfidenceHigh)))
        #expect(!detail.contains(L10n.Transcript.learningNextStepApprovePopover))
        #expect(!detail.contains(L10n.Transcript.learningReasonConversationContext))
    }
}
