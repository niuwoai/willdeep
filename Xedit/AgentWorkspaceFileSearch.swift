//
//  AgentWorkspaceFileSearch.swift
//  WillDeep
//
//  Workspace-scoped file lookup for the composer's `@file` picker.
//

import Foundation

nonisolated enum AgentWorkspaceFileSearch {
    static let defaultResultLimit = 30
    static let maxTraversalNodes = 50_000

    static func search(
        root: URL,
        query rawQuery: String,
        limit: Int = defaultResultLimit
    ) -> [URL] {
        guard limit > 0 else { return [] }

        let root = root.standardizedFileURL
        let rootPath = root.path
        let query = normalizedQuery(rawQuery)
        var matches: [(url: URL, relativePath: String, rank: Int)] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var visited = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            visited += 1
            if visited > maxTraversalNodes { break }

            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let relativePath = relativePath(for: url, rootPath: rootPath)
            guard let rank = matchRank(
                query: query,
                filename: url.lastPathComponent.lowercased(),
                relativePath: relativePath.lowercased()
            ) else {
                continue
            }
            matches.append((url.standardizedFileURL, relativePath, rank))
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.relativePath.count != rhs.relativePath.count {
                    return lhs.relativePath.count < rhs.relativePath.count
                }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            .prefix(limit)
            .map(\.url)
    }

    private static func normalizedQuery(_ rawQuery: String) -> String {
        rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
            .lowercased()
    }

    private static func relativePath(for url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func matchRank(
        query: String,
        filename: String,
        relativePath: String
    ) -> Int? {
        guard !query.isEmpty else { return 5 }
        if relativePath == query { return 0 }
        if filename == query { return 1 }
        if filename.hasPrefix(query) { return 2 }
        if filename.contains(query) { return 3 }
        if relativePath.contains(query) { return 4 }
        return nil
    }
}
