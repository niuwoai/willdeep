import Foundation
import Testing
@testable import WillDeep

@Suite("工作面板多标签状态")
struct AgentPanelTabTests {
    @Test("旧会话按稳定身份迁移，保留文件")
    func migrateLegacyState() throws {
        let data = Data(#"{"kind":"preview","selectedFilePath":"/tmp/README.md"}"#.utf8)
        let state = try JSONDecoder().decode(AgentSidePanelState.self, from: data)
        #expect(state.openTabs.count == 1)
        #expect(state.openTabs == state.openTabs)
        #expect(state.selectedTab?.title == "README.md")
    }

    @Test("打开不同种类不替换原标签，同类工具复用")
    func openingPreservesTabs() {
        var state = AgentSidePanelState.empty
        let terminal = state.openTab(kind: .terminal)
        state.openTab(kind: .backgroundTasks)
        state.openTab(kind: .files)
        #expect(state.openTabs.count == 3)
        #expect(state.openTab(kind: .terminal).id == terminal.id)
        #expect(state.openTabs.count == 3)
    }

    @Test("不同文件各有标签，相同文件定位已有标签")
    func fileIdentity() {
        var state = AgentSidePanelState.empty
        let first = state.openTab(kind: .preview, file: URL(fileURLWithPath: "/tmp/README.md"), exactFile: true)
        state.openTab(kind: .preview, file: URL(fileURLWithPath: "/tmp/notes.md"), exactFile: true)
        #expect(state.openTabs.count == 2)
        #expect(state.openTab(kind: .preview, file: first.file, exactFile: true).id == first.id)
        #expect(state.selectedTab?.title == "README.md")
    }

    @Test("关闭当前标签选择相邻标签，关闭最后标签隐藏侧栏")
    func closeSelection() {
        var state = AgentSidePanelState.empty
        let first = state.openTab(kind: .terminal)
        let second = state.openTab(kind: .plan)
        state.closeTab(second.id)
        #expect(state.selectedTab?.id == first.id)
        state.closeTab(first.id)
        #expect(state.openTabs.isEmpty)
        #expect(state.kind == nil)
    }

    @Test("关闭非当前标签不改变当前选择")
    func closeInactive() {
        var state = AgentSidePanelState.empty
        let first = state.openTab(kind: .files)
        let second = state.openTab(kind: .terminal)
        state.closeTab(first.id)
        #expect(state.selectedTab?.id == second.id)
    }

    @Test("隐藏侧栏不会丢失标签")
    func hideAndReopen() {
        var state = AgentSidePanelState.empty
        let terminal = state.openTab(kind: .terminal)
        state.openTab(kind: .plan)
        state.kind = nil
        #expect(state.openTabs.count == 2)
        #expect(state.openTab(kind: .terminal).id == terminal.id)
    }

    @Test("非当前文件更新不串到当前标签")
    func updateInactiveFile() {
        var state = AgentSidePanelState.empty
        let preview = state.openTab(kind: .preview)
        state.openTab(kind: .terminal)
        state.updateTabFile(URL(fileURLWithPath: "/tmp/A.md"), tabID: preview.id)
        #expect(state.selectedFilePath == nil)
        #expect(state.openTabs.first?.title == "A.md")
        state.selectTab(preview.id)
        #expect(state.selectedFilePath == "/tmp/A.md")
    }

    @Test("拖动排序保留身份和选择")
    func reorderTabs() {
        var state = AgentSidePanelState.empty
        let first = state.openTab(kind: .terminal)
        let second = state.openTab(kind: .plan)
        state.moveTab(second.id, before: first.id)
        #expect(state.openTabs.map(\.id) == [second.id, first.id])
        #expect(state.selectedTab?.id == second.id)
    }

    @Test("标签列表及选中文件持久化往返")
    func roundTrip() throws {
        var state = AgentSidePanelState.empty
        state.openTab(kind: .terminal)
        state.openTab(kind: .preview, file: URL(fileURLWithPath: "/tmp/A.md"))
        let decoded = try JSONDecoder().decode(AgentSidePanelState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test("会话是窗口身份的一部分")
    func windowIdentityIncludesSession() {
        let tab = UUID()
        #expect(AgentPanelTabID(sessionID: UUID(), tabID: tab) != AgentPanelTabID(sessionID: UUID(), tabID: tab))
    }

    @Test("未知标签操作无副作用")
    func invalidActions() {
        var state = AgentSidePanelState.empty
        state.openTab(kind: .terminal)
        let original = state
        state.closeTab(UUID())
        state.selectTab(UUID())
        state.updateTabFile(URL(fileURLWithPath: "/tmp/A.md"), tabID: UUID())
        state.moveTab(UUID(), before: UUID())
        #expect(state == original)
    }

    @Test("旧调用直接切换 kind 不会继续展示旧选中标签")
    func legacyKindMutation() {
        var state = AgentSidePanelState.empty
        state.openTab(kind: .files)
        state.kind = .terminal
        #expect(state.selectedTab?.kind != .files)
        state.openTab(kind: .terminal)
        #expect(state.selectedTab?.kind == .terminal)
        #expect(state.openTabs.count == 2)
    }
}
