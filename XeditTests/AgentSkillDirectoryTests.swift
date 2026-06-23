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
