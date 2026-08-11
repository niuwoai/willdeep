import Testing
@testable import WillDeep

struct SettingsInformationArchitectureTests {
    @Test("settings groups follow task-oriented information architecture")
    @MainActor
    func taskOrientedGroups() {
        #expect(SettingsGroup.allCases == [
            .accountAndDevices,
            .ai,
            .agentTools,
            .runtimes,
            .integrations,
            .terminal,
            .voice,
            .pet,
            .editor,
            .agentAppearance,
            .general,
        ])
        // 编辑器组同时承载工作区设置，并在侧栏中排倒数第二。
        #expect(SettingsGroup.editor.tabs == [.editing, .appearance, .typography, .workspace])
        #expect(SettingsGroup.agentAppearance.tabs == [.agentAppearance])
        #expect(EditorSettingsTab.agentAppearance.group == .agentAppearance)
        #expect(SettingsGroup.allCases.suffix(3) == [.editor, .agentAppearance, .general])
        #expect(SettingsGroup.ai.tabs == [.agent, .subagents, .memory, .rules])
        #expect(SettingsGroup.agentTools.tabs == [.skills, .mcp, .tools])
        #expect(SettingsGroup.accountAndDevices.tabs == [.someIM, .mobileGateway])
        // 连接器 hub 是集成组唯一的 pane;每个外部集成是 hub 里的子连接器。
        #expect(SettingsGroup.integrations.tabs == [.connectors])
    }

    @Test("every settings pane belongs to exactly one group")
    @MainActor
    func everyPaneHasOneGroup() {
        let groupedTabs = SettingsGroup.allCases.flatMap(\.tabs)
        #expect(Set(groupedTabs).count == groupedTabs.count)
        #expect(groupedTabs.contains(.updates))
        #expect(groupedTabs.contains(.editing))
        #expect(groupedTabs.contains(.workspace))
        #expect(groupedTabs.contains(.agentAppearance))
        #expect(groupedTabs.contains(.subagents))
        #expect(groupedTabs.contains(.voice))
    }

    @Test("the replicate deep-link tab still resolves inside the integrations group")
    @MainActor
    func replicateDeepLinkResolvesToIntegrations() {
        // `.replicate` is no longer a standalone pane, but existing
        // deep-links (image edit panel) must keep landing on the hub.
        #expect(EditorSettingsTab.replicate.group == .integrations)
        #expect(EditorSettingsTab.connectors.group == .integrations)
    }
}

struct AgentSkillPaginationTests {
    @Test("page count rounds up and never drops below one")
    func pageCountBounds() {
        #expect(AgentSkillPagination.pageCount(totalCount: 0) == 1)
        #expect(AgentSkillPagination.pageCount(totalCount: 1) == 1)
        #expect(AgentSkillPagination.pageCount(totalCount: 20) == 1)
        #expect(AgentSkillPagination.pageCount(totalCount: 21) == 2)
        #expect(AgentSkillPagination.pageCount(totalCount: 300) == 15)
    }

    @Test("slices are bounded and clamp out-of-range pages")
    func sliceBounds() {
        let items = Array(0..<45)
        #expect(AgentSkillPagination.slice(items, page: 0) == Array(0..<20))
        #expect(AgentSkillPagination.slice(items, page: 1) == Array(20..<40))
        #expect(AgentSkillPagination.slice(items, page: 2) == Array(40..<45))
        // 过界与负值都收敛到有效页,过滤收缩后 UI 不会停在空页上。
        #expect(AgentSkillPagination.slice(items, page: 99) == Array(40..<45))
        #expect(AgentSkillPagination.slice(items, page: -1) == Array(0..<20))
        #expect(AgentSkillPagination.slice([Int](), page: 0).isEmpty)
    }

    @Test("custom page sizes keep the same math")
    func customPageSize() {
        let items = Array(0..<10)
        #expect(AgentSkillPagination.pageCount(totalCount: 10, pageSize: 3) == 4)
        #expect(AgentSkillPagination.slice(items, page: 3, pageSize: 3) == [9])
    }
}
