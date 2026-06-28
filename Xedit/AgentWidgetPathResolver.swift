//
//  AgentWidgetPathResolver.swift
//  WillDeep
//
//  Shared local path boundary for sandboxed Widget HTML and source files.
//

import Foundation

enum AgentWidgetPathResolver {
    static func normalize(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    static func resolve(_ rawPath: String, workspaceRoot: URL?) -> URL? {
        let trimmed = normalize(rawPath)
        guard !trimmed.isEmpty else { return nil }
        let url: URL
        if (trimmed as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else if let workspaceRoot {
            url = workspaceRoot.standardizedFileURL.appendingPathComponent(trimmed).standardizedFileURL
        } else {
            return nil
        }
        return isAllowed(url, workspaceRoot: workspaceRoot) ? url : nil
    }

    static func resolveExisting(_ rawPath: String, workspaceRoot: URL?) -> URL? {
        guard let url = resolve(rawPath, workspaceRoot: workspaceRoot) else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) ? url : nil
    }

    static func isAllowed(_ url: URL, workspaceRoot: URL?) -> Bool {
        if let workspaceRoot, isURL(url, inside: workspaceRoot.standardizedFileURL) {
            return true
        }
        if temporaryDirectories().contains(where: { isURL(url, inside: $0) }) {
            return true
        }
        return isURL(url, inside: shortDramaExportsDirectory())
    }

    static func temporaryDirectories() -> [URL] {
        [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    static func shortDramaExportsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("WillDeep/short-drama/exports", isDirectory: true).standardizedFileURL
    }

    static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }
}
