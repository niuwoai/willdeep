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

        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            // Permission denied or other error — set to empty to avoid repeated attempts.
            DispatchQueue.main.async { [weak self] in
                self?.children = []
            }
            return
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

        let nodes = contents
            .map { FileSystemNode(url: $0) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        DispatchQueue.main.async { [weak self] in
            self?.children = nodes
        }
    }

    func reloadChildren() {
        children = nil
        loadChildren()
    }
}

// MARK: - URL Helpers

private extension URL {
    /// Returns `true` if this URL refers to an existing directory.
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
