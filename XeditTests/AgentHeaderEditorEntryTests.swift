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
        let modeSource = try Self.source(in: "Xedit", named: "AgentModeView.swift")
        let sidebarSource = try Self.source(in: "Xedit", named: "AgentSessionsSidebar.swift")
        let appSource = try Self.source(in: "Xedit", named: "XeditApp.swift")

        #expect(!headerSource.contains("pencil.and.outline"))
        #expect(!headerSource.contains("appState.showEditor()"))
        #expect(!headerSource.contains("EditorWindowID.value"))
        #expect(!headerSource.contains("sidePanelMenu"))
        #expect(!headerSource.contains("Image(systemName: \"ellipsis\")"))
        #expect(headerSource.contains("ForEach(visibleKinds)"))
        #expect(!headerSource.contains("return !appState.agentJobRegistry.jobs.isEmpty"))
        #expect(headerSource.contains("@ObservedObject private var detachedPanels = AgentDetachedPanelRegistry.shared"))
        #expect(headerSource.contains("sidePanel == item || detachedPanels.isDetached(item)"))
        #expect(headerSource.contains("selectedColor: .black"))
        #expect(headerSource.contains("isHovered ? hoverColor : normalColor"))
        #expect(headerSource.contains("private final class AgentSidePanelHoverButton"))
        #expect(headerSource.contains(".onHover { isDesktopPetHovered = $0 }"))
        #expect(!headerSource.contains("sessionSearchButton"))
        #expect(modeSource.contains("#selector(presentSearch)"))
        #expect(modeSource.contains("AgentWindowChromeControlLayout.searchButtonFrame"))
        #expect(!sidebarSource.contains("L10n.Sidebar.searchSessionsAction"))
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

    @Test("Chat links and adjacent error actions stay in the grayscale hierarchy")
    func chatActionsAvoidAccentBlue() throws {
        let formatterSource = try Self.source(in: "Xedit", named: "AgentChatHistoryFormatter.swift")
        let errorSource = try Self.source(in: "Xedit", named: "AgentErrorCard.swift")

        #expect(!formatterSource.contains("NSColor.linkColor"))
        #expect(formatterSource.contains("NSColor.secondaryLabelColor.blended"))
        #expect(errorSource.components(separatedBy: ".foregroundStyle(.secondary)").count >= 3)
    }

    @Test("Ordinary files use the system default app; only shortcut JSON stays in-app")
    func filesOpenExternally() throws {
        let terminalSource = try Self.source(in: "Xedit", named: "AgentSidePanelTerminalView.swift")
        let appSource = try Self.source(in: "Xedit", named: "XeditApp.swift")
        let filePanelSource = try Self.source(in: "Xedit", named: "AgentSidePanel.swift")
        let infoPlist = try Self.source(in: "Xedit", named: "Info.plist")

        // Terminal shortcut JSON is the one deliberate exception to "files
        // open externally": the recordings carry `${secret:...}` values, and
        // handing that file to whichever app owns .json would leak them into
        // another process. It opens in the app's own editor window instead.
        #expect(terminalSource.contains("openWindow(value: TerminalShortcutEditorRequest("))
        #expect(!terminalSource.contains("NSWorkspace.shared.open(url)"))
        // The call site alone is not enough: without the matching scene the
        // window silently fails to open at runtime while this test stays green.
        #expect(appSource.contains("WindowGroup(for: TerminalShortcutEditorRequest.self)"))
        // The exception is that window, NOT a revived Editor scene: the local
        // editor was split out into Qeditor and must not come back through
        // this door.
        #expect(!terminalSource.contains("appState.openEditorFile"))
        #expect(filePanelSource.contains("NSWorkspace.shared.open(url)"))
        #expect(!infoPlist.contains("CFBundleDocumentTypes"))
    }

    @Test("Queued rows mirror the Codex hover handle and action order")
    func queuedRowsExposeCodexActions() throws {
        let source = try Self.source(in: "Xedit", named: "AgentMessageSupportViews.swift")

        #expect(source.contains("private var sixDotDragHandle"))
        #expect(source.contains(".opacity(isHovering ? 1 : 0)"))
        #expect(source.contains("Text(L10n.QueuedMessage.adjustDirection)"))
        #expect(source.contains("systemName: \"trash\""))
        #expect(source.contains("Label(L10n.QueuedMessage.editButton"))
        #expect(source.contains("Label(L10n.QueuedMessage.openInSideChat"))
        #expect(source.contains("Label(L10n.QueuedMessage.closeQueue"))
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
