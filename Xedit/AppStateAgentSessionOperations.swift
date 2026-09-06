//
//  AppStateAgentSessionOperations.swift
//  WillDeep
//
//  会话本身的操作：置顶 / 归档 / 重命名 / 工作区快照 / 落盘。
//
//  与 AppStateAgentRoutines.swift 同一次拆分。原文件那段 `// MARK: - Routines`
//  其实混着三簇互不相干的代码——例行任务、会话操作、模型选择——这也是它
//  长到 3189 行还没人察觉的原因之一。这一刀按真实边界切，不按那条已经名不
//  副实的 MARK 注释切。
//

import AppKit
import Foundation

extension AppState {
    /// Toggle pin state. Pinned sessions move into the global pinned section
    /// above every workspace, sorted by `pinnedAt` (most recently pinned
    /// first). The timestamp doubles as both the on/off flag and the ordering
    /// key, so re-pinning sends the row back to the top.
    func toggleAgentSessionPinned(id: AgentSession.ID) {
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].pinnedAt = agentSessions[index].pinnedAt == nil ? Date() : nil
        // Mirror onto the live runtime's session copy (rename already
        // does) — otherwise the runtime's next persist() writes its own
        // stale copy back and silently un-pins the row.
        if let runtime = agentRuntimes[id] {
            runtime.session.pinnedAt = agentSessions[index].pinnedAt
        }
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    /// Toggle archive state. Archived sessions disappear from the main
    /// workspace list and instead live under a collapsed "已归档" row
    /// at the bottom of each workspace group. Unarchiving puts them
    /// back into the active set with their original `updatedAt` intact
    /// so they sort back into their natural recency position.
    func toggleAgentSessionArchived(id: AgentSession.ID) {
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        let willArchive = agentSessions[index].archivedAt == nil
        agentSessions[index].archivedAt = willArchive ? Date() : nil
        // Mirror onto the live runtime's session copy (rename already
        // does) — otherwise the runtime's next persist() writes its own
        // stale copy back and silently un-archives the row.
        if let runtime = agentRuntimes[id] {
            runtime.session.archivedAt = agentSessions[index].archivedAt
        }
        if willArchive {
            // Runtime-event journals may contain mail, webhook, terminal, or
            // worker payloads. Archiving is the retention boundary: discard
            // those payloads immediately instead of waiting for relaunch.
            agentRuntimeKernel.removeEvents(for: id)
            agentExternalWakeRetryTasks.removeValue(forKey: id)?.cancel()
            agentKernelPreemptedRuntimeIDs.remove(id)
        }
        // Archiving the currently-active session shouldn't kick the
        // user out — the chat stays selected. They can pick another
        // session whenever they want; in the meantime the row simply
        // vanishes from the visible list, which is exactly what every
        // other chat app (Cursor, Slack, Linear) does.
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    /// Rename a session to a user-provided title. Sets `titleIsUserSet`
    /// so neither the per-persist deriveTitle nor the LLM summarizer
    /// will overwrite it later. Empty/whitespace-only input is treated
    /// as "cancel" (no-op) — clearing a session title to "" would just
    /// confuse the sidebar.
    func renameAgentSession(id: AgentSession.ID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].title = trimmed
        agentSessions[index].titleIsUserSet = true
        if let runtime = agentRuntimes[id] {
            runtime.session.title = trimmed
            runtime.session.titleIsUserSet = true
        }
        // Async: rename must not stall the main thread behind a backlog
        // of large session writes (the caller discards the result anyway).
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    func renameAgentSessionFromTool(
        runtimeID: AgentSession.ID,
        to newTitle: String
    ) throws -> String {
        guard agentRuntimes[runtimeID] != nil else {
            throw AgentToolError.invalidArgument("the originating session is no longer available")
        }
        renameAgentSession(id: runtimeID, to: newTitle)
        guard let title = agentSessions.first(where: { $0.id == runtimeID })?.title else {
            throw AgentToolError.invalidArgument("the originating session could not be renamed")
        }
        return title
    }

    /// Manually request an LLM title summary for a session. Bypasses
    /// the "only on first assistant turn" gate so the user can refresh
    /// the title at any point. Clears `titleIsUserSet` so the
    /// summarizer is allowed to run, then defers to the shared
    /// summarizer path; the summarizer itself re-sets the flag on
    /// success.
    func manuallySummarizeAgentSessionTitle(id: AgentSession.ID) {
        guard let runtime = agentRuntimes[id] else { return }
        // Temporarily unlock so the summarizer doesn't bail at rule (1).
        runtime.session.titleIsUserSet = false
        if let index = agentSessions.firstIndex(where: { $0.id == id }) {
            agentSessions[index].titleIsUserSet = false
        }
        summarizeAgentSessionTitleIfNeeded(runtime: runtime, force: true)
    }

    func workspaceSessionSnapshots(for runtime: AgentRuntime) -> [AgentWorkspaceSessionSnapshot] {
        let workspaceKey = runtime.session.workspaceSidebarGroupKey
        return agentSessions
            .filter { $0.workspaceSidebarGroupKey == workspaceKey }
            .map { session in
                let live = agentRuntimes[session.id]
                let source = live?.session ?? session
                let goal = live?.currentGoal ?? source.currentGoal
                let completedGoalItems = goal?.checklist.filter(\.done).count ?? 0
                let totalGoalItems = goal?.checklist.count ?? 0
                let dispatchProject = agentDispatchCoordinator.goals.first {
                    $0.sessionID == source.id
                }
                return AgentWorkspaceSessionSnapshot(
                    id: source.id,
                    title: source.title,
                    workspaceRootPath: source.workspaceLocation?.localPath ?? source.workspaceRootPath,
                    workspaceDisplayName: source.workspaceName,
                    presentationScope: source.presentationScope,
                    isActive: source.id == runtime.id,
                    isPinned: source.isPinned,
                    isArchived: source.isArchived,
                    isResponding: live?.isResponding ?? false,
                    isAwaitingProviderSlot: live?.isAwaitingProviderSlot ?? false,
                    queuedMessageCount: live?.queuedMessages.count ?? 0,
                    updatedAt: source.updatedAt,
                    lastActivityAt: source.lastActivityAt,
                    interactionMode: live?.interactionMode ?? source.interactionMode,
                    approvalMode: live?.approvalMode ?? source.approvalMode,
                    executionAgent: live?.executionAgent ?? source.executionAgent,
                    titleIsUserSet: source.titleIsUserSet,
                    goalStatement: goal?.statement,
                    goalCompletedItemCount: completedGoalItems,
                    goalTotalItemCount: totalGoalItems,
                    goalIsComplete: totalGoalItems > 0 && completedGoalItems == totalGoalItems,
                    goalPlanningPhase: live?.goalPlanningState?.phase
                        ?? source.goalPlanningState?.phase,
                    dispatchParentProjectID: source.dispatchParentProjectID,
                    dispatchTaskID: source.dispatchTaskID,
                    isDispatchProject: source.presentationScope == .dispatchBoard
                        && source.dispatchParentProjectID == nil
                        && goal != nil,
                    isDispatchPaused: dispatchProject?.isPaused ?? false
                )
            }
    }

    /// Write the active session back to disk. No-op if no session is
    /// active (Editor-mode chats aren't persisted). Convenience wrapper
    /// that targets `activeRuntime`; concurrent code paths that need to
    /// persist a specific (potentially background) runtime should call
    /// `persistAgentSession(runtime:)` directly.
    func persistActiveAgentSession() {
        guard let runtime = activeRuntime else { return }
        persistAgentSession(runtime: runtime)
    }

    /// Persist a specific runtime's session. Used by the turn loop's
    /// defer so background runtimes that finish while the user is on a
    /// different session still write their final state to disk.
    func persistAgentSession(
        runtime: AgentRuntime,
        touchUpdatedAt: Bool = true,
        moveToFront: Bool = true
    ) {
        guard let index = agentSessions.firstIndex(where: { $0.id == runtime.id }) else { return }
        synchronizeApprovalKernelEvents(for: runtime)
        if runtime.managedRouting != nil {
            // Managed routing resolves a model per-turn; there is no single
            // session model. Keep modelID clear so nothing downstream mistakes
            // a route-default snapshot for an explicit user choice.
            runtime.session.modelID = nil
        } else if let override = runtime.sessionModelOverride, !override.isEmpty {
            runtime.session.modelID = override
        } else {
            runtime.session.modelID = configurationForCurrentTurn(for: runtime)
                .model(for: .interactive)
        }
        let sessionProvider = providerEntry(for: runtime)
        runtime.session.providerEntryID = runtime.sessionProviderEntryID ?? sessionProvider?.id
        runtime.session.providerID = runtime.sessionProviderIDOverride
            ?? sessionProvider?.providerID
            ?? runtime.session.providerID
            ?? agentConfiguration.normalized.providerID
        runtime.session.providerDisplayName = AgentProviderPreset.normalizedDisplayName(
            providerID: runtime.session.providerID,
            storedDisplayName: sessionProvider?.displayName ?? runtime.session.providerDisplayName
        )
        runtime.persist(touchUpdatedAt: touchUpdatedAt)
        agentSessions[index] = runtime.session
        clearAgentSessionMetadataOnlyFlag(runtime.id)
        // `persist()` just stamped `updatedAt = now`, so this session is
        // the newest — a single move-to-front keeps the list sorted.
        // The previous full `sort` here ran on EVERY persist (several
        // times per turn, for every concurrent runtime), re-comparing
        // hundreds of already-ordered sessions each time; and because
        // `agentSessions` is @Published, the wholesale reorder also
        // invalidated the sidebar more than needed.
        if moveToFront, index > 0 {
            let updated = agentSessions.remove(at: index)
            agentSessions.insert(updated, at: 0)
        }
        upsertAgentUsageSnapshot(for: runtime.session)
        if !runtime.isResponding && !runtime.isAwaitingProviderSlot && !runtime.isCompressingContext {
            scheduleDispatchDecisionResumption()
        }

        // After every persist, give the LLM summarizer a chance to
        // upgrade the auto-derived first-message-prefix title to a
        // polished one. The method is no-op-cheap on hot paths
        // (returns immediately when there's no first user→assistant
        // exchange yet, or the title is already locked, or a request
        // is in flight), so it's safe to fire unconditionally here.
        summarizeAgentSessionTitleIfNeeded(runtime: runtime)
    }
}
