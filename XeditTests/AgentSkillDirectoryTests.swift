//
//  AgentSkillDirectoryTests.swift
//  WillDeepTests
//
//  Covers built-in skill discovery and enable/disable filtering.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentSkillDirectoryTests {
    @Test
    func bundledBrowserSkillIsDiscovered() {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "browser", enabled: true)
        let skills = AgentSkillDirectory.list(includeDisabled: true)
        let browser = skills.first { $0.identifier == "browser" }

        #expect(browser != nil)
        #expect(browser?.source == .bundled)
        #expect(browser?.isEnabled == true)
    }

    @Test
    func bundledBrowserSkillDocumentsPlaywrightMCPPreset() throws {
        let skills = AgentSkillDirectory.list(includeDisabled: true)
        let browser = try #require(skills.first { $0.identifier == "browser" })
        let body = try String(contentsOf: browser.url, encoding: .utf8)

        #expect(body.contains("Playwright MCP"))
        #expect(body.contains("\"args\": [\"npx\", \"-y\", \"@playwright/mcp@latest\"]"))
        #expect(body.contains("npm_config_registry"))
        #expect(body.contains("https://registry.npmmirror.com"))
    }

    @Test
    func bundledSwiftUIHangDiagnoseSkillIsDiscoveredAndReadable() throws {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "swiftui-hang-diagnose", enabled: true)
        let skills = AgentSkillDirectory.list(includeDisabled: true)
        let skill = try #require(skills.first { $0.identifier == "swiftui-hang-diagnose" })
        let body = try #require(AgentSkillDirectory.loadBody(for: skill))

        #expect(skill.source == .bundled)
        #expect(skill.name == "swiftui-hang-diagnose")
        #expect(skill.description.contains("SwiftUI"))
        #expect(body.contains("sample <PID> 5 -mayDie"))
        #expect(body.contains("spindump <PID> 5"))
        #expect(body.contains("com.apple.main-thread"))
    }

    @Test
    func bundledFigmaSwiftUISkillSupportsAutomaticMCPFallback() throws {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "figma-swiftui", enabled: true)
        let skill = try #require(AgentSkillDirectory.bundledSkill(identifier: "figma-swiftui"))
        let body = try #require(AgentSkillDirectory.loadBody(for: skill))
        let references = skill.url.deletingLastPathComponent().appendingPathComponent("references")

        #expect(skill.source == .bundled)
        #expect(body.contains("list_mcp_servers"))
        #expect(body.contains("resource: references/design-to-code.md"))
        #expect(body.contains("resource: references/code-to-design.md"))
        #expect(FileManager.default.fileExists(atPath: references.appendingPathComponent("design-to-code.md").path))
        #expect(FileManager.default.fileExists(atPath: references.appendingPathComponent("code-to-design.md").path))

        let reference = try AgentSkillCatalog.readSkill(arguments: [
            "name": .string("figma-swiftui"),
            "resource": .string("references/design-to-code.md"),
        ])
        #expect(reference.payload.contains("Figma → SwiftUI"))
        #expect(reference.payload.contains("Map design structure to native SwiftUI"))

        #expect(throws: AgentToolError.self) {
            try AgentSkillCatalog.readSkill(arguments: [
                "name": .string("figma-swiftui"),
                "resource": .string("../../CHANGELOG.md"),
            ])
        }
    }

    @Test
    func automaticFigmaSwiftUIActivationRespectsDisabledSetting() {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "figma-swiftui", enabled: false)
        defer {
            AgentSkillSettingsStore.setSkillEnabled(identifier: "figma-swiftui", enabled: true)
        }

        let skills = AgentSkillAutoActivation.mergedSkills(
            userText: "请使用 $figma-swiftui 把这个设计稿实现成 SwiftUI",
            workspaceRootPath: nil,
            manuallySelectedSkills: []
        )

        #expect(skills.isEmpty)
    }

    @Test
    func bundledDesignToCodeSkillIsDiscoverableAndReadable() throws {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "design-to-code", enabled: true)
        let skill = try #require(AgentSkillDirectory.bundledSkill(identifier: "design-to-code"))
        let body = try #require(AgentSkillDirectory.loadBody(for: skill))

        #expect(skill.source == .bundled)
        #expect(body.contains("references/implementation-workflow.md"))
        #expect(body.contains("references/design-qa.md"))

        let workflow = try AgentSkillCatalog.readSkill(arguments: [
            "name": .string("design-to-code"),
            "resource": .string("references/implementation-workflow.md"),
        ])
        #expect(workflow.payload.contains("Design-to-Code Implementation Workflow"))
        #expect(workflow.payload.contains("Compare and iterate"))
    }

    @Test
    func automaticDesignToCodeActivationRespectsDisabledSetting() {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "design-to-code", enabled: false)
        defer {
            AgentSkillSettingsStore.setSkillEnabled(identifier: "design-to-code", enabled: true)
        }

        let skills = AgentSkillAutoActivation.mergedSkills(
            userText: "照这个做成前端",
            workspaceRootPath: nil,
            manuallySelectedSkills: [],
            hasVisualTargetAttachment: true
        )

        #expect(skills.isEmpty)
    }

    @Test
    func disabledSkillIsHiddenFromAgentListButVisibleInSettingsList() {
        AgentSkillSettingsStore.setSkillEnabled(identifier: "browser", enabled: false)
        defer {
            AgentSkillSettingsStore.setSkillEnabled(identifier: "browser", enabled: true)
        }

        let settingsList = AgentSkillDirectory.list(includeDisabled: true)
        let agentList = AgentSkillDirectory.list(includeDisabled: false)

        #expect(settingsList.contains { $0.identifier == "browser" && !$0.isEnabled })
        #expect(!agentList.contains { $0.identifier == "browser" })
    }

    @Test
    func userSkillDeleteRemovesSkillDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepSkillDeleteTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let skillURL = try AgentSkillFileManager.createUserSkill(
            name: "Delete Me",
            description: "Temporary skill",
            body: "Use only inside this test.",
            root: root
        )
        let skillDirectory = skillURL.deletingLastPathComponent()
        let entry = AgentSkillEntry(
            identifier: "delete-me",
            name: "Delete Me",
            description: "Temporary skill",
            url: skillURL,
            source: .user,
            isEnabled: true
        )

        try AgentSkillFileManager.deleteUserSkill(entry, allowedRoots: [root])

        #expect(!FileManager.default.fileExists(atPath: skillDirectory.path))
    }

    @Test
    func userSkillUpdatePreservesSafeFrontMatterAndBody() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepSkillUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let skillURL = try AgentSkillFileManager.createUserSkill(
            name: "Update Me",
            description: "Old description",
            body: "# Update Me\n\nOld body.",
            root: root
        )
        let entry = AgentSkillEntry(
            identifier: "update-me",
            name: "Update Me",
            description: "Old description",
            url: skillURL,
            source: .user,
            isEnabled: true
        )

        try AgentSkillFileManager.updateUserSkill(
            entry,
            description: "New description",
            body: "# Update Me\n\nNew instructions.",
            allowedRoots: [root]
        )
        let text = try String(contentsOf: skillURL, encoding: .utf8)

        #expect(text.contains("name: Update Me"))
        #expect(text.contains("description: New description"))
        #expect(text.contains("New instructions."))
        #expect(!text.contains("Old body."))
    }

    @Test
    func deleteRejectsNonUserSkills() throws {
        let entry = AgentSkillEntry(
            identifier: "browser",
            name: "browser",
            description: "",
            url: URL(fileURLWithPath: "/Applications/WillDeep.app/Contents/Resources/BundledSkills/browser/SKILL.md"),
            source: .bundled,
            isEnabled: true
        )

        do {
            try AgentSkillFileManager.deleteUserSkill(entry)
            Issue.record("Expected bundled skill deletion to fail.")
        } catch AgentSkillFileError.notUserSkill {
            #expect(true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
