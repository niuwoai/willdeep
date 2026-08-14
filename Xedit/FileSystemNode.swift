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
    nonisolated private static let maxLoadedChildren = 1_000

    // MARK: - Stored Properties

    /// Absolute filesystem URL of the represented file or directory.
    let url: URL

    /// Whether this node behaves as a directory in the tree. Symbolic links
    /// that point at a directory count: `.isDirectoryKey` reports false for
    /// the link itself, which used to render a linked folder as an
    /// unexpandable file — the "that's not a real directory" complaint.
    let isDirectory: Bool

    /// Whether this node is a symbolic link (to a directory or a file).
    let isSymbolicLink: Bool

    /// `url` with every symlink on the way resolved. Computed incrementally
    /// from the parent so a plain directory costs no extra `realpath` call.
    let resolvedPath: String

    /// Resolved paths of every ancestor on this expansion chain. A symlinked
    /// directory whose target already appears here would expand forever
    /// (`a/link -> a`), so it is kept visible but refuses to load children.
    private let ancestorResolvedPaths: Set<String>

    /// True when expanding this node would re-enter a directory already on the
    /// chain above it.
    let isCyclicSymlink: Bool

    /// Lazy-loaded child nodes. `nil` means children have not been loaded yet;
    /// an empty array means the directory has been scanned and is empty.
    @Published var children: [FileSystemNode]? = nil

    /// Whether this directory node is currently expanded in the tree.
    /// Setting to `true` triggers lazy child loading if not already loaded.
    @Published var isExpanded: Bool = false

    // MARK: - Initializer

    /// - Parameters:
    ///   - parentResolvedPath: the parent's already-resolved path, so a plain
    ///     child only has to append its own name instead of resolving again.
    ///   - ancestorResolvedPaths: resolved paths of the chain above, used for
    ///     the symlink cycle check.
    init(
        url: URL,
        parentResolvedPath: String? = nil,
        ancestorResolvedPaths: Set<String> = []
    ) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isLink = values?.isSymbolicLink ?? false
        self.isSymbolicLink = isLink
        if isLink {
            // A link has to be followed to learn what it is; `.isDirectoryKey`
            // describes the link file itself and is always false here.
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            self.resolvedPath = target.path
            self.isDirectory = target.isDirectoryURL
        } else {
            self.resolvedPath = parentResolvedPath.map {
                URL(fileURLWithPath: $0)
                    .appendingPathComponent(url.lastPathComponent)
                    .standardizedFileURL
                    .path
            } ?? url.resolvingSymlinksInPath().standardizedFileURL.path
            self.isDirectory = values?.isDirectory ?? false
        }
        self.ancestorResolvedPaths = ancestorResolvedPaths
        self.isCyclicSymlink = isLink
            && self.isDirectory
            && ancestorResolvedPaths.contains(self.resolvedPath)
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
        guard isDirectory, !isCyclicSymlink, children == nil else { return }
        let directoryURL = url
        Task { [weak self] in
            let urls = await Task.detached(priority: .utility) {
                Self.scanChildURLs(of: directoryURL)
            }.value
            guard let self, self.children == nil else { return }
            self.children = self.makeChildren(from: urls)
        }
    }

    /// Wrap scanned URLs as child nodes, extending the resolved-ancestor chain
    /// by one level so descendants can detect a link back into it.
    private func makeChildren(from urls: [URL]) -> [FileSystemNode] {
        let childAncestors = ancestorResolvedPaths.union([resolvedPath])
        return urls.map {
            FileSystemNode(
                url: $0,
                parentResolvedPath: resolvedPath,
                ancestorResolvedPaths: childAncestors
            )
        }
    }

    /// Synchronous sibling of `loadChildren` used by reveal-to-path: assigns
    /// `children` on the current runloop so the caller can immediately walk
    /// one level deeper without waiting for the async dispatch. Idempotent —
    /// a no-op once children are loaded.
    func loadChildrenSyncIfNeeded() {
        guard isDirectory, !isCyclicSymlink, children == nil else { return }
        children = makeChildren(from: Self.scanChildURLs(of: url))
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
    private nonisolated static func scanChildURLs(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        // `FileManager.enumerator` refuses to descend into a symlinked
        // directory, so scan the resolved target instead and re-attach the
        // names to the spelling the tree uses. The sidebar keeps showing
        // `project/linked/file`, which is what every path-prefixed feature
        // around it — selection, git badges, reveal-to-path — expects.
        let scanURL = url.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: scanURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var contents: [URL] = []
        for case let childURL as URL in enumerator {
            if behavesAsDirectory(childURL) {
                enumerator.skipDescendants()
                if ProjectDirectoryExclusions.shouldSkip(childURL) {
                    continue
                }
            }
            contents.append(url.appendingPathComponent(childURL.lastPathComponent))
            if contents.count >= Self.maxLoadedChildren {
                break
            }
        }

        return contents.sorted { a, b in
                let aIsDirectory = behavesAsDirectory(a)
                let bIsDirectory = behavesAsDirectory(b)
                if aIsDirectory != bIsDirectory {
                    return aIsDirectory
                }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
    }

    /// Whether `url` should be grouped and rendered as a folder — true for a
    /// real directory and for a symlink pointing at one. Kept in one place so
    /// the scan's exclusion check, its sorting, and `init` all agree.
    nonisolated static func behavesAsDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            return url.resolvingSymlinksInPath().isDirectoryURL
        }
        return values?.isDirectory ?? false
    }
}

// MARK: - URL Helpers

private extension URL {
    /// Returns `true` if this URL refers to an existing directory.
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
