import Foundation

extension AppState {
    /// Fork a conversation into a fresh, independently persisted session.
    /// History and durable context are copied, while live execution state,
    /// plans/goals, pin/archive state, and provider continuation cursors are
    /// deliberately reset so the two conversations cannot mutate each other.
    @discardableResult
    func continueAgentSession(id: AgentSession.ID) -> AgentSession? {
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let source = agentSessions.first(where: { $0.id == id }) else { return nil }
        let continued = AgentSession(
            title: source.title,
            workspaceRootPath: source.workspaceRootPath,
            workspaceLocation: source.workspaceLocation,
            sidebarWorkspaceRootPath: source.sidebarWorkspaceRootPath,
            worktreeRecoveryInfo: source.worktreeRecoveryInfo,
            projectID: source.projectID,
            modelID: source.modelID,
            providerEntryID: source.providerEntryID,
            providerID: source.providerID,
            providerDisplayName: source.providerDisplayName,
            managedRouting: source.managedRouting,
            messages: source.messages,
            contextSummary: source.contextSummary,
            contextSummaryThroughMessageID: source.contextSummaryThroughMessageID,
            interactionMode: .normal,
            approvalMode: source.approvalMode,
            executionAgent: source.executionAgent,
            documentAttachments: source.documentAttachments,
            knowledgeFolders: source.knowledgeFolders,
            documentTaskMode: source.documentTaskMode,
            redactSensitiveAttachmentContent: source.redactSensitiveAttachmentContent,
            titleIsUserSet: source.titleIsUserSet
        )
        agentSessions.insert(continued, at: 0)
        let runtime = AgentRuntime(session: continued)
        seedPersistedSessionModelOverride(for: runtime)
        agentRuntimes[continued.id] = runtime
        activeAgentSessionID = continued.id
        agentPrimaryDestination = .conversation
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        AgentSessionStore.saveAsync(continued)
        upsertAgentUsageSnapshot(for: continued)
        refreshAgentGitWorktrees()
        return continued
    }
}
