import Testing
@testable import WillDeep

struct SettingsInformationArchitectureTests {
    @Test("settings groups follow task-oriented information architecture")
    @MainActor
    func taskOrientedGroups() {
        #expect(SettingsGroup.allCases == [
            .general,
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
        #expect(groupedTabs.contains(.background))
        #expect(groupedTabs.contains(.workspace))
        #expect(groupedTabs.contains(.voice))
    }
}
