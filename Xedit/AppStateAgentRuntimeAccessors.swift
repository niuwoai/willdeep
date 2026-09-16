//
//  AppStateAgentRuntimeAccessors.swift
//  WillDeep
//
//  Compatibility accessors that delegate legacy AppState agent fields
//  to the active per-session AgentRuntime.
//

import Foundation

extension AppState {
    // MARK: - Per-session state (rc2: delegated to activeRuntime)
    //
    // These fields used to be `@Published` stored properties on AppState.
    // rc2 moved the data onto `AgentRuntime` (one runtime per session) and
    // kept the AppState-side names as get/set delegates so existing UI and
    // AppState companion files can continue reading `appState.agentMessages`
    // and friends without knowing where the storage lives.

    var activeRuntime: AgentRuntime? {
        guard let id = activeAgentSessionID else { return nil }
        return loadedRuntime(for: id)
    }

    /// Side-effect-free lookup for rendering and snapshot paths.
    ///
    /// Unlike `runtime(for:)`, this accessor never materializes a persisted
    /// session, starts watchers, applies pending proposals, or evicts another
    /// runtime. SwiftUI `body` evaluation must use this read-only path so a
    /// render pass cannot publish new state and recursively invalidate itself.
    func loadedRuntime(for sessionID: AgentSession.ID) -> AgentRuntime? {
        agentRuntimes[sessionID]
    }

    var agentMessages: [AgentMessage] {
        get { activeRuntime?.messages ?? [] }
        set { activeRuntime?.messages = newValue }
    }

    var agentPatchProposals: [AgentPatchProposal] {
        get { activeRuntime?.patchProposals ?? [] }
        set { activeRuntime?.patchProposals = newValue }
    }

    var agentToolCalls: [AgentToolCall] {
        get { activeRuntime?.toolCalls ?? [] }
        set { activeRuntime?.toolCalls = newValue }
    }

    var agentInput: String {
        get { activeRuntime?.input ?? "" }
        set {
            if let runtime = activeRuntime {
                runtime.input = newValue
            } else if !newValue.isEmpty {
                // No active session yet (standalone Agent window, just after
                // deleting the current session, or a cold start that never
                // selected one) but the user is typing. Without a runtime this
                // setter is a no-op: the keystrokes only live in the local
                // NSTextView, so `sendAgentMessage` reads an empty input and
                // the empty-message guard silently returns — the bug where
                // sending "does nothing" with no workspace selected. Lazily
                // create a session so the text always has a real runtime to
                // land in. (A session with no workspace is valid — its
                // workspaceLocation is just nil.) Empty writes (binding init /
                // post-send clear) are ignored so we never spawn a phantom
                // session.
                activeRuntimeAfterCreatingNewSession()?.input = newValue
            }
        }
    }

    var isAgentResponding: Bool {
        get { activeRuntime?.isResponding ?? false }
        set { activeRuntime?.isResponding = newValue }
    }

    /// Wall-clock moment the current turn started; the thinking banner
    /// reads this through a `TimelineView` so elapsed seconds tick while
    /// the model is still working.
    var agentTurnStartedAt: Date? {
        get { activeRuntime?.turnStartedAt }
        set { activeRuntime?.turnStartedAt = newValue }
    }

    var agentErrorMessage: String? {
        get { activeRuntime?.errorMessage }
        set { activeRuntime?.errorMessage = newValue }
    }

    var agentErrorDetails: AgentErrorDetails? {
        get { activeRuntime?.errorDetails }
        set { activeRuntime?.errorDetails = newValue }
    }

    /// Presentation weight of the current banner. Defaults to `.error` so any
    /// path that sets `agentErrorMessage` without an opinion keeps the old
    /// red treatment.
    var agentErrorSeverity: AgentBannerSeverity {
        get { activeRuntime?.errorSeverity ?? .error }
        set { activeRuntime?.errorSeverity = newValue }
    }

    /// Whether the current error banner is the some.im login gate — lets the
    /// error card offer a "去登录 some.im" button instead of the generic retry.
    var agentErrorRequiresSomeIMLogin: Bool {
        get { activeRuntime?.errorRequiresSomeIMLogin ?? false }
        set { activeRuntime?.errorRequiresSomeIMLogin = newValue }
    }

    /// Images staged in the composer for the next user message.
    var agentPendingImages: [AgentImageAttachment] {
        get { activeRuntime?.pendingImages ?? [] }
        set { activeRuntime?.pendingImages = newValue }
    }

    /// Long pasted text staged in the composer for the next user message.
    var agentPendingTextAttachments: [AgentTextAttachment] {
        get { activeRuntime?.pendingTextAttachments ?? [] }
        set { activeRuntime?.pendingTextAttachments = newValue }
    }

    /// Skills the user attached via `$skill` for the next send.
    var agentPendingSkills: [AgentSkillEntry] {
        get { activeRuntime?.pendingSkills ?? [] }
        set { activeRuntime?.pendingSkills = newValue }
    }

    /// Files the user attached via the `@` picker for the next send.
    var agentPendingFiles: [AgentFileAttachment] {
        get { activeRuntime?.pendingFiles ?? [] }
        set { activeRuntime?.pendingFiles = newValue }
    }

    /// Parsed documents retained for every future turn in this session.
    var agentSessionDocuments: [AgentFileAttachment] {
        get { activeRuntime?.documentAttachments ?? [] }
        set { activeRuntime?.documentAttachments = newValue }
    }

    var agentKnowledgeFolders: [AgentKnowledgeFolder] {
        get { activeRuntime?.knowledgeFolders ?? [] }
        set { activeRuntime?.knowledgeFolders = newValue }
    }

    var agentDocumentTaskMode: AgentDocumentTaskMode {
        get { activeRuntime?.documentTaskMode ?? .automatic }
        set { activeRuntime?.documentTaskMode = newValue }
    }

    var agentRedactsSensitiveAttachmentContent: Bool {
        get { activeRuntime?.redactSensitiveAttachmentContent ?? true }
        set { activeRuntime?.redactSensitiveAttachmentContent = newValue }
    }

    /// Whether the next send should include a workspace overview block.
    var agentPendingIncludeWorkspaceOverview: Bool {
        get { activeRuntime?.pendingIncludeWorkspaceOverview ?? false }
        set { activeRuntime?.pendingIncludeWorkspaceOverview = newValue }
    }

    /// 用户附给下一轮的面板现状（`@` / `+` 选择器写入，发送时消费）。
    var agentPendingPanelStateMentions: Set<AgentPanelStateMention.PanelKind> {
        get { activeRuntime?.pendingPanelStateMentions ?? [] }
        set { activeRuntime?.pendingPanelStateMentions = newValue }
    }

    /// 操作员点名的 worker（`@` 选择器写入，chip 显示，发送时消费）。
    var agentPendingWorkerProfileID: String? {
        get { activeRuntime?.pendingWorkerProfileID }
        set { activeRuntime?.pendingWorkerProfileID = newValue }
    }

    /// Top-level interaction mode for the active session.
    var agentInteractionMode: AgentInteractionMode {
        get { activeRuntime?.interactionMode ?? .normal }
        set { activeRuntime?.interactionMode = newValue }
    }

    /// Per-session approval behavior shown in the composer.
    var agentApprovalMode: AgentApprovalMode {
        get { activeRuntime?.approvalMode ?? .smart }
        set { activeRuntime?.approvalMode = newValue }
    }

    /// Per-session execution backend selected in the composer.
    var agentExecutionAgent: AgentExecutionAgent {
        get { activeRuntime?.executionAgent ?? .willDeep }
        set { activeRuntime?.executionAgent = newValue }
    }

    /// Per-session specialist packs enabled from the composer.
    var agentActiveExperts: Set<AgentExpert> {
        get { activeRuntime?.activeExperts ?? [] }
        set { activeRuntime?.activeExperts = newValue }
    }

    /// Current visible execution plan for ordinary or Goal mode.
    var agentCurrentPlan: AgentPlan? {
        get { activeRuntime?.currentPlan }
        set { activeRuntime?.currentPlan = newValue }
    }

    /// Currently-pinned goal for Goal mode.
    var agentCurrentGoal: AgentGoal? {
        get { activeRuntime?.currentGoal }
        set { activeRuntime?.currentGoal = newValue }
    }

    /// Coarse multi-turn phase roadmap for the active Goal.
    var agentGoalRoadmap: AgentGoalRoadmap? {
        get { activeRuntime?.goalRoadmap }
        set { activeRuntime?.goalRoadmap = newValue }
    }

    /// Recent automatic learning outcomes captured for the active session.
    var agentLearningEvents: [AgentLearningEvent] {
        get { activeRuntime?.learningEvents ?? [] }
        set { activeRuntime?.learningEvents = newValue }
    }

    /// Learning events captured strictly within the CURRENT turn (>= 最近一条
    /// user message 的 createdAt)。`agentLearningEvents` 本身是 runtime 上
    /// 跨轮累计的最近 24 条,直接拿来当"本轮"会让 footer popover 把上一轮
    /// 的事件也算进去 —— 1.102.0-rc1 修复(原 rc2 修复并入本版本)。
    var agentCurrentTurnLearningEvents: [AgentLearningEvent] {
        guard let runtime = activeRuntime else { return [] }
        guard let latestUser = runtime.messages.last(where: { $0.role == .user }) else {
            return []
        }
        return runtime.learningEvents.filter { $0.createdAt >= latestUser.createdAt }
    }

    /// True only while Goal's host-owned evidence phase has not produced an
    /// executable plan. Ordinary mode never gates tools on plan state.
    var isPlanGateActive: Bool {
        activeRuntime?.isPlanGateActive ?? false
    }

    /// Messages the user queued while the agent was busy.
    var agentQueuedMessages: [AgentQueuedMessage] {
        get { activeRuntime?.queuedMessages ?? [] }
        set { activeRuntime?.queuedMessages = newValue }
    }

    /// Per-session concrete model override.
    var agentSessionModelOverride: String? {
        get { activeRuntime?.sessionModelOverride }
        set { activeRuntime?.sessionModelOverride = newValue }
    }

    /// Provider library entry used by the active conversation, independent
    /// from the Settings-wide default provider used for new conversations.
    var activeAgentProviderEntry: AgentProviderEntry? {
        guard let runtime = activeRuntime else { return agentProviderLibrary.active }
        return providerEntry(for: runtime)
    }

    /// Live `git status` snapshot for the active session's workspace.
    var agentWorktreeChanges: AgentWorktreeChangeSummary {
        get { activeRuntime?.worktreeChanges ?? .init() }
        set {
            activeRuntime?.worktreeChanges = newValue
            // A fresh snapshot can add/remove files on disk; the memoized
            // per-row existence answers must not outlive it.
            invalidateAgentChangedFileURLCache()
        }
    }

    /// User-controlled expansion for the changed-file list above composer.
    var isAgentWorktreeChangeCardExpanded: Bool {
        get { activeRuntime?.isWorktreeChangeCardExpanded ?? false }
        set { activeRuntime?.isWorktreeChangeCardExpanded = newValue }
    }

    /// Mirrors `AgentRuntime.didEditFiles` for the active session. Used to
    /// gate the worktree-change card so a fresh New Chat never shows it.
    var agentSessionDidEditFiles: Bool {
        get { activeRuntime?.didEditFiles ?? false }
        set { activeRuntime?.didEditFiles = newValue }
    }

    /// Workspace-relative paths the Agent has actually written to in the
    /// active session, used to filter out the user's own diffs.
    var agentEditedRelativePaths: Set<String> {
        get { activeRuntime?.agentEditedPaths ?? [] }
        set { activeRuntime?.agentEditedPaths = newValue }
    }

    /// User-facing files created in the active conversation. This is not a
    /// Git-status view; committed outputs remain in the session ledger.
    var agentArtifactRelativePaths: Set<String> {
        get { activeRuntime?.agentArtifactPaths ?? [] }
        set { activeRuntime?.agentArtifactPaths = newValue }
    }

    /// Continuation resumed when the user resolves the currently-blocked
    /// tool call. Each runtime owns its own waiter so concurrent sessions
    /// do not fight over one slot.
    var agentToolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>? {
        activeRuntime?.toolDecisionWaiter
    }

    /// Provider request task for the active turn. Each runtime holds its
    /// own task so background sessions can continue independently.
    var agentRequestTask: Task<Void, Never>? {
        get { activeRuntime?.requestTask }
        set { activeRuntime?.requestTask = newValue }
    }

    var agentSidePanelKind: AgentSidePanelKind? {
        get { activeRuntime?.sidePanelState.kind }
        set {
            updateActiveSidePanelState { state in
                if let newValue { state.openTab(kind: newValue) }
                else { state.kind = nil }
            }
        }
    }

    var agentSidePanelSelectedFile: URL? {
        get {
            guard let path = activeRuntime?.sidePanelState.selectedFilePath, !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
        set {
            updateActiveSidePanelState { state in
                state.selectedFilePath = newValue?.standardizedFileURL.path
                if let id = state.selectedTab?.id { state.updateTabFile(newValue, tabID: id) }
            }
        }
    }

    func updateActiveSidePanelState(_ mutate: (inout AgentSidePanelState) -> Void) {
        guard let runtime = activeRuntime else { return }
        var state = runtime.sidePanelState
        mutate(&state)
        guard state != runtime.sidePanelState else { return }
        runtime.sidePanelState = state
        persistAgentSidePanelState(runtime: runtime)
    }

    func syncActiveSidePanelPayloadFromGlobals() {
        guard !isRestoringAgentSidePanelGlobals,
              activeRuntime != nil else { return }
        updateActiveSidePanelState { state in
            state.mediaTaskScope = agentMediaTaskPanelScope
            state.imageEditorImagePath = agentImageEditorImageURL?.standardizedFileURL.path
            state.imageEditorMaskPath = agentImageEditorMaskURL?.standardizedFileURL.path
            state.imageEditorPreferredOperation = agentImageEditorPreferredOperation
            state.imageEditorContext = agentImageEditorContext
        }
    }

    func restoreAgentSidePanelGlobals(from runtime: AgentRuntime?) {
        isRestoringAgentSidePanelGlobals = true
        defer { isRestoringAgentSidePanelGlobals = false }

        guard let state = runtime?.sidePanelState else {
            agentMediaTaskPanelScope = nil
            agentImageEditorImageURL = nil
            agentImageEditorMaskURL = nil
            agentImageEditorPreferredOperation = nil
            agentImageEditorContext = nil
            return
        }

        agentMediaTaskPanelScope = state.mediaTaskScope
        agentImageEditorImageURL = state.imageEditorImagePath.map { URL(fileURLWithPath: $0) }
        agentImageEditorMaskURL = state.imageEditorMaskPath.map { URL(fileURLWithPath: $0) }
        agentImageEditorPreferredOperation = state.imageEditorPreferredOperation
        agentImageEditorContext = state.imageEditorContext
    }

    func markActiveSidePanelViewedIfOpen() {
        guard let activeAgentSessionID else { return }
        markSidePanelViewed(sessionID: activeAgentSessionID)
    }

    func markSidePanelViewed(sessionID: AgentSession.ID, now: Date = Date()) {
        var didUpdateRuntime = false
        if let runtime = agentRuntimes[sessionID],
           runtime.sidePanelState.kind != nil {
            var state = runtime.sidePanelState
            state.lastViewedAt = now
            runtime.sidePanelState = state
            runtime.session.sidePanelState = runtime.sidePanelState
            didUpdateRuntime = true
        }

        if let index = agentSessions.firstIndex(where: { $0.id == sessionID }),
           agentSessions[index].sidePanelState.kind != nil {
            agentSessions[index].sidePanelState.lastViewedAt = now
            AgentSessionStore.saveAsync(agentSessions[index])
        } else if didUpdateRuntime, let runtime = agentRuntimes[sessionID] {
            AgentSessionStore.saveAsync(runtime.session)
        }
    }

    func reapStaleAgentSidePanelResources(now: Date = Date()) {
        let timeout = Self.agentSidePanelResourceIdleTimeout
        let activeID = activeAgentSessionID

        for runtime in agentRuntimes.values {
            guard runtime.id != activeID,
                  !AgentDetachedPanelRegistry.shared.hasWindow(sessionID: runtime.id),
                  shouldReapSidePanelResources(state: runtime.sidePanelState, now: now, timeout: timeout) else {
                continue
            }
            releaseSidePanelResources(for: runtime.id, kind: runtime.sidePanelState.kind)
            var state = runtime.sidePanelState
            state.kind = nil
            runtime.sidePanelState = state
            runtime.session.sidePanelState = runtime.sidePanelState
            persistAgentSidePanelState(runtime: runtime)
        }

        for index in agentSessions.indices {
            guard agentSessions[index].id != activeID,
                  !AgentDetachedPanelRegistry.shared.hasWindow(sessionID: agentSessions[index].id),
                  shouldReapSidePanelResources(state: agentSessions[index].sidePanelState, now: now, timeout: timeout) else {
                continue
            }
            let kind = agentSessions[index].sidePanelState.kind
            releaseSidePanelResources(for: agentSessions[index].id, kind: kind)
            agentSessions[index].sidePanelState.kind = nil
            AgentSessionStore.saveAsync(agentSessions[index])
        }
    }

    private func shouldReapSidePanelResources(
        state: AgentSidePanelState,
        now: Date,
        timeout: TimeInterval
    ) -> Bool {
        guard let kind = state.kind,
              kind.releasesResourcesWhenUnviewed,
              let lastViewedAt = state.lastViewedAt else {
            return false
        }
        return now.timeIntervalSince(lastViewedAt) >= timeout
    }

    private func releaseSidePanelResources(for sessionID: AgentSession.ID, kind: AgentSidePanelKind?) {
        // 分离到独立窗口的面板可能正被用户盯着看,且分离窗口不更新任何
        // session 的 lastViewedAt —— 一律豁免,窗口关闭后下轮 reap 再收。
        let registry = AgentDetachedPanelRegistry.shared
        if registry.hasWindow(sessionID: sessionID) || (kind == .terminal && registry.isDetached(.terminal)) {
            return
        }
        switch kind {
        case .terminal:
            agentTerminalController.closeTabs(openedBy: sessionID)
        case .embeddedBrowser:
            AgentEmbeddedBrowserController.release(for: sessionID)
        default:
            break
        }
    }

    func persistAgentSidePanelState(runtime: AgentRuntime) {
        runtime.session.sidePanelState = runtime.sidePanelState
        if let index = agentSessions.firstIndex(where: { $0.id == runtime.id }) {
            agentSessions[index].sidePanelState = runtime.sidePanelState
            AgentSessionStore.saveAsync(agentSessions[index])
        } else {
            AgentSessionStore.saveAsync(runtime.session)
        }
    }
}
