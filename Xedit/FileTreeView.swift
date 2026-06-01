//
//  FileTreeView.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

/// A recursive file-tree view that renders a `FileSystemNode` tree using
/// compact custom rows for directories and files.
///
/// Directories expand lazily — children are loaded from disk only on first expand.
struct FileTreeView: View {
    @EnvironmentObject var appState: AppState

    /// The root node of the tree to display.
    @ObservedObject var root: FileSystemNode

    /// A binding to the currently selected file URL (writes into AppState).
    @Binding var selectedURL: URL?
    @Binding var selectedFolderURL: URL?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FileNodeRow(
                    node: root,
                    selectedURL: $selectedURL,
                    selectedFolderURL: $selectedFolderURL,
                    level: 0
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.defaultMinListRowHeight, CGFloat(max(18, appState.editorSettings.fileTreeFontSize + 6)))
        .onAppear {
            root.isExpanded = true
            root.loadChildren()
            appState.refreshGitStatus()
        }
    }
}

// MARK: - Recursive Row

/// A single row in the file tree. Directories render as expandable rows;
/// files render as tappable label rows.
private struct FileNodeRow: View {
    @EnvironmentObject var appState: AppState
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
                            .font(.system(size: CGFloat(max(9, appState.editorSettings.fileTreeFontSize - 2)), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .padding(.leading, CGFloat(level) * 8)
                        FileTreeIcon(descriptor: .folder)
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        GitStatusBadge(kind: appState.gitStatusKind(for: node.url))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: CGFloat(appState.editorSettings.fileTreeFontSize)))
                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        selectedFolderURL == node.url
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    directoryContextMenu
                }
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
                selectFile()
            } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        FileTreeIcon(descriptor: FileTreeIconDescriptor.file(for: node.url))
                        Text(node.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.leading, CGFloat(level) * 8 + 14)
                    GitStatusBadge(kind: appState.gitStatusKind(for: node.url))
                    Spacer(minLength: 0)
                }
                .font(.system(size: CGFloat(appState.editorSettings.fileTreeFontSize)))
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    selectedURL == node.url || appState.selectedSidebarFileURL == node.url
                        ? Color.accentColor.opacity(0.3)
                        : Color.clear
                )
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        openFileFromDoubleClick()
                    }
            )
            .contextMenu {
                fileContextMenu
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 0))
        }
    }

    private var isVisuallyExpanded: Bool {
        level == 0 || node.isExpanded
    }

    private var rowHeight: CGFloat {
        CGFloat(max(18, appState.editorSettings.fileTreeFontSize + 6))
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

    private func selectFile() {
        appState.selectedSidebarFileURL = node.url
        if AppState.isImageFile(at: node.url) {
            return
        }

        appState.closeImagePreview()
        selectedURL = node.url
    }

    private func openFileFromDoubleClick() {
        appState.selectedSidebarFileURL = node.url
        if AppState.isImageFile(at: node.url) {
            appState.openImagePreview(node.url)
        } else {
            appState.closeImagePreview()
            selectedURL = node.url
        }
    }

    @ViewBuilder
    private var directoryContextMenu: some View {
        Button("New File") {
            appState.createNewFile(in: node.url) {
                node.reloadChildren()
            }
        }
        Button("New Folder") {
            appState.createNewFolder(in: node.url) {
                node.reloadChildren()
            }
        }
        Divider()
        Button("Open in Terminal") {
            appState.openTerminalHere(node.url)
        }
        Button("Reveal in Finder") {
            appState.revealInFinder(node.url)
        }
        Divider()
        Button("Copy Path") {
            appState.copyPath(node.url)
        }
        Button("Copy Relative Path") {
            appState.copyRelativePath(node.url)
        }
    }

    @ViewBuilder
    private var fileContextMenu: some View {
        Button("Open in Terminal") {
            appState.openTerminalHere(node.url)
        }
        Button("Reveal in Finder") {
            appState.revealInFinder(node.url)
        }
        Divider()
        Button("Copy Path") {
            appState.copyPath(node.url)
        }
        Button("Copy Relative Path") {
            appState.copyRelativePath(node.url)
        }
    }
}

struct FileTreeIconDescriptor: Equatable {
    let symbolName: String
    let color: Color
    let helpText: String

    static func == (lhs: FileTreeIconDescriptor, rhs: FileTreeIconDescriptor) -> Bool {
        lhs.symbolName == rhs.symbolName && lhs.helpText == rhs.helpText
    }

    static let folder = FileTreeIconDescriptor(
        symbolName: "folder.fill",
        color: Color(nsColor: .systemBlue),
        helpText: "Folder"
    )

    static func file(for url: URL) -> FileTreeIconDescriptor {
        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        switch filename {
        case "package.swift", "podfile", "cartfile":
            return descriptor("shippingbox.fill", .systemOrange, "Package")
        case "dockerfile", "containerfile", "docker-compose.yml", "docker-compose.yaml":
            return descriptor("shippingbox.circle.fill", .systemBlue, "Container")
        case "makefile", "gnumakefile", "rakefile", "gemfile":
            return descriptor("hammer.fill", .systemBrown, "Build Script")
        case ".env", ".env.local", ".env.development", ".env.production":
            return descriptor("lock.doc.fill", .systemPurple, "Environment")
        default:
            break
        }

        switch ext {
        case "swift":
            return descriptor("swift", .systemOrange, "Swift")
        case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx":
            return descriptor("curlybraces", .systemYellow, "JavaScript / TypeScript")
        case "html", "htm", "xhtml":
            return descriptor("globe", .systemBlue, "Web Page")
        case "css", "scss", "sass", "less":
            return descriptor("paintpalette.fill", .systemPink, "Stylesheet")
        case "json", "jsonc", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "plist":
            return descriptor("slider.horizontal.3", .systemTeal, "Config")
        case "md", "markdown", "txt", "rtf":
            return descriptor("doc.richtext.fill", .systemIndigo, "Document")
        case "sh", "bash", "zsh", "ksh", "fish":
            return descriptor("terminal.fill", .systemGreen, "Shell Script")
        case "py", "rb", "php", "java", "go", "rs", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "cs":
            return descriptor("chevron.left.forwardslash.chevron.right", .systemPurple, "Source Code")
        case "sql", "sqlite", "db":
            return descriptor("cylinder.split.1x2.fill", .systemMint, "Database")
        case "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "ico", "icns":
            return descriptor("photo.fill", .systemCyan, "Image")
        case "svg", "pdf":
            return descriptor("doc.viewfinder.fill", .systemRed, "Vector / PDF")
        case "mp3", "wav", "m4a", "aac", "flac", "ogg":
            return descriptor("music.note", .systemPink, "Audio")
        case "mp4", "mov", "m4v", "webm", "avi", "mkv":
            return descriptor("film.fill", .systemPurple, "Video")
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar":
            return descriptor("archivebox.fill", .systemBrown, "Archive")
        case "xcodeproj", "xcworkspace", "playground":
            return descriptor("hammer.circle.fill", .systemBlue, "Xcode Project")
        case "xcassets":
            return descriptor("square.stack.3d.up.fill", .systemOrange, "Asset Catalog")
        default:
            return descriptor("doc.fill", .secondaryLabelColor, "File")
        }
    }

    private static func descriptor(_ symbolName: String, _ color: NSColor, _ helpText: String) -> FileTreeIconDescriptor {
        FileTreeIconDescriptor(symbolName: symbolName, color: Color(nsColor: color), helpText: helpText)
    }
}

private struct FileTreeIcon: View {
    let descriptor: FileTreeIconDescriptor

    var body: some View {
        Image(systemName: descriptor.symbolName)
            .foregroundStyle(descriptor.color)
            .frame(width: 14)
            .help(descriptor.helpText)
    }
}

private struct GitStatusBadge: View {
    let kind: GitFileStatusKind?

    var body: some View {
        if let kind {
            Text(kind.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12)
                .help(helpText)
        }
    }

    private var color: Color {
        switch kind {
        case .added:
            return .green
        case .deleted:
            return .red
        case .renamed:
            return .blue
        case .untracked:
            return .orange
        case .modified:
            return .purple
        case nil:
            return .secondary
        }
    }

    private var helpText: String {
        switch kind {
        case .added:
            return "Added"
        case .deleted:
            return "Deleted"
        case .renamed:
            return "Renamed"
        case .untracked:
            return "Untracked"
        case .modified:
            return "Modified"
        case nil:
            return ""
        }
    }
}
