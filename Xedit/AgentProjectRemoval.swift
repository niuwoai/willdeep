//
//  AgentProjectRemoval.swift
//  WillDeep
//
//  Deciding what happens to conversations when a project is removed.
//
//  Removing a project deletes its conversations — that was the explicit
//  product decision. But a folder may belong to several projects, and those
//  two rules together would let removing project A destroy history that
//  project B still shows, with no undo and no warning that B was involved.
//
//  So deletion is limited to conversations *exclusive* to the removed
//  project. Anything whose folder is still claimed elsewhere is rebound to
//  that other project instead. The plan is computed up front, as data, so
//  the confirmation dialog can state both numbers before anything is
//  destroyed — and so this rule is testable without deleting real files.
//

import Foundation

nonisolated struct AgentProjectRemovalPlan: Equatable {
    /// Conversations that belong only to the project being removed.
    let deletedSessionIDs: [UUID]
    /// Conversations kept because another project also claims their folder,
    /// mapped to the project they move to.
    let rebindings: [UUID: UUID]

    var deletedCount: Int { deletedSessionIDs.count }
    var rebindingCount: Int { rebindings.count }

    /// True when nothing is destroyed, so the caller can skip the
    /// destructive confirmation entirely.
    var isNonDestructive: Bool { deletedSessionIDs.isEmpty }

    static let empty = AgentProjectRemovalPlan(deletedSessionIDs: [], rebindings: [:])
}

nonisolated enum AgentProjectRemoval {
    /// What removing `project` would do.
    ///
    /// `projects` must still contain `project`; it is excluded internally so
    /// the "is this folder claimed elsewhere" test cannot match itself.
    static func plan(
        removing project: AgentProject,
        projects: [AgentProject],
        sessions: [AgentSession]
    ) -> AgentProjectRemovalPlan {
        let survivors = projects.filter { $0.id != project.id }
        var deleted: [UUID] = []
        var rebindings: [UUID: UUID] = [:]

        for session in sessions where session.projectID == project.id {
            let path = sessionPath(session)
            // Resolve among the remaining projects using the same rule new
            // sessions use, so a rebound conversation lands where it would
            // have landed had the removed project never existed.
            if let inheritor = AgentProjectResolver.project(for: path, in: survivors) {
                rebindings[session.id] = inheritor.id
            } else {
                deleted.append(session.id)
            }
        }

        return AgentProjectRemovalPlan(deletedSessionIDs: deleted, rebindings: rebindings)
    }

    /// The local path a session is grouped by. Remote workspaces have no
    /// local folder to compare against, so they never match a project folder
    /// and fall through to deletion only if they were explicitly bound.
    static func sessionPath(_ session: AgentSession) -> String? {
        if let sidebarRoot = session.sidebarWorkspaceRootPath,
           !sidebarRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sidebarRoot
        }
        if case .local(let path)? = session.workspaceLocation {
            return path
        }
        return session.workspaceRootPath
    }
}
