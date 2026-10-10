import Foundation

nonisolated enum AgentProjectArchiving {
    static let enabledKey = "com.willdeep.agentSettings.projectAutoArchive.v1"
    static let inactiveDays = 30
    static let inactivityInterval: TimeInterval = TimeInterval(inactiveDays * 24 * 60 * 60)

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func lastActivity(of project: AgentProject, sessions: [AgentSession]) -> Date {
        let sessionActivity = sessions.filter { belongs($0, to: project) }.map {
            max($0.updatedAt, $0.lastActivityAt, $0.messages.last?.createdAt ?? .distantPast)
        }.max()
        return [project.createdAt, project.updatedAt, project.lastActivityAt, sessionActivity]
            .compactMap { $0 }.max() ?? project.createdAt
    }

    static func belongs(_ session: AgentSession, to project: AgentProject) -> Bool {
        if case .remote? = session.workspaceLocation { return false }
        return session.projectID == project.id
            || (session.projectID == nil && AgentProjectRemoval.sessionPath(session).map(project.contains) == true)
    }

    static func belongs(_ goal: AgentDispatchGoal, to project: AgentProject) -> Bool {
        if let owner = goal.logicalProject?.managedProjectID { return owner == project.id }
        if case .remote? = goal.workspaceLocation { return false }
        let path = goal.logicalProject?.primaryWorkspacePath ?? goal.workspaceLocation?.localPath
        return path.map(project.contains) == true
    }

    static func candidates(projects: [AgentProject], sessions: [AgentSession],
                           protectedIDs: Set<UUID>, now: Date) -> [UUID] {
        let cutoff = now.addingTimeInterval(-inactivityInterval)
        return projects.filter {
            !$0.isArchived && !$0.isPinned && !protectedIDs.contains($0.id)
                && lastActivity(of: $0, sessions: sessions) < cutoff
        }.map(\.id)
    }

    static func visibleSessions(_ sessions: [AgentSession], projects: [AgentProject]) -> [AgentSession] {
        let archived = projects.filter(\.isArchived)
        return sessions.filter { session in !archived.contains { belongs(session, to: $0) } }
    }
}
