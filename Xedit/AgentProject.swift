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
//  Project folders are both sidebar grouping and explicit local tool roots.
//  Relative paths still resolve against the session's `workspaceLocation`;
//  absolute paths may address any other folder attached to the Project.
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
    /// Presentation priority in the sidebar. Optional storage keeps projects
    /// written by older versions backward-compatible when the key is absent.
    var pinnedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        folderPaths: [String],
        repositoryIdentities: [String] = [],
        pinnedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.folderPaths = folderPaths.compactMap(AgentProject.normalizedPath)
        self.repositoryIdentities = repositoryIdentities
        self.pinnedAt = pinnedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var primaryFolderPath: String? {
        folderPaths.first
    }

    var isPinned: Bool {
        pinnedAt != nil
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
/// What to do with a session whose workspace path is actually a sidebar group
/// key rather than a folder.
nonisolated enum AgentWorkspacePathRepair: Equatable {
    case notCorrupted
    /// Point the session at this folder instead.
    case repair(String)
    /// The project is gone, so there is no folder to recover — drop the
    /// workspace rather than leave a path that cannot resolve.
    case clear
}

/// Repairs sessions anchored to a `project:<uuid>` group key.
///
/// 1.234.0-rc18 shipped a sidebar that handed "new chat in this group" the
/// group key where a path was expected. For a bare folder the key *is* the
/// path, so this was invisible until workspaces became projects; afterwards
/// `startNewAgentSession(inWorkspaceAt:)` standardized the key into the
/// absolute-looking `/project:<uuid>` and stored it as the session's workspace
/// root. Every file, terminal and git operation would then resolve against a
/// directory that does not exist.
///
/// The sidebar no longer produces these, but rc18 is already published, so
/// existing sessions have to be healed on load.
nonisolated enum AgentWorkspacePathRepairPlan {
    static func plan(
        workspacePath path: String?,
        projects: [AgentProject]
    ) -> AgentWorkspacePathRepair {
        guard let path, let id = leakedProjectID(in: path) else { return .notCorrupted }
        guard let project = projects.first(where: { $0.id == id }),
              let folder = project.primaryFolderPath else {
            return .clear
        }
        return .repair(folder)
    }

    /// Accepts both the raw key and the standardized `/project:<uuid>` form.
    static func leakedProjectID(in path: String) -> UUID? {
        let candidate = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return AgentSession.projectID(fromSidebarGroupKey: candidate)
    }
}

/// Decides which bare workspace folders still need to become projects.
///
/// Split out from `AppState.migrateAgentWorkspacesToProjects()` so the rule is
/// testable without a live AppState or the projects file on disk.
nonisolated enum AgentWorkspaceProjectMigration {
    /// Local workspace folders not yet claimed by any project, in first-seen
    /// order and de-duplicated.
    ///
    /// Skips sessions with no workspace, sessions already in a project, and
    /// remote workspaces — a `remote:` group has no local folder that a
    /// project could be built from.
    static func foldersNeedingProject(
        sessions: [AgentSession],
        existing: [AgentProject]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for session in sessions {
            // Dispatch-board and roundtable sessions are internal product
            // runtimes, not user workspaces. Promoting their isolated Git
            // worktrees created one permanent `dispatch-*` project per task.
            guard session.presentationScope == .workspace else { continue }
            let key = session.workspaceSidebarGroupKey
            guard key != AgentSession.noWorkspaceSidebarGroupKey,
                  AgentSession.projectID(fromSidebarGroupKey: key) == nil,
                  WorkspacePresentation.remoteWorkspaceGroup(from: key) == nil,
                  let path = AgentProject.normalizedPath(key),
                  !seen.contains(path) else {
                continue
            }
            seen.insert(path)
            // A parent folder already covered by a project counts as claimed:
            // adding a second project for the child would split one group in
            // two, which is the opposite of the point.
            guard AgentProjectResolver.project(for: path, in: existing) == nil else { continue }
            result.append(path)
        }
        return result
    }
}

/// Finds project records accidentally minted from Dispatch task worktrees.
///
/// The repair is intentionally conservative: a candidate must live below
/// WillDeep's private worktree root, use the automatic folder-name title, be
/// unpinned, and have no ordinary workspace session attached. It removes only
/// the catalog record; the worktree and every task session remain untouched.
nonisolated enum AgentDispatchProjectLeakRepair {
    static func projectIDsToRemove(
        projects: [AgentProject],
        sessions: [AgentSession],
        managedWorktreeRoot: String
    ) -> Set<AgentProject.ID> {
        guard let root = AgentProject.normalizedPath(managedWorktreeRoot) else { return [] }
        let sessionsByProject = Dictionary(grouping: sessions.compactMap { session in
            session.projectID.map { ($0, session) }
        }, by: { $0.0 })

        return Set(projects.compactMap { project in
            guard !project.isPinned,
                  project.folderPaths.count == 1,
                  let folder = project.primaryFolderPath,
                  AgentProject.folder(root, contains: folder),
                  URL(fileURLWithPath: folder).lastPathComponent.hasPrefix("dispatch-"),
                  project.resolvedDisplayName == URL(fileURLWithPath: folder).lastPathComponent else {
                return nil
            }
            let attachedSessions = sessionsByProject[project.id, default: []].map(\.1)
            guard attachedSessions.allSatisfy({ $0.presentationScope != .workspace }) else {
                return nil
            }
            return project.id
        })
    }
}

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
