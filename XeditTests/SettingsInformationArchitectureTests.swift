import Testing
@testable import WillDeep

struct SettingsInformationArchitectureTests {
    @Test("language preference resolves explicit Chinese, English, and Japanese overrides")
    func explicitLanguagePreferenceOverridesSystem() {
        #expect(AppLocale.resolvedLanguageTag(
            preference: .system,
            preferredLanguages: ["fr-FR"],
            localeIdentifier: "de-DE"
        ) == "fr-FR")
        #expect(AppLocale.resolvedLanguageTag(
            preference: .simplifiedChinese,
            preferredLanguages: ["fr-FR"],
            localeIdentifier: "de-DE"
        ) == "zh-Hans")
        #expect(AppLocale.resolvedLanguageTag(
            preference: .english,
            preferredLanguages: ["fr-FR"],
            localeIdentifier: "de-DE"
        ) == "en")
        #expect(AppLocale.resolvedLanguageTag(
            preference: .japanese,
            preferredLanguages: ["fr-FR"],
            localeIdentifier: "de-DE"
        ) == "ja")
        #expect(AppLocale.resolvedLanguageTag(
            preference: .spanish,
            preferredLanguages: ["ja-JP"],
            localeIdentifier: "de-DE"
        ) == "es")
        #expect(AppLocale.resolvedLanguageTag(
            preference: .french,
            preferredLanguages: ["ja-JP"],
            localeIdentifier: "de-DE"
        ) == "fr")
    }

    @Test("every selectable language maps to a bundle locale except system")
    func languagePreferenceTags() {
        #expect(AppLanguagePreference.allCases.map(\.rawValue) == [
            "system",
            "simplifiedChinese",
            "english",
            "japanese",
            "spanish",
            "french",
        ])
        #expect(AppLanguagePreference.system.languageTag == nil)
        // 每个非 system 选项都要有唯一的 BCP-47 标签,否则 Picker 里两
        // 个条目会指向同一份 .lproj。
        let tags = AppLanguagePreference.allCases.compactMap(\.languageTag)
        #expect(tags == ["zh-Hans", "en", "ja", "es", "fr"])
        #expect(Set(tags).count == tags.count)
        // 提示卡片写的是语言自己的名字,不能空。
        for preference in AppLanguagePreference.allCases {
            #expect(!preference.nativeDisplayName.isEmpty)
        }
    }

    @Test("relaunch hands the bundle path to sh as an argument, never inside the script")
    func relaunchArgumentsKeepPathOutOfScript() {
        let path = "/Applications/Some App (beta)'s \"build\".app"
        let arguments = AppRelaunch.relaunchArguments(pid: 4242, bundlePath: path)
        #expect(arguments.first == "-c")
        #expect(arguments.count == 5)
        // 路径以位置参数传入,脚本正文里不出现 → shell 不会二次解析它。
        let script = arguments[1]
        #expect(!script.contains(path))
        #expect(script.contains("$1"))
        #expect(script.contains("$2"))
        #expect(arguments[2] == "sh")
        #expect(arguments[3] == "4242")
        #expect(arguments[4] == path)
    }

    @Test("settings groups follow task-oriented information architecture")
    @MainActor
    func taskOrientedGroups() {
        #expect(SettingsGroup.allCases == [
            .accountAndDevices,
            .ai,
            .localModels,
            .agentProfiles,
            .agentLibrary,
            .agentExperiments,
            .agentTools,
            .runtimes,
            .integrations,
            .terminal,
            .pet,
            .agentAppearance,
            .general,
            .dataAndDiagnostics,
        ])
        #expect(SettingsGroup.agentAppearance.tabs == [.agentAppearance])
        #expect(SettingsGroup.agentLibrary.tabs == [.agentLibrary])
        #expect(SettingsGroup.agentExperiments.tabs == [.agentExperiments])
        #expect(EditorSettingsTab.agentLibrary.group == .agentLibrary)
        #expect(EditorSettingsTab.agentExperiments.group == .agentExperiments)
        #expect(EditorSettingsTab.agentAppearance.group == .agentAppearance)
        #expect(SettingsGroup.allCases.suffix(3) == [.agentAppearance, .general, .dataAndDiagnostics])
        // 1.376.0-rc2：「更新」这一组此前既叫「更新」又装着隐私与诊断导出，
        // 组名和内容对不上。拆开之后它只剩更新检查一项（`tabs.count == 1`
        // 会让二级 picker 自动消失），隐私与诊断导出移入「数据与诊断」——
        // 两者管的是同一个对象：这台机器上关于你的数据往哪儿去。
        #expect(SettingsGroup.general.tabs == [.updates])
        #expect(SettingsGroup.dataAndDiagnostics.tabs == [.privacy, .diagnostics])
        #expect(EditorSettingsTab.updates.group == .general)
        #expect(EditorSettingsTab.privacy.group == .dataAndDiagnostics)
        #expect(EditorSettingsTab.diagnostics.group == .dataAndDiagnostics)
        #expect(SettingsGroup.localModels.tabs == [.localModels])
        #expect(EditorSettingsTab.localModels.group == .localModels)
        #expect(SettingsGroup.ai.tabs == [.agent, .notifications, .memory, .rules])
        // 1.306.0-rc1：代理档案升为一级页签。工种的模型、窗口、轮次预算和
        // 预加载技能都在这儿定，是会反复回来改的配置，不该是 AI 组里的第
        // 四个次级项。它必须**离开**原来那组，而不是两处都出现——
        // `everyPaneHasOneGroup` 守的就是这条。
        #expect(SettingsGroup.agentProfiles.tabs == [.subagents])
        #expect(EditorSettingsTab.subagents.group == .agentProfiles)
        // 密钥管理器与技能/MCP/工具同属「Agent 的资源」，放在同一组末位。
        #expect(SettingsGroup.agentTools.tabs == [.skills, .mcp, .tools, .secrets])
        #expect(SettingsGroup.accountAndDevices.tabs == [.someIM, .mobileGateway])
        // 连接器 hub 是集成组唯一的 pane;每个外部集成是 hub 里的子连接器。
        #expect(SettingsGroup.integrations.tabs == [.connectors])
    }

    @Test("离开设置内的未保存智能体编辑页必须先确认")
    @MainActor
    func settingsWorkspaceNavigationProtectsDraftUntilExplicitDiscard() {
        let workspace = AgentWorkspaceNavigation()
        let settings = EditorSettingsNavigation(workspaceNavigation: workspace)
        settings.selectedTab = .agentLibrary
        #expect(workspace.section == .library)
        workspace.dirtySections.insert(.library)
        settings.selectedTab = .agentExperiments
        #expect(settings.selectedTab == .agentLibrary)
        #expect(workspace.pendingSettingsTab == .agentExperiments)
        workspace.cancelPendingNavigation()
        #expect(workspace.dirtySections.contains(.library))
        #expect(settings.selectedTab == .agentLibrary)
        settings.selectedTab = .agentExperiments
        // SwiftUI dismisses the sheet before invoking its button action.
        workspace.navigationConfirmationPresented = false
        workspace.discardAndContinue()
        #expect(settings.selectedTab == .agentExperiments)
        #expect(workspace.section == .experiments)
        #expect(workspace.dirtySections.isEmpty)
        workspace.dirtySections.insert(.experiments)
        settings.selectedTab = .updates
        #expect(settings.selectedTab == .agentExperiments)
        workspace.discardAndContinue()
        #expect(settings.selectedTab == .updates)
    }

    @Test("账号切换撤销尚未确认的设置跳转")
    @MainActor
    func accountChangeCancelsPendingSettingsNavigation() {
        let workspace = AgentWorkspaceNavigation()
        let settings = EditorSettingsNavigation(workspaceNavigation: workspace)
        settings.selectedTab = .agentLibrary
        workspace.dirtySections.insert(.library)
        settings.selectedTab = .updates
        workspace.accountChanged()
        workspace.discardAndContinue()
        #expect(settings.selectedTab == .agentLibrary)
        #expect(workspace.pendingSettingsTab == nil)
    }

    @Test("every settings pane belongs to exactly one group")
    @MainActor
    func everyPaneHasOneGroup() {
        let groupedTabs = SettingsGroup.allCases.flatMap(\.tabs)
        #expect(Set(groupedTabs).count == groupedTabs.count)
        #expect(groupedTabs.contains(.updates))
        #expect(groupedTabs.contains(.privacy))
        #expect(groupedTabs.contains(.diagnostics))
        #expect(groupedTabs.contains(.agentAppearance))
        #expect(groupedTabs.contains(.subagents))
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
