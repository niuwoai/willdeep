import Foundation

extension AppState {
    var activeAgentProjects: [AgentProject] { agentProjects.filter { !$0.isArchived } }

    var archivedAgentProjects: [AgentProject] {
        agentProjects.filter(\.isArchived).sorted {
            if $0.archivedAt != $1.archivedAt { return ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func canArchiveAgentProject(_ project: AgentProject) -> Bool {
        guard hasLoadedAgentSessionCatalog else { return false }
        for state in projectArchivingStates {
            if let root = state.rootDirectory?.path, project.contains(path: root) { return false }
            let goals = state.agentDispatchCoordinator.goals.filter { AgentProjectArchiving.belongs($0, to: project) }
            if goals.contains(where: \.isOperationallyActive) { return false }
            let dispatchIDs = Set(goals.map(\.id))
            for session in state.agentSessions where AgentProjectArchiving.belongs(session, to: project)
                || session.dispatchParentProjectID.map(dispatchIDs.contains) == true {
                if state.sessionManagementProtectionReason(session, protectDedicatedWorkflows: false) != nil { return false }
            }
        }
        return true
    }

    private var projectArchivingStates: [AppState] {
        let peers = EditorAppStateRegistry.shared.appStatesForTerminationCheck.filter { $0 !== self }
        return [self] + peers
    }

    /// Only the project catalog changes. Individual chat archive markers,
    /// transcripts, folder trust, and source files remain intact.
    @discardableResult
    func setAgentProjectArchived(id: UUID, archived: Bool, now: Date = Date()) -> Bool {
        guard let index = agentProjects.firstIndex(where: { $0.id == id }) else { return false }
        guard agentProjects[index].isArchived != archived else { return true }
        if archived && !canArchiveAgentProject(agentProjects[index]) { return false }
        var projects = agentProjects
        projects[index].archivedAt = archived ? now : nil
        if !archived { projects[index].lastActivityAt = now }
        guard saveProjectArchivingCatalog(projects[index]) else { return false }
        if !archived {
            unhideWorkspace(key: AgentSession.projectSidebarGroupKeyPrefix + id.uuidString)
        }
        return true
    }

    @discardableResult
    func recordAgentProjectActivity(id: UUID?, now: Date = Date()) -> Bool {
        guard let id, let index = agentProjects.firstIndex(where: { $0.id == id }) else { return true }
        var projects = agentProjects
        projects[index].lastActivityAt = now
        projects[index].archivedAt = nil
        return saveProjectArchivingCatalog(projects[index])
    }

    private func saveProjectArchivingCatalog(_ project: AgentProject) -> Bool {
        guard let projects = projectArchivingCatalogUpdater(project) else {
            projectArchivingSaveFailed = true
            return false
        }
        projectArchivingSaveFailed = false
        agentProjects = projects
        for state in projectArchivingStates where state !== self {
            let changed = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            state.agentProjects = state.agentProjects.map { changed[$0.id] ?? $0 }
        }
        return true
    }

    func archiveInactiveAgentProjects(now: Date = Date()) {
        guard hasLoadedAgentSessionCatalog,
              AgentProjectArchiving.isEnabled(defaults: sessionManagementDefaults) else { return }
        let protected = Set(agentProjects.filter { !canArchiveAgentProject($0) }.map(\.id))
        let sessions = projectArchivingStates.flatMap(\.agentSessions)
        let ids = AgentProjectArchiving.candidates(projects: agentProjects, sessions: sessions,
                                                   protectedIDs: protected, now: now)
        for id in ids {
            // Keep the first persistence failure visible and retry on the
            // next maintenance pass instead of overwriting it with success.
            guard setAgentProjectArchived(id: id, archived: true, now: now) else { break }
        }
    }
}
