//
//  AgentSkillAutoActivationTests.swift
//  XeditTests
//


import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSkillAutoActivationTests {
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
}
