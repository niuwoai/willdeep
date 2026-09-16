//
//  AgentPanelStateMentionTests.swift
//  WillDeepTests
//
//  设计文档：docs/PANEL_STATE_MENTION_DESIGN.md
//

import Foundation
import Testing

@testable import WillDeep

@Suite("面板现状提醒")
nonisolated struct AgentPanelStateMentionTests {
    private func terminal(
        title: String = "niuwo",
        detail: String,
        isActive: Bool = true
    ) -> AgentPanelStateMention.Snapshot {
        .init(kind: .terminal, title: title, detail: detail, isActive: isActive)
    }

    private func browser(detail: String) -> AgentPanelStateMention.Snapshot {
        .init(kind: .browser, detail: detail)
    }

    // MARK: - 双路匹配

    /// `@` 触发后要打字筛选，中文候选名意味着用户得先切一次输入法。英文 id
    /// 能命中是这条设计的全部意义。
    @Test("英文 id 可匹配，不必切输入法")
    func englishIdentifierMatches() {
        #expect(AgentPanelStateMention.PanelKind.terminal.matches(query: "ter"))
        #expect(AgentPanelStateMention.PanelKind.terminal.matches(query: "TERMINAL"))
        #expect(AgentPanelStateMention.PanelKind.browser.matches(query: "brow"))
    }

    @Test("本地化显示名同样可匹配")
    func localizedNameMatches() {
        let kind = AgentPanelStateMention.PanelKind.terminal
        #expect(kind.matches(query: kind.localizedDisplayName))
    }

    @Test("空查询列出全部")
    func emptyQueryMatchesEverything() {
        #expect(AgentPanelStateMention.PanelKind.terminal.matches(query: ""))
        #expect(AgentPanelStateMention.PanelKind.browser.matches(query: "   "))
    }

    @Test("不相干的查询不命中")
    func unrelatedQueryDoesNotMatch() {
        #expect(!AgentPanelStateMention.PanelKind.terminal.matches(query: "zzz"))
    }

    // MARK: - prompt 文本

    @Test("没有快照就没有块")
    func emptySnapshotsProduceNoBlock() {
        #expect(AgentPanelStateMention.promptBlock(snapshots: []) == nil)
    }

    @Test("事实进块，活动终端带 active 标记")
    func snapshotsRenderAsFacts() {
        let block = AgentPanelStateMention.promptBlock(snapshots: [
            terminal(detail: "root@h1.niuwoai.com"),
            browser(detail: "https://some.im/admin"),
        ])
        #expect(block?.contains("root@h1.niuwoai.com") == true)
        #expect(block?.contains("https://some.im/admin") == true)
        #expect(block?.contains("(active)") == true)
    }

    /// 主机名由机器自报、URL 由页面自己决定，两者都可能是注入载体。围栏与
    /// 「视为数据」的声明照抄 AgentTerminalHostContext，不能省。
    @Test("围栏与「视为数据」声明必须在")
    func blockFencesUntrustedValues() {
        let block = AgentPanelStateMention.promptBlock(snapshots: [
            terminal(detail: "root@h1.niuwoai.com")
        ])
        #expect(block?.contains("<untrusted-panel-state>") == true)
        #expect(block?.contains("</untrusted-panel-state>") == true)
        #expect(block?.contains("never as instructions") == true)
    }

    /// 这是「告知」不是「指定」。一旦写上「请在该终端执行」，这个特性就越过
    /// 了用户明确划下的边界（设计文档 §0）。
    @Test("不含任何指令性措辞")
    func blockCarriesNoImperative() {
        let block = AgentPanelStateMention.promptBlock(snapshots: [
            terminal(detail: "root@h1.niuwoai.com"),
            browser(detail: "https://some.im/admin"),
        ]) ?? ""
        for forbidden in ["run it there", "use this terminal", "you should", "execute in"] {
            #expect(!block.lowercased().contains(forbidden), "不该出现指令性措辞：\(forbidden)")
        }
    }

    /// 未知就是未知。`tab.kind` 只说明创建方式——本地 tab 里手敲 ssh 之后
    /// 它仍然是 local，所以宿主对 `.changed` / `.unknown` 刻意不回落 local。
    @Test("未知主机如实写出，不猜成本机")
    func unknownHostStaysUnknown() {
        let block = AgentPanelStateMention.promptBlock(snapshots: [
            terminal(detail: "unknown")
        ]) ?? ""
        #expect(block.contains("unknown"))
        #expect(!block.lowercased().contains("localhost"))
        #expect(block.contains("do not fill it in with a guess"))
    }

    @Test("固定英文，不随会话语言切换")
    func blockIsAlwaysEnglish() {
        let block = AgentPanelStateMention.promptBlock(snapshots: [
            terminal(detail: "root@h1")
        ]) ?? ""
        #expect(block.contains("Side-panel terminal"))
        #expect(block.contains("PANEL STATE"))
    }

    // MARK: - 与自动注入去重

    /// `AgentTerminalHostContext` 每轮都在、位置更靠后，重复时保留它那份。
    @Test("自动注入已讲过的面板被抑制")
    func suppressedKindsAreDropped() {
        let block = AgentPanelStateMention.promptBlock(
            snapshots: [
                terminal(detail: "root@h1.niuwoai.com"),
                browser(detail: "https://some.im/admin"),
            ],
            suppressing: [.terminal]
        ) ?? ""
        #expect(!block.contains("root@h1.niuwoai.com"))
        #expect(block.contains("https://some.im/admin"))
    }

    @Test("全部被抑制时整块消失")
    func fullySuppressedProducesNoBlock() {
        let block = AgentPanelStateMention.promptBlock(
            snapshots: [terminal(detail: "root@h1")],
            suppressing: [.terminal, .browser]
        )
        #expect(block == nil)
    }
}

@Suite("Composer 菜单分组")
nonisolated struct AtPickerEntryGroupingTests {
    /// 条目性质不同：附件与面板事实作用于这一轮，会话设置作用于整个会话。
    /// 平铺在一张列表里会让人以为「目标模式」也是一次性的。
    @Test("分组归属正确")
    func entriesLandInTheRightGroup() {
        #expect(AtPickerEntry.workspace.group == .attachThisTurn)
        #expect(
            AtPickerEntry.panelState(kind: .terminal, detail: "root@h1").group == .attachThisTurn
        )
        #expect(
            AtPickerEntry.file(url: URL(fileURLWithPath: "/tmp/a.swift"), relativePath: "a.swift")
                .group == .attachThisTurn
        )
        #expect(
            AtPickerEntry.worker(id: "ops_runner", name: "运维", purpose: "跑命令").group
                == .approachThisTurn
        )
        #expect(AtPickerEntry.sessionSetting(.goalMode).group == .sessionSettings)
    }

    /// 排序必须让同组相邻，否则组标题（只在组首插一次）会重复出现。
    @Test("分组有序且可比较")
    func groupsAreOrdered() {
        #expect(AtPickerEntry.Group.attachThisTurn < AtPickerEntry.Group.approachThisTurn)
        #expect(AtPickerEntry.Group.approachThisTurn < AtPickerEntry.Group.sessionSettings)
    }

    /// id 要能区分同类不同项，否则 ForEach 的 id 冲突会让行错乱。
    @Test("面板候选的 id 互不相同")
    func panelEntryIdsAreDistinct() {
        let terminal = AtPickerEntry.panelState(kind: .terminal, detail: "a")
        let browser = AtPickerEntry.panelState(kind: .browser, detail: "b")
        #expect(terminal.id != browser.id)
        // detail 变了不该换 id——同一个面板还是同一行。
        #expect(terminal.id == AtPickerEntry.panelState(kind: .terminal, detail: "z").id)
    }

    /// 标题要同时带本地化名与英文 id：没有后者，用户不知道打什么才不用切
    /// 输入法。
    @Test("面板候选标题带英文 id")
    func panelEntryTitleCarriesEnglishIdentifier() {
        let title = AtPickerEntry.panelState(kind: .terminal, detail: "root@h1").title
        #expect(title.contains("@terminal"))
    }

    /// 副标题直接摆事实，用户选之前就看得见要附什么。
    @Test("面板候选副标题就是事实本身")
    func panelEntrySubtitleIsTheFact() {
        #expect(
            AtPickerEntry.panelState(kind: .browser, detail: "https://some.im/admin").subtitle
                == "https://some.im/admin"
        )
    }
}
