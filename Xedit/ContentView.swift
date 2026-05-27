//
//  ContentView.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Derived from `appState.rootDirectory` — the tree model root node.
    /// Re-created whenever the root directory changes.
    @State private var rootNode: FileSystemNode?

    var body: some View {
        NavigationSplitView {
            // Sidebar: directory tree
            Group {
                if let root = rootNode {
                    FileTreeView(
                        root: root,
                        selectedURL: $appState.openedFileURL,
                        selectedFolderURL: $appState.selectedFolderURL
                    )
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
                                appState.openFolder()
                            } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                            .buttonStyle(EmptyStateIconButtonStyle())
                            .focusable(false)
                            .help("Open Folder")
                            .accessibilityLabel("Open Folder")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 180)
            .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if appState.activeTab != nil {
                    EditorTabBar(
                        tabs: appState.tabs,
                        activeTabID: appState.activeTabID,
                        onSelect: { appState.activateTab(id: $0) },
                        onClose: { appState.closeTab(id: $0) }
                    )

                    if appState.isFindBarVisible {
                        FindReplaceBar()
                            .environmentObject(appState)
                    }

                    // Detail: editor area with syntax highlighting.
                    let detectedLanguage: Language? = {
                        if let url = appState.openedFileURL {
                            return Language.fromURL(url)
                        }
                        return nil
                    }()

                    HStack(spacing: 0) {
                        EditorView(
                            text: $appState.fileContent,
                            language: detectedLanguage,
                            settings: appState.editorSettings,
                            renderRevision: appState.editorRenderRevision,
                            navigationRequest: appState.editorNavigationRequest,
                            searchRanges: appState.findMatchRanges,
                            activeSearchRange: appState.activeFindRange,
                            onEdit: {
                                // Mark dirty when the user types.
                                appState.isEdited = true
                                NSApplication.shared.keyWindow?.isDocumentEdited = true
                            },
                            onCursorChange: { line, column in
                                appState.updateCursorPosition(line: line, column: column)
                            }
                        )
                        .frame(minWidth: 400, minHeight: 400)

                        if appState.isInspectorVisible {
                            EditorInspectorSidebar(
                                text: appState.fileContent,
                                language: detectedLanguage,
                                mode: $appState.inspectorMode,
                                onNavigateToLine: { line in
                                    appState.navigateEditor(toLine: line)
                                },
                                onClose: {
                                    appState.isInspectorVisible = false
                                }
                            )
                            .frame(width: 220)
                        } else {
                            InspectorCollapsedRail {
                                appState.isInspectorVisible = true
                            }
                        }
                    }

                    EditorStatusBar(language: detectedLanguage)
                        .environmentObject(appState)
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
        appState.beginOpeningTab(for: newURL)
        appState.loadFile(from: newURL, fallbackURL: oldValue, allowLargeFile: allowLargeFile)
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
            Text(appState.isEdited ? "Modified" : "Saved")
                .foregroundColor(appState.isEdited ? .orange : .secondary)
            Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
            Spacer(minLength: 0)
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
    let onNavigateToLine: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector", selection: $mode) {
                    ForEach(EditorInspectorMode.allCases) { mode in
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
