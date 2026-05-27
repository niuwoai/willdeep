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

    var body: some View {
        List {
            FileNodeRow(node: root, selectedURL: $selectedURL, level: 0)
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Recursive Row

/// A single row in the file tree. Directories render as expandable
/// `DisclosureGroup` rows; files render as tappable label rows.
private struct FileNodeRow: View {
    @ObservedObject var node: FileSystemNode
    @Binding var selectedURL: URL?
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
                            FileNodeRow(node: child, selectedURL: $selectedURL, level: level + 1)
                        }
                    }
                },
                label: {
                    Label(node.name, systemImage: "folder")
                        .padding(.leading, CGFloat(level) * 2)
                }
            )
        } else {
            HStack(spacing: 0) {
                Label(node.name, systemImage: "doc")
                    .padding(.leading, CGFloat(level) * 2)
                Spacer(minLength: 0)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedURL = node.url
                }
                .background(
                    selectedURL == node.url
                        ? Color.accentColor.opacity(0.3)
                        : Color.clear
                )
        }
    }
}
