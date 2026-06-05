//
//  AppStatePersistenceStores.swift
//  VeilWriter
//
//  Extracted from AppState.swift in v1.52.1-rc42 as part of the stage-3
//  code-health pass. Houses the three private UserDefaults-backed stores
//  the AppState relies on for editor session restore and recent items,
//  plus the tiny actor that accumulates context-compression summary
//  chunks. None of these touch any AppState instance state — they're
//  pure persistence helpers that were just historically inlined into
//  the same file.
//

import Foundation

enum RecentItemsStore {
    private static let filesKey = "im.some.veilwriter.recentFiles.v1"
    private static let foldersKey = "im.some.veilwriter.recentFolders.v1"
    private static let limit = 8

    static func loadFiles() -> [URL] {
        loadCleaned(key: filesKey)
    }

    static func loadFolders() -> [URL] {
        loadCleaned(key: foldersKey)
    }

    static func saveFiles(_ urls: [URL]) {
        save(urls, key: filesKey)
    }

    static func saveFolders(_ urls: [URL]) {
        save(urls, key: foldersKey)
    }

    static func add(_ url: URL, to urls: [URL]) -> [URL] {
        let standardized = url.standardizedFileURL
        let cleaned = urls.filter(Self.isEligible)
        guard isEligible(standardized) else {
            return Array(cleaned.prefix(limit))
        }

        let unique = cleaned.filter { $0.standardizedFileURL != standardized }
        return Array(([standardized] + unique).prefix(limit))
    }

    private static func loadCleaned(key: String) -> [URL] {
        let urls = load(key: key)
        let cleaned = Array(urls.filter(Self.isEligible).prefix(limit))
        if cleaned.map(\.path) != urls.map(\.path) {
            save(cleaned, key: key)
        }
        return cleaned
    }

    private static func load(key: String) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private static func save(_ urls: [URL], key: String) {
        UserDefaults.standard.set(urls.filter(Self.isEligible).map(\.path), forKey: key)
    }

    nonisolated static func isEligible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return !temporaryDirectoryPaths.contains { tempPath in
            path == tempPath || path.hasPrefix(tempPath + "/")
        }
    }

    nonisolated private static var temporaryDirectoryPaths: [String] {
        [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory()),
            URL(fileURLWithPath: "/tmp"),
            URL(fileURLWithPath: "/private/tmp")
        ]
        .map { $0.standardizedFileURL.path }
    }
}

struct EditorSessionSnapshot: Codable {
    let rootDirectoryPath: String?
    let rootDirectoryBookmarkData: Data?
    let tabPaths: [String]
    let activeTabPath: String?
}

/// Tiny actor used to thread-safely accumulate a streamed summary
/// without leaking `@MainActor` isolation into the streaming callback.
actor CompressionSummaryCollector {
    private(set) var value: String = ""
    func append(_ chunk: String) {
        value += chunk
    }
}

enum SessionStore {
    private static let key = "im.some.veilwriter.session.v1"

    static func load() -> EditorSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
    }

    static func save(_ snapshot: EditorSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
