//
//  FileTreeView.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI

/// A recursive file-tree view that renders a `FileSystemNode` tree using
/// `DisclosureGroup` for directories and tappable rows for files.
///
/// Directories expand lazily — children are loaded from disk only on first expand.
struct FileTreeView: View {

    /// The root node of the tree to display.
    @ObservedObject var root: FileSystemNode

    /// A binding to the currently selected file URL (writes into AppState).
    @Binding var selectedURL: URL?
    @Binding var selectedFolderURL: URL?

    var body: some View {
        List {
            FileNodeRow(
                node: root,
                selectedURL: $selectedURL,
                selectedFolderURL: $selectedFolderURL,
                level: 0
            )
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }
}

// MARK: - Recursive Row

/// A single row in the file tree. Directories render as expandable
/// `DisclosureGroup` rows; files render as tappable label rows.
private struct FileNodeRow: View {
    @ObservedObject var node: FileSystemNode
    @Binding var selectedURL: URL?
    @Binding var selectedFolderURL: URL?
    let level: Int

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { node.isExpanded },
                    set: { newValue in
                        node.isExpanded = newValue
                        if newValue {
                            node.loadChildren()
                        }
                    }
                ),
                content: {
                    if let children = node.children {
                        ForEach(children) { child in
                            FileNodeRow(
                                node: child,
                                selectedURL: $selectedURL,
                                selectedFolderURL: $selectedFolderURL,
                                level: level + 1
                            )
                        }
                    }
                },
                label: {
                    HStack(spacing: 0) {
                        Label(node.name, systemImage: "folder")
                            .padding(.leading, CGFloat(level) * 2)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        selectedFolderURL == node.url
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .onTapGesture {
                        selectedFolderURL = node.url
                    }
                }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
        } else {
            Button {
                selectedURL = node.url
            } label: {
                HStack(spacing: 0) {
                    Label(node.name, systemImage: "doc")
                        .padding(.leading, CGFloat(level) * 2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    selectedURL == node.url
                        ? Color.accentColor.opacity(0.3)
                        : Color.clear
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
        }
    }
}
