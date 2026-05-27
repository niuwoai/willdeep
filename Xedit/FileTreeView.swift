//
//  FileTreeView.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI

/// A recursive file-tree view that renders a `FileSystemNode` tree using
/// compact custom rows for directories and files.
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
        .environment(\.defaultMinListRowHeight, 18)
        .onAppear {
            root.isExpanded = true
            root.loadChildren()
        }
    }
}

// MARK: - Recursive Row

/// A single row in the file tree. Directories render as expandable rows;
/// files render as tappable label rows.
private struct FileNodeRow: View {
    @ObservedObject var node: FileSystemNode
    @Binding var selectedURL: URL?
    @Binding var selectedFolderURL: URL?
    let level: Int

    var body: some View {
        if node.isDirectory {
            VStack(spacing: 0) {
                Button {
                    toggleDirectory()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isVisuallyExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .padding(.leading, CGFloat(level) * 8)
                        Label(node.name, systemImage: "folder")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        selectedFolderURL == node.url
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
                .onAppear {
                    if isVisuallyExpanded {
                        node.loadChildren()
                    }
                }

                if isVisuallyExpanded {
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
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 0))
        } else {
            Button {
                selectedURL = node.url
            } label: {
                HStack(spacing: 0) {
                    Label(node.name, systemImage: "doc")
                        .padding(.leading, CGFloat(level) * 8 + 14)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    selectedURL == node.url
                        ? Color.accentColor.opacity(0.3)
                        : Color.clear
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 0))
        }
    }

    private var isVisuallyExpanded: Bool {
        level == 0 || node.isExpanded
    }

    private func toggleDirectory() {
        selectedFolderURL = node.url
        if level == 0 {
            node.isExpanded = true
            node.loadChildren()
            return
        }

        node.isExpanded.toggle()
        if node.isExpanded {
            node.loadChildren()
        }
    }
}
