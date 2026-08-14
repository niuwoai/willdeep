//
//  AgentHeaderEditorEntryTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@Suite("Agent header editor entry policy")
struct AgentHeaderEditorEntryTests {
    @Test("Agent header stays flat and the app owns no Editor scene")
    func headerEntriesStayFlatAndEditorIsUnavailable() throws {
        let headerSource = try Self.source(in: "Xedit", named: "AgentChatHeader.swift")
        let appSource = try Self.source(in: "Xedit", named: "XeditApp.swift")

        #expect(!headerSource.contains("pencil.and.outline"))
        #expect(!headerSource.contains("appState.showEditor()"))
        #expect(!headerSource.contains("EditorWindowID.value"))
        #expect(!headerSource.contains("sidePanelMenu"))
        #expect(!headerSource.contains("Image(systemName: \"ellipsis\")"))
        #expect(headerSource.contains("ForEach(visibleKinds)"))
        #expect(headerSource.contains("@ObservedObject private var detachedPanels = AgentDetachedPanelRegistry.shared"))
        #expect(headerSource.contains("sidePanel == item || detachedPanels.isDetached(item)"))
        #expect(appSource.contains("AgentOnlyCommands()"))
        #expect(!appSource.contains("WindowGroup(id: EditorWindowID.value)"))
        #expect(!appSource.contains("WindowGroup(for: URL.self)"))
        #expect(!appSource.contains("viewShowEditor"))
        #expect(!appSource.contains("showEditorAction"))
        #expect(!appSource.contains("Switch to Editor Mode"))
        #expect(!appSource.contains("RoundtableWindowID"))
        #expect(!appSource.contains("RoundtableWindowRootView"))
        #expect(!appSource.contains("L10n.AgentWindow.openMenuItem"))
    }

    @Test("Terminal shortcut JSON stays in-app while ordinary files use the system default app")
    func shortcutJSONEditsInAppAndOtherFilesOpenExternally() throws {
        let terminalSource = try Self.source(in: "Xedit", named: "AgentSidePanelTerminalView.swift")
        let appSource = try Self.source(in: "Xedit", named: "XeditApp.swift")
        let filePanelSource = try Self.source(in: "Xedit", named: "AgentSidePanel.swift")
        let infoPlist = try Self.source(in: "Xedit", named: "Info.plist")

        // 捷径 JSON 里带加密后的受保护片段,交给外部编辑器等于把凭据落成明文,
        // 所以从 1.254.0-rc1 起改走 WillDeep 自己的安全编辑器窗口。
        #expect(!terminalSource.contains("NSWorkspace.shared.open(url)"))
        #expect(terminalSource.contains("openWindow(value: TerminalShortcutEditorRequest("))
        #expect(appSource.contains("WindowGroup(for: TerminalShortcutEditorRequest.self)"))
        // 安全编辑器是独立窗口场景,不是被砍掉的 Editor 模式。
        #expect(!terminalSource.contains("appState.openEditorFile"))

        // 除捷径 JSON 外的普通文件仍然交给系统默认 App,WillDeep 也不注册成文档处理器。
        #expect(filePanelSource.contains("NSWorkspace.shared.open(url)"))
        #expect(!infoPlist.contains("CFBundleDocumentTypes"))
    }

    private static func source(in directory: String, named fileName: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
