//
//  AgentWorkspaceAvailability.swift
//  WillDeep
//
//  Lazy local-workspace diagnostics for Agent sessions. The happy path is
//  optimistic: tools use the recorded path directly. Only after a real file
//  operation fails, or after the runtime is already known to be unavailable,
//  do we resolve bookmarks and inspect the original directory.
//

import Foundation

struct LocalWorkspaceIdentity: Codable, Equatable {
    var bookmarkData: Data?
    var volumeIdentifierDescription: String?
    var fileResourceIdentifierDescription: String?

    var hasIdentity: Bool {
        bookmarkData != nil || volumeIdentifierDescription != nil || fileResourceIdentifierDescription != nil
    }
}

enum AgentWorkspaceAvailability: Equatable {
    case optimistic
    case verified(path: String, checkedAt: Date)
    case missing(path: String, checkedAt: Date)
    case moved(originalPath: String, resolvedPath: String, checkedAt: Date)
    case permissionDenied(path: String, checkedAt: Date)

    var blocksLocalWorkspaceUse: Bool {
        switch self {
        case .missing, .moved, .permissionDenied:
            return true
        case .optimistic, .verified:
            return false
        }
    }

    var message: String? {
        switch self {
        case .optimistic, .verified:
            return nil
        case .missing(let path, _):
            return "Workspace is unavailable: \(path). It may have been deleted, moved, renamed, or become inaccessible. Re-select the folder before running workspace tools."
        case .moved(let originalPath, let resolvedPath, _):
            return "Workspace path changed from \(originalPath) to \(resolvedPath). Re-select the folder to confirm this session should use the new location."
        case .permissionDenied(let path, _):
            return "Workspace permission was lost for \(path). Re-select the folder to restore access before running workspace tools."
        }
    }
}

enum AgentWorkspaceAvailabilityError: LocalizedError, Equatable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

enum AgentWorkspaceAvailabilityResolver {
    static func captureIdentity(for path: String?) -> LocalWorkspaceIdentity? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return captureIdentity(for: URL(fileURLWithPath: path).standardizedFileURL)
    }

    static func captureIdentity(for url: URL) -> LocalWorkspaceIdentity {
        let standardized = url.standardizedFileURL
        let values = try? standardized.resourceValues(forKeys: [
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ])
        return LocalWorkspaceIdentity(
            bookmarkData: bookmarkData(for: standardized),
            volumeIdentifierDescription: values?.volumeIdentifier.map { String(describing: $0) },
            fileResourceIdentifierDescription: values?.fileResourceIdentifier.map { String(describing: $0) }
        )
    }

    static func diagnose(path: String, identity: LocalWorkspaceIdentity?) -> AgentWorkspaceAvailability {
        let standardizedURL = URL(fileURLWithPath: path).standardizedFileURL
        let standardizedPath = standardizedURL.path
        let now = Date()
        if isExistingDirectory(standardizedURL) {
            return .verified(path: standardizedPath, checkedAt: now)
        }
        guard let bookmarkData = identity?.bookmarkData else {
            return .missing(path: standardizedPath, checkedAt: now)
        }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                return .permissionDenied(path: standardizedPath, checkedAt: now)
            }
            defer { resolvedURL.stopAccessingSecurityScopedResource() }

            guard isExistingDirectory(resolvedURL) else {
                return .missing(path: standardizedPath, checkedAt: now)
            }
            if resolvedURL.path == standardizedPath {
                return .verified(path: standardizedPath, checkedAt: now)
            }
            return .moved(originalPath: standardizedPath, resolvedPath: resolvedURL.path, checkedAt: now)
        } catch {
            return .missing(path: standardizedPath, checkedAt: now)
        }
    }

    static func message(for availability: AgentWorkspaceAvailability) -> String? {
        availability.message
    }

    private static func bookmarkData(for url: URL) -> Data? {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
