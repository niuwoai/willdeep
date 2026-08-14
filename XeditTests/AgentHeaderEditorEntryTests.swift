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

    @Test("Ordinary files use the system default app; shortcut JSON has its own window, not the Editor")
    func filesOpenExternally() throws {
        let terminalSource = try Self.source(in: "Xedit", named: "AgentSidePanelTerminalView.swift")
        let filePanelSource = try Self.source(in: "Xedit", named: "AgentSidePanel.swift")
        let infoPlist = try Self.source(in: "Xedit", named: "Info.plist")

        // 1.254.0-rc1 replaced "hand the shortcut JSON to the system editor"
        // with WillDeep's own shortcut editor window. That is a dedicated
        // scene, not the general Editor this suite exists to keep out — so
        // the assertion tracks the new route while the invariant that
        // matters (no routing into `openEditorFile`) stays.
        #expect(terminalSource.contains("openWindow(value: TerminalShortcutEditorRequest"))
        #expect(!terminalSource.contains("appState.openEditorFile"))
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
