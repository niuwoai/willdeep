//
//  AppStateAgentSessions.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses the Agent-mode session lifecycle, routines, plan and
//  goal management, and provider-library switch:
//
//    - Provider library: apply/select/upsert/remove + sync helpers
//    - Plan mode: approve/reject/complete/restart/edit/insert/remove +
//      capture from latest message + step status
//    - Goal mode: setAgentGoal / toggleAgentGoalItem +
//      captureAgentGoalEvaluationFromLatestMessage
//    - reviewAgentWorktreeChanges / showAgentWorktreeDiff
//    - stopAgentResponse / clearAgentQueue / addAgentImage /
//      removeAgentImage staging helpers
//    - setAppMode / toggleAppMode + sessions: startNewAgentSession,
//      selectAgentSession, deleteAgentSession
//    - Routines: saveAgentRoutine / deleteAgentRoutine /
//      toggleAgentRoutineEnabled / runAgentRoutineNow / fireRoutine
//    - toggleAgentSessionPinned / toggleAgentSessionArchived /
//      persistActiveAgentSession / persistAgentSession
//    - recordFetchedAgentModels / setAgentSessionModel /
//      selectAgentEntryAndModel
//
//  Lives on AppState via extension; call sites in the chat / Settings
//  / routine UIs keep using appState.startNewAgentSession(),
//  appState.setAgentInteractionMode(_:) etc. unchanged.
//

import AppKit
import Foundation

struct AgentSessionLoadFailure: Identifiable, Equatable {
    let id: AgentSession.ID
    let title: String
}

extension AppState {

    // MARK: - Interactive session materialization

    /// Composer controls are useful before a project is chosen: a user may
    /// select an execution backend, approval posture, or specialist pack
    /// while starting a general-purpose conversation. Those settings are
    /// session-scoped, so create one unbound draft on the first such action
    /// instead of silently dropping the write because `activeRuntime` is nil.
    /// Choosing a workspace later migrates this empty draft in place.
    func ensureActiveAgentSessionForInteractiveControl() {
        guard activeRuntime == nil else { return }
        _ = startNewAgentSession(inWorkspaceAt: nil)
    }

    // MARK: - Provider library

    /// Reflect the active library entry's tier picks back into
    /// `agentConfiguration` so the existing agent loop (which still
    /// reads from the single configuration) sees the right provider
    /// + key + model the moment the user picks one in Settings.
    ///
    /// A 方案：这是 library → cfg 的**唯一**写入方向。cfg.didSet
    /// 不再回灌 library，所以这里无需 reentrancy 守卫。
    func applyActiveProviderLibraryEntry() {
        guard let entry = agentProviderLibrary.active else { return }
        if !entry.apiKeyLoaded {
            var loadedLibrary = agentProviderLibrary
            if AgentSettingsStore.materializeProviderLibraryAPIKey(in: &loadedLibrary, id: entry.id) {
                agentProviderLibrary = loadedLibrary
                return
            }
        }
        var cfg = agentConfiguration
        cfg.providerID = entry.providerID
        cfg.baseURL = entry.baseURL
        cfg.apiKey = entry.apiKey
        cfg.flashModel = entry.flashPrimary
        cfg.proModel = entry.proPrimary
        cfg.routingMode = entry.routingMode
        if cfg.model.isEmpty { cfg.model = entry.flashPrimary }
        agentConfiguration = cfg.normalized
        clearIncompatibleAgentSessionModelOverride()
    }

    /// Activate a different library entry by id and immediately apply
    /// it to the live configuration. No-op if the id is unknown.
    func setActiveProviderLibraryEntry(id: UUID) {
        guard agentProviderLibrary.entries.contains(where: { $0.id == id }) else { return }
        var library = agentProviderLibrary
        library.setActive(id)
        AgentSettingsStore.materializeProviderLibraryAPIKey(in: &library, id: id)
        agentProviderLibrary = library
        applyActiveProviderLibraryEntry()
    }

    func materializeProviderLibraryEntryAPIKey(id: UUID) {
        guard agentProviderLibrary.entries.contains(where: { $0.id == id }) else { return }
        var library = agentProviderLibrary
        guard AgentSettingsStore.materializeProviderLibraryAPIKey(in: &library, id: id) else { return }
        agentProviderLibrary = library
    }

    @discardableResult
    func ensureActiveProviderIsUsableForChatSelection() -> Bool {
        var library = agentProviderLibrary
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()

        // The active provider is the only credential needed on the normal
        // path. Loading every saved provider here made merely opening the
        // model picker query dozens of historical Keychain rows, multiplying
        // access-control prompts when Debug and Release signatures differed.
        _ = AgentSettingsStore.materializeProviderLibraryAPIKey(
            in: &library,
            id: library.active?.id
        )
        if library.active?.isUsableForChatSelection(
            isSomeIMAuthenticated: authenticated
        ) == true {
            guard library != agentProviderLibrary else { return false }
            agentProviderLibrary = library
            return false
        }

        // Only a genuinely unusable active provider needs fallback discovery.
        // Materialize candidates one at a time and stop at the first usable
        // entry instead of touching the entire Keychain namespace.
        let originalActiveID = library.activeID
        for entry in library.entries where entry.id != library.active?.id {
            _ = AgentSettingsStore.materializeProviderLibraryAPIKey(in: &library, id: entry.id)
            guard let candidate = library.entries.first(where: { $0.id == entry.id }),
                  candidate.isUsableForChatSelection(
                    isSomeIMAuthenticated: authenticated
                  ) else { continue }
            library.activeID = candidate.id
            break
        }

        let changedActive = library.activeID != originalActiveID
        guard library != agentProviderLibrary else { return changedActive }
        agentProviderLibrary = library
        return changedActive
    }

    /// Add or update a library entry. If the entry is the active one,
    /// the live configuration is refreshed too.
    func upsertProviderLibraryEntry(_ entry: AgentProviderEntry) {
        agentProviderLibrary.upsert(entry)
        if agentProviderLibrary.activeID == entry.id {
            applyActiveProviderLibraryEntry()
        }
    }

    func syncSomeIMProvider(settings: SomeIMIntegrationSettings, apiKey: String, activate: Bool = true) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        let normalizedSettings = settings.normalized
        let presetID = "some-im"
        let existing = agentProviderLibrary.entries.first { entry in
            entry.providerID == presetID
                || entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedSettings.baseURL
        }

        let entryID = existing?.id ?? UUID()
        let entry = AgentProviderEntry(
            id: entryID,
            providerID: presetID,
            displayName: existing?.displayName ?? AgentProviderPreset.preset(id: presetID)?.displayName,
            baseURL: normalizedSettings.baseURL,
            apiKey: trimmedKey,
            flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
            flashAlternates: existing?.flashAlternates ?? [],
            proPrimary: existing?.proPrimary ?? SomeIMIntegrationSettings.defaultTextModel,
            proAlternates: existing?.proAlternates ?? [],
            routingMode: existing?.routingMode ?? .flash
        )

        agentProviderLibrary.upsert(entry)
        if activate {
            agentProviderLibrary.setActive(entryID)
        }
        if agentProviderLibrary.activeID == entryID {
            applyActiveProviderLibraryEntry()
            adoptSomeIMManagedRoutingForEmptySessionIfNeeded()
        }
    }

    func syncSomeIMImageUnderstanding(
        apiKey: String,
        settings: SomeIMIntegrationSettings? = nil
    ) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var configuration = agentConfiguration.normalized
        configuration.imageDescription = AgentImageDescriptionConfiguration(
            providerID: "some-im",
            baseURL: (settings ?? SomeIMIntegrationStore.loadSettings()).normalized.baseURL,
            model: SomeIMIntegrationSettings.defaultVisionModel,
            apiKey: trimmedKey
        ).normalized
        agentConfiguration = configuration.normalized
    }

    func startSomeIMCodingPlanRefreshTimer() {
        someIMCodingPlanRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak appState = self] in
                appState?.refreshSomeIMCodingPlanStatus(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        someIMCodingPlanRefreshTimer = timer
    }

    func refreshSomeIMCodingPlanStatus(force: Bool) {
        if !force, !someIMCodingPlanStatus.isStale {
            return
        }
        someIMCodingPlanRefreshTask?.cancel()
        someIMCodingPlanRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.refreshedSomeIMCodingPlanStatusIfNeeded(force: force)
        }
    }

    func refreshedSomeIMCodingPlanStatusIfNeeded(force: Bool = false) async -> SomeIMCodingPlanStatus {
        if !force, !someIMCodingPlanStatus.isStale {
            return someIMCodingPlanStatus
        }
        someIMCodingPlanRefreshFailure = nil
        do {
            let status = try await SomeIMClient.fetchCodingPlanStatus()
            someIMCodingPlanStatus = status
            SomeIMIntegrationStore.saveCodingPlanStatus(status)
            return status
        } catch {
            someIMCodingPlanRefreshFailure = SomeIMCodingPlanRefreshFailure.classify(error)
            return someIMCodingPlanStatus
        }
    }

    func syncLocalModelComposerProvider(settings rawSettings: AgentLocalModelSettings) {
        let settings = rawSettings.normalized
        let entryID = AgentLocalModelSettings.composerProviderEntryID
        guard settings.enabled, settings.exposeAsComposerModel else {
            if agentProviderLibrary.entries.contains(where: { $0.id == entryID }) {
                removeProviderLibraryEntry(id: entryID)
            }
            return
        }

        let entry = AgentProviderEntry(
            id: entryID,
            providerID: AgentProviderPreset.ollamaID,
            displayName: settings.composerDisplayName,
            baseURL: settings.baseURL,
            apiKey: "",
            flashPrimary: settings.summaryModel,
            flashAlternates: settings.visionModel == settings.summaryModel ? [] : [settings.visionModel],
            proPrimary: settings.summaryModel,
            proAlternates: [],
            routingMode: .flash
        )
        upsertProviderLibraryEntry(entry)
    }

    /// React to a shared some.im session change (this app or another one sharing
    /// the Keychain access group). Login/key-change adopts the fresh key without
    /// hijacking the user's active provider; logout drops the some-im entry.
    @discardableResult
    func reconcileSomeIMProviderFromSharedSession() -> Bool {
        let apiKey = SomeIMIntegrationStore.loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            clearSomeIMProvider()
            ensureActiveProviderIsUsableForChatSelection()
            return false
        } else {
            syncSomeIMProvider(
                settings: SomeIMIntegrationStore.loadSettings(),
                apiKey: apiKey,
                activate: false
            )
            syncSomeIMImageUnderstanding(apiKey: apiKey)
            ensureActiveProviderIsUsableForChatSelection()
            return true
        }
    }

    /// Last-chance repair for the exact split-brain state where the shared
    /// some.im session is valid but the active provider entry has no materialized
    /// key. This is intentionally run before constructing the turn snapshot so
    /// the first send after launch cannot fail merely because startup routing is
    /// still probing the user's region.
    @discardableResult
    func repairSomeIMProviderCredentialsForTurnIfNeeded(for runtime: AgentRuntime) -> Bool {
        let current = agentConfiguration.normalized
        let usesSomeIM = current.providerID == AgentProviderPreset.someIMID
            || agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID
            || runtime.managedRouting != nil
        guard usesSomeIM else { return false }
        guard current.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        let apiKey = SomeIMIntegrationStore.loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return false }
        syncSomeIMProvider(
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: apiKey,
            activate: runtime.managedRouting != nil
                || agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID
        )
        syncSomeIMImageUnderstanding(apiKey: apiKey)
        return !agentConfiguration.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    func refreshSomeIMRelayRouting(
        resolveBaseURL: () async throws -> String = {
            try await SomeIMClient.resolveAutomaticRelayBaseURL()
        }
    ) async {
        var settings = SomeIMIntegrationStore.loadSettings()
        let apiKey = SomeIMIntegrationStore.loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }

        // Credential availability must never depend on the location probes.
        // Preserve the live provider route while offline; a successful probe
        // below may refine only the Base URL.
        let existingSomeIMEntry = agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID
            ? agentProviderLibrary.active
            : agentProviderLibrary.entries.first { $0.providerID == AgentProviderPreset.someIMID }
        if let existingBaseURL = existingSomeIMEntry?.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existingBaseURL.isEmpty {
            settings.baseURL = existingBaseURL
        }
        settings.enabled = true
        settings = settings.normalized
        SomeIMIntegrationStore.saveSettings(settings)
        syncSomeIMProvider(settings: settings, apiKey: apiKey, activate: false)
        syncSomeIMImageUnderstanding(apiKey: apiKey, settings: settings)

        do {
            let baseURL = try await resolveBaseURL()
            settings.baseURL = baseURL
            let normalized = settings.normalized
            SomeIMIntegrationStore.saveSettings(normalized)
            syncSomeIMProvider(settings: normalized, apiKey: apiKey, activate: false)
            syncSomeIMImageUnderstanding(apiKey: apiKey, settings: normalized)
        } catch {
            // Keep the last known route when the lightweight location probe is
            // temporarily unavailable; the existing relay remains usable.
        }
    }

    /// Remove every some.im provider entry (used when the shared session is
    /// cleared). `removeProviderLibraryEntry` re-points `activeID` to a
    /// surviving entry when one exists.
    func clearSomeIMProvider() {
        let someIMEntryIDs = agentProviderLibrary.entries
            .filter { $0.providerID == "some-im" }
            .map(\.id)
        for id in someIMEntryIDs {
            removeProviderLibraryEntry(id: id)
        }
    }

    /// Remove a library entry. The library auto-repoints `activeID`
    /// to the next entry; if nothing remains the live configuration
    /// is left as-is (the Settings UI is expected to require at
    /// least one entry to chat).
    func removeProviderLibraryEntry(id: UUID) {
        let wasActive = agentProviderLibrary.activeID == id
        agentProviderLibrary.remove(id: id)
        // Drop the Keychain row for the removed entry's API key.
        AgentSettingsStore.deleteLibraryEntryAPIKey(for: id)
        if wasActive, agentProviderLibrary.active != nil {
            applyActiveProviderLibraryEntry()
        }
    }

    // A 方案：原先的 `syncActiveLibraryEntryFromConfiguration` 已被移除。
    // 该函数曾从 cfg.didSet 回灌 active entry，把 legacy
    // `agentConfiguration.providerID = "openai"` 默认值写到 DeepSeek
    // 条目身上，造成 "OpenAI 顶着 DeepSeek 的 API key" 这类 bug。
    // 单向流：library → cfg via `applyActiveProviderLibraryEntry`。

    // MARK: - Interaction modes (plan / goal)

    /// Flip the session into a different interaction mode. Switching out
    /// of Plan or Goal also drops any associated state so the next
    /// session pick-up starts clean.
    func setAgentInteractionMode(_ mode: AgentInteractionMode) {
        ensureActiveAgentSessionForInteractiveControl()
        guard agentInteractionMode != mode else { return }
        cancelAgentPlanModeSuggestion()
        agentInteractionMode = mode
        if mode != .plan { agentCurrentPlan = nil }
        if mode != .goal {
            agentCurrentGoal = nil
            activeRuntime?.goalTurnRecoveryCheckpoint = nil
        }
        persistActiveAgentSession()
    }

    /// Update the active session's tool approval posture. This is
    /// intentionally session-scoped so a cautious remote-runtime chat
    /// can require every approval while a local scratch chat stays
    /// frictionless.
    func setAgentApprovalMode(_ mode: AgentApprovalMode) {
        ensureActiveAgentSessionForInteractiveControl()
        guard let runtime = activeRuntime, runtime.approvalMode != mode else { return }
        runtime.approvalMode = mode
        persistActiveAgentSession()
        if mode == .workspaceAccess {
            reevaluatePendingToolCallsForWorkspaceAccess(for: runtime)
        }
    }

    /// Choose which execution backend the composer should use for this
    /// session. Provider/model selection remains separate; this only
    /// controls whether the next user turn runs natively or delegates to
    /// an external coding-agent CLI.
    func setAgentExecutionAgent(_ agent: AgentExecutionAgent) {
        ensureActiveAgentSessionForInteractiveControl()
        guard agentExecutionAgent != agent else { return }
        agentExecutionAgent = agent
        persistActiveAgentSession()
    }

    /// Activate an optional expert pack for the active session. Experts widen
    /// the model-facing tool surface and add a small domain contract once
    /// enabled.
    func activateAgentExpert(_ expert: AgentExpert) {
        ensureActiveAgentSessionForInteractiveControl()
        var experts = agentActiveExperts
        guard !experts.contains(expert) else { return }
        experts.insert(expert)
        agentActiveExperts = experts
        persistActiveAgentSession()
    }

    /// Expert activation can still be undone before the first real user turn.
    /// Once the conversation has started, keep the expert surface stable so
    /// follow-up turns cannot silently lose tools or prompt contracts.
    func canDeactivateAgentExperts() -> Bool {
        activeRuntime?.isEmpty ?? true
    }

    @discardableResult
    func deactivateAgentExpert(_ expert: AgentExpert) -> Bool {
        guard canDeactivateAgentExperts() else { return false }
        var experts = agentActiveExperts
        guard experts.remove(expert) != nil else { return false }
        agentActiveExperts = experts
        persistActiveAgentSession()
        return true
    }

    /// User clicks Approve on the proposed plan — flips it to approved
    /// so the next turn's system prompt unlocks write tools.
    func approveAgentPlan() {
        if agentInteractionMode == .goal {
            confirmAgentPlanAndExecute()
            return
        }
        guard var plan = agentCurrentPlan else { return }
        plan.status = .approved
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// User clicks Reject — drops the plan so the agent re-plans next turn.
    func rejectAgentPlan() {
        guard let runtime = activeRuntime else { return }
        agentCurrentPlan = nil
        runtime.goalTurnRecoveryCheckpoint = nil
        persistActiveAgentSession()
        if agentInteractionMode == .goal {
            _ = startAgentGoalPlanningIfNeeded(for: runtime, forceRestart: true)
        }
    }

    /// 1.79.0 plan 自动执行 banner 入口。用户点「执行」或倒计时归零
    /// 时调用。等效于 approve plan + 立刻派发一条「按 plan 执行」的
    /// user 消息，agent 下个 turn 就会开干。
    ///
    /// 故意**留在 Plan 模式**，不切到 Normal：plan 模式的 system
    /// prompt 在 `plan.status == .approved` 时已自动解锁 write tools，
    /// 留在 plan 模式可以保留 plan card 的步骤勾选 / 进度跟踪体验。
    /// 如果 agent 当前 turn 还在跑（罕见 —— banner 只在 plan 刚解析
    /// 完时出现），prompt 会进队列。
    func confirmAgentPlanAndExecute() {
        guard agentInteractionMode == .plan || agentInteractionMode == .goal,
              var plan = agentCurrentPlan,
              plan.status == .proposed else { return }
        plan.status = .approved
        agentCurrentPlan = plan
        if agentInteractionMode == .goal, var state = activeRuntime?.goalPlanningState {
            state.phase = .executing
            activeRuntime?.goalPlanningState = state
        }
        if agentInteractionMode == .goal,
           activeRuntime?.goalTurnRecoveryCheckpoint == nil {
            // Approval may be queued behind a still-finishing synthesis turn.
            // Persist the user's execution intent now so an app exit before
            // queue consumption can still recover the approved Plan.
            activeRuntime?.goalTurnRecoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint()
        }
        persistActiveAgentSession()

        let goalTurnEndContract = agentInteractionMode == .goal
            ? "At the end of every reply, emit both exactly one ```progress fenced block and exactly one ```goal-check fenced block in the same reply, even when either block contains no changes."
            : "At the end of each reply, emit exactly one ```progress fenced block with the latest status of every step touched."
        let prompt = """
        Plan approved. Execute the complete plan step by step. Do not treat an outline, sample, first file, \
        or first chapter as completion when an approved step promises the full deliverable. \
        \(goalTurnEndContract) If the response budget forces a pause, leave the current step in_progress so \
        WillDeep can continue automatically. Stop only when every step has reached a terminal state.
        """
        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(
                AgentQueuedMessage(text: prompt, images: [], source: .hostInstruction)
            )
            return
        }
        dispatchAgentMessage(
            for: runtime,
            text: prompt,
            images: [],
            source: .hostInstruction
        )
    }

    /// Manually retire an approved plan (e.g. after the agent reported done).
    func completeAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .done
        agentCurrentPlan = plan
        activeRuntime?.goalTurnRecoveryCheckpoint = nil
        persistActiveAgentSession()
        if let runtime = activeRuntime {
            prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
        }
    }

    /// Ask the agent to revise the current plan. Drops the existing
    /// plan (so the system prompt flips back to "needs a plan") and
    /// auto-sends a user message — either the bare "please revise"
    /// boilerplate, or the caller's free-form note appended to it.
    /// Falls through to the normal queue path if the agent is busy.
    func requestPlanRevision(note: String) {
        guard agentInteractionMode == .plan || agentInteractionMode == .goal else { return }
        // Drop the existing plan so the next turn's system prompt
        // sends the "you must emit a ```plan block" instructions.
        agentCurrentPlan = nil
        activeRuntime?.goalTurnRecoveryCheckpoint = nil
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if trimmed.isEmpty {
            prompt = "Please revise the plan. Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval."
        } else {
            prompt = """
            Please revise the plan with this guidance from me:

            \(trimmed)

            Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval.
            """
        }

        guard let runtime = activeRuntime else { return }
        if runtime.interactionMode == .goal {
            _ = startAgentGoalPlanningIfNeeded(
                for: runtime,
                forceRestart: true,
                revisionNote: trimmed.isEmpty ? nil : trimmed
            )
            return
        }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Parse the most recent assistant message looking for a ```plan
    /// fenced block and replace `agentCurrentPlan` if one is found and
    /// the user hasn't already approved a plan this session. Convenience
    /// wrapper that targets `activeRuntime`; the turn loop calls the
    /// runtime-explicit variant below.
    func captureAgentPlanFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentPlanFromLatestMessage(for: runtime)
    }

    @discardableResult
    func captureAgentPlanFromLatestMessage(for runtime: AgentRuntime) -> AgentGoalProposalCaptureOutcome {
        guard runtime.interactionMode == .plan || runtime.interactionMode == .goal else { return .noProposal }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            return .noProposal
        }
        if let parsed = AgentPlanParser.extract(from: last.content) {
            if runtime.interactionMode == .plan {
                runtime.currentPlan = parsed
                return .captured
            }
            if runtime.goalPlanningState?.phase == .readyForProposal {
                let failures = AgentGoalPlanProposalValidator.validationFailures(
                    content: last.content,
                    plan: parsed,
                    generationID: runtime.goalPlanningState?.generationID
                )
                if failures.isEmpty {
                    runtime.currentPlan = parsed
                    if var state = runtime.goalPlanningState {
                        state.phase = .awaitingApproval
                        runtime.goalPlanningState = state
                    }
                    return .captured
                }
                // A proposal the model clearly attempted but that fails
                // validation must not vanish silently — feed the reasons
                // back (bounded) or surface a blocked state to the user.
                return requestAgentGoalProposalCorrection(for: runtime, failures: failures)
            }
        }
        if let existing = runtime.currentPlan,
           existing.status == .approved || existing.status == .executing || existing.status == .done {
            applyAgentPlanProgressFromLatestMessage(for: runtime, existingPlan: existing)
        }
        return .noProposal
    }

    func applyAgentPlanProgressFromLatestMessage(for runtime: AgentRuntime, existingPlan: AgentPlan) {
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let next = AgentPlanParser.applyProgress(to: existingPlan, from: last.content) {
            runtime.currentPlan = next
        }
    }

    /// Convenience wrapper that targets `activeRuntime`.
    func captureAgentGoalEvaluationFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentGoalEvaluationFromLatestMessage(for: runtime)
    }

    @discardableResult
    func captureAgentGoalDefinitionFromLatestMessage(for runtime: AgentRuntime) -> Bool {
        guard runtime.interactionMode == .goal,
              runtime.currentGoal == nil || runtime.currentGoal?.isEmpty == true else { return false }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }),
              let parsed = AgentGoalParser.extract(from: last.content),
              !parsed.isEmpty else {
            return false
        }
        runtime.currentGoal = parsed
        runtime.currentPlan = nil
        runtime.goalPlanningState = nil
        persistAgentSession(runtime: runtime)
        return true
    }

    func startAgentGoalPlanningAfterCaptureIfNeeded(
        _ didDefineGoal: Bool,
        for runtime: AgentRuntime
    ) {
        guard didDefineGoal else { return }
        _ = startAgentGoalPlanningIfNeeded(for: runtime)
    }

    func captureAgentGoalEvaluationFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              let goal = runtime.currentGoal,
              !goal.checklist.isEmpty else { return }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let editedAt = runtime.currentGoalEditedAt,
           last.createdAt < editedAt {
            return
        }
        if let updated = AgentGoalChecklistParser.applyEvaluation(to: goal, from: last.content) {
            runtime.currentGoal = updated
            persistAgentSession(runtime: runtime)
        }
    }

    /// Manually override a single step's status from the UI checkbox.
    /// Mirrors the model-driven path: bumps the plan to .executing on
    /// first touch, .done when everything is terminal.
    func setAgentPlanStepStatus(id: UUID, status: AgentPlan.StepStatus) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps[idx].status = status
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        } else if plan.status == .approved {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Edit a step's text in place — handy when the agent's wording
    /// isn't quite right and the user wants to fix it before/during
    /// execution. Status is preserved.
    func editAgentPlanStepText(id: UUID, newText: String) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        plan.steps[idx].text = trimmed
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Insert a fresh pending step before/after another step (or at the
    /// list start/end if `relativeToID` is nil). Plan status is left
    /// alone — adding a step to an executing plan keeps it executing.
    func insertAgentPlanStep(text: String, relativeToID: UUID?, before: Bool) {
        guard var plan = agentCurrentPlan else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newStep = AgentPlan.Step(text: trimmed, status: .pending)
        let insertIdx: Int
        if let relativeToID, let i = plan.steps.firstIndex(where: { $0.id == relativeToID }) {
            insertIdx = before ? i : i + 1
        } else {
            insertIdx = before ? 0 : plan.steps.count
        }
        plan.steps.insert(newStep, at: insertIdx)
        // If the plan was already .done but a step was added, it's not
        // done anymore — bump it back to executing.
        if plan.status == .done {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Remove a step entirely. Promotes to .done if the remaining steps
    /// are all terminal; demotes to .approved if the plan becomes empty.
    func removeAgentPlanStep(id: UUID) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps.remove(at: idx)
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.isEmpty {
            plan.status = .approved   // back to "no progress yet" rather than .done
        } else if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Reset a step (and every step after it) back to .pending, then
    /// ask the agent to resume from that point. "Run from here" — the
    /// common need when an earlier step's output turned out wrong and
    /// every downstream step has to be redone.
    func restartAgentPlanFromStep(id: UUID, note: String) {
        guard agentInteractionMode == .plan || agentInteractionMode == .goal,
              var plan = agentCurrentPlan,
              let startIdx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        for i in startIdx..<plan.steps.count {
            plan.steps[i].status = .pending
        }
        // Plan stays approved/executing — we're not redoing the
        // approval gate, just rewinding the execution head.
        if plan.status == .done { plan.status = .executing }
        agentCurrentPlan = plan
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "Please restart execution from step \(startIdx + 1) onward."
        let prompt: String
        if trimmed.isEmpty {
            prompt = "\(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Pick up there and emit a `progress` block as you go."
        } else {
            prompt = """
            \(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Here's why:

            \(trimmed)

            Pick up from step \(startIdx + 1) and emit a `progress` block as you go.
            """
        }
        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Replace the goal definition for Goal mode. Empty values clear it.
    /// Preserves existing checklist `done` state when an item's text
    /// hasn't changed — so the user can tweak the goal statement or add
    /// new items without losing what's already ticked.
    func setAgentGoal(statement: String, items: [String]) {
        guard let runtime = activeRuntime else { return }
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let previousGoal = runtime.currentGoal

        if trimmedStatement.isEmpty && trimmedItems.isEmpty {
            if let state = runtime.goalPlanningState {
                agentSubagentRegistry.cancelGoalPlanningRuns(Set(state.members.compactMap(\.runID)))
            }
            runtime.currentGoal = nil
            runtime.currentPlan = nil
            runtime.goalPlanningState = nil
            runtime.goalTurnRecoveryCheckpoint = nil
            if previousGoal != nil {
                runtime.currentGoalEditedAt = Date()
            }
            persistActiveAgentSession()
            enqueueGoalUpdateNoticeIfNeeded(for: runtime, previousGoal: previousGoal, updatedGoal: nil)
            return
        }
        var priorItemsByText: [String: AgentGoal.Item] = [:]
        for item in runtime.currentGoal?.checklist ?? [] {
            if priorItemsByText[item.text] == nil {
                priorItemsByText[item.text] = item
            }
        }
        let updatedGoal = AgentGoal(
            statement: trimmedStatement,
            checklist: trimmedItems.map { text in
                if let prior = priorItemsByText[text] {
                    return AgentGoal.Item(id: prior.id, text: text, done: prior.done)
                }
                return AgentGoal.Item(text: text)
            }
        )
        runtime.currentGoal = updatedGoal
        if previousGoal != updatedGoal {
            if let state = runtime.goalPlanningState {
                agentSubagentRegistry.cancelGoalPlanningRuns(Set(state.members.compactMap(\.runID)))
            }
            runtime.currentGoalEditedAt = Date()
            runtime.currentPlan = nil
            runtime.goalPlanningState = nil
            runtime.goalTurnRecoveryCheckpoint = nil
        }
        persistActiveAgentSession()
        enqueueGoalUpdateNoticeIfNeeded(for: runtime, previousGoal: previousGoal, updatedGoal: updatedGoal)
        if previousGoal != updatedGoal {
            _ = startAgentGoalPlanningIfNeeded(for: runtime)
        }
    }

    private func enqueueGoalUpdateNoticeIfNeeded(
        for runtime: AgentRuntime,
        previousGoal: AgentGoal?,
        updatedGoal: AgentGoal?
    ) {
        guard runtime.interactionMode == .goal,
              runtime.isResponding,
              previousGoal != updatedGoal else { return }
        runtime.queuedMessages.append(
            AgentQueuedMessage(
                text: Self.goalUpdateFollowUpPrompt(for: updatedGoal),
                images: [],
                executionAgent: runtime.executionAgent
            )
        )
    }

    private static func goalUpdateFollowUpPrompt(for goal: AgentGoal?) -> String {
        guard let goal, !goal.isEmpty else {
            return "The user cleared the active Goal while you were working. Stop following the previous goal. Ask for a new goal if needed before continuing Goal-mode work."
        }

        var lines = [
            "The user updated the active Goal while you were working. Continue using this updated goal and ignore the previous goal.",
            "",
            "Updated goal:",
            goal.statement.isEmpty ? "- Goal statement: (none)" : "- Goal statement: \(goal.statement)"
        ]
        if !goal.checklist.isEmpty {
            lines.append("- Acceptance checklist:")
            for (index, item) in goal.checklist.enumerated() {
                lines.append("  \(index + 1). [\(item.done ? "x" : " ")] \(item.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Toggle a single checklist item by id. The flipped state shows up
    /// in the next system prompt, so the agent sees progress.
    func toggleAgentGoalItem(_ id: UUID) {
        guard var goal = agentCurrentGoal else { return }
        guard let idx = goal.checklist.firstIndex(where: { $0.id == id }) else { return }
        goal.checklist[idx].done.toggle()
        agentCurrentGoal = goal
        persistActiveAgentSession()
    }

    func reviewAgentWorktreeChanges() {
        guard !agentWorktreeChanges.isEmpty else { return }

        let files = agentWorktreeChanges.files
            .prefix(40)
            .map { change in
                "- \(change.path) \(Self.formatLineStats(change.lineStats))"
            }
            .joined(separator: "\n")
        let extraCount = max(0, agentWorktreeChanges.fileCount - 40)
        let extraLine = extraCount > 0 ? "\n- ...and \(extraCount) more files" : ""
        let prompt = """
        Please review the current uncommitted workspace changes.

        Focus on bugs, hangs/freezes, regressions, approval/security risks, and missing tests. Start with findings ordered by severity and cite file paths.

        Change summary:
        \(files)\(extraLine)
        """

        guard let runtime = activeRuntime else { return }
        runtime.input = ""
        runtime.pendingImages = []

        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }

        if appMode == .editor {
            isAgentPanelVisible = true
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    func showAgentWorktreeDiff() {
        let changes = agentWorktreeChanges
        guard !changes.isEmpty, !isAgentWorktreeDiffPreviewLoading else { return }

        let repositoryRoot = changes.repositoryRoot
            ?? activeRuntime?.workspaceRootPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? rootDirectory?.standardizedFileURL
        guard let repositoryRoot else { return }

        isAgentWorktreeDiffPreviewLoading = true
        Task { [weak self] in
            let preview = await Task.detached(priority: .utility) {
                Self.loadAgentWorktreeDiffPreview(changes: changes, repositoryRoot: repositoryRoot)
            }.value
            guard let self else { return }
            self.isAgentWorktreeDiffPreviewLoading = false
            self.agentWorktreeDiffPreview = preview
        }
    }

    /// Cancel the in-flight response and every active workflow owned by the
    /// current session. Queued messages are kept and the next one is
    /// dispatched automatically. Use `clearAgentQueue` to drop them.
    func stopAgentResponse() {
        guard let runtime = activeRuntime else { return }
        if runtime.goalTurnRecoveryCheckpoint != nil {
            runtime.goalTurnRecoveryCheckpoint = nil
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        }
        let activeWorkflowIDs = runtime.messages.compactMap { message -> UUID? in
            guard let report = message.workflowReport,
                  report.status == .planning || report.status == .running else { return nil }
            return report.id
        }
        for reportID in activeWorkflowIDs {
            cancelWorkflow(reportID: reportID, runtimeID: runtime.id)
        }
        guard runtime.isResponding else { return }
        closeBlockingAgentToolDecision(for: runtime, reason: "Response stopped")
        runtime.shouldConsumeQueueAfterStop = !runtime.queuedMessages.isEmpty
        runtime.requestTask?.cancel()
        scheduleQueuedMessageConsumptionAfterCancellation(for: runtime)
    }

    func scheduleQueuedMessageConsumptionAfterCancellation(for runtime: AgentRuntime) {
        Task { @MainActor [weak self, weak runtime] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, let runtime else { return }
                guard runtime.shouldConsumeQueueAfterStop else { return }
                if !runtime.isResponding, runtime.requestTask == nil {
                    runtime.shouldConsumeQueueAfterStop = false
                    self.consumeNextQueuedMessageIfNeeded(for: runtime)
                    return
                }
            }
            guard let self, let runtime else { return }
            guard runtime.shouldConsumeQueueAfterStop, runtime.isResponding else { return }
            let claim = runtime.currentProviderSlotClaim
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            runtime.shouldConsumeQueueAfterStop = false
            runtime.currentTurnAttachedSkills = []
            runtime.goalTurnRecoveryCheckpoint = nil
            self.persistAgentSession(runtime: runtime)
            if let claim {
                self.releaseProviderSlot(
                    for: runtime,
                    claimID: claim.id,
                    providerID: claim.providerID
                )
            }
            self.consumeNextQueuedMessageIfNeeded(for: runtime)
        }
    }

    @discardableResult
    func closeBlockingAgentToolDecision(for runtime: AgentRuntime, reason: String) -> Bool {
        var closedAny = false
        for index in runtime.toolCalls.indices where runtime.toolCalls[index].status.isBlockingForUserDecision {
            runtime.pendingToolDecisions.removeValue(forKey: runtime.toolCalls[index].id)
            runtime.toolCalls[index].status = .denied
            runtime.toolCalls[index].errorMessage = reason
            closedAny = true
        }
        if let waiter = runtime.toolDecisionWaiter {
            runtime.toolDecisionWaiter = nil
            runtime.toolDecisionWaiterCallID = nil
            waiter.resume(returning: .denied(reason: reason))
            closedAny = true
        }
        return closedAny
    }

    func clearAgentQueue() {
        agentQueuedMessages.forEach(Self.removeStoredImageFiles)
        agentQueuedMessages.removeAll()
    }

    func removeQueuedAgentMessage(id: AgentQueuedMessage.ID) {
        let removed = agentQueuedMessages.filter { $0.id == id }
        removed.forEach(Self.removeStoredImageFiles)
        agentQueuedMessages.removeAll { $0.id == id }
    }

    func moveQueuedAgentMessage(id: AgentQueuedMessage.ID, to targetID: AgentQueuedMessage.ID) {
        guard id != targetID,
              let runtime = activeRuntime,
              let sourceIndex = runtime.queuedMessages.firstIndex(where: { $0.id == id }),
              let targetIndex = runtime.queuedMessages.firstIndex(where: { $0.id == targetID })
        else { return }

        let message = runtime.queuedMessages.remove(at: sourceIndex)
        runtime.queuedMessages.insert(message, at: targetIndex)
    }

    func editQueuedAgentMessage(id: AgentQueuedMessage.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.queuedMessages.firstIndex(where: { $0.id == id })
        else { return }

        let message = runtime.queuedMessages.remove(at: index)
        runtime.input = message.text
        runtime.pendingImages = message.images
        runtime.pendingTextAttachments = message.textAttachments
        runtime.pendingSkills = []
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false
    }

    func sendQueuedAgentMessageNow(id: AgentQueuedMessage.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.queuedMessages.firstIndex(where: { $0.id == id })
        else { return }

        let message = runtime.queuedMessages.remove(at: index)
        runtime.queuedMessages.insert(message, at: 0)

        if runtime.isResponding {
            closeBlockingAgentToolDecision(for: runtime, reason: "Sending queued message")
            runtime.shouldConsumeQueueAfterStop = true
            runtime.requestTask?.cancel()
            scheduleQueuedMessageConsumptionAfterCancellation(for: runtime)
        } else {
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }
    }

    func addAgentImage(data: Data, mimeType: String) {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        let attachment = (try? AgentImageAttachment.fileBacked(data: data, mimeType: mimeType))
            ?? AgentImageAttachment(mimeType: mimeType, dataBase64: data.base64EncodedString())
        runtime.pendingImages.append(attachment)
    }

    func removeAgentImage(id: AgentImageAttachment.ID) {
        agentPendingImages
            .filter { $0.id == id }
            .forEach { $0.removeStoredFileIfNeeded() }
        agentPendingImages.removeAll { $0.id == id }
    }

    private nonisolated static func removeStoredImageFiles(_ message: AgentQueuedMessage) {
        message.images.forEach { $0.removeStoredFileIfNeeded() }
    }

    // MARK: - Agent mode + sessions

    func setAppMode(_ mode: AppMode) {
        guard appMode != mode else { return }
        appMode = mode
        if mode == .agent, activeAgentSessionID == nil {
            // Drop any stale Editor-mode chat state when first entering
            // Agent mode so the user lands on an empty New Chat.
            agentRequestTask?.cancel()
            agentMessages = []
            agentPatchProposals = []
            agentToolCalls = []
            agentQueuedMessages = []
            agentPendingImages = []
            agentErrorMessage = nil
            agentErrorDetails = nil
            isAgentResponding = false
            agentTurnStartedAt = nil
            startNewAgentSession()
        }
    }

    func toggleAppMode() {
        setAppMode(appMode == .agent ? .editor : .agent)
    }

    private func upsertAgentUsageSnapshot(for session: AgentSession) {
        let snapshot = AgentUsageSessionSnapshot(session: session)
        if let index = agentUsageSnapshots.firstIndex(where: { $0.id == session.id }) {
            agentUsageSnapshots[index] = snapshot
        } else {
            agentUsageSnapshots.insert(snapshot, at: 0)
        }
        agentUsageSnapshots.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Analytics are intentionally absent from the launch path. The stats
    /// dashboard calls this on first appearance; live in-memory snapshots
    /// win over disk so a turn saved while the scan runs cannot regress.
    func loadAgentUsageSnapshotsIfNeeded() async {
        guard !hasLoadedAgentUsageSnapshots, !isLoadingAgentUsageSnapshots else { return }
        isLoadingAgentUsageSnapshots = true
        defer { isLoadingAgentUsageSnapshots = false }

        let persisted = await Task.detached(priority: .utility) {
            AgentSessionStore.loadUsageSnapshots()
        }.value
        guard !Task.isCancelled else { return }

        var snapshotsByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        for snapshot in agentUsageSnapshots {
            snapshotsByID[snapshot.id] = snapshot
        }
        agentUsageSnapshots = snapshotsByID.values.sorted { $0.updatedAt > $1.updatedAt }
        hasLoadedAgentUsageSnapshots = true
    }

    private func removeAgentUsageSnapshot(id: AgentSession.ID) {
        agentUsageSnapshots.removeAll { $0.id == id }
    }

    @discardableResult
    func startNewAgentSession() -> AgentSession {
        agentPrimaryDestination = .conversation
        // Pre-rc2 this function cleared a wall of `agent*` fields on
        // AppState (messages, toolCalls, queued, errors, …). Under rc2
        // those fields delegate to `activeRuntime`, so clearing them
        // here would actually wipe the OUTGOING session's runtime —
        // the wrong thing. rc4 went further: the outgoing turn isn't
        // even cancelled. With per-runtime concurrency, "I want a new
        // chat" no longer implies "kill the one I was on" — the old
        // one keeps streaming in the background and the user can pick
        // it back up from the sidebar.

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        let defaultManagedRouting = defaultSomeIMManagedRoutingState()
        let defaultModelID = defaultAgentModelIDForNewSession(managedRouting: defaultManagedRouting)
        let session = AgentSession(
            workspaceRootPath: rootDirectory?.standardizedFileURL.path,
            workspaceLocation: (rootDirectory?.standardizedFileURL.path).map { WorkspaceLocation.local(path: $0) },
            modelID: defaultModelID,
            managedRouting: defaultManagedRouting
        )
        agentSessions.insert(session, at: 0)
        // Build the runtime BEFORE flipping activeAgentSessionID — the
        // delegated `agent*` setters below all route to `activeRuntime`,
        // and there has to be one in `agentRuntimes` for those writes
        // to land somewhere.
        let newRuntime = AgentRuntime(session: session)
        seedPersistedSessionModelOverride(for: newRuntime)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        // These now go to the freshly-built runtime via delegation.
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        // saveAsync, not save: sync save can beachball behind another
        // instance's NSFileCoordinator hold on the session directory.
        AgentSessionStore.saveAsync(session)
        upsertAgentUsageSnapshot(for: session)
        refreshAgentGitWorktrees()
        return session
    }

    /// Start a new session bound to a specific workspace. 1.85.0-rc11 起
    /// 不再顺手把 editor 窗口的 `rootDirectory` 切过去 —— agent runtime 自
    /// 己持有 workspace 路径就够了,editor 不应该被 agent 这边的切换拖着
    /// 走。Pass `nil` for the "no workspace" group。
    ///
    /// 注意:`startNewAgentSession()` 是从 `rootDirectory` 推 workspace 的
    /// (老路径默认认为 agent 跟 editor 同根)。rc11 解耦后,这里必须显式
    /// 用入参重建 session,而不是甩给无参版本 —— 否则新会话会继承 editor
    /// 当前的根,跟用户在菜单里选的目录对不上。
    @discardableResult
    func startNewAgentSession(inWorkspaceAt workspacePath: String?) -> AgentSession {
        agentPrimaryDestination = .conversation
        let normalizedPath: String?
        if let workspacePath, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
            if Self.isExistingDirectory(url) {
                _ = activateSecurityScope(for: url)
                registerRecentFolder(url)
            }
            normalizedPath = url.path
        } else {
            normalizedPath = nil
        }

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        let defaultManagedRouting = defaultSomeIMManagedRoutingState()
        let defaultModelID = defaultAgentModelIDForNewSession(managedRouting: defaultManagedRouting)
        let session = AgentSession(
            workspaceRootPath: normalizedPath,
            workspaceLocation: normalizedPath.map { WorkspaceLocation.local(path: $0) },
            modelID: defaultModelID,
            managedRouting: defaultManagedRouting
        )
        agentSessions.insert(session, at: 0)
        let newRuntime = AgentRuntime(session: session)
        seedPersistedSessionModelOverride(for: newRuntime)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        // saveAsync, not save: sync save can beachball behind another
        // instance's NSFileCoordinator hold on the session directory.
        AgentSessionStore.saveAsync(session)
        upsertAgentUsageSnapshot(for: session)
        unhideWorkspace(key: session.workspaceSidebarGroupKey)
        refreshAgentGitWorktrees()
        return session
    }

    // MARK: - Hidden workspaces

    private static let hiddenWorkspaceKeysDefaultsKey = "com.willdeep.sidebar.hiddenWorkspaceKeys.v1"

    static func loadHiddenWorkspaceKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenWorkspaceKeysDefaultsKey) ?? [])
    }

    private func persistHiddenWorkspaceKeys() {
        UserDefaults.standard.set(Array(hiddenWorkspaceKeys), forKey: Self.hiddenWorkspaceKeysDefaultsKey)
    }

    /// Hide a workspace group from the sidebar. Sessions stay on disk —
    /// this only flips visibility, so re-adding the same folder restores
    /// the full chat list. The catch-all "no workspace" group can't be
    /// hidden.
    func hideWorkspace(key: String) {
        guard key != AgentSession.noWorkspaceSidebarGroupKey else { return }
        hiddenWorkspaceKeys.insert(key)
        persistHiddenWorkspaceKeys()
    }

    /// Un-hide a workspace (called when the user re-adds / switches into
    /// it), bringing its preserved sessions back into the sidebar.
    func unhideWorkspace(key: String) {
        guard hiddenWorkspaceKeys.contains(key) else { return }
        hiddenWorkspaceKeys.remove(key)
        persistHiddenWorkspaceKeys()
    }

    /// Bind the current composer/session to a selected workspace. Empty
    /// placeholder sessions are migrated in place. A history-bearing
    /// session is also migrated when it currently lives under "No
    /// workspace", because the user is anchoring that same conversation
    /// rather than switching between real project roots. Sessions with
    /// real history and an existing workspace still get a fresh chat so
    /// old tool context is never silently rewritten to a different folder.
    @discardableResult
    func moveActiveAgentSessionToWorkspace(at workspacePath: String) -> AgentSession {
        agentPrimaryDestination = .conversation
        let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
        if Self.isExistingDirectory(url) {
            // 1.85.0-rc9：agent 选 folder 不再联动 editor 窗口的 rootDirectory。
            // 只为 agent 子进程拿读取权限 + 写 recents,editor 侧保持原样。
            _ = activateSecurityScope(for: url)
            registerRecentFolder(url)
        }

        if let runtime = activeRuntime {
            let currentLocalPath = runtime.workspaceLocation?.localPath ?? runtime.workspaceRootPath
            if let currentLocalPath,
               URL(fileURLWithPath: currentLocalPath).standardizedFileURL.path == url.path {
                // Selecting the checked/current workspace is a true no-op.
                // A history-bearing runtime used to fall through and create a
                // duplicate session, followed by another filesystem/Git scan.
                unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
                return runtime.session
            }
        }

        if let runtime = activeRuntime, canRebindActiveRuntimeInPlace(runtime) {
            runtime.rebindWorkspace(to: url.path)
            runtime.worktreeChanges = .init()
            runtime.agentArtifactPaths = []
            persistAgentSession(runtime: runtime)
            unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
            refreshAgentGitWorktrees()
            refreshAgentWorkspaceCollision()
            return runtime.session
        }

        // startNewAgentSession(inWorkspaceAt:) already schedules the Git
        // refresh. Calling it again here used to launch two identical
        // `git status -uall` / worktree scans for every new workspace.
        return startNewAgentSession(inWorkspaceAt: url.path)
    }

    /// Move the current conversation's execution directory into a Git
    /// worktree without moving the conversation to another sidebar workspace.
    /// Unlike a regular workspace switch, this preserves conversation history.
    @discardableResult
    func moveActiveAgentSessionToGitWorktree(
        at worktreePath: String,
        sidebarWorkspaceRootPath: String
    ) -> AgentSession? {
        guard let runtime = activeRuntime, !runtime.isResponding else { return nil }
        let worktreeURL = URL(fileURLWithPath: worktreePath).standardizedFileURL
        let sidebarURL = URL(fileURLWithPath: sidebarWorkspaceRootPath).standardizedFileURL
        guard Self.isExistingDirectory(worktreeURL) else { return nil }

        _ = activateSecurityScope(for: worktreeURL)
        runtime.rebindGitWorktree(
            to: worktreeURL.path,
            sidebarWorkspaceRootPath: sidebarURL.path
        )
        runtime.worktreeChanges = .init()
        runtime.agentArtifactPaths = []
        persistAgentSession(runtime: runtime)
        unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
        refreshAgentGitWorktrees()
        refreshAgentWorkspaceCollision()
        return runtime.session
    }

    /// Rebind the runtime that invoked the approved `change_workspace` tool.
    /// Unlike the composer picker this deliberately keeps the same historical
    /// conversation; the agent loop stops the current tool round immediately
    /// afterwards so no operation can accidentally use its captured old root.
    func changeAgentSessionWorkspaceAfterApproval(
        runtimeID: AgentSession.ID,
        to workspacePath: String
    ) throws -> String {
        let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
        guard Self.isExistingDirectory(url) else {
            throw AgentToolError.invalidArgument("workspace directory does not exist: \(url.path)")
        }
        guard let runtime = agentRuntimes[runtimeID] else {
            throw AgentToolError.invalidArgument("the originating session is no longer available")
        }

        _ = activateSecurityScope(for: url)
        registerRecentFolder(url)
        runtime.rebindWorkspace(to: url.path)
        runtime.worktreeChanges = .init()
        runtime.agentArtifactPaths = []
        persistAgentSession(runtime: runtime)
        unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
        return url.path
    }

    private func canRebindActiveRuntimeInPlace(_ runtime: AgentRuntime) -> Bool {
        guard !runtime.isResponding else { return false }
        if runtime.isEmpty { return true }
        return runtime.workspaceLocation == nil
            && (runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    @discardableResult
    func moveActiveAgentSessionToRemoteWorkspace(runtimeID: UUID, path: String) -> AgentSession {
        agentPrimaryDestination = .conversation
        let normalizedPath = RemotePathValidator.normalizedWorkspaceRoot(path)
        if let runtime = activeRuntime, runtime.isEmpty, !runtime.isResponding {
            runtime.rebindRemoteWorkspace(runtimeID: runtimeID, path: normalizedPath)
            runtime.worktreeChanges = .init()
            runtime.agentArtifactPaths = []
            persistAgentSession(runtime: runtime)
            unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
            return runtime.session
        }

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        let defaultManagedRouting = defaultSomeIMManagedRoutingState()
        let defaultModelID = defaultAgentModelIDForNewSession(managedRouting: defaultManagedRouting)
        let session = AgentSession(
            workspaceRootPath: nil,
            workspaceLocation: .remote(runtimeID: runtimeID, path: normalizedPath),
            modelID: defaultModelID,
            managedRouting: defaultManagedRouting
        )
        agentSessions.insert(session, at: 0)
        let newRuntime = AgentRuntime(session: session)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        // saveAsync, not save: sync save can beachball behind another
        // instance's NSFileCoordinator hold on the session directory.
        AgentSessionStore.saveAsync(session)
        upsertAgentUsageSnapshot(for: session)
        unhideWorkspace(key: session.workspaceSidebarGroupKey)
        return session
    }

    @discardableResult
    func selectAgentSession(id: AgentSession.ID) -> Bool {
        agentPrimaryDestination = .conversation
        guard let targetSession = agentSessions.first(where: { $0.id == id }) else { return false }
        guard activeAgentSessionID != id else {
            agentSessionLoadFailure = nil
            return true
        }
        let outgoingRuntime = activeRuntime

        // rc4: switching away from a session no longer kills its in-flight
        // turn. Each runtime owns its own request task and waiter; with
        // real concurrency in place, switching is purely a UI focus
        // change. The outgoing turn keeps streaming, and the sidebar's
        // status dot makes that visible (green pulse on the row you
        // just left). If the user actually wants to stop it, the Stop
        // button on that runtime's chat pane is the explicit affordance.

        // Make sure the destination runtime is built before flipping
        // `activeAgentSessionID` — delegated readers fall back to
        // safe defaults if the runtime is missing, which would briefly
        // show the new session as empty before the runtime appears.
        guard runtime(for: id) != nil else {
            // Keep the metadata row visible so a Time Machine/manual restore
            // can reconnect it later. The old silent return made a valid
            // click look broken and encouraged repeated clicks/restarts.
            agentSessionLoadFailure = AgentSessionLoadFailure(
                id: targetSession.id,
                title: targetSession.title
            )
            return false
        }
        agentSessionLoadFailure = nil
        activeAgentSessionID = id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()

        // Keep the click path visually instant: the highlighted row and
        // transcript switch first, then the outgoing runtime is saved without
        // marking it newly active or moving it to the top of the sidebar.
        if let outgoingRuntime {
            persistAgentSession(runtime: outgoingRuntime, touchUpdatedAt: false, moveToFront: false)
        }

        // Re-derive the session model override from the persisted
        // session record. The runtime carries it across the lifetime
        // of one launch, but a freshly-built runtime started from a
        // disk session needs this seeded.
        if let runtime = activeRuntime {
            let session = runtime.session
            seedPersistedSessionModelOverride(for: runtime)
            syncWorkspaceContext(for: session)
            refreshAgentGitWorktrees()
            autoSummarizeTitleIfPlaceholder(runtime)
        }
        return true
    }

    func dismissAgentSessionLoadFailure() {
        agentSessionLoadFailure = nil
    }

    /// When the user opens a session still carrying a generic placeholder
    /// title ("New Chat" / "新对话" / "Chat"), kick off a one-shot LLM title
    /// summary so the sidebar stops showing the placeholder. The summarizer
    /// self-gates: it no-ops unless there's a finished user→assistant
    /// exchange, a usable provider, and no summary already in flight — so an
    /// empty new chat won't trigger a request. `force` bypasses the
    /// "only on the first assistant turn" gate so older multi-turn sessions
    /// still get titled on reopen. User-renamed titles are left alone.
    private func autoSummarizeTitleIfPlaceholder(_ runtime: AgentRuntime) {
        guard !runtime.session.titleIsUserSet,
              AgentSessionStore.isPlaceholderTitle(runtime.session.title) else { return }
        summarizeAgentSessionTitleIfNeeded(runtime: runtime, force: true)
    }

    /// 1.85.0-rc11:切到历史会话时不再把 editor 窗口的 `rootDirectory`
    /// 一起拽过去。Agent 工具读 / git status / quick-open 等都基于
    /// `runtime.session.workspaceRootPath` 走 agent 自己的上下文,editor
    /// 窗口保持用户当前的浏览状态。这里只确保子进程拿到该路径的
    /// security scope。Remote 会话本来就不动 editor。
    private func syncWorkspaceContext(for session: AgentSession) {
        let location = session.workspaceLocation ?? session.workspaceRootPath.map { .local(path: $0) }
        guard case .local(let path) = location, !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Already validated + security-scoped this workspace on an earlier
        // switch (the common case: hopping between two sessions in the same
        // folder). `activateSecurityScope` would early-return anyway, but the
        // `isExistingDirectory` stat below still hit the filesystem on every
        // single session switch — skip it once the scope is live.
        if securityScopedAccessURLs.contains(url) { return }
        guard Self.isExistingDirectory(url) else { return }
        _ = activateSecurityScope(for: url)
    }

    /// Lazy lookup: returns the existing runtime for `sessionID` or
    /// builds one on demand from the persisted session list. Used by
    /// the session lifecycle hooks below to make sure every selected
    /// session has a runtime entry sitting in `agentRuntimes`. Returns
    /// nil only when the session id doesn't exist anymore (e.g. it was
    /// just deleted on disk).
    @discardableResult
    func runtime(for sessionID: AgentSession.ID) -> AgentRuntime? {
        if let existing = agentRuntimes[sessionID] { return existing }
        guard let session = materializeAgentSessionIfNeeded(id: sessionID) else { return nil }
        let runtime = AgentRuntime(session: session)
        agentRuntimes[sessionID] = runtime
        startAgentKnowledgeFolderWatchers(for: runtime)
        evictInactiveAgentRuntimesIfNeeded()
        return runtime
    }

    @discardableResult
    private func materializeAgentSessionIfNeeded(id: AgentSession.ID) -> AgentSession? {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return nil }
        guard AgentSessionStore.isMetadataOnly(id) else {
            return agentSessions[index]
        }
        guard let fullSession = AgentSessionStore.load(id: id) else {
            return nil
        }
        agentSessions[index] = fullSession
        return fullSession
    }

    private func evictInactiveAgentRuntimesIfNeeded() {
        let maximumIdleRuntimes = 6
        var protectedIDs = Set([activeAgentSessionID].compactMap { $0 })
        protectedIDs.formUnion(pendingDispatchQueue.map(\.runtimeID))
        protectedIDs.formUnion(titleSummarizationsInFlight)
        let idle = agentRuntimes.values
            .filter { runtime in
                !protectedIDs.contains(runtime.id)
                    && !runtime.isResponding
                    && runtime.requestTask == nil
                    && runtime.workflowTasks.isEmpty
                    && runtime.toolDecisionWaiter == nil
                    // A session waiting on background work is not idle:
                    // evicting it here would cancel its live subagents
                    // (cancelAll below) and orphan alive shell jobs, and
                    // any already-queued completion would depend on the
                    // finish-hook re-materializing the runtime. Keep it
                    // resident until the work is surfaced.
                    && agentJobRegistry.aliveJobs(forRuntime: runtime.id).isEmpty
                    && agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) == 0
                    && !hasPendingBackgroundWakeups(for: runtime)
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }

        guard idle.count > maximumIdleRuntimes else { return }
        for runtime in idle.dropFirst(maximumIdleRuntimes) {
            persistAgentSession(runtime: runtime)
            cancelAllWorkflows(for: runtime)
            agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
            cancelAgentKnowledgeFolderWatchers(sessionID: runtime.id)
            agentRuntimes.removeValue(forKey: runtime.id)
        }
    }

    func deleteAgentSession(id: AgentSession.ID) {
        // If the doomed session is currently mid-turn, cancel its
        // in-flight work before tearing down the runtime so the URL
        // session task and tool-decision waiter don't leak. The
        // turn loop's defer will release the provider slot when the
        // cancellation propagates.
        if let doomed = agentRuntimes[id] {
            doomed.requestTask?.cancel()
            cancelAllWorkflows(for: doomed)
            doomed.toolDecisionWaiter?.resume(returning: .denied(reason: "Session deleted"))
            doomed.toolDecisionWaiter = nil
            doomed.toolDecisionWaiterCallID = nil
            doomed.pendingToolDecisions.removeAll()
        }
        // Orphaned background subagents must not keep burning tokens
        // for a session that no longer exists.
        agentSubagentRegistry.cancelAll(forParentRuntime: id)
        // Drop any not-yet-started dispatches queued for this session
        // so they don't fire after the session is gone.
        pendingDispatchQueue.removeAll { $0.runtimeID == id }

        AgentSessionStore.delete(id: id)
        agentSessions.removeAll { $0.id == id }
        removeAgentUsageSnapshot(id: id)
        cancelAgentKnowledgeFolderWatchers(sessionID: id)
        agentRuntimes.removeValue(forKey: id)
        if activeAgentSessionID == id {
            activeAgentSessionID = nil
            subscribeToActiveRuntime()
        }
    }

    // MARK: - Routines

    /// Insert or replace a routine, then persist + notify the scheduler.
    /// Used by both "create" (id not in list) and "edit" (id already
    /// present) paths from the routine editor sheet.
    func saveAgentRoutine(_ routine: AgentRoutine) {
        var updated = routine
        updated.updatedAt = Date()
        if let index = agentRoutines.firstIndex(where: { $0.id == updated.id }) {
            agentRoutines[index] = updated
        } else {
            agentRoutines.insert(updated, at: 0)
        }
        AgentRoutineStore.save(updated)
        agentRoutines.sort { $0.updatedAt > $1.updatedAt }
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if updated.isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    func deleteAgentRoutine(id: AgentRoutine.ID) {
        AgentRoutineStore.delete(id: id)
        agentRoutines.removeAll { $0.id == id }
        agentRoutineScheduler.routinesChanged(agentRoutines)
    }

    /// Flip enabled on/off in place. Cheaper than going through the
    /// editor sheet for the sidebar inline toggle.
    func toggleAgentRoutineEnabled(id: AgentRoutine.ID) {
        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return }
        agentRoutines[index].isEnabled.toggle()
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if agentRoutines[index].isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    /// User-driven manual fire ("Run now" button in editor or sidebar).
    /// Ignores `isEnabled` — a disabled routine can still be run on demand.
    ///
    /// 1.96.0-rc2:点完"立即运行"以后立刻把活动会话切到新建的 routine
    /// 会话 —— 否则用户什么反馈都看不到,体感是"按了没反应"。
    /// 调度器自动触发(`force == false`)不走这条路,继续保持后台运行。
    func runAgentRoutineNow(id: AgentRoutine.ID) {
        guard let newSessionID = fireRoutine(id: id, force: true) else { return }
        if appMode != .agent {
            setAppMode(.agent)
        }
        selectAgentSession(id: newSessionID)
    }

    /// Scheduler entry point. Returns the new session ID when the routine
    /// actually started a session; nil if the routine was empty / missing
    /// (the scheduler will retry next tick if appropriate).
    ///
    /// Concurrency model (rc3+): scheduler-driven fires spawn a background
    /// runtime rather than yanking the user's UI — they do NOT change
    /// `activeAgentSessionID` and do NOT flip `appMode`. The user keeps
    /// working in whatever session they had on screen; the routine's
    /// session shows up in the sidebar and they can click into it later.
    /// Manual "Run now" (`runAgentRoutineNow`) does switch the active
    /// session — that path is handled by the wrapper above.
    @discardableResult
    func fireRoutine(id: AgentRoutine.ID, force: Bool = false) -> AgentSession.ID? {
        _ = force // The per-provider concurrency cap replaces the old
                  // "is anyone responding?" gate; manual "Run now"
                  // doesn't need to bypass anything different.

        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return nil }
        let routine = agentRoutines[index]
        let prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        // Build the session and its runtime, but DO NOT touch
        // activeAgentSessionID or appMode — that would yank the user
        // out of whatever they're reading.
        let session = AgentSession(
            workspaceRootPath: routine.workspaceRootPath,
            modelID: routine.modelID?.isEmpty == false
                ? routine.modelID
                : agentConfiguration.normalized.model(for: .interactive)
        )
        agentSessions.insert(session, at: 0)
        // saveAsync, not save: sync save can beachball behind another
        // instance's NSFileCoordinator hold on the session directory.
        AgentSessionStore.saveAsync(session)
        upsertAgentUsageSnapshot(for: session)
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        // Routine session stays a background runtime — no activeRuntime
        // forward subscription. Sidebar status dot observes it directly.
        if let modelID = routine.modelID, !modelID.isEmpty {
            runtime.sessionModelOverride = modelID
        }

        agentRoutines[index].lastRunAt = Date()
        agentRoutines[index].lastSessionID = session.id
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)

        // Goal-bearing tasks self-complete: tell this run to evaluate the goal
        // and, if met, call complete_scheduled_task with its own id so the task
        // (and its card) disappears. Plain routines just run the prompt.
        let dispatchText: String
        if let goal = routine.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            dispatchText = """
            \(prompt)

            [定时任务 · 自完成判定] 本次运行来自定时任务「\(routine.name)」(task_id: \(routine.id.uuidString))。
            目标:\(goal)
            完成上述工作后,判断该目标是否已达成:
            - 已达成 → 调用 complete_scheduled_task 工具(task_id 传 \(routine.id.uuidString)),移除这个定时任务;它将不再运行,卡片也会消失。
            - 未达成 → 正常简短汇报当前进展即可,不要调用 complete_scheduled_task。
            """
        } else {
            dispatchText = prompt
        }

        // dispatchAgentMessage handles the per-provider concurrency
        // cap — if the cap is hit, the dispatch queues and drains
        // FIFO as slots free. So even a fleet of 10 routines hitting
        // the same provider all at 09:00 won't stomp on each other.
        dispatchAgentMessage(for: runtime, text: dispatchText, images: [])

        // Sidebar hides sessions whose persisted `session.messages` is
        // still empty (the "empty New Chat" filter in AgentSessionsSidebar
        // groupedSessions). For interactive chats the activeID branch
        // keeps the row visible, but a routine-spawned session is NEVER
        // active by design (rc3+ keeps the user on whatever they were
        // reading). The first message only lands on `session.messages`
        // when runAgentLoop's defer calls persistAgentSession — which is
        // way after the click, and never if the provider call hangs. So
        // here, right after the dispatch synchronously appended the user
        // message to `runtime.messages`, push that state to the session
        // so the row pops into the sidebar immediately. Provider-queue
        // path (cap full → PendingDispatch) leaves runtime.messages
        // empty, which is fine: persist is a no-op-cheap copy in that
        // case and the drain will re-trigger this path soon.
        persistAgentSession(runtime: runtime)
        return session.id
    }

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

    func renameAgentSessionAfterApproval(
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
                return AgentWorkspaceSessionSnapshot(
                    id: source.id,
                    title: source.title,
                    workspaceRootPath: source.workspaceLocation?.localPath ?? source.workspaceRootPath,
                    workspaceDisplayName: source.workspaceName,
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
                    titleIsUserSet: source.titleIsUserSet
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
        if runtime.managedRouting != nil {
            // Managed routing resolves a model per-turn; there is no single
            // session model. Keep modelID clear so nothing downstream mistakes
            // a route-default snapshot for an explicit user choice.
            runtime.session.modelID = nil
        } else if let override = runtime.sessionModelOverride, !override.isEmpty {
            runtime.session.modelID = override
        } else if runtime.id == activeAgentSessionID {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        } else if runtime.session.modelID == nil {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        }
        let activeProvider = agentProviderLibrary.active
        runtime.session.providerID = activeProvider?.providerID ?? agentConfiguration.normalized.providerID
        runtime.session.providerDisplayName = AgentProviderPreset.normalizedDisplayName(
            providerID: runtime.session.providerID,
            storedDisplayName: activeProvider?.displayName
        )
        runtime.persist(touchUpdatedAt: touchUpdatedAt)
        agentSessions[index] = runtime.session
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

        // After every persist, give the LLM summarizer a chance to
        // upgrade the auto-derived first-message-prefix title to a
        // polished one. The method is no-op-cheap on hot paths
        // (returns immediately when there's no first user→assistant
        // exchange yet, or the title is already locked, or a request
        // is in flight), so it's safe to fire unconditionally here.
        summarizeAgentSessionTitleIfNeeded(runtime: runtime)
    }

    func recordFetchedAgentModels(_ ids: [String]) {
        let merged = Array(Set(agentKnownModelIDs + ids))
            .filter { !$0.isEmpty }
            .sorted()
        agentKnownModelIDs = merged
        AgentSettingsStore.saveKnownModelIDs(merged)
    }

    func recordFetchedAgentModelDiscoveries(_ models: [AgentModelDiscovery]) {
        recordFetchedAgentModels(models.map(\.id))
        agentDiscoveredModelMetadata = models
        AgentSettingsStore.saveDiscoveredModelMetadata(models)
    }

    func recordRecentlyUsedAgentModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withoutExisting = agentRecentlyUsedModelIDs.filter {
            $0.caseInsensitiveCompare(trimmed) != .orderedSame
        }
        let updated = [trimmed] + withoutExisting
        agentRecentlyUsedModelIDs = Array(updated.prefix(24))
        AgentSettingsStore.saveRecentlyUsedModelIDs(agentRecentlyUsedModelIDs)
    }

    func setAgentSessionModel(_ model: String?, previousModelForNotice: String? = nil) {
        // The model picker is available before a workspace is chosen. Materialize
        // an unbound conversation so the user's selection has a real session to
        // land on; choosing a folder later rebinds this empty runtime in place.
        ensureActiveAgentSessionForInteractiveControl()
        ensureActiveProviderIsUsableForChatSelection()
        let previousModel = previousModelForNotice ?? activeAgentModelSelectionLabel
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard agentProviderLibrary.active?.isUsableForChatSelection(
            isSomeIMAuthenticated: authenticated
        ) == true else {
            agentSessionModelOverride = nil
            persistActiveAgentSession()
            return
        }
        // Picking any explicit model (or route-default) exits managed
        // routing — the three session-selection states (route default /
        // explicit model / managed) are mutually exclusive.
        activeRuntime?.managedRouting = nil
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if agentModelIsCompatibleWithActiveProvider(trimmed) {
                agentSessionModelOverride = trimmed
                recordFetchedAgentModels([trimmed])
                recordRecentlyUsedAgentModel(trimmed)
            } else {
                agentSessionModelOverride = nil
            }
        } else {
            agentSessionModelOverride = nil
        }
        persistActiveAgentSession()
        appendModelChangeNoticeIfNeeded(from: previousModel, to: activeAgentModelID)
    }

    private func appendModelChangeNoticeIfNeeded(from previousModel: String, to currentModel: String) {
        let old = previousModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty,
              !new.isEmpty,
              old.caseInsensitiveCompare(new) != .orderedSame,
              let runtime = activeRuntime else {
            return
        }
        runtime.messages.append(
            AgentMessage(
                role: .system,
                content: L10n.AgentModelPicker.modelChanged(from: old, to: new),
                transcriptEvent: .modelChanged
            )
        )
        persistActiveAgentSession()
    }

    private var activeAgentModelSelectionLabel: String {
        activeRuntime?.managedRouting == nil
            ? activeAgentModelID
            : L10n.AgentModelPicker.managed
    }

    func agentModelIsCompatibleWithActiveProvider(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let active = agentProviderLibrary.active,
              let preset = AgentProviderPreset.preset(id: active.providerID),
              preset.id != AgentProviderPreset.customID else {
            return true
        }
        return preset.recognizesModelID(trimmed)
    }

    private func clearIncompatibleAgentSessionModelOverride() {
        guard let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty,
              !agentModelIsCompatibleWithActiveProvider(override) else {
            return
        }
        agentSessionModelOverride = nil
        persistActiveAgentSession()
    }

    /// Chat-mode picker entry point — pick a (library entry, model)
    /// pair in one shot. When `entryID` differs from the current
    /// active, activates that entry first (rebuilds configuration),
    /// then sets the session override to `model`. Picking a model
    /// that already matches the route default clears the override so
    /// the chip falls back to displaying the routed name.
    func selectAgentEntryAndModel(entryID: UUID, model: String) {
        let previousModel = activeAgentModelSelectionLabel
        materializeProviderLibraryEntryAPIKey(id: entryID)
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard agentProviderLibrary.entries.first(where: { $0.id == entryID })?
            .isUsableForChatSelection(isSomeIMAuthenticated: authenticated) == true else {
            return
        }
        // Activate the target library entry — this rebuilds
        // agentConfiguration's provider / base URL / key / primaries.
        if agentProviderLibrary.activeID != entryID {
            setActiveProviderLibraryEntry(id: entryID)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setAgentSessionModel(nil, previousModelForNotice: previousModel)
            return
        }
        // If the chosen model is already what the route would pick by
        // default, clear the override so the picker shows the natural
        // "Use route default" state instead of a redundant lock.
        let routed = agentConfiguration.normalized.model(for: .interactive)
        if trimmed == routed {
            recordRecentlyUsedAgentModel(trimmed)
            setAgentSessionModel(nil, previousModelForNotice: previousModel)
        } else {
            setAgentSessionModel(trimmed, previousModelForNotice: previousModel)
        }
    }

    // MARK: - some.im managed routing ("省心托管") selection

    /// Composer entry point for "省心托管". Only valid when the active
    /// provider is some.im. Sets a fresh `.low` managed-routing floor and
    /// clears any explicit model override so the three session-selection
    /// states stay mutually exclusive.
    func selectSomeIMManagedRouting() {
        let previousModel = activeAgentModelSelectionLabel
        if agentProviderLibrary.active?.providerID != AgentProviderPreset.someIMID {
            guard let someIMEntry = agentProviderLibrary.entries.first(where: {
                $0.providerID == AgentProviderPreset.someIMID
            }) else { return }
            setActiveProviderLibraryEntry(id: someIMEntry.id)
        }
        guard agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID else { return }
        // Model choice comes before workspace choice in the composer. Keep that
        // order valid by creating an empty, workspace-less conversation now;
        // moveActiveAgentSessionToWorkspace will preserve it when a folder is
        // selected later.
        if activeRuntime == nil {
            startNewAgentSession(inWorkspaceAt: nil)
        }
        guard let runtime = activeRuntime else { return }
        let wasUsingManagedRouting = runtime.managedRouting != nil
        runtime.sessionModelOverride = nil
        if runtime.managedRouting == nil {
            runtime.managedRouting = AgentManagedRoutingState()
        }
        persistActiveAgentSession()
        if !wasUsingManagedRouting {
            appendModelChangeNoticeIfNeeded(
                from: previousModel,
                to: L10n.AgentModelPicker.managed
            )
        }
    }

    /// Signed-in some.im users start new chats in managed routing until they
    /// explicitly choose a concrete model for the current conversation.
    /// Existing historical conversations are never rewritten; login
    /// reconciliation may only adopt an empty chat.
    private func defaultSomeIMManagedRoutingState() -> AgentManagedRoutingState? {
        guard SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults(),
              agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID,
              AgentSettingsStore.loadDefaultModelModePreference().usesManagedRoutingForNewSessions else {
            return nil
        }
        return AgentManagedRoutingState()
    }

    private func defaultAgentModelIDForNewSession(
        managedRouting: AgentManagedRoutingState?
    ) -> String? {
        if managedRouting != nil {
            return nil
        }
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard agentProviderLibrary.active?.isUsableForChatSelection(
            isSomeIMAuthenticated: authenticated
        ) == true else {
            return nil
        }
        if SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults(),
           agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID,
           !AgentSettingsStore.loadDefaultModelModePreference().usesManagedRoutingForNewSessions {
            return SomeIMIntegrationSettings.defaultTextModel
        }
        return activeAgentModelID
    }

    /// Rebuild the runtime-only model override from the persisted session.
    /// Launch recovery uses the same path as an explicit sidebar selection so
    /// a background-resumed Goal continues on its original concrete model.
    func seedPersistedSessionModelOverride(for runtime: AgentRuntime) {
        guard runtime.managedRouting == nil else {
            runtime.sessionModelOverride = nil
            return
        }
        let routedModel = agentConfiguration.normalized.model(for: .interactive)
        runtime.sessionModelOverride = runtime.session.modelID == routedModel
            ? nil
            : runtime.session.modelID
    }

    private func adoptSomeIMManagedRoutingForEmptySessionIfNeeded() {
        guard let runtime = activeRuntime,
              runtime.isEmpty,
              !runtime.isResponding,
              runtime.managedRouting == nil,
              defaultSomeIMManagedRoutingState() != nil else {
            return
        }
        runtime.sessionModelOverride = nil
        runtime.managedRouting = AgentManagedRoutingState()
        persistActiveAgentSession()
    }

    /// User selected a managed-routing floor in the composer menu.
    func setManagedRoutingFloor(_ tier: AgentManagedCapabilityTier) {
        guard let runtime = activeRuntime else { return }
        guard runtime.managedRouting != nil else { return }
        runtime.setManagedFloor(to: tier)
        persistActiveAgentSession()
    }

    /// User selected the base managed tier.
    func resetManagedRoutingFloor() {
        setManagedRoutingFloor(.low)
    }
}
