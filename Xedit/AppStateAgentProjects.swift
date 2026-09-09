//
//  AppStateAgentProjects.swift
//  WillDeep
//
//  Creating, editing and removing projects.
//
//  Every mutation here re-resolves session ownership and persists it, rather
//  than leaving grouping to be recomputed at render time: a folder may
//  belong to several projects, so a purely dynamic rule would let creating
//  one project silently move another project's conversations.
//

import AppKit
import Combine
import Foundation

extension AppState {
    /// Focus a project group in the sidebar without changing the open
    /// conversation. This is the project-name counterpart of a title-search
    /// hit on a single chat.
    func revealAgentProjectInSidebar(id: AgentProject.ID) {
        guard agentProjects.contains(where: { $0.id == id }) else { return }
        agentPrimaryDestination = .conversation
        agentSidebarRevealRequest = AgentSidebarRevealRequest(target: .project(id))
    }

    /// Local filesystem roots explicitly authorized by the session's Project.
    /// The session workspace stays first so relative tool paths remain stable.
    func agentWorkspaceRoots(for session: AgentSession) -> [URL] {
        guard case .local(let primaryPath) = session.workspaceLocation
                ?? session.workspaceRootPath.map({ .local(path: $0) }) else {
            return []
        }
        let projectPaths = session.projectID
            .flatMap { id in agentProjects.first(where: { $0.id == id }) }?
            .folderPaths ?? []
        var seen = Set<String>()
        return ([primaryPath] + projectPaths).compactMap { rawPath in
            guard let path = AgentProject.normalizedPath(rawPath), seen.insert(path).inserted else {
                return nil
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    // MARK: Create / update

    /// Turn a plain folder group into a named project, or extend an existing
    /// one. Returns the project so callers can immediately edit it.
    @discardableResult
    func createAgentProject(displayName: String, folderPaths: [String]) -> AgentProject? {
        let normalized = folderPaths.compactMap(AgentProject.normalizedPath)
        guard !normalized.isEmpty else { return nil }
        let project = AgentProject(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            folderPaths: normalized
        )
        agentProjects.append(project)
        AgentProjectStore.save(agentProjects)
        rebindAgentSessionsToProjects()
        activateAgentProjectFolderAccess(projectID: project.id)
        return project
    }

    /// Apply an edit from the project sheet. Removing the last folder is
    /// equivalent to removing the project, and the caller is expected to have
    /// confirmed that separately — this refuses rather than silently
    /// orphaning the conversations.
    @discardableResult
    func updateAgentProject(
        id: UUID,
        displayName: String,
        folderPaths: [String]
    ) -> Bool {
        guard let index = agentProjects.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = folderPaths.compactMap(AgentProject.normalizedPath)
        guard !normalized.isEmpty else { return false }

        agentProjects[index].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        agentProjects[index].folderPaths = normalized
        agentProjects[index].updatedAt = Date()
        AgentProjectStore.save(agentProjects)
        rebindAgentSessionsToProjects()
        activateAgentProjectFolderAccess(projectID: id)
        return true
    }

    /// Pinning changes sidebar priority only. It deliberately leaves
    /// `createdAt` and `updatedAt` untouched so project ordering remains
    /// stable and repository ownership tie-breaking does not change.
    func toggleAgentProjectPinned(id: UUID) {
        guard let index = agentProjects.firstIndex(where: { $0.id == id }) else { return }
        agentProjects[index].pinnedAt = agentProjects[index].isPinned ? nil : Date()
        AgentProjectStore.save(agentProjects)
    }

    // MARK: Removal

    /// What removing this project would do to its conversations. Computed
    /// before anything is destroyed so the confirmation can state both the
    /// number deleted and the number moved elsewhere.
    func agentProjectRemovalPlan(for id: UUID) -> AgentProjectRemovalPlan {
        guard let project = agentProjects.first(where: { $0.id == id }) else {
            return .empty
        }
        return AgentProjectRemoval.plan(
            removing: project,
            projects: agentProjects,
            sessions: agentSessions
        )
    }

    /// Remove the project, applying the plan above.
    ///
    /// Deletion goes through `deleteAgentSession`, which already handles a
    /// responding runtime, the async write queue and sidecar cleanup — a
    /// second deletion path here would drift from it.
    func removeAgentProject(id: UUID) {
        guard agentProjects.contains(where: { $0.id == id }) else { return }
        let plan = agentProjectRemovalPlan(for: id)

        // Rebind survivors first: if deletion fails partway, no conversation
        // is left pointing at a project that no longer exists.
        for (sessionID, newProjectID) in plan.rebindings {
            guard let index = agentSessions.firstIndex(where: { $0.id == sessionID }) else { continue }
            agentSessions[index].projectID = newProjectID
            if let runtime = agentRuntimes[sessionID] {
                runtime.session.projectID = newProjectID
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            } else {
                AgentSessionStore.save(agentSessions[index])
            }
        }

        for sessionID in plan.deletedSessionIDs {
            deleteAgentSession(id: sessionID)
        }

        agentProjects.removeAll { $0.id == id }
        AgentProjectStore.save(agentProjects)
        rebindAgentSessionsToProjects()
    }

    // MARK: Ownership

    /// Re-resolve and persist project ownership for every session.
    ///
    /// Resolution is stored rather than recomputed at render time so adding
    /// or editing a project cannot retroactively move conversations that
    /// already settled somewhere.
    func rebindAgentSessionsToProjects() {
        let projects = agentProjects
        var changed = false

        for index in agentSessions.indices {
            let session = agentSessions[index]
            let resolved = AgentProjectResolver.projectID(for: session, in: projects)
            guard session.projectID != resolved else { continue }
            agentSessions[index].projectID = resolved
            changed = true
            if let runtime = agentRuntimes[session.id] {
                runtime.session.projectID = resolved
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            } else {
                // The in-memory copy here is usually a metadata skeleton;
                // saving it verbatim is refused by the store's
                // anti-truncation guard, so the binding never reached disk
                // and re-materialized sessions hopped back to path groups.
                AgentSessionStore.updateStoredSessionMetadata(id: session.id) {
                    $0.projectID = resolved
                }
            }
        }

        if changed {
            objectWillChange.send()
        }
    }

    /// Heal sessions whose workspace path is a `project:<uuid>` group key.
    ///
    /// See `AgentWorkspacePathRepairPlan`: 1.234.0-rc18 let the sidebar pass a
    /// group key where a folder path was expected, so "new chat in this group"
    /// anchored the session to `/project:<uuid>`. The sidebar is fixed, but
    /// rc18 is published, so already-created sessions need repairing on load.
    @discardableResult
    func repairAgentSessionsAnchoredToProjectKeys() -> Int {
        var repaired = 0

        for index in agentSessions.indices {
            let session = agentSessions[index]
            let candidate = session.sidebarWorkspaceRootPath
                ?? session.workspaceLocation?.localPath
                ?? session.workspaceRootPath
            let plan = AgentWorkspacePathRepairPlan.plan(
                workspacePath: candidate,
                projects: agentProjects
            )
            guard plan != .notCorrupted else { continue }

            let folder: String?
            switch plan {
            case .repair(let path):
                folder = path
            case .clear:
                folder = nil
            case .notCorrupted:
                continue
            }

            agentSessions[index].workspaceRootPath = folder
            agentSessions[index].workspaceLocation = folder.map { .local(path: $0) }
            let repairSidebarRoot = agentSessions[index].sidebarWorkspaceRootPath.map {
                AgentWorkspacePathRepairPlan.leakedProjectID(in: $0) != nil
            } ?? false
            if repairSidebarRoot {
                agentSessions[index].sidebarWorkspaceRootPath = folder
            }
            repaired += 1

            if let runtime = agentRuntimes[session.id] {
                runtime.session = agentSessions[index]
                persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            } else {
                // Same skeleton-save trap as rebinding: write the repair
                // through the store so the full transcript is materialized
                // and the anti-truncation guard lets it land.
                AgentSessionStore.updateStoredSessionMetadata(id: session.id) {
                    $0.workspaceRootPath = folder
                    $0.workspaceLocation = folder.map { .local(path: $0) }
                    if repairSidebarRoot {
                        $0.sidebarWorkspaceRootPath = folder
                    }
                }
            }
        }

        if repaired > 0 {
            objectWillChange.send()
        }
        return repaired
    }

    /// Remove the project-catalog rows created by the old workspace migration
    /// for Dispatch task worktrees. This deliberately does not remove folders,
    /// Git branches, sessions, or task history.
    @discardableResult
    func repairLeakedDispatchProjects() -> Int {
        let managedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/worktrees", isDirectory: true)
            .standardizedFileURL.path
        let leakedIDs = AgentDispatchProjectLeakRepair.projectIDsToRemove(
            projects: agentProjects,
            sessions: agentSessions,
            managedWorktreeRoot: managedRoot
        )
        guard !leakedIDs.isEmpty else { return 0 }

        agentProjects.removeAll { leakedIDs.contains($0.id) }
        AgentProjectStore.save(agentProjects)
        // Clear the stale projectID from task sessions through the existing
        // metadata-safe path. Their Dispatch ownership fields stay intact.
        rebindAgentSessionsToProjects()
        return leakedIDs.count
    }

    /// Guarantee that `path` is covered by a project, creating one named after
    /// the folder if it is not.
    ///
    /// Picking a folder used to produce a bare workspace group, which is why
    /// "add a workspace" and "add a project" felt like two different things.
    /// Adding a folder now always yields a project; an existing project that
    /// already claims the folder (or a parent of it) is reused rather than
    /// shadowed by a second group for the same tree.
    @discardableResult
    func ensureAgentProject(forFolderPath path: String) -> AgentProject? {
        guard let normalized = AgentProject.normalizedPath(path) else { return nil }
        if let existing = AgentProjectResolver.project(for: normalized, in: agentProjects) {
            return existing
        }
        return createAgentProject(
            displayName: WorkspacePresentation.localDisplayName(path: normalized),
            folderPaths: [normalized]
        )
    }

    /// Promote every remaining bare workspace folder to a named project.
    ///
    /// Workspaces and projects were parallel grouping concepts: a session bound
    /// to a plain folder grouped under that path, while a project grouped one
    /// or more folders under a name. The sidebar therefore listed both kinds of
    /// row side by side, and "upgrading" a workspace appeared to *add* a group
    /// rather than convert one. Projects subsume workspaces, so each surviving
    /// folder becomes a project named after the folder and the folder-keyed
    /// group disappears on the next `rebindAgentSessionsToProjects()`.
    ///
    /// Only local folder groups are promoted. Remote (`remote:…`) and
    /// workspace-less sessions have no folder to name a project after.
    ///
    /// Idempotent — a folder already claimed by a project is skipped — so this
    /// is safe to run on every launch.
    @discardableResult
    func migrateAgentWorkspacesToProjects() -> [AgentProject] {
        var projects = agentProjects
        var created: [AgentProject] = []

        // The candidate list is computed once, so this loop is bounded by the
        // number of sessions. Re-querying until the list emptied would hang
        // forever on any folder the freshly created project fails to claim.
        // The per-iteration re-check below covers the reason that recompute
        // was tempting: two candidates where one is nested under the other.
        for path in AgentWorkspaceProjectMigration.foldersNeedingProject(
            sessions: agentSessions,
            existing: projects
        ) {
            guard AgentProjectResolver.project(for: path, in: projects) == nil else { continue }
            let project = AgentProject(
                displayName: WorkspacePresentation.localDisplayName(path: path),
                folderPaths: [path]
            )
            projects.append(project)
            created.append(project)
        }

        if !created.isEmpty {
            agentProjects = projects
            AgentProjectStore.save(agentProjects)
        }
        // Rebind unconditionally, not only when a project was just created:
        // sessions can be missing their binding even though every folder is
        // already claimed — they may have loaded after the project was made,
        // or were persisted by another AppState instance that never saw the
        // rebind. The early return here left those sessions path-keyed
        // forever, so the sidebar kept a second group with the project's
        // name. Rebinding is idempotent and bounded by sessions × projects.
        rebindAgentSessionsToProjects()
        for project in created {
            activateAgentProjectFolderAccess(projectID: project.id)
        }
        return created
    }

    /// The project owning a sidebar group key, if that key is a project key.
    func agentProject(forSidebarGroupKey key: String) -> AgentProject? {
        guard let id = AgentSession.projectID(fromSidebarGroupKey: key) else { return nil }
        return agentProjects.first { $0.id == id }
    }

    private func activateAgentProjectFolderAccess(projectID: UUID) {
        guard let session = agentSessions.first(where: { $0.projectID == projectID }) else { return }
        let roots = agentWorkspaceRoots(for: session).filter { Self.isExistingDirectory($0) }
        // Adding a folder to a project is the moment to ask about it, and the
        // whole project is one question — a per-folder prompt three times in a
        // row is how a prompt turns into something people click through.
        confirmWorkspaceTrustIfNeeded(forRoots: roots)
        for url in roots {
            _ = activateSecurityScope(for: url)
        }
    }
}

extension AppState {
    /// Confirm and remove, stating both numbers before anything is destroyed.
    ///
    /// The second number is the one the user would not otherwise expect: a
    /// folder shared with another project means some conversations survive.
    /// Hiding that would make "remove project" feel like it deleted more —
    /// or less — than it did.
    @discardableResult
    func confirmAndRemoveAgentProject(id: UUID) -> Bool {
        guard let project = agentProjects.first(where: { $0.id == id }) else { return false }
        let plan = agentProjectRemovalPlan(for: id)

        var lines: [String] = []
        if plan.isNonDestructive {
            lines.append(L10n.AgentProjectStrings.removeNothingToDelete)
        } else {
            lines.append(L10n.AgentProjectStrings.removeDeletesMessage("\(plan.deletedCount)"))
        }
        if plan.rebindingCount > 0 {
            let inheritorName = plan.rebindings.values.first
                .flatMap { inheritorID in agentProjects.first { $0.id == inheritorID } }?
                .resolvedDisplayName ?? ""
            lines.append(
                L10n.AgentProjectStrings.removeKeepsMessage("\(plan.rebindingCount)", inheritorName)
            )
        }

        let alert = NSAlert()
        alert.messageText = L10n.AgentProjectStrings.removeTitle(project.resolvedDisplayName)
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.AgentProjectStrings.removeConfirm)
        alert.addButton(withTitle: L10n.AgentProjectStrings.removeCancel)
        if let confirmButton = alert.buttons.first {
            confirmButton.hasDestructiveAction = !plan.isNonDestructive
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        removeAgentProject(id: id)
        return true
    }
}
