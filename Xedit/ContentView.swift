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
                            searchRanges: appState.findMatchRanges,
                            activeSearchRange: appState.activeFindRange,
                            onEdit: {
                                // Mark dirty when the user types.
                                appState.isEdited = true
                                NSApplication.shared.keyWindow?.isDocumentEdited = true
                            }
                        )
                        .frame(minWidth: 400, minHeight: 400)

                        if appState.isInspectorVisible {
                            EditorInspectorSidebar(
                                text: appState.fileContent,
                                language: detectedLanguage,
                                mode: $appState.inspectorMode,
                                onClose: {
                                    appState.isInspectorVisible = false
                                }
                            )
                            .frame(width: 220)
                        }
                    }
                } else {
                    Color(nsColor: .textBackgroundColor)
                        .frame(minWidth: 400, minHeight: 400)
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

private struct EditorInspectorSidebar: View {
    let text: String
    let language: Language?
    @Binding var mode: EditorInspectorMode
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
                EditorMinimapView(text: text)
            case .structure:
                EditorStructureView(items: EditorOutlineExtractor.outline(for: text, language: language))
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

    private var lines: [String] {
        Array(text.components(separatedBy: .newlines).prefix(600))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(line.trimmingCharacters(in: .whitespaces).isEmpty
                              ? Color(nsColor: .separatorColor).opacity(0.28)
                              : Color(nsColor: .secondaryLabelColor).opacity(0.38))
                        .frame(width: minimapWidth(for: line), height: 2)
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
