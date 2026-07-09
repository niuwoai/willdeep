//
//  FileSystemNode.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import Combine
import Foundation

/// A recursive tree model representing a file or folder on disk.
/// Children are loaded lazily via FileManager when `loadChildren()` is called,
/// keeping directory scans fast even for large projects.
final class FileSystemNode: ObservableObject, Identifiable, Hashable {
    /// Per-directory child cap for the sidebar tree. A single generated folder
    /// can contain tens of thousands of entries; rendering all of them would
    /// balloon memory before the user can do anything useful.
    private static let maxLoadedChildren = 1_000

    // MARK: - Stored Properties

    /// Absolute filesystem URL of the represented file or directory.
    let url: URL

    /// Whether this node represents a directory.
    let isDirectory: Bool

    /// Lazy-loaded child nodes. `nil` means children have not been loaded yet;
    /// an empty array means the directory has been scanned and is empty.
    @Published var children: [FileSystemNode]? = nil

    /// Whether this directory node is currently expanded in the tree.
    /// Setting to `true` triggers lazy child loading if not already loaded.
    @Published var isExpanded: Bool = false

    // MARK: - Initializer

    init(url: URL) {
        self.url = url
        self.isDirectory = url.isDirectoryURL
    }

    // MARK: - Computed Properties

    /// Display name — the last path component of the URL.
    var name: String {
        url.lastPathComponent
    }

    // MARK: - Identifiable

    var id: URL { url }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileSystemNode, rhs: FileSystemNode) -> Bool {
        lhs.url == rhs.url
    }

    // MARK: - Child Loading

    /// Scans the directory at `url` using FileManager and populates `children`
    /// with a sorted array of FileSystemNode instances.
    ///
    /// Sorting: directories first, then files, alphabetically within each group.
    /// Hidden files (dotfiles) are included.
    ///
    /// - Note: Safe to call multiple times; only loads if `children` is nil
    ///   and `isDirectory` is true.
    func loadChildren() {
        guard isDirectory, children == nil else { return }
        let nodes = Self.scanChildren(of: url)
        DispatchQueue.main.async { [weak self] in
            self?.children = nodes
        }
    }

    /// Synchronous sibling of `loadChildren` used by reveal-to-path: assigns
    /// `children` on the current runloop so the caller can immediately walk
    /// one level deeper without waiting for the async dispatch. Idempotent —
    /// a no-op once children are loaded.
    func loadChildrenSyncIfNeeded() {
        guard isDirectory, children == nil else { return }
        children = Self.scanChildren(of: url)
    }

    /// Expand this subtree along the path toward `target`, loading each level
    /// synchronously and marking the ancestors `isExpanded`. Returns the node
    /// whose URL equals `target`, or nil if `target` isn't a descendant (or
    /// sits beyond a directory's child cap / hidden-file filter). Used to
    /// reveal a chat-referenced folder in the Files tree.
    @discardableResult
    func expandToDescendant(_ target: URL) -> FileSystemNode? {
        let targetPath = target.standardizedFileURL.path
        let selfPath = url.standardizedFileURL.path
        guard targetPath == selfPath || targetPath.hasPrefix(selfPath + "/") else { return nil }
        isExpanded = true
        if targetPath == selfPath { return self }
        guard isDirectory else { return nil }
        loadChildrenSyncIfNeeded()
        guard let children else { return nil }
        for child in children {
            let childPath = child.url.standardizedFileURL.path
            if targetPath == childPath || targetPath.hasPrefix(childPath + "/") {
                return child.expandToDescendant(target)
            }
        }
        return nil
    }

    func reloadChildren() {
        children = nil
        loadChildren()
    }

    /// Shared directory scan behind `loadChildren` / `loadChildrenSyncIfNeeded`.
    /// Directories first, then files, alphabetically; hidden files skipped;
    /// bounded by `maxLoadedChildren`. Returns `[]` on permission errors so the
    /// caller can cache the empty result and avoid re-scanning.
    private static func scanChildren(of url: URL) -> [FileSystemNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var contents: [URL] = []
        for case let childURL as URL in enumerator {
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                enumerator.skipDescendants()
                if ProjectDirectoryExclusions.shouldSkip(childURL) {
                    continue
                }
            }
            contents.append(childURL)
            if contents.count >= Self.maxLoadedChildren {
                break
            }
        }

        return contents
            .map { FileSystemNode(url: $0) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}

// MARK: - URL Helpers

private extension URL {
    /// Returns `true` if this URL refers to an existing directory.
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
