//
//  ContentView.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Derived from `appState.rootDirectory` — the tree model root node.
    /// Re-created whenever the root directory changes.
    @State private var rootNode: FileSystemNode?
    @State private var sidebarWidth: CGFloat = 220
    @State private var isFileTreeCollapsed = false
    @State private var isEditorMaximized = false
    @State private var fileTreeCollapsedBeforeEditorMaximize = false
    @State private var inspectorVisibleBeforeEditorMaximize: Bool?

    private let minSidebarWidth: CGFloat = 170
    private let maxSidebarWidth: CGFloat = 380
    private let sidebarTopPadding: CGFloat = 48

    var body: some View {
        ZStack {
            WorkspaceWindowBackground()

            if appState.appMode == .agent {
                AgentModeView()
            } else {
                HStack(spacing: 0) {
                    sidebar
                    sidebarControl

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: appState.rootDirectory) { _, newDirectory in
            if let dir = newDirectory {
                let node = FileSystemNode(url: dir)
                node.loadChildren()
                node.isExpanded = true
                rootNode = node
                if appState.selectedFolderURL == nil {
                    appState.selectedFolderURL = dir
                }
            } else {
                rootNode = nil
                appState.selectedFolderURL = nil
            }
        }
        .onChange(of: appState.openedFileURL) { oldValue, newValue in
            handleFileSelectionChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: appState.fileContent) { _, _ in
            appState.refreshExternalFileStatus()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            appState.refreshExternalFileStatus()
            appState.refreshGitStatus()
        }
        .onAppear {
            // If rootDirectory was set before the view appeared, create the node.
            if let dir = appState.rootDirectory {
                let node = FileSystemNode(url: dir)
                node.loadChildren()
                node.isExpanded = true
                rootNode = node
                if appState.selectedFolderURL == nil {
                    appState.selectedFolderURL = dir
                }
            }
        }
        .background(
            MainWindowKeyboardShortcutHandler(
                hasActiveTab: appState.activeTabID != nil,
                onCloseTab: {
                    appState.closeActiveTab()
                }
            )
        )
        .background(WindowChromeConfigurator())
    }

    private var sidebar: some View {
        Group {
            if appState.isFocusModeEnabled {
                Color.clear
                    .frame(width: 0)
            } else if let root = rootNode {
                FileTreeView(
                    root: root,
                    selectedURL: $appState.openedFileURL,
                    selectedFolderURL: $appState.selectedFolderURL
                )
                .id(root.url.standardizedFileURL)
            } else {
                Color.clear
                    .frame(width: 0)
            }
        }
        .padding(.top, shouldShowSidebar ? sidebarTopPadding : 0)
        .frame(width: shouldShowSidebar ? sidebarWidth : 0)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }

    private var shouldShowSidebar: Bool {
        !appState.isFocusModeEnabled
            && rootNode != nil
            && !isFileTreeCollapsed
            && !isEditorMaximized
    }

    private var tabBarLeadingReserve: CGFloat {
        shouldShowSidebar ? 0 : 72
    }

    private var shouldShowSidebarControl: Bool {
        !appState.isFocusModeEnabled && rootNode != nil && !isEditorMaximized
    }

    /// Floating "Enter Agent Mode" pill is meaningful only when a real
    /// workspace is open — Agent mode needs project context — and the
    /// editor isn't currently in focus/maximized mode (would collide
    /// with the chrome-free intent).
    private var shouldShowEnterAgentButton: Bool {
        appState.rootDirectory != nil
            && appState.appMode == .editor
            && !appState.isFocusModeEnabled
            && !isEditorMaximized
    }

    @ViewBuilder
    private var sidebarControl: some View {
        if shouldShowSidebarControl && shouldShowSidebar {
            SidebarResizeHandle(
                width: $sidebarWidth,
                minWidth: minSidebarWidth,
                maxWidth: maxSidebarWidth
            )
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
                if let imageURL = appState.imagePreviewURL {
                    ImagePreviewPane(url: imageURL) {
                        appState.closeImagePreview()
                    }
                    .frame(minWidth: 400, minHeight: 400)
                } else if appState.activeTab != nil {
                    if !appState.isFocusModeEnabled {
                        EditorTabBar(
                            tabs: appState.tabs,
                            activeTabID: appState.activeTabID,
                            // Reserve room on the right for the floating
                            // Agent-mode toggle so the rightmost tab's
                            // close button doesn't slip under it.
                            leadingReserve: tabBarLeadingReserve,
                            trailingReserve: shouldShowEnterAgentButton ? 72 : 0,
                            onSelect: { appState.activateTab(id: $0) },
                            onClose: { appState.closeTab(id: $0) },
                            onDoubleClick: { id in
                                appState.activateTab(id: id)
                                toggleEditorMaximized()
                            }
                        )
                        .overlay(alignment: .trailing) {
                            if shouldShowEnterAgentButton {
                                EnterAgentModeButton()
                                    .padding(.trailing, 12)
                            }
                        }
                    }

                    if appState.isFindBarVisible && !appState.isFocusModeEnabled {
                        FindReplaceBar()
                            .environmentObject(appState)
                    }

                    // Detail: editor area with syntax highlighting.
                    let detectedLanguage = appState.detectedLanguage
                    let editorLanguage = appState.effectiveLanguage

                    HStack(spacing: 0) {
                        EditorView(
                            text: $appState.fileContent,
                            language: editorLanguage,
                            detectedLanguage: detectedLanguage,
                            syntaxHighlightingSelection: appState.syntaxHighlightingSelection,
                            settings: appState.editorSettings,
                            activeTabID: appState.activeTabID,
                            renderRevision: appState.editorRenderRevision,
                            highlightRevision: appState.editorHighlightRevision,
                            navigationRequest: appState.editorNavigationRequest,
                            changedLineNumbers: appState.changedLineNumbers,
                            searchRanges: appState.findMatchRanges,
                            activeSearchRange: appState.activeFindRange,
                            onEdit: {
                                // Mark dirty when the user types.
                                appState.isEdited = true
                                NSApplication.shared.keyWindow?.isDocumentEdited = true
                            },
                            onSelectionChange: { line, column, selectedCharacters, selectedLines, selectedText in
                                appState.updateSelectionInfo(
                                    line: line,
                                    column: column,
                                    selectedCharacters: selectedCharacters,
                                    selectedLines: selectedLines,
                                    selectedText: selectedText
                                )
                            },
                            onSyntaxHighlightingChange: { selection in
                                appState.setSyntaxHighlightingSelection(selection)
                            },
                            onAddSelectionToAgentConversation: { selection in
                                appState.addEditorSelectionToAgentConversation(selection)
                            },
                            onAskSelectionInAgentPanel: { selection in
                                appState.askAgentAboutEditorSelection(selection)
                            }
                        )
                        .editorGlassBackground(settings: appState.editorSettings)
                        .frame(minWidth: 400, minHeight: 400)

                        if appState.isSplitEditorVisible {
                            SplitEditorPane()
                                .environmentObject(appState)
                                .frame(minWidth: 280, idealWidth: 360)
                        }

                        if appState.isPreviewVisible, PreviewPane.supports(editorLanguage) {
                            PreviewPane(text: appState.fileContent, language: editorLanguage) {
                                appState.isPreviewVisible = false
                            }
                            .frame(minWidth: 280, idealWidth: 360)
                        }

                        if appState.isInspectorVisible && !appState.isFocusModeEnabled && !isEditorMaximized {
                            EditorInspectorSidebar(
                                text: appState.fileContent,
                                language: editorLanguage,
                                mode: $appState.inspectorMode,
                                orderedModes: appState.editorSettings.orderedInspectorModes,
                                onNavigateToLine: { line in
                                    appState.navigateEditor(toLine: line)
                                },
                                onClose: {
                                    appState.isInspectorVisible = false
                                }
                            )
                            .frame(width: 220)
                        } else if !appState.isFocusModeEnabled && !isEditorMaximized {
                            InspectorCollapsedRail {
                                appState.isInspectorVisible = true
                            }
                        }

                        if appState.isAgentPanelVisible && !appState.isFocusModeEnabled && !isEditorMaximized {
                            AgentPanelView()
                                .environmentObject(appState)
                                .frame(width: 330)
                        }
                    }

                    if !appState.isFocusModeEnabled {
                        EditorStatusBar(language: editorLanguage)
                            .environmentObject(appState)
                    }
                } else {
                    if rootNode == nil {
                        EmptyWorkspaceView {
                            appState.openFile()
                        } onOpenFolder: {
                            appState.openFolder { url in
                                openWindow(value: url)
                            }
                        }
                        .frame(minWidth: 400, minHeight: 400)
                        .environmentObject(appState)
                    } else {
                        EmptyProjectEditorView {
                            appState.showQuickOpen()
                        } onOpenFile: {
                            appState.openFile()
                        }
                        .frame(minWidth: 400, minHeight: 400)
                        .overlay(alignment: .topTrailing) {
                            if shouldShowEnterAgentButton {
                                EnterAgentModeButton()
                                    .padding(.top, 10)
                                    .padding(.trailing, 12)
                            }
                        }
                    }
                }
            }
            .background(EditorAreaBackground(settings: appState.editorSettings))
            .overlay {
                if appState.isQuickOpenVisible {
                    QuickOpenPanel()
                        .environmentObject(appState)
                }
                if appState.isGoToLineVisible {
                    GoToLinePanel()
                        .environmentObject(appState)
                }
                if appState.isCommandPaletteVisible {
                    CommandPalettePanel()
                        .environmentObject(appState)
                }
                if appState.isSymbolJumpVisible {
                    SymbolJumpPanel()
                        .environmentObject(appState)
                }
            }
    }

    private func toggleEditorMaximized() {
        if isEditorMaximized {
            isEditorMaximized = false
            isFileTreeCollapsed = fileTreeCollapsedBeforeEditorMaximize
            if let inspectorVisibleBeforeEditorMaximize {
                appState.isInspectorVisible = inspectorVisibleBeforeEditorMaximize
            }
            inspectorVisibleBeforeEditorMaximize = nil
            return
        }

        fileTreeCollapsedBeforeEditorMaximize = isFileTreeCollapsed
        inspectorVisibleBeforeEditorMaximize = appState.isInspectorVisible
        isFileTreeCollapsed = true
        appState.isInspectorVisible = false
        isEditorMaximized = true
    }

    // MARK: - File Selection Handling

    /// Handles changes to `appState.openedFileURL`:
    /// - Unsaved-change prompt (Save / Discard / Cancel).
    /// - Binary file detection.
    /// - Delegates actual file reading to `AppState.loadFile(from:)`.
    private func handleFileSelectionChange(oldValue: URL?, newValue: URL?) {
        // Guard against re-entrant calls from programmatic reverts.
        if appState.suppressURLChangeProcessing {
            appState.suppressURLChangeProcessing = false
            return
        }

        guard let newURL = newValue else {
            // openedFileURL was set to nil — clear the editor and window state.
            appState.imagePreviewURL = nil
            appState.fileContent = ""
            appState.isEdited = false
            if let window = NSApplication.shared.keyWindow {
                window.title = ""
                window.isDocumentEdited = false
            }
            return
        }

        // Skip if the URL didn't actually change (e.g. click same file twice).
        if newURL == oldValue { return }

        appState.imagePreviewURL = nil
        appState.selectedSidebarFileURL = newURL

        if appState.activateTab(for: newURL) {
            return
        }

        // --- Binary file detection (c5) ---
        if AppState.isBinaryFile(at: newURL) {
            let alert = NSAlert()
            alert.messageText = L10n.Alert.binaryFileTitle
            alert.informativeText = L10n.Alert.binaryFileMessage(newURL.lastPathComponent)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.Alert.binaryFileButtonOk)
            alert.runModal()

            // Revert selection to the previous URL (or nil).
            appState.suppressURLChangeProcessing = true
            appState.openedFileURL = oldValue
            return
        }

        // --- File size guard (c1) ---
        var allowLargeFile = false
        if AppState.shouldRequireLargeFileConfirmation(at: newURL) {
            let alert = NSAlert()
            alert.messageText = L10n.Alert.largeFileTitle
            alert.informativeText = L10n.Alert.largeFileMessage(newURL.lastPathComponent)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.Alert.largeFileButtonOpenAnyway)
            alert.addButton(withTitle: L10n.Alert.largeFileButtonCancel)
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // Cancel — revert selection.
                appState.suppressURLChangeProcessing = true
                appState.openedFileURL = oldValue
                return
            }
            allowLargeFile = true
        }

        // --- Load the file (c1, c2) ---
        appState.registerRecentFile(newURL)
        appState.registerRecentFolder(newURL.deletingLastPathComponent())
        appState.beginOpeningTab(for: newURL)
        appState.loadFile(from: newURL, fallbackURL: oldValue, allowLargeFile: allowLargeFile)
    }
}

// `WorkspaceWindowBackground` / `EditorAreaBackground` /
// `EditorGlassBackgroundModifier` / `VisualEffectView` /
// `SidebarResizeHandle` / `CursorModifier` (+ `.editorGlassBackground` /
// `.cursor` modifiers) live in `ContentViewBackgrounds.swift` since
// rc39.

// `EmptyProjectEditorView` / `EmptyWorkspaceView` /
// `EmptyWorkspaceHero` / `EmptyWorkspaceRecentSection` /
// `EmptyWorkspaceButtonStyle` live in `EmptyStateViews.swift` since
// rc39.

private struct CommandPalettePanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @FocusState private var queryFocused: Bool
    @State private var selectedCommandIndex = 0
    @State private var ignoredHoverSelectionUntil = Date.distantPast
    @State private var lastHoverMouseLocation: CGPoint?

    private var commands: [PaletteCommand] {
        [
            PaletteCommand(title: L10n.Command.quickOpenTitle, subtitle: L10n.Command.quickOpenSubtitle, icon: "doc.text.magnifyingglass", isEnabled: appState.rootDirectory != nil, keywords: ["file", "folder", "project"], shortcut: "⌘P") {
                appState.hideCommandPalette()
                appState.showQuickOpen()
            },
            PaletteCommand(title: L10n.Command.goToLineTitle, subtitle: L10n.Command.goToLineSubtitle, icon: "arrow.down.to.line", isEnabled: appState.activeTabID != nil, keywords: ["line", "jump"], shortcut: "⌘L") {
                appState.hideCommandPalette()
                appState.showGoToLine()
            },
            PaletteCommand(title: L10n.Command.goToSymbolTitle, subtitle: L10n.Command.goToSymbolSubtitle, icon: "list.bullet.indent", isEnabled: appState.activeTabID != nil, keywords: ["outline", "method", "function"]) {
                appState.hideCommandPalette()
                appState.showSymbolJump()
            },
            PaletteCommand(title: L10n.Command.findTitle, subtitle: L10n.Command.findSubtitle, icon: "magnifyingglass", isEnabled: appState.activeTabID != nil, keywords: ["replace", "search"], shortcut: "⌘F") {
                appState.hideCommandPalette()
                appState.showFindBar()
            },
            PaletteCommand(title: L10n.Command.toggleInspectorTitle, subtitle: L10n.Command.toggleInspectorSubtitle, icon: "sidebar.right", isEnabled: appState.activeTabID != nil, keywords: ["minimap", "outline"]) {
                appState.hideCommandPalette()
                appState.isInspectorVisible.toggle()
            },
            PaletteCommand(title: L10n.Command.toggleAgentTitle, subtitle: L10n.Command.toggleAgentSubtitle, icon: "sparkles", isEnabled: true, keywords: ["ai", "chat", "assistant"]) {
                appState.hideCommandPalette()
                appState.toggleAgentPanel()
            },
            PaletteCommand(title: L10n.Command.toggleFocusModeTitle, subtitle: L10n.Command.toggleFocusModeSubtitle, icon: "viewfinder", isEnabled: appState.activeTabID != nil, keywords: ["zen", "clean"]) {
                appState.hideCommandPalette()
                appState.toggleFocusMode()
            },
            PaletteCommand(title: L10n.Command.togglePreviewTitle, subtitle: L10n.Command.togglePreviewSubtitle, icon: "doc.richtext", isEnabled: appState.canShowPreview, keywords: ["markdown", "md", "html"]) {
                appState.hideCommandPalette()
                appState.togglePreview()
            },
            PaletteCommand(title: L10n.Command.openSplitFileTitle, subtitle: L10n.Command.openSplitFileSubtitle, icon: "rectangle.split.2x1", isEnabled: true, keywords: ["side", "compare"]) {
                appState.hideCommandPalette()
                appState.openSplitFile()
            },
            PaletteCommand(title: L10n.Command.openContainingFolderTitle, subtitle: L10n.Command.openContainingFolderSubtitle, icon: "folder.badge.gearshape", isEnabled: appState.openedFileURL != nil, keywords: ["finder", "reveal"]) {
                appState.hideCommandPalette()
                appState.openContainingFolder()
            },
            PaletteCommand(title: L10n.Command.openFileTitle, subtitle: L10n.Command.openFileSubtitle, icon: "doc", isEnabled: true, keywords: ["document"], shortcut: "⌘O") {
                appState.hideCommandPalette()
                appState.openFile()
            },
            PaletteCommand(title: L10n.Command.openFolderTitle, subtitle: L10n.Command.openFolderSubtitle, icon: "folder", isEnabled: true, keywords: ["project", "workspace"]) {
                appState.hideCommandPalette()
                appState.openFolder { url in
                    openWindow(value: url)
                }
            },
            PaletteCommand(title: L10n.Command.openTerminalHereTitle, subtitle: L10n.Command.openTerminalHereSubtitle, icon: "terminal", isEnabled: appState.rootDirectory != nil || appState.openedFileURL != nil, keywords: ["shell", "cli", "command line"]) {
                appState.hideCommandPalette()
                appState.openTerminalHere(appState.openedFileURL ?? appState.rootDirectory)
            },
            PaletteCommand(title: L10n.Command.copyFilePathTitle, subtitle: L10n.Command.copyFilePathSubtitle, icon: "doc.on.doc", isEnabled: appState.openedFileURL != nil, keywords: ["absolute", "clipboard"]) {
                appState.hideCommandPalette()
                if let url = appState.openedFileURL {
                    appState.copyPath(url)
                }
            },
            PaletteCommand(title: L10n.Command.copyRelativeFilePathTitle, subtitle: L10n.Command.copyRelativeFilePathSubtitle, icon: "rectangle.on.rectangle", isEnabled: appState.openedFileURL != nil, keywords: ["relative", "clipboard"]) {
                appState.hideCommandPalette()
                if let url = appState.openedFileURL {
                    appState.copyRelativePath(url)
                }
            },
            PaletteCommand(title: L10n.Command.refreshGitStatusTitle, subtitle: L10n.Command.refreshGitStatusSubtitle, icon: "arrow.clockwise", isEnabled: appState.rootDirectory != nil, keywords: ["source control", "branch", "changes"]) {
                appState.hideCommandPalette()
                appState.refreshGitStatus()
            },
            PaletteCommand(title: L10n.Command.saveTitle, subtitle: L10n.Command.saveSubtitle, icon: "square.and.arrow.down", isEnabled: appState.activeTabID != nil, keywords: ["write"], shortcut: "⌘S") {
                appState.hideCommandPalette()
                appState.saveCurrentFile()
            },
            PaletteCommand(title: L10n.Command.nextTabTitle, subtitle: L10n.Command.nextTabSubtitle, icon: "chevron.right", isEnabled: appState.tabs.count > 1, keywords: ["tab"], shortcut: "⌘}") {
                appState.hideCommandPalette()
                appState.activateNextTab()
            },
            PaletteCommand(title: L10n.Command.previousTabTitle, subtitle: L10n.Command.previousTabSubtitle, icon: "chevron.left", isEnabled: appState.tabs.count > 1, keywords: ["tab"], shortcut: "⌘{") {
                appState.hideCommandPalette()
                appState.activatePreviousTab()
            },
            PaletteCommand(title: L10n.Command.reopenClosedTabTitle, subtitle: L10n.Command.reopenClosedTabSubtitle, icon: "arrow.uturn.backward", isEnabled: true, keywords: ["undo", "tab"]) {
                appState.hideCommandPalette()
                appState.reopenClosedTab()
            },
            PaletteCommand(title: L10n.Command.duplicateLineTitle, subtitle: L10n.Command.duplicateLineSubtitle, icon: "plus.square.on.square", isEnabled: appState.activeTabID != nil, keywords: ["copy", "editor"]) {
                appState.hideCommandPalette()
                appState.duplicateCurrentLine()
            },
            PaletteCommand(title: L10n.Command.moveLineUpTitle, subtitle: L10n.Command.moveLineUpSubtitle, icon: "arrow.up", isEnabled: appState.activeTabID != nil, keywords: ["editor", "line"]) {
                appState.hideCommandPalette()
                appState.moveCurrentLineUp()
            },
            PaletteCommand(title: L10n.Command.moveLineDownTitle, subtitle: L10n.Command.moveLineDownSubtitle, icon: "arrow.down", isEnabled: appState.activeTabID != nil, keywords: ["editor", "line"]) {
                appState.hideCommandPalette()
                appState.moveCurrentLineDown()
            },
            PaletteCommand(title: L10n.Command.closeTabTitle, subtitle: L10n.Command.closeTabSubtitle, icon: "xmark", isEnabled: appState.activeTabID != nil, keywords: ["tab"], shortcut: "⌘W") {
                appState.hideCommandPalette()
                appState.closeActiveTab()
            },
        ]
    }

    private var filteredCommands: [PaletteCommand] {
        let query = appState.commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }
        return commands.filter {
            PaletteCommandMatcher.matches(query, command: $0)
        }
    }

    private var selectedCommand: PaletteCommand? {
        guard filteredCommands.indices.contains(selectedCommandIndex) else { return nil }
        return filteredCommands[selectedCommandIndex]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.hideCommandPalette()
                }

            VStack(spacing: 0) {
                TextField(L10n.CommandPalette.placeholder, text: $appState.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(12)
                    .focused($queryFocused)
                    .onSubmit {
                        run(selectedCommand)
                    }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                let isSelected = index == selectedCommandIndex

                                Button {
                                    run(command)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: command.icon)
                                            .foregroundColor(isSelected ? .accentColor : .secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(command.title)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(command.subtitle)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if let shortcut = command.shortcut {
                                            Text(shortcut)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.accentColor.opacity(0.16))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!command.isEnabled)
                                .opacity(command.isEnabled ? 1 : 0.42)
                                .padding(.horizontal, 6)
                                .id(command.id)
                                .onHover { isHovering in
                                    if isHovering {
                                        selectCommandFromHover(at: index)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: selectedCommandIndex) { _, newValue in
                        scrollSelectedCommandIntoView(with: proxy, index: newValue)
                    }
                }
            }
            .frame(width: 520)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 18, y: 10)
        }
        .background {
            PaletteKeyboardHandler(
                onMoveUp: selectPreviousCommand,
                onMoveDown: selectNextCommand,
                onSubmit: { run(selectedCommand) },
                onCancel: { appState.hideCommandPalette() }
            )
        }
        .onAppear {
            queryFocused = true
            resetSelection()
        }
        .onChange(of: appState.commandPaletteQuery) { _, _ in
            resetSelection()
        }
        .onChange(of: filteredCommands.count) { _, _ in
            clampSelection()
        }
    }

    private func selectPreviousCommand() {
        guard !filteredCommands.isEmpty else { return }
        ignoreHoverSelectionDuringKeyboardMove()
        selectedCommandIndex = selectableIndex(from: selectedCommandIndex, offset: -1)
    }

    private func selectNextCommand() {
        guard !filteredCommands.isEmpty else { return }
        ignoreHoverSelectionDuringKeyboardMove()
        selectedCommandIndex = selectableIndex(from: selectedCommandIndex, offset: 1)
    }

    private func ignoreHoverSelectionDuringKeyboardMove() {
        ignoredHoverSelectionUntil = Date().addingTimeInterval(0.35)
        lastHoverMouseLocation = NSEvent.mouseLocation
    }

    private func selectCommandFromHover(at index: Int) {
        guard filteredCommands.indices.contains(index), filteredCommands[index].isEnabled else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard Date() >= ignoredHoverSelectionUntil else {
            lastHoverMouseLocation = mouseLocation
            return
        }

        guard lastHoverMouseLocation != mouseLocation else { return }
        lastHoverMouseLocation = mouseLocation
        selectedCommandIndex = index
    }

    private func selectableIndex(from startIndex: Int, offset: Int) -> Int {
        guard !filteredCommands.isEmpty else { return 0 }
        var nextIndex = startIndex

        for _ in filteredCommands.indices {
            nextIndex = (nextIndex + offset + filteredCommands.count) % filteredCommands.count
            if filteredCommands[nextIndex].isEnabled {
                return nextIndex
            }
        }

        return min(max(nextIndex, 0), filteredCommands.count - 1)
    }

    private func resetSelection() {
        selectedCommandIndex = filteredCommands.firstIndex(where: \.isEnabled) ?? 0
        clampSelection()
    }

    private func clampSelection() {
        guard !filteredCommands.isEmpty else {
            selectedCommandIndex = 0
            return
        }

        if !filteredCommands.indices.contains(selectedCommandIndex) {
            selectedCommandIndex = filteredCommands.firstIndex(where: \.isEnabled) ?? 0
        }
    }

    private func scrollSelectedCommandIntoView(with proxy: ScrollViewProxy, index: Int) {
        guard filteredCommands.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(filteredCommands[index].id, anchor: .center)
        }
    }

    private func run(_ command: PaletteCommand?) {
        guard let command, command.isEnabled else { return }
        command.action()
    }
}
// `MainWindowKeyboardShortcutHandler` / `WindowChromeConfigurator` /
// `ClearDividerSplitView` / `PaletteKeyboardHandler` /
// `FloatingPanelEscapeKeyHandler` + the NSView extensions live in
// `MainWindowChrome.swift` since rc39.


struct PaletteCommand: Identifiable {
    var id: String { title }
    let title: String
    let subtitle: String
    let icon: String
    let isEnabled: Bool
    let keywords: [String]
    let shortcut: String?
    let action: () -> Void

    init(
        title: String,
        subtitle: String,
        icon: String,
        isEnabled: Bool,
        keywords: [String] = [],
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isEnabled = isEnabled
        self.keywords = keywords
        self.shortcut = shortcut
        self.action = action
    }
}

struct PaletteCommandMatcher {
    static func matches(_ query: String, command: PaletteCommand) -> Bool {
        let haystacks = [command.title, command.subtitle] + command.keywords
        return haystacks.contains { fuzzyMatches(query, in: $0) }
    }

    static func fuzzyMatches(_ query: String, in candidate: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCandidate = candidate.lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        if normalizedCandidate.contains(normalizedQuery) {
            return true
        }

        var searchIndex = normalizedCandidate.startIndex
        for character in normalizedQuery {
            guard let foundIndex = normalizedCandidate[searchIndex...].firstIndex(of: character) else {
                return false
            }
            searchIndex = normalizedCandidate.index(after: foundIndex)
        }
        return true
    }
}

private struct SymbolJumpPanel: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var queryFocused: Bool
    @State private var selectedIndex = 0
    @State private var ignoredHoverSelectionUntil = Date.distantPast
    @State private var lastHoverMouseLocation = NSEvent.mouseLocation
    // Cache the extracted outline so the regex-heavy `EditorOutlineExtractor.outline`
    // pass runs only when the panel opens (and when file content/language actually
    // change), not on every body evaluation triggered by arrow-key navigation or
    // typing in the query field.
    @State private var allSymbols: [EditorOutlineItem] = []

    private func extractOutline() -> [EditorOutlineItem] {
        guard let url = appState.openedFileURL else { return [] }
        let language = appState.effectiveLanguage ?? Language.fromURL(url)
        return EditorOutlineExtractor.outline(for: appState.fileContent, language: language)
    }

    private var symbols: [EditorOutlineItem] {
        let query = appState.symbolJumpQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allSymbols }
        return allSymbols.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.kind.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSymbol: EditorOutlineItem? {
        guard symbols.indices.contains(selectedIndex) else { return nil }
        return symbols[selectedIndex]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.hideSymbolJump()
                }

            VStack(spacing: 0) {
                TextField(L10n.SymbolJump.placeholder, text: $appState.symbolJumpQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(12)
                    .focused($queryFocused)
                    .onSubmit {
                        jump(selectedSymbol)
                    }

                Divider()

                if symbols.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 22))
                        Text(L10n.SymbolJump.noSymbols)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(symbols.enumerated()), id: \.offset) { index, item in
                                    let isSelected = index == selectedIndex

                                    Button {
                                        jump(item)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: symbolIcon(for: item.kind))
                                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                                .frame(width: 18)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                    .font(.system(size: 13, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(L10n.SymbolJump.symbolKindLine(item.kind.rawValue, String(item.line)))
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background {
                                            if isSelected {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.accentColor.opacity(0.16))
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 6)
                                    .id(index)
                                    .onHover { isHovering in
                                        if isHovering {
                                            selectFromHover(at: index)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: selectedIndex) { _, newValue in
                            scrollSelectionIntoView(with: proxy, index: newValue)
                        }
                    }
                }
            }
            .frame(width: 520)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 18, y: 10)
        }
        .background {
            PaletteKeyboardHandler(
                onMoveUp: selectPrevious,
                onMoveDown: selectNext,
                onSubmit: { jump(selectedSymbol) },
                onCancel: { appState.hideSymbolJump() }
            )
        }
        .onAppear {
            queryFocused = true
            allSymbols = extractOutline()
            resetSelection()
        }
        .onChange(of: appState.fileContent) { _, _ in
            allSymbols = extractOutline()
            clampSelection()
        }
        .onChange(of: appState.effectiveLanguage) { _, _ in
            allSymbols = extractOutline()
            clampSelection()
        }
        .onChange(of: appState.symbolJumpQuery) { _, _ in
            resetSelection()
        }
        .onChange(of: symbols.count) { _, _ in
            clampSelection()
        }
    }

    private func selectPrevious() {
        guard !symbols.isEmpty else { return }
        ignoreHoverSelectionDuringKeyboardMove()
        selectedIndex = (selectedIndex - 1 + symbols.count) % symbols.count
    }

    private func selectNext() {
        guard !symbols.isEmpty else { return }
        ignoreHoverSelectionDuringKeyboardMove()
        selectedIndex = (selectedIndex + 1) % symbols.count
    }

    private func ignoreHoverSelectionDuringKeyboardMove() {
        ignoredHoverSelectionUntil = Date().addingTimeInterval(0.35)
        lastHoverMouseLocation = NSEvent.mouseLocation
    }

    private func selectFromHover(at index: Int) {
        guard symbols.indices.contains(index) else { return }

        let mouseLocation = NSEvent.mouseLocation
        guard Date() >= ignoredHoverSelectionUntil else {
            lastHoverMouseLocation = mouseLocation
            return
        }

        guard lastHoverMouseLocation != mouseLocation else { return }
        lastHoverMouseLocation = mouseLocation
        selectedIndex = index
    }

    private func resetSelection() {
        selectedIndex = 0
        clampSelection()
    }

    private func clampSelection() {
        guard !symbols.isEmpty else {
            selectedIndex = 0
            return
        }
        if !symbols.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }

    private func scrollSelectionIntoView(with proxy: ScrollViewProxy, index: Int) {
        guard symbols.indices.contains(index) else { return }
        // Scroll by row index rather than by item id: `symbols` is recomputed on
        // every body evaluation and each `EditorOutlineItem` gets a fresh UUID, so
        // an id captured here would never match the id rendered in the list and
        // the scroll would silently no-op.
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func jump(_ item: EditorOutlineItem?) {
        guard let item else { return }
        appState.navigateEditor(toLine: item.line)
        appState.hideSymbolJump()
    }

    private func symbolIcon(for kind: EditorOutlineItem.Kind) -> String {
        switch kind {
        case .type:
            return "cube"
        case .function:
            return "function"
        case .property:
            return "number"
        case .section:
            return "text.alignleft"
        case .key:
            return "key"
        }
    }
}

private struct ImagePreviewPane: View {
    let url: URL
    let onClose: () -> Void

    private var image: NSImage? {
        NSImage(contentsOf: url)
    }

    private var imageSizeText: String? {
        guard let image else { return nil }
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        return "\(width) × \(height)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let imageSizeText {
                    Text(imageSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.ImagePreview.closeButton)
                .accessibilityLabel(L10n.ImagePreview.closeButton)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }

            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                    Text(L10n.ImagePreview.cannotPreview)
                        .font(.headline)
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct QuickOpenPanel: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var queryFocused: Bool

    private var candidates: [URL] {
        // Reads the cache-backed, in-memory list maintained by AppState instead
        // of re-walking the project tree on every keystroke. Filtering stays in
        // the view because it's cheap (in-memory string match over <=1500 paths).
        let all = appState.quickOpenFiles
        let query = appState.quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(all.prefix(80)) }

        return all
            .filter { url in
                relativePath(for: url).localizedCaseInsensitiveContains(query)
                    || url.lastPathComponent.localizedCaseInsensitiveContains(query)
            }
            .prefix(80)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.hideQuickOpen()
                }

            VStack(spacing: 0) {
                TextField(L10n.QuickOpen.placeholder, text: $appState.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(12)
                    .focused($queryFocused)
                    .onSubmit {
                        open(candidates.first)
                    }

                Divider()

                if candidates.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                        Text(L10n.QuickOpen.noFiles)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(candidates, id: \.self) { url in
                                Button {
                                    open(url)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc")
                                            .foregroundColor(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.lastPathComponent)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                            Text(relativePath(for: url))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
            .frame(width: 520)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 18, y: 10)
        }
        .onAppear {
            queryFocused = true
            // Safety net: backfill if the list is empty (e.g. project was opened
            // before this list existed, or a prior refresh was cancelled). A
            // refresh already in flight is a cheap no-op via task cancellation.
            if appState.quickOpenFiles.isEmpty {
                appState.refreshProjectFileList()
            }
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                appState.hideQuickOpen()
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        appState.hideQuickOpen()
        appState.openedFileURL = url
    }

    private func relativePath(for url: URL) -> String {
        guard let root = appState.rootDirectory else { return url.path }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// `GoToLinePanel` / `EditorStatusBar` / `SplitEditorPane` / `PreviewPane` /
// `EditorInspectorSidebar` / `FindReplaceBar` / `EditorTabBar` /
// `EnterAgentModeButton` live in `ContentViewEditorChrome.swift` since rc56.
