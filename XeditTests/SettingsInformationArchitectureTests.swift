import Testing
@testable import WillDeep

struct SettingsInformationArchitectureTests {
    @Test("settings groups follow task-oriented information architecture")
    @MainActor
    func taskOrientedGroups() {
        #expect(SettingsGroup.allCases == [
            .general,
            .editing,
            .formatAndAppearance,
            .workspace,
            .ai,
            .agentTools,
            .accountAndDevices,
            .runtimes,
            .integrations,
            .terminal,
            .voice,
            .pet,
        ])
        // 编辑行为独立成组;格式与外观组承载皮肤/主题/壁纸/字体排印
        // (含 Agent 聊天字号)。
        #expect(SettingsGroup.editing.tabs == [.editing])
        #expect(SettingsGroup.formatAndAppearance.tabs == [.appearance, .background, .typography])
        #expect(SettingsGroup.ai.tabs == [.agent, .memory, .rules])
        #expect(SettingsGroup.agentTools.tabs == [.skills, .mcp, .tools])
        #expect(SettingsGroup.accountAndDevices.tabs == [.someIM, .mobileGateway])
    }

    @Test("every settings pane belongs to exactly one group")
    @MainActor
    func everyPaneHasOneGroup() {
        let groupedTabs = SettingsGroup.allCases.flatMap(\.tabs)
        #expect(Set(groupedTabs).count == groupedTabs.count)
        #expect(groupedTabs.contains(.updates))
        #expect(groupedTabs.contains(.editing))
        #expect(groupedTabs.contains(.background))
        #expect(groupedTabs.contains(.workspace))
        #expect(groupedTabs.contains(.voice))
    }
}
