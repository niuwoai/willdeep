//
//  ContentView.swift
//  VeilWriter
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

    var body: some View {
        NavigationSplitView {
            // Sidebar: directory tree
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
                    VStack(spacing: 14) {
                        Image(systemName: "folder")
                            .font(.system(size: 32))
                        Text("No Folder Open")
                            .font(.headline)
                        Text("Choose a file or folder to start editing.")
                            .font(.caption)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 8) {
                            Button {
                                appState.openFile()
                            } label: {
                                Label("Open File", systemImage: "doc")
                            }
                            .buttonStyle(EmptyStateIconButtonStyle())
                            .focusable(false)
                            .help("Open File")
                            .accessibilityLabel("Open File")

                            Button {
                                appState.openFolder { url in
                                    openWindow(value: url)
                                }
                            } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                            .buttonStyle(EmptyStateIconButtonStyle())
                            .focusable(false)
                            .help("Open Folder")
                            .accessibilityLabel("Open Folder")
                        }
                        .labelStyle(.iconOnly)

                        RecentItemsView()
                            .environmentObject(appState)
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: appState.isFocusModeEnabled ? 0 : 180)
            .navigationSplitViewColumnWidth(
                min: appState.isFocusModeEnabled ? 0 : 160,
                ideal: appState.isFocusModeEnabled ? 0 : 220,
                max: appState.isFocusModeEnabled ? 0 : 400
            )
        } detail: {
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
                            onSelect: { appState.activateTab(id: $0) },
                            onClose: { appState.closeTab(id: $0) }
                        )
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
                            onSelectionChange: { line, column, selectedCharacters, selectedLines in
                                appState.updateSelectionInfo(
                                    line: line,
                                    column: column,
                                    selectedCharacters: selectedCharacters,
                                    selectedLines: selectedLines
                                )
                            },
                            onSyntaxHighlightingChange: { selection in
                                appState.setSyntaxHighlightingSelection(selection)
                            }
                        )
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

                        if appState.isInspectorVisible && !appState.isFocusModeEnabled {
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
                        } else if !appState.isFocusModeEnabled {
                            InspectorCollapsedRail {
                                appState.isInspectorVisible = true
                            }
                        }
                    }

                    if !appState.isFocusModeEnabled {
                        EditorStatusBar(language: editorLanguage)
                            .environmentObject(appState)
                    }
                } else {
                    Color(nsColor: .textBackgroundColor)
                        .frame(minWidth: 400, minHeight: 400)
                }
            }
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
            alert.messageText = "Cannot Open Binary File"
            alert.informativeText = "\"\(newURL.lastPathComponent)\" appears to be a binary file and cannot be opened in the editor."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
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
            alert.messageText = "Large File"
            alert.informativeText = "\"\(newURL.lastPathComponent)\" is larger than 1 MB and may take time to load or become unresponsive."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Anyway")
            alert.addButton(withTitle: "Cancel")
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

private struct RecentItemsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.recentFolders.isEmpty {
                recentSection(title: "Recent Folders", urls: appState.recentFolders, icon: "folder") { url in
                    appState.openRecentFolder(url) { folderURL in
                        openWindow(value: folderURL)
                    }
                }
            }
            if !appState.recentFiles.isEmpty {
                recentSection(title: "Recent Files", urls: appState.recentFiles, icon: "doc") { url in
                    appState.openRecentFile(url)
                }
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private func recentSection(
        title: String,
        urls: [URL],
        icon: String,
        action: @escaping (URL) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(urls.prefix(4), id: \.self) { url in
                Button {
                    action(url)
                } label: {
                    Label(url.lastPathComponent, systemImage: icon)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
    }
}

private struct CommandPalettePanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @FocusState private var queryFocused: Bool
    @State private var selectedCommandIndex = 0
    @State private var ignoredHoverSelectionUntil = Date.distantPast
    @State private var lastHoverMouseLocation: CGPoint?

    private var commands: [PaletteCommand] {
        [
            PaletteCommand(title: "Quick Open", subtitle: "Search files in the current folder", icon: "doc.text.magnifyingglass", isEnabled: appState.rootDirectory != nil, keywords: ["file", "folder", "project"], shortcut: "⌘P") {
                appState.hideCommandPalette()
                appState.showQuickOpen()
            },
            PaletteCommand(title: "Go to Line", subtitle: "Jump to a line in the active tab", icon: "arrow.down.to.line", isEnabled: appState.activeTabID != nil, keywords: ["line", "jump"], shortcut: "⌘L") {
                appState.hideCommandPalette()
                appState.showGoToLine()
            },
            PaletteCommand(title: "Go to Symbol", subtitle: "Search symbols in the active tab", icon: "list.bullet.indent", isEnabled: appState.activeTabID != nil, keywords: ["outline", "method", "function"]) {
                appState.hideCommandPalette()
                appState.showSymbolJump()
            },
            PaletteCommand(title: "Find", subtitle: "Show find and replace", icon: "magnifyingglass", isEnabled: appState.activeTabID != nil, keywords: ["replace", "search"], shortcut: "⌘F") {
                appState.hideCommandPalette()
                appState.showFindBar()
            },
            PaletteCommand(title: "Toggle Inspector", subtitle: "Show or hide minimap and structure", icon: "sidebar.right", isEnabled: appState.activeTabID != nil, keywords: ["minimap", "outline"]) {
                appState.hideCommandPalette()
                appState.isInspectorVisible.toggle()
            },
            PaletteCommand(title: "Toggle Focus Mode", subtitle: "Hide chrome and keep only the editor", icon: "viewfinder", isEnabled: appState.activeTabID != nil, keywords: ["zen", "clean"]) {
                appState.hideCommandPalette()
                appState.toggleFocusMode()
            },
            PaletteCommand(title: "Toggle Preview", subtitle: "Show or hide Markdown and HTML preview", icon: "doc.richtext", isEnabled: appState.canShowPreview, keywords: ["markdown", "md", "html"]) {
                appState.hideCommandPalette()
                appState.togglePreview()
            },
            PaletteCommand(title: "Open Split File", subtitle: "Show another text file beside the editor", icon: "rectangle.split.2x1", isEnabled: true, keywords: ["side", "compare"]) {
                appState.hideCommandPalette()
                appState.openSplitFile()
            },
            PaletteCommand(title: "Open Containing Folder", subtitle: "Reveal the active file in Finder", icon: "folder.badge.gearshape", isEnabled: appState.openedFileURL != nil, keywords: ["finder", "reveal"]) {
                appState.hideCommandPalette()
                appState.openContainingFolder()
            },
            PaletteCommand(title: "Open File", subtitle: "Choose a file from disk", icon: "doc", isEnabled: true, keywords: ["document"], shortcut: "⌘O") {
                appState.hideCommandPalette()
                appState.openFile()
            },
            PaletteCommand(title: "Open Folder", subtitle: "Choose a folder for the sidebar", icon: "folder", isEnabled: true, keywords: ["project", "workspace"]) {
                appState.hideCommandPalette()
                appState.openFolder { url in
                    openWindow(value: url)
                }
            },
            PaletteCommand(title: "Open Terminal Here", subtitle: "Open Terminal at the project or active file location", icon: "terminal", isEnabled: appState.rootDirectory != nil || appState.openedFileURL != nil, keywords: ["shell", "cli", "command line"]) {
                appState.hideCommandPalette()
                appState.openTerminalHere(appState.openedFileURL ?? appState.rootDirectory)
            },
            PaletteCommand(title: "Copy File Path", subtitle: "Copy the active file path", icon: "doc.on.doc", isEnabled: appState.openedFileURL != nil, keywords: ["absolute", "clipboard"]) {
                appState.hideCommandPalette()
                if let url = appState.openedFileURL {
                    appState.copyPath(url)
                }
            },
            PaletteCommand(title: "Copy Relative File Path", subtitle: "Copy the active file path relative to the current folder", icon: "rectangle.on.rectangle", isEnabled: appState.openedFileURL != nil, keywords: ["relative", "clipboard"]) {
                appState.hideCommandPalette()
                if let url = appState.openedFileURL {
                    appState.copyRelativePath(url)
                }
            },
            PaletteCommand(title: "Refresh Git Status", subtitle: "Refresh branch and file status markers", icon: "arrow.clockwise", isEnabled: appState.rootDirectory != nil, keywords: ["source control", "branch", "changes"]) {
                appState.hideCommandPalette()
                appState.refreshGitStatus()
            },
            PaletteCommand(title: "Save", subtitle: "Write the active file", icon: "square.and.arrow.down", isEnabled: appState.activeTabID != nil, keywords: ["write"], shortcut: "⌘S") {
                appState.hideCommandPalette()
                appState.saveCurrentFile()
            },
            PaletteCommand(title: "Next Tab", subtitle: "Activate the tab to the right", icon: "chevron.right", isEnabled: appState.tabs.count > 1, keywords: ["tab"], shortcut: "⌘}") {
                appState.hideCommandPalette()
                appState.activateNextTab()
            },
            PaletteCommand(title: "Previous Tab", subtitle: "Activate the tab to the left", icon: "chevron.left", isEnabled: appState.tabs.count > 1, keywords: ["tab"], shortcut: "⌘{") {
                appState.hideCommandPalette()
                appState.activatePreviousTab()
            },
            PaletteCommand(title: "Reopen Closed Tab", subtitle: "Restore the most recently closed tab", icon: "arrow.uturn.backward", isEnabled: true, keywords: ["undo", "tab"]) {
                appState.hideCommandPalette()
                appState.reopenClosedTab()
            },
            PaletteCommand(title: "Duplicate Line", subtitle: "Copy the current line below", icon: "plus.square.on.square", isEnabled: appState.activeTabID != nil, keywords: ["copy", "editor"]) {
                appState.hideCommandPalette()
                appState.duplicateCurrentLine()
            },
            PaletteCommand(title: "Move Line Up", subtitle: "Move the current line upward", icon: "arrow.up", isEnabled: appState.activeTabID != nil, keywords: ["editor", "line"]) {
                appState.hideCommandPalette()
                appState.moveCurrentLineUp()
            },
            PaletteCommand(title: "Move Line Down", subtitle: "Move the current line downward", icon: "arrow.down", isEnabled: appState.activeTabID != nil, keywords: ["editor", "line"]) {
                appState.hideCommandPalette()
                appState.moveCurrentLineDown()
            },
            PaletteCommand(title: "Close Tab", subtitle: "Close the active tab", icon: "xmark", isEnabled: appState.activeTabID != nil, keywords: ["tab"], shortcut: "⌘W") {
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
                TextField("Command Palette", text: $appState.commandPaletteQuery)
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

private struct MainWindowKeyboardShortcutHandler: NSViewRepresentable {
    let hasActiveTab: Bool
    let onCloseTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.hasActiveTab = hasActiveTab
        context.coordinator.onCloseTab = onCloseTab
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hasActiveTab: hasActiveTab, onCloseTab: onCloseTab)
    }

    final class Coordinator {
        weak var view: NSView?
        var hasActiveTab: Bool
        var onCloseTab: () -> Void
        private var monitor: Any?

        init(hasActiveTab: Bool, onCloseTab: @escaping () -> Void) {
            self.hasActiveTab = hasActiveTab
            self.onCloseTab = onCloseTab
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  hasActiveTab,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
            guard relevantModifiers == .command else {
                return event
            }

            onCloseTab()
            return nil
        }
    }
}

private struct PaletteKeyboardHandler: NSViewRepresentable {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    final class Coordinator {
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void
        private var monitor: Any?

        init(
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == 53 {
                onCancel()
                return nil
            }

            switch event.specialKey {
            case .upArrow:
                onMoveUp()
                return nil
            case .downArrow:
                onMoveDown()
                return nil
            case .carriageReturn:
                onSubmit()
                return nil
            default:
                return event
            }
        }
    }
}

private struct FloatingPanelEscapeKeyHandler: NSViewRepresentable {
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    final class Coordinator {
        weak var view: NSView?
        var onCancel: () -> Void
        private var monitor: Any?

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.keyCode == 53 else { return event }
            if let window = view?.window,
               let eventWindow = event.window,
               eventWindow !== window {
                return event
            }

            onCancel()
            return nil
        }
    }
}

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

    private var symbols: [EditorOutlineItem] {
        guard let url = appState.openedFileURL else { return [] }
        let language = appState.effectiveLanguage ?? Language.fromURL(url)
        let all = EditorOutlineExtractor.outline(for: appState.fileContent, language: language)
        let query = appState.symbolJumpQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { item in
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
                TextField("Go to Symbol", text: $appState.symbolJumpQuery)
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
                        Text("No Symbols")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(symbols.enumerated()), id: \.element.id) { index, item in
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
                                                Text("\(item.kind.rawValue) · line \(item.line)")
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
                                    .id(item.id)
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
            resetSelection()
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
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(symbols[index].id, anchor: .center)
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
                .help("Close Preview")
                .accessibilityLabel("Close Preview")
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
                    Text("Cannot Preview Image")
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
        guard let root = appState.rootDirectory else { return [] }
        let all = AppState.quickOpenFileURLs(in: root)
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
                TextField("Quick Open", text: $appState.quickOpenQuery)
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
                        Text("No Files")
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

private struct GoToLinePanel: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var lineFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.hideGoToLine()
                }

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundColor(.secondary)

                TextField("Go to Line", text: $appState.goToLineText)
                    .textFieldStyle(.plain)
                    .focused($lineFieldFocused)
                    .onSubmit {
                        submit()
                    }

                Button {
                    submit()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.borderless)
                .disabled(Int(appState.goToLineText) == nil)
            }
            .padding(12)
            .frame(width: 260)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 16, y: 8)
        }
        .onAppear {
            lineFieldFocused = true
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                appState.hideGoToLine()
            }
        }
    }

    private func submit() {
        guard let line = Int(appState.goToLineText), line > 0 else { return }
        appState.navigateEditor(toLine: line)
        appState.hideGoToLine()
    }
}

private struct EditorStatusBar: View {
    @EnvironmentObject var appState: AppState
    let language: Language?

    private var fileSizeText: String {
        guard let url = appState.openedFileURL,
              let size = AppState.fileSize(at: url) else {
            return "--"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 14) {
            if appState.hasExternalFileChanges {
                Text("External changes")
                    .foregroundColor(.orange)
                Button("Reload") {
                    appState.reloadCurrentFileFromDisk()
                }
                .buttonStyle(.borderless)
            }
            Text(appState.isEdited ? "Modified" : "Saved")
                .foregroundColor(appState.isEdited ? .orange : .secondary)
            Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
            if appState.selectedCharacterCount > 0 {
                Text("\(appState.selectedCharacterCount) chars, \(appState.selectedLineCount) lines selected")
            }
            Spacer(minLength: 0)
            if let branchName = appState.gitStatus.branchName {
                Text("Git \(branchName)")
            }
            Text(language?.displayName ?? "Plain Text")
            Text(fileSizeText)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct SplitEditorPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let splitLanguage = appState.splitFileURL.map(Language.fromURL) ?? nil

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundColor(.secondary)
                Text(appState.splitFileURL?.lastPathComponent ?? "Split")
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    appState.closeSplitEditor()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            EditorView(
                text: $appState.splitFileContent,
                language: splitLanguage,
                settings: appState.editorSettings,
                highlightRevision: appState.editorHighlightRevision,
                searchRanges: [],
                activeSearchRange: nil
            )
        }
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

private struct PreviewPane: View {
    let text: String
    let language: Language?
    let onClose: () -> Void

    private var blocks: [MarkdownPreviewBlock] {
        switch language {
        case .html:
            return HTMLPreviewParser.blocks(from: text)
        default:
            return MarkdownPreviewParser.blocks(from: text)
        }
    }

    static func supports(_ language: Language?) -> Bool {
        language == .markdown || language == .html
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundColor(.secondary)
                Text("Preview")
                    .font(.caption)
                Spacer(minLength: 0)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownPreviewBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

struct MarkdownPreviewBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case quote
        case unorderedList
        case orderedList
        case code
        case divider
    }

    let kind: Kind
    let text: String
}

enum MarkdownPreviewParser {
    static func blocks(from source: String) -> [MarkdownPreviewBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownPreviewBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownPreviewBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushCode() {
            guard !code.isEmpty else { return }
            blocks.append(MarkdownPreviewBlock(kind: .code, text: code.joined(separator: "\n")))
            code.removeAll()
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if isInCodeBlock {
                    flushCode()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                code.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .divider, text: ""))
                continue
            }

            if let heading = headingBlock(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quote = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownPreviewBlock(kind: .quote, text: quote))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .unorderedList, text: String(trimmed.dropFirst(2))))
                continue
            }

            if let ordered = orderedListText(from: trimmed) {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .orderedList, text: ordered))
                continue
            }

            paragraph.append(trimmed)
        }

        if isInCodeBlock {
            flushCode()
        }
        flushParagraph()
        return blocks
    }

    private static func headingBlock(from line: String) -> MarkdownPreviewBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6, line.dropFirst(hashes.count).hasPrefix(" ") else {
            return nil
        }
        let text = line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
        return MarkdownPreviewBlock(kind: .heading(level: hashes.count), text: text)
    }

    private static func orderedListText(from line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dotIndex]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line[line.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return String(afterDot.dropFirst())
    }
}

enum HTMLPreviewParser {
    static func blocks(from source: String) -> [MarkdownPreviewBlock] {
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        let pattern = #"<\s*(title|h[1-5]|p|li|blockquote|pre|code|hr|div)\b([^>]*)>"#
        guard let tagRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var blocks: [MarkdownPreviewBlock] = []
        let matches = tagRegex.matches(in: source, range: range)

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let tagName = nsSource.substring(with: match.range(at: 1)).lowercased()

            if tagName == "hr" {
                blocks.append(MarkdownPreviewBlock(kind: .divider, text: ""))
                continue
            }

            guard let text = innerText(tagName: tagName, source: nsSource, after: match.range.upperBound) else {
                continue
            }

            switch tagName {
            case "title":
                blocks.append(MarkdownPreviewBlock(kind: .heading(level: 1), text: text))
            case "h1", "h2", "h3", "h4", "h5":
                let level = tagName.last?.wholeNumberValue ?? 1
                blocks.append(MarkdownPreviewBlock(kind: .heading(level: level), text: text))
            case "li":
                blocks.append(MarkdownPreviewBlock(kind: .unorderedList, text: text))
            case "blockquote":
                blocks.append(MarkdownPreviewBlock(kind: .quote, text: text))
            case "pre", "code":
                blocks.append(MarkdownPreviewBlock(kind: .code, text: text))
            default:
                blocks.append(MarkdownPreviewBlock(kind: .paragraph, text: text))
            }

            if blocks.count >= 200 {
                return blocks
            }
        }

        return blocks
    }

    private static func innerText(tagName: String, source: NSString, after start: Int) -> String? {
        let remainingLength = source.length - start
        guard remainingLength > 0 else { return nil }

        let closingPattern = "</\\s*\(NSRegularExpression.escapedPattern(for: tagName))\\s*>"
        guard let closingRegex = try? NSRegularExpression(pattern: closingPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let searchRange = NSRange(location: start, length: min(remainingLength, 8_000))
        guard let closing = closingRegex.firstMatch(in: source as String, range: searchRange) else {
            return nil
        }

        let textRange = NSRange(location: start, length: closing.range.location - start)
        guard textRange.length > 0 else { return nil }

        let raw = source.substring(with: textRange)
        let withoutHiddenContent = raw
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        let stripped = withoutHiddenContent.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return normalizedText(stripped)
    }

    private static func normalizedText(_ text: String) -> String? {
        let decoded = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }
}

private struct MarkdownPreviewBlockView: View {
    let block: MarkdownPreviewBlock

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(inlineText(block.text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundColor(.primary)
                .padding(.top, level <= 2 ? 8 : 2)
        case .paragraph:
            Text(inlineText(block.text))
                .font(.body)
                .lineSpacing(3)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                Text(inlineText(block.text))
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        case .unorderedList:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                Text(inlineText(block.text))
            }
            .font(.body)
        case .orderedList:
            HStack(alignment: .top, spacing: 8) {
                Text("1.")
                    .foregroundColor(.secondary)
                Text(inlineText(block.text))
            }
            .font(.body)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
                .padding(.vertical, 8)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 26
        case 2: return 21
        case 3: return 18
        default: return 15
        }
    }

    private func inlineText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct InspectorCollapsedRail: View {
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(90))
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show Inspector")
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

private struct EditorInspectorSidebar: View {
    let text: String
    let language: Language?
    @Binding var mode: EditorInspectorMode
    let orderedModes: [EditorInspectorMode]
    let onNavigateToLine: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector", selection: $mode) {
                    ForEach(orderedModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Hide Inspector")
            }
            .padding(8)

            Divider()

            switch mode {
            case .minimap:
                EditorMinimapView(text: text, onNavigateToLine: onNavigateToLine)
            case .structure:
                EditorStructureView(
                    items: EditorOutlineExtractor.outline(for: text, language: language),
                    onNavigateToLine: onNavigateToLine
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

private struct EditorMinimapView: View {
    let text: String
    let onNavigateToLine: (Int) -> Void

    private var lines: [String] {
        Array(text.components(separatedBy: .newlines).prefix(600))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Button {
                        onNavigateToLine(index + 1)
                    } label: {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(line.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color(nsColor: .separatorColor).opacity(0.28)
                                  : Color(nsColor: .secondaryLabelColor).opacity(0.38))
                            .frame(width: minimapWidth(for: line), height: 2)
                            .frame(maxWidth: .infinity, minHeight: 6, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func minimapWidth(for line: String) -> CGFloat {
        let count = line.trimmingCharacters(in: .whitespaces).count
        return min(180, max(12, CGFloat(count) * 1.8))
    }
}

private struct EditorStructureView: View {
    let items: [EditorOutlineItem]
    let onNavigateToLine: (Int) -> Void

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 22))
                Text("No Structure")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                Button {
                    onNavigateToLine(item.line)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: item.kind))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(item.line)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, CGFloat(item.level) * 10)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func iconName(for kind: EditorOutlineItem.Kind) -> String {
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

private struct FindReplaceBar: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var findFieldFocused: Bool

    private var matchText: String {
        let matches = appState.findMatchRanges
        guard !appState.findQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(min(appState.activeFindIndex + 1, matches.count)) of \(matches.count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $appState.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($findFieldFocused)

            Button {
                appState.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchRanges.isEmpty)
            .help("Previous Match")

            Button {
                appState.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchRanges.isEmpty)
            .help("Next Match")

            Text(matchText)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)

            Divider()
                .frame(height: 18)

            TextField("Replace", text: $appState.replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Picker("Scope", selection: $appState.findReplaceScope) {
                ForEach(FindReplaceScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(appState.findReplaceScope == .selectedFolder && appState.selectedFolderURL == nil)

            Button("Replace") {
                appState.replaceCurrentFindMatch()
            }
            .disabled(appState.findMatchRanges.isEmpty)

            Button("All") {
                appState.replaceAllFindMatches()
            }
            .disabled(appState.findMatchRanges.isEmpty)

            Spacer(minLength: 0)

            Button {
                appState.hideFindBar()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear {
            findFieldFocused = true
        }
    }
}

private struct EmptyStateIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .frame(width: 40, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        configuration.isPressed
                            ? Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                            : Color(nsColor: .quaternaryLabelColor).opacity(0.16)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EditorTabBar: View {
    let tabs: [EditorTab]
    let activeTabID: EditorTab.ID?
    let onSelect: (EditorTab.ID) -> Void
    let onClose: (EditorTab.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Text(tab.isEdited ? "\(tab.title) *" : tab.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 12, weight: tab.id == activeTabID ? .semibold : .regular))

                        Button {
                            onClose(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Close \(tab.title)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 96, maxWidth: 220)
                    .background(tab.id == activeTabID ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        onSelect(tab.id)
                    }
                    .help(tab.url.path)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
