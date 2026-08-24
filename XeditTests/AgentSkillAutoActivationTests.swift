//
//  AgentSkillAutoActivationTests.swift
//  XeditTests
//


import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSkillAutoActivationTests {
    private func skill(
        _ identifier: String,
        description: String,
        enabled: Bool = true
    ) -> AgentSkillEntry {
        AgentSkillEntry(
            identifier: identifier,
            name: identifier,
            description: description,
            url: URL(fileURLWithPath: "/tmp/\(identifier)/SKILL.md"),
            source: .user,
            isEnabled: enabled
        )
    }

    @Test
    func explicitSkillInvocationAlwaysActivates() {
        #expect(AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "Use $figma-swiftui for this screen",
            workspaceContainsSwiftProject: false
        ))
    }

    @Test
    func figmaURLActivatesInsideSwiftWorkspace() {
        #expect(AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "https://figma.com/design/example/app?node-id=1-2",
            workspaceContainsSwiftProject: true
        ))
    }

    @Test
    func attachedDesignRoutesToSwiftUISkillInSwiftWorkspace() {
        #expect(AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "照着这个实现页面",
            workspaceContainsSwiftProject: true,
            hasVisualTargetAttachment: true
        ))
    }

    @Test
    func explicitWebDestinationDoesNotRouteToSwiftUIInSwiftWorkspace() {
        #expect(!AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "照着这个实现成 React 前端",
            workspaceContainsSwiftProject: true,
            hasVisualTargetAttachment: true
        ))
    }

    @Test
    func bilingualTranslationRequestsActivate() {
        #expect(AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "把这个 Figma 设计稿还原成 SwiftUI 页面",
            workspaceContainsSwiftProject: false
        ))
        #expect(AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "Push this SwiftUI settings screen back into Figma",
            workspaceContainsSwiftProject: false
        ))
    }

    @Test
    func unrelatedSwiftOrFigmaConversationDoesNotActivate() {
        #expect(!AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "Why is this Swift actor isolated?",
            workspaceContainsSwiftProject: true
        ))
        #expect(!AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "介绍一下 Figma 和 SwiftUI 的区别",
            workspaceContainsSwiftProject: false
        ))
        #expect(!AgentSkillAutoActivation.shouldActivateFigmaSwiftUI(
            userText: "Implement this Figma landing page in React",
            workspaceContainsSwiftProject: false
        ))
    }

    @Test
    func selectedVisualWithImplementationIntentActivatesDesignToCode() {
        #expect(AgentSkillAutoActivation.shouldActivateDesignToCode(
            userText: "照这个做成前端",
            workspaceContainsWebProject: false,
            hasVisualTargetAttachment: true
        ))
        #expect(AgentSkillAutoActivation.shouldActivateDesignToCode(
            userText: "Implement https://figma.com/design/example as a React page",
            workspaceContainsWebProject: false,
            hasVisualTargetAttachment: false
        ))
    }

    @Test
    func critiqueImageEditingAndSwiftUITasksDoNotActivateDesignToCode() {
        #expect(!AgentSkillAutoActivation.shouldActivateDesignToCode(
            userText: "评价一下这个页面的视觉层级",
            workspaceContainsWebProject: true,
            hasVisualTargetAttachment: true
        ))
        #expect(!AgentSkillAutoActivation.shouldActivateDesignToCode(
            userText: "把这张图背景擦掉",
            workspaceContainsWebProject: true,
            hasVisualTargetAttachment: true
        ))
        #expect(!AgentSkillAutoActivation.shouldActivateDesignToCode(
            userText: "照着这个实现 SwiftUI 页面",
            workspaceContainsWebProject: false,
            hasVisualTargetAttachment: true,
            prefersSwiftUI: true
        ))
    }

    @Test
    func manualDesignToCodeSelectionPreventsCompetingAutomaticRouting() {
        let designSkill = AgentSkillEntry(
            identifier: "design-to-code",
            name: "Design to Code",
            description: "test",
            url: URL(fileURLWithPath: "/tmp/design-to-code/SKILL.md"),
            source: .bundled,
            isEnabled: true
        )

        let result = AgentSkillAutoActivation.mergedSkills(
            userText: "Use $design-to-code for this SwiftUI screenshot",
            workspaceRootPath: nil,
            manuallySelectedSkills: [designSkill],
            hasVisualTargetAttachment: true
        )

        #expect(result.map(\.identifier) == ["design-to-code"])
    }

    @Test
    func explicitGenericSkillInvocationAutoAttachesExactSkill() {
        let release = skill(
            "release-macos-app",
            description: "Release, sign, notarize, and publish an independently distributed macOS app."
        )
        let route = AgentSkillRouter.route(
            userText: "请使用 $release-macos-app 完成这次发布",
            availableSkills: [release]
        )

        #expect(route.autoAttach?.identifier == "release-macos-app")
        #expect(route.candidates.isEmpty)
    }

    @Test
    func strongMetadataMatchStaysACandidateWithoutExplicitIntent() {
        // 1.287.0-rc6: even a high-scoring metadata match no longer attaches a
        // body on its own — the model judges it via the `read_skill` hint. Only
        // `$name` invocation or a literal name mention is deterministic.
        let release = skill(
            "release-macos-app",
            description: "Release, build, sign, codesign, notarize, and publish a Swift macOS application."
        )
        let unrelated = skill(
            "system-info",
            description: "Inspect system memory, disk, network, and running processes."
        )
        let route = AgentSkillRouter.route(
            userText: "帮我发布这个 macOS App，完成签名和公证",
            availableSkills: [release, unrelated]
        )

        #expect(route.autoAttach == nil)
        #expect(route.candidates.first?.skill.identifier == "release-macos-app")
    }

    @Test
    func everydayCJKBigramOverlapDoesNotAutoAttach() {
        // Regression: "当前没有设计租户管理员的角色吗?" once auto-attached a
        // drama-writing skill because "没有" (from the description's own
        // "don't trigger" guard sentence) and "设计" were treated as rare,
        // high-value terms by catalog-relative IDF.
        let drama = skill(
            "hongguo-drama",
            description: "红果短剧/微短剧/竖屏爽剧创作技能。用于用户要求创作短剧剧本、分集大纲、爽点设计、钩子设计时。若用户只说普通电影剧本且没有短剧语境，不要优先触发。"
        )
        let unrelated = skill(
            "system-info",
            description: "Inspect system memory, disk, network, and running processes."
        )
        let route = AgentSkillRouter.route(
            userText: "当前没有设计租户管理员的角色吗?",
            availableSkills: [drama, unrelated]
        )

        #expect(route.autoAttach == nil)
    }

    @Test
    func literalChineseSkillNameMentionStillAutoAttaches() {
        let drama = AgentSkillEntry(
            identifier: "hongguo-drama",
            name: "红果短剧",
            description: "红果短剧/微短剧/竖屏爽剧创作技能。",
            url: URL(fileURLWithPath: "/tmp/hongguo-drama/SKILL.md"),
            source: .user,
            isEnabled: true
        )
        let route = AgentSkillRouter.route(
            userText: "帮我写一个红果短剧的分集大纲",
            availableSkills: [drama]
        )

        #expect(route.autoAttach?.identifier == "hongguo-drama")
    }

    @Test
    func ambiguousMetadataMatchesStayAsReadSkillCandidates() {
        let browser = skill(
            "browser",
            description: "Read and operate interactive web pages in a browser."
        )
        let webFetch = skill(
            "web-fetch",
            description: "Fetch and read a known public web page."
        )
        let route = AgentSkillRouter.route(
            userText: "帮我看看这个网页",
            availableSkills: [browser, webFetch]
        )

        #expect(route.autoAttach == nil)
        #expect(Set(route.candidates.map { $0.skill.identifier }) == ["browser", "web-fetch"])
    }

    @Test
    func disabledAndAlreadyAttachedSkillsAreNotRoutedAgain() {
        let manual = skill("daily-report", description: "Create a daily work report.")
        let disabled = skill("system-info", description: "Inspect system memory and disk.", enabled: false)
        let decision = AgentSkillAutoActivation.routingDecision(
            userText: "生成日报并查看系统内存",
            workspaceRootPath: nil,
            manuallySelectedSkills: [manual],
            availableSkills: [manual, disabled]
        )

        #expect(decision.attachedSkills.map(\.identifier) == ["daily-report"])
        #expect(decision.candidateSkills.isEmpty)
    }

    @Test @MainActor
    func ambiguousCandidatesAddOnlyCompactReadSkillHint() {
        let browser = skill(
            "browser",
            description: "Read and operate interactive web pages in a browser."
        )
        let candidate = AgentSkillRoutingCandidate(
            skill: browser,
            score: 3,
            matchedTerms: ["web"]
        )
        let prompt = AppState().composeAttachedPrompt(
            userText: "看看这个网页",
            skills: [],
            files: [],
            includeWorkspaceOverview: false,
            skillCandidates: [candidate]
        )

        #expect(prompt.contains("Skill routing candidates"))
        #expect(prompt.contains("`read_skill`"))
        #expect(prompt.contains("`browser`"))
        #expect(!prompt.contains("### Skill: browser"))
    }
}
