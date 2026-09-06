import Foundation

extension AppState {
    private var sessionManagementPeers: [AppState] {
        EditorAppStateRegistry.shared.appStatesForTerminationCheck.filter { $0 !== self }
    }

    func sessionManagementProtectionReason(_ session: AgentSession, callerID: UUID? = nil) -> String? {
        if let reason = localSessionManagementProtectionReason(session, callerID: callerID) { return reason }
        for peer in sessionManagementPeers {
            if let other = peer.agentSessions.first(where: { $0.id == session.id }),
               peer.localSessionManagementProtectionReason(other, callerID: callerID) != nil {
                return "protected_in_another_window"
            }
        }
        return nil
    }

    private func localSessionManagementProtectionReason(_ session: AgentSession, callerID: UUID?) -> String? {
        if session.id == callerID || session.id == activeAgentSessionID { return "active_session" }
        if session.isPinned { return "pinned" }
        if session.presentationScope != .workspace { return "dedicated_workflow" }
        if session.lastTurnFailure != nil || session.goalTurnRecoveryCheckpoint != nil { return "awaiting_attention" }
        if pendingDispatchQueue.contains(where: { $0.runtimeID == session.id }) { return "queued_dispatch" }
        if !agentJobRegistry.aliveJobs(forRuntime: session.id).isEmpty
            || agentJobRegistry.pendingCompletionCount(forRuntime: session.id) > 0
            || agentSubagentRegistry.activeCount(forParentRuntime: session.id) > 0
            || agentSubagentRegistry.pendingReportCount(forParentRuntime: session.id) > 0
            || agentMediaTaskRegistry.tasks.contains(where: { $0.runtimeID == session.id && $0.isActive })
            || agentMediaTaskRegistry.hasOutstandingCompletion(forRuntime: session.id)
            || agentMediaTaskRegistry.pendingCompletionCount(forRuntime: session.id) > 0 { return "background_work" }
        if let runtime = agentRuntimes[session.id] {
            if runtime.isResponding || runtime.requestTask != nil || runtime.isAwaitingProviderSlot
                || !runtime.queuedMessages.isEmpty || !runtime.workflowTasks.isEmpty { return "running_or_queued" }
            if runtime.toolDecisionWaiter != nil || !runtime.pendingToolDecisions.isEmpty
                || hasPendingBackgroundWakeups(for: runtime) { return "awaiting_attention" }
            if !runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !runtime.pendingImages.isEmpty || !runtime.pendingTextAttachments.isEmpty
                || !runtime.pendingFiles.isEmpty || !runtime.pendingSkills.isEmpty { return "unsent_draft" }
        }
        return nil
    }

    func handleSessionManagement(_ request: AgentSessionManagementRequest, callerID: UUID?) async throws -> AgentToolResult {
        guard hasLoadedAgentSessionCatalog else {
            throw AgentToolError.invalidArgument("Session catalog is still loading; retry shortly")
        }
        switch request {
        case .projects(let offset, let limit):
            let projects = agentProjects.sorted { $0.id.uuidString < $1.id.uuidString }
            let rows: [[String: Any]] = projects.dropFirst(offset).prefix(limit).map { project in
                let sessions = agentSessions.filter { $0.projectID == project.id && $0.presentationScope == .workspace }
                return ["id": project.id.uuidString, "name": project.resolvedDisplayName,
                        "folder_paths": project.folderPaths, "session_count": sessions.count,
                        "active_session_count": sessions.filter { !$0.isArchived }.count,
                        "archived_session_count": sessions.filter(\.isArchived).count]
            }
            return try sessionManagementPage(key: "projects", rows: rows, total: projects.count, offset: offset)
        case .sessions(let projectID, let includeArchived, let offset, let limit):
            guard agentProjects.contains(where: { $0.id == projectID }) else {
                throw AgentToolError.invalidArgument("Unknown project_id; list_projects again")
            }
            let sessions = agentSessions.filter {
                $0.projectID == projectID && $0.presentationScope == .workspace && (includeArchived || !$0.isArchived)
            }.sorted(by: AgentSessionRetentionPolicy.newestFirst)
            let rows = sessions.dropFirst(offset).prefix(limit).map { sessionManagementRow($0, callerID: callerID) }
            return try sessionManagementPage(key: "sessions", rows: rows, total: sessions.count, offset: offset)
        case .manage(let ids, let action, let dryRun):
            // Resolve the complete target set before allowing the first write.
            let knownIDs = Set(agentSessions.map(\.id))
            guard ids.allSatisfy(knownIDs.contains) else {
                throw AgentToolError.invalidArgument("Some session IDs no longer exist. No changes made; list sessions again")
            }
            var outcomes: [[String: Any]] = []
            for id in ids {
                try Task.checkCancellation()
                outcomes.append(await manageSession(id: id, action: action, dryRun: dryRun, callerID: callerID))
            }
            if !dryRun { await Task.detached { AgentSessionStore.flushPendingWrites() }.value }
            return try sessionManagementResult([
                "dry_run": dryRun, "action": action.rawValue, "outcomes": outcomes,
                "deletion_is_permanent": action == .delete
            ], summary: "\(dryRun ? "Preview" : "Processed") \(outcomes.count) sessions")
        }
    }

    private func sessionManagementRow(_ session: AgentSession, callerID: UUID?) -> [String: Any] {
        ["id": session.id.uuidString, "title": session.title,
         "project_id": session.projectID?.uuidString ?? "",
         "updated_at": ISO8601DateFormatter().string(from: session.updatedAt),
         "is_archived": session.isArchived, "is_pinned": session.isPinned,
         "protection_reason": sessionManagementProtectionReason(session, callerID: callerID) as Any? ?? NSNull()]
    }

    private func sessionManagementPage(key: String, rows: [[String: Any]], total: Int, offset: Int) throws -> AgentToolResult {
        try sessionManagementResult([
            key: rows, "total": total, "offset": offset,
            "next_offset": offset < total && rows.count < total - offset ? (offset + rows.count) as Any : NSNull()
        ], summary: "\(rows.count) \(key) (total \(total))")
    }

    private func sessionManagementResult(_ payload: [String: Any], summary: String) throws -> AgentToolResult {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        return AgentToolResult(summary: summary, payload: String(decoding: data, as: UTF8.self))
    }

    /// Load only the target, off the main thread. If its catalog entry changed
    /// during IO, leave it alone rather than replacing fresher metadata.
    private func materializeManagedSession(id: UUID) async -> Bool {
        guard agentSessionIsMetadataOnly(id) else { return agentSessions.contains { $0.id == id } }
        guard let before = agentSessions.first(where: { $0.id == id }) else { return false }
        let stored = await Task.detached(priority: .utility) { AgentSessionStore.load(id: id) }.value
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return false }
        if !agentSessionIsMetadataOnly(id) { return true }
        guard agentSessions[index] == before, let stored else { return false }
        agentSessions[index] = stored
        clearAgentSessionMetadataOnlyFlag(id)
        return true
    }

    private func manageSession(
        id: UUID, action: AgentSessionManagementAction, dryRun: Bool, callerID: UUID?, automatic: Bool = false
    ) async -> [String: Any] {
        var result: [String: Any] = ["id": id.uuidString]
        if !dryRun, !(await materializeManagedSession(id: id)) {
            result["status"] = "skipped"; result["reason"] = "load_failed_or_changed"
            return result
        }
        guard let session = agentSessions.first(where: { $0.id == id }) else {
            result["status"] = "skipped"; result["reason"] = "no_longer_exists"
            return result
        }
        result["title"] = session.title
        if action != .unarchive, let reason = sessionManagementProtectionReason(session, callerID: callerID) {
            result["status"] = "skipped"; result["reason"] = reason
        } else if session.presentationScope != .workspace {
            result["status"] = "skipped"; result["reason"] = "dedicated_workflow"
        } else if automatic && (!AgentSessionRetentionSettings.load(defaults: sessionManagementDefaults).enabled || !automaticArchiveCandidates().contains(id)) {
            result["status"] = "skipped"; result["reason"] = "retention_policy_changed"
        } else if (action == .archive && session.isArchived) || (action == .unarchive && !session.isArchived) {
            result["status"] = "unchanged"
        } else if dryRun {
            result["status"] = "would_\(action.rawValue)"
        } else if Task.isCancelled {
            result["status"] = "skipped"; result["reason"] = "cancelled"
        } else {
            if action == .delete {
                guard deleteAgentSession(id: id) else {
                    result["status"] = "failed"; result["reason"] = "delete_failed"
                    return result
                }
                for peer in sessionManagementPeers where peer.agentSessions.contains(where: { $0.id == id }) {
                    peer.deleteAgentSession(id: id, removeFromStore: false)
                }
            } else {
                toggleAgentSessionArchived(id: id)
                let expected = agentSessions.first(where: { $0.id == id })?.archivedAt
                let stored = await Task.detached(priority: .utility) {
                    AgentSessionStore.flushPendingWrites()
                    return AgentSessionStore.load(id: id)
                }.value
                // The store uses ISO-8601 at second precision; compare the
                // persisted state, not a freshly-created subsecond Date.
                guard let stored, stored.isArchived == (action == .archive) else {
                    // Restore just this marker if no newer UI action changed it.
                    if let index = agentSessions.firstIndex(where: { $0.id == id }),
                       agentSessions[index].archivedAt == expected {
                        agentSessions[index].archivedAt = session.archivedAt
                        agentRuntimes[id]?.session.archivedAt = session.archivedAt
                        upsertAgentUsageSnapshot(for: agentSessions[index])
                    }
                    result["status"] = "failed"; result["reason"] = "archive_persistence_failed_or_changed"
                    return result
                }
                for peer in sessionManagementPeers {
                    if let index = peer.agentSessions.firstIndex(where: { $0.id == id }) {
                        peer.agentSessions[index].archivedAt = expected
                        peer.agentRuntimes[id]?.session.archivedAt = expected
                    }
                }
            }
            result["status"] = action == .delete ? "deleted" : action == .archive ? "archived" : "unarchived"
        }
        return result
    }

    func automaticArchiveCandidates() -> [UUID] {
        let protectedIDs = Set(agentSessions.filter { sessionManagementProtectionReason($0) != nil }.map(\.id))
        return AgentSessionRetentionPolicy.candidates(
            sessions: agentSessions, projectIDs: Set(agentProjects.map(\.id)),
            keepCount: AgentSessionRetentionSettings.load(defaults: sessionManagementDefaults).keepCount, protectedIDs: protectedIDs
        )
    }

    func requestAutomaticSessionArchiving() {
        let saved = AgentSessionRetentionSettings.load(defaults: sessionManagementDefaults)
        if saved != sessionRetentionSettings {
            sessionRetentionSettings = saved
            return
        }
        guard hasLoadedAgentSessionCatalog, sessionRetentionSettings.enabled, sessionAutoArchiveTask == nil else { return }
        sessionAutoArchiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.sessionAutoArchiveRunning = true
            defer { self.sessionAutoArchiveTask = nil; self.sessionAutoArchiveRunning = false }
            var count = 0
            var failed = 0
            for id in self.automaticArchiveCandidates() {
                guard !Task.isCancelled, AgentSessionRetentionSettings.load(defaults: self.sessionManagementDefaults).enabled else { break }
                let result = await self.manageSession(id: id, action: .archive, dryRun: false, callerID: nil, automatic: true)
                if result["status"] as? String == "archived" { count += 1 }
                if result["reason"] as? String == "load_failed_or_changed" || result["status"] as? String == "failed" { failed += 1 }
                await Task.yield()
            }
            await Task.detached { AgentSessionStore.flushPendingWrites() }.value
            self.sessionAutoArchiveLastCount = count
            self.sessionAutoArchiveFailedCount = failed
        }
    }

    // MARK: - Abandoned empty-session sweep

    /// How long an empty, workspace-less placeholder must sit untouched before
    /// the launch sweep will remove it. Generous on purpose: the only cost of
    /// waiting is a few stale files, while the cost of being too eager is
    /// deleting a session someone is still using from another process.
    static let abandonedEmptySessionGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Placeholders the launch sweep may remove: no user message, no workspace
    /// binding of any kind, no project, not pinned or archived, ordinary
    /// workspace scope, untouched for `abandonedEmptySessionGracePeriod`, and
    /// not protected by any window's live state.
    ///
    /// These rows are invisible: `AgentSidebarVisibility.visibleSessions` hides
    /// them and chat search skips them, so the user cannot open or delete them
    /// by hand — which is exactly why they need sweeping rather than a button.
    ///
    /// Retention settings do not cover them either: that policy groups by
    /// `projectID`, and every session here has none.
    func abandonedEmptySessionCandidates(now: Date = Date()) -> [AgentSession.ID] {
        let cutoff = now.addingTimeInterval(-Self.abandonedEmptySessionGracePeriod)
        let orchestratorSessionID = AgentRuntimeEventSettingsStore.load().orchestratorSessionID
        return agentSessions.filter { session in
            guard session.updatedAt < cutoff,
                  session.id != orchestratorSessionID,
                  session.projectID == nil,
                  session.workspaceRootPath == nil,
                  session.workspaceLocation == nil,
                  session.presentationScope == .workspace,
                  !session.isPinned,
                  !session.isArchived,
                  agentRuntimes[session.id] == nil
            else { return false }
            // A catalog skeleton always has empty `messages`, so asking the
            // session value directly would call every unmaterialized row empty.
            // The launch scan's per-id answer is the only correct source.
            //
            // This is the loose half of the predicate: it only knows about USER
            // messages, so a session holding just a `workflowReport` row still
            // reaches the disk gate — which rejects it, because that gate
            // requires no messages of any role. Erring loose here costs one
            // futile file read; erring loose there would delete real output.
            let hasUserMessage = agentSessionIsMetadataOnly(session.id)
                ? agentSessionMetadataOnlyHasUserMessage(session.id)
                : session.messages.contains { $0.role == .user }
            guard !hasUserMessage else { return false }
            // Covers active/pinned/scope again plus everything only the live
            // state knows: in-flight turns, queued dispatches, background jobs,
            // unsent composer drafts — in this window and in every other one.
            return sessionManagementProtectionReason(session) == nil
        }.map(\.id)
    }

    /// Remove abandoned placeholders left by builds that persisted every new
    /// chat at creation. Runs once per launch, after the catalog lands.
    ///
    /// Deleting is delegated to `deleteIfStillEmptyAndUnattached`, which
    /// re-reads each file under coordination and refuses anything it cannot
    /// decode. Nothing decided here is trusted at the point of deletion.
    func sweepAbandonedEmptySessions(now: Date = Date()) async {
        let candidates = abandonedEmptySessionCandidates(now: now)
        guard !candidates.isEmpty else { return }
        let protectedSessionIDs = Set(
            [AgentRuntimeEventSettingsStore.load().orchestratorSessionID].compactMap { $0 }
        )
        let removed = await Task.detached(priority: .utility) {
            candidates.filter {
                AgentSessionStore.deleteIfStillEmptyAndUnattached(
                    id: $0,
                    protectedSessionIDs: protectedSessionIDs
                )
            }
        }.value
        // The sweep ran off-main; re-check before dropping rows so a session
        // that came alive in between keeps its (now file-less) in-memory row
        // rather than vanishing from under an open window.
        let dropped = Set(removed.filter { activeAgentSessionID != $0 && agentRuntimes[$0] == nil })
        guard !dropped.isEmpty else { return }
        agentSessions.removeAll { dropped.contains($0.id) }
        agentUsageSnapshots.removeAll { dropped.contains($0.id) }
        // Other windows hold their own copy of the same catalog; leaving the
        // rows there would let one of them persist a deleted id back to disk.
        for peer in sessionManagementPeers {
            peer.agentSessions.removeAll { dropped.contains($0.id) }
            peer.agentUsageSnapshots.removeAll { dropped.contains($0.id) }
        }
        sweptAbandonedEmptySessionCount = dropped.count
    }
}
