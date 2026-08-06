//
//  AgentProject.swift
//  WillDeep
//
//  A named project owning several source folders.
//
//  Until now a "project" was literally one folder path: the sidebar grouped
//  by `workspaceSidebarGroupKey` and took the group's name from the last
//  path component. That split a front-end and back-end repo into unrelated
//  groups, and left the group name stuck at whatever the directory happened
//  to be called.
//
//  This is a presentation and grouping concept only. Tools always execute
//  against the session's own `workspaceLocation`, so nothing here can move
//  where work actually happens — the separation the Git-worktree support
//  already established (see `AgentSession.sidebarWorkspaceRootPath`).
//

import Foundation

nonisolated struct AgentProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    /// Folders belonging to this project, normalized absolute paths. Order is
    /// the UI's order; the first is the primary folder (default landing spot
    /// for new sessions, and the dispatch board's primary path).
    var folderPaths: [String]
    /// Local repository fingerprints, reusing the dispatch resolver's notion
    /// of identity so a folder moved in Finder can still be recognized.
    var repositoryIdentities: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        folderPaths: [String],
        repositoryIdentities: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.folderPaths = folderPaths.compactMap(AgentProject.normalizedPath)
        self.repositoryIdentities = repositoryIdentities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var primaryFolderPath: String? {
        folderPaths.first
    }

    /// The name to show. An empty name would render as a blank sidebar
    /// group, so it falls back to the primary folder's own name.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let primary = primaryFolderPath else { return displayName }
        return URL(fileURLWithPath: primary).lastPathComponent
    }

    /// Trailing slashes and `.` segments removed so path comparison is a
    /// plain string test. Returns nil for anything unusable.
    static func normalizedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard !standardized.isEmpty, standardized != "/" else { return nil }
        return standardized
    }

    /// Whether `path` is this folder or lives inside it.
    ///
    /// Compares on path boundaries, so `/a/b` does not swallow `/a/bc`.
    static func folder(_ folder: String, contains path: String) -> Bool {
        guard let folder = normalizedPath(folder), let path = normalizedPath(path) else {
            return false
        }
        return path == folder || path.hasPrefix(folder + "/")
    }

    func contains(path: String) -> Bool {
        folderPaths.contains { Self.folder($0, contains: path) }
    }

    /// Length of the most specific folder in this project that contains
    /// `path`, used to arbitrate when several projects claim the same path.
    func matchDepth(for path: String) -> Int? {
        folderPaths
            .filter { Self.folder($0, contains: path) }
            .map(\.count)
            .max()
    }
}

// MARK: - Ownership resolution

nonisolated enum AgentProjectResolver {
    /// Which project owns `path`.
    ///
    /// A folder may belong to several projects, so ties need a deterministic
    /// rule: the most specific folder wins (deepest match), then the most
    /// recently updated project. Callers persist the result on the session —
    /// without that, adding a new project could silently move old
    /// conversations into a different group.
    static func project(for path: String?, in projects: [AgentProject]) -> AgentProject? {
        guard let path, let normalized = AgentProject.normalizedPath(path) else { return nil }
        let candidates = projects.compactMap { project -> (AgentProject, Int)? in
            guard let depth = project.matchDepth(for: normalized) else { return nil }
            return (project, depth)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.updatedAt < rhs.0.updatedAt
        }?.0
    }

    /// Projects other than `excluded` that also claim `path`. Drives the
    /// "remove project" rules: a session whose folder is shared is rebound
    /// rather than deleted.
    static func otherProjectsClaiming(
        path: String?,
        excluding excluded: UUID,
        in projects: [AgentProject]
    ) -> [AgentProject] {
        guard let path, let normalized = AgentProject.normalizedPath(path) else { return [] }
        return projects.filter { $0.id != excluded && $0.contains(path: normalized) }
    }
}

// MARK: - Storage

/// Projects live in one small JSON file beside the session directory, so the
/// test-sandbox redirect on `AgentSessionStore.directory` carries over.
/// There are a handful of projects at most; no sharding needed.
nonisolated enum AgentProjectStore {
    static var fileURL: URL {
        AgentSessionStore.directory
            .deletingLastPathComponent()
            .appendingPathComponent("projects.json", isDirectory: false)
    }

    static func load() -> [AgentProject] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // Dates stay on the default numeric encoding, matching how sessions
        // are stored. ISO8601 drops sub-second precision, and `updatedAt` is
        // what breaks ties when two projects claim the same folder — a value
        // that shifts every time it round-trips would make that arbitration
        // unstable.
        return (try? JSONDecoder().decode([AgentProject].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ projects: [AgentProject]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(projects).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
