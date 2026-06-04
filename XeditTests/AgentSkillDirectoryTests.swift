//
//  AgentSkillDirectoryTests.swift
//  VeilWriterTests
//
//  Covers built-in skill discovery and enable/disable filtering.
//

import Testing
import Foundation
@testable import VeilWriter

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
}
