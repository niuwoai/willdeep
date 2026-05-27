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
                    FileTreeView(root: root, selectedURL: $appState.openedFileURL)
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

                            Button {
                                appState.openFolder()
                            } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                        }
                        .labelStyle(.iconOnly)
                        .help("Open a file or folder")
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

                    // Detail: editor area with syntax highlighting.
                    let detectedLanguage: Language? = {
                        if let url = appState.openedFileURL {
                            return Language.fromURL(url)
                        }
                        return nil
                    }()

                    EditorView(
                        text: $appState.fileContent,
                        language: detectedLanguage,
                        settings: appState.editorSettings,
                        onEdit: {
                            // Mark dirty when the user types.
                            appState.isEdited = true
                            NSApplication.shared.keyWindow?.isDocumentEdited = true
                        }
                    )
                    .frame(minWidth: 400, minHeight: 400)
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
            } else {
                rootNode = nil
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
