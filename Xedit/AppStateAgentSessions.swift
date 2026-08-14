//
//  AppStateAgentSessions.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses the Agent-mode session lifecycle, routines, plan and
//  goal management, and provider-library switch:
//
//    - Provider library: apply/select/upsert/remove + sync helpers
//    - Visible plan progress: complete/restart/edit/insert/remove +
//      capture from latest message + step status
//    - Goal mode: setAgentGoal / AI-owned acceptance reconciliation +
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

    #if DEBUG
    /// Dev-only: seed an agent provider (base URL + API key) from a local JSON
    /// file so Debug builds have a usable provider without manual entry — same
    /// idea as Claude Code storing config in a JSON file. Opt-in via file
    /// presence, so it is a no-op for everyone who hasn't created the file.
    ///
    /// Resolution order:
    ///   1. env `WILLDEEP_DEV_PROVIDER_CONFIG` = path to the JSON
    ///   2. `~/.willdeep/dev-provider.json`
    ///
    /// The key is stored the normal way (into `entry.apiKey` → Keychain via the
    /// `agentProviderLibrary` `didSet`), and is never written to the log.
    func seedDevProviderIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard let config = Self.loadDevProviderConfig() else { return }

        let base = config.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let flash = (config.flashModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty else {
            NSLog("[dev-provider] skipped: apiBase and apiKey are both required")
            return
        }
        guard !flash.isEmpty else {
            NSLog("[dev-provider] skipped: flashModel is required")
            return
        }

        let presetID = config.providerID?.nonEmptyOrNil
            ?? AgentProviderPreset.customID
        // Idempotent: reuse an existing entry with the same base URL so relaunch
        // doesn't append duplicate rows.
        let existing = agentProviderLibrary.entries.first {
            $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == base
        }
        let entryID = existing?.id ?? UUID()
        let pro = config.proModel?.nonEmptyOrNil ?? flash
        let routing: AgentModelRoutingMode
        switch (config.routingMode ?? "auto").lowercased() {
        case "flash": routing = .flash
        case "pro": routing = .pro
        default: routing = .auto
        }

        let entry = AgentProviderEntry(
            id: entryID,
            providerID: presetID,
            displayName: config.displayName?.nonEmptyOrNil ?? existing?.displayName ?? "Dev Seed",
            baseURL: base,
            apiKey: key,
            flashPrimary: flash,
            flashAlternates: existing?.flashAlternates ?? [],
            proPrimary: pro,
            proAlternates: existing?.proAlternates ?? [],
            routingMode: routing
        )
        agentProviderLibrary.upsert(entry)
        if config.setActive ?? true {
            agentProviderLibrary.setActive(entryID)
            if agentProviderLibrary.activeID == entryID {
                applyActiveProviderLibraryEntry()
            }
        }
        NSLog("[dev-provider] seeded provider preset=%@ base=%@ (key from dev config, not logged)", presetID, base)
    }

    private static func loadDevProviderConfig() -> DevProviderSeedConfig? {
        let fileManager = FileManager.default
        var resolvedPath: String?
        if let envPath = ProcessInfo.processInfo.environment["WILLDEEP_DEV_PROVIDER_CONFIG"],
           !envPath.isEmpty, !envPath.hasPrefix("$(") {
            resolvedPath = (envPath as NSString).expandingTildeInPath
        } else {
            let defaultPath = ("~/.willdeep/dev-provider.json" as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: defaultPath) { resolvedPath = defaultPath }
        }
        guard let resolvedPath, fileManager.fileExists(atPath: resolvedPath) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
            return try JSONDecoder().decode(DevProviderSeedConfig.self, from: data)
        } catch {
            NSLog("[dev-provider] failed to load %@: %@", resolvedPath, error.localizedDescription)
            return nil
        }
    }
    #endif

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
            || runtime.sessionProviderIDOverride == AgentProviderPreset.someIMID
            || runtime.managedRouting != nil
        guard usesSomeIM else { return false }
        let configuredAPIKey = runtime.sessionProviderIDOverride == AgentProviderPreset.someIMID
            ? agentProviderLibrary.entries.first(where: {
                $0.providerID == AgentProviderPreset.someIMID
            })?.apiKey ?? ""
            : current.apiKey
        guard configuredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        return configurationForCurrentTurn(for: runtime).apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
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

    // MARK: - Interaction modes (ordinary / goal)

    /// Flip how the next turn executes. The selection is presentation-neutral:
    /// it must not clear history, plans, goals, or move the conversation between
    /// navigation surfaces.
    func setAgentInteractionMode(_ mode: AgentInteractionMode) {
        ensureActiveAgentSessionForInteractiveControl()
        if mode == .goal,
           let runtime = activeRuntime,
           runtime.workspaceLocation == nil,
           (runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            runtime.errorMessage = L10n.Dispatch.workspaceRequired
            return
        }
        guard agentInteractionMode != mode else { return }
        agentInteractionMode = mode
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

    /// Manually retire an active plan (e.g. after the agent reported done).
    func completeAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .done
        agentCurrentPlan = plan
        activeRuntime?.goalTurnRecoveryCheckpoint = nil
        persistActiveAgentSession()
        if let runtime = activeRuntime {
            if !advanceAgentGoalRoadmapIfNeeded(for: runtime) {
                prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
            }
        }
    }

    /// Explicitly revise the visible plan. Ordinary mode replaces it in the
    /// next round and continues execution; Goal mode intentionally restarts
    /// evidence planning because the user asked to change the contract.
    func requestPlanRevision(note: String) {
        guard let runtime = activeRuntime else { return }
        agentCurrentPlan = nil
        runtime.goalTurnRecoveryCheckpoint = nil
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if trimmed.isEmpty {
            prompt = "Please revise the execution plan, emit one complete replacement ```plan``` block, and continue executing it without waiting for plan approval."
        } else {
            prompt = """
            Please revise the plan with this guidance from me:

            \(trimmed)

            Emit one complete replacement ```plan``` block and continue executing it without waiting for plan approval.
            """
        }

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

    /// Parse the latest visible plan/progress. Ordinary plans become ready
    /// immediately; Goal plans additionally pass the host-owned proposal
    /// validator before execution.
    func captureAgentPlanFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentPlanFromLatestMessage(for: runtime)
    }

    @discardableResult
    func captureAgentPlanFromLatestMessage(for runtime: AgentRuntime) -> AgentGoalProposalCaptureOutcome {
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            return .noProposal
        }
        if runtime.interactionMode == .goal,
           runtime.goalPlanningState?.phase == .readyForProposal,
           let generationID = runtime.goalPlanningState?.generationID,
           !last.content.contains("<!-- goal-planning-generation:\(generationID.uuidString) -->") {
            return .noProposal
        }
        if let parsed = AgentPlanParser.extract(from: last.content) {
            if runtime.interactionMode == .normal {
                if let existing = runtime.currentPlan,
                   AgentPlanContinuationPolicy.hasActiveExecutionContract(existing) {
                    applyAgentPlanProgressFromLatestMessage(for: runtime, existingPlan: existing)
                    return .noProposal
                }
                var executable = parsed
                executable.status = .approved
                runtime.currentPlan = AgentPlanParser.applyProgress(
                    to: executable,
                    from: last.content
                ) ?? executable
                return .captured
            }
            if runtime.goalPlanningState?.phase == .executing,
               runtime.currentPlan == nil,
               runtime.goalRoadmap?.activePhase?.status == .planning {
                let requiresDispatchGraph = runtime.session.presentationScope == .dispatchBoard
                let availableProfiles = requiresDispatchGraph
                    ? Set(runtime.currentGoal?.selectedWorkerProfileIDs
                        ?? [AgentExecutionProfile.recommendedWorkerID])
                    : nil
                var failures = AgentGoalPhasePlanValidator.validationFailures(plan: parsed)
                if requiresDispatchGraph {
                    failures += AgentGoalDispatchPlanParser.validationFailures(
                        content: last.content,
                        availableProfileIDs: availableProfiles
                    )
                }
                guard failures.isEmpty else {
                    return requestAgentGoalPhasePlanCorrection(
                        for: runtime,
                        failures: failures,
                        requiresDispatchGraph: requiresDispatchGraph
                    )
                }
                var executable = parsed
                executable.status = .approved
                runtime.currentPlan = executable
                if requiresDispatchGraph,
                   let dispatchPlan = AgentGoalDispatchPlanParser.extract(
                       from: last.content,
                       availableProfileIDs: availableProfiles,
                       namespace: runtime.id.uuidString
                   ),
                   var goal = runtime.currentGoal {
                    goal.dispatchPlan = dispatchPlan
                    runtime.currentGoal = goal
                }
                if var roadmap = runtime.goalRoadmap,
                   roadmap.phases.indices.contains(roadmap.activePhaseIndex) {
                    roadmap.phases[roadmap.activePhaseIndex].status = .executing
                    runtime.goalRoadmap = roadmap
                }
                runtime.goalTurnRecoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint()
                return .captured
            }
            if runtime.goalPlanningState?.phase == .readyForProposal {
                let requiresDispatchGraph = runtime.session.presentationScope == .dispatchBoard
                let availableProfiles = requiresDispatchGraph
                    ? Set(runtime.currentGoal?.selectedWorkerProfileIDs
                        ?? [AgentExecutionProfile.recommendedWorkerID])
                    : nil
                let failures = AgentGoalPlanProposalValidator.validationFailures(
                    content: last.content,
                    plan: parsed,
                    generationID: runtime.goalPlanningState?.generationID,
                    requiresRoadmap: true,
                    requiresDispatchGraph: requiresDispatchGraph,
                    availableProfileIDs: availableProfiles
                )
                if failures.isEmpty {
                    guard let acceptanceCriteria = AgentGoalAcceptanceCriteriaParser.extract(
                        from: last.content
                    ) else {
                        return requestAgentGoalProposalCorrection(
                            for: runtime,
                            failures: ["the Goal acceptance contract could not be parsed after validation"]
                        )
                    }
                    guard let roadmap = AgentGoalRoadmapParser.extract(from: last.content) else {
                        return requestAgentGoalProposalCorrection(
                            for: runtime,
                            failures: ["the Goal roadmap could not be parsed after validation"]
                        )
                    }
                    var executable = parsed
                    executable.status = .approved
                    runtime.currentPlan = executable
                    runtime.goalRoadmap = roadmap
                    if let goal = runtime.currentGoal {
                        runtime.currentGoal = AgentGoalAcceptanceCriteriaParser.reconcile(
                            goal,
                            with: acceptanceCriteria
                        )
                    }
                    if requiresDispatchGraph,
                       let dispatchPlan = AgentGoalDispatchPlanParser.extract(
                           from: last.content,
                           availableProfileIDs: availableProfiles,
                           namespace: runtime.id.uuidString
                       ),
                       var goal = runtime.currentGoal {
                        goal.dispatchPlan = dispatchPlan
                        runtime.currentGoal = goal
                    }
                    if var state = runtime.goalPlanningState {
                        state.phase = .executing
                        runtime.goalPlanningState = state
                    }
                    if runtime.goalTurnRecoveryCheckpoint == nil {
                        runtime.goalTurnRecoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint()
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
           existing.status == .proposed
            || existing.status == .approved
            || existing.status == .executing
            || existing.status == .done {
            applyAgentPlanProgressFromLatestMessage(for: runtime, existingPlan: existing)
        }
        return .noProposal
    }

    func applyAgentPlanProgressFromLatestMessage(for runtime: AgentRuntime, existingPlan: AgentPlan) {
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if var next = AgentPlanParser.applyProgress(to: existingPlan, from: last.content) {
            // A progress report against an interrupted plan is the model
            // resuming it (the interrupted-plan prompt only allows progress
            // blocks on resume) — restore it as the execution contract.
            next.interruptedAt = nil
            runtime.currentPlan = next
        }
    }

    /// Convenience wrapper that targets `activeRuntime`.
    func captureAgentGoalEvaluationFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        _ = captureAgentGoalEvaluationFromLatestMessage(for: runtime)
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
        runtime.goalRoadmap = nil
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

    @discardableResult
    func captureAgentGoalEvaluationFromLatestMessage(
        for runtime: AgentRuntime,
        finishReason: String? = nil
    ) -> Bool {
        guard runtime.interactionMode == .goal,
              let goal = runtime.currentGoal,
              !goal.checklist.isEmpty else { return false }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            return false
        }
        if let editedAt = runtime.currentGoalEditedAt,
           last.createdAt < editedAt {
            return false
        }
        if let updated = AgentGoalChecklistParser.applyEvaluation(
            to: goal,
            from: last.content,
            finishReason: finishReason
        ) {
            runtime.currentGoal = updated
            persistAgentSession(runtime: runtime)
            return true
        }
        return false
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
        if plan.status == .done, let runtime = activeRuntime {
            if !advanceAgentGoalRoadmapIfNeeded(for: runtime) {
                prepareNextAgentGoalPlanningCycleIfNeeded(for: runtime)
            }
        }
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
        guard var plan = agentCurrentPlan,
              let startIdx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        for i in startIdx..<plan.steps.count {
            plan.steps[i].status = .pending
        }
        // Plan stays approved/executing — we're not redoing the
        // approval gate, just rewinding the execution head. "Run from
        // here" is also an explicit resume, so it lifts any interruption.
        if plan.status == .done { plan.status = .executing }
        plan.interruptedAt = nil
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

    /// Update only the user-authored objective. Acceptance criteria stay
    /// host-owned and are reconciled by the next Goal Teams proposal.
    func setAgentGoalStatement(_ statement: String) {
        let existingItems = activeRuntime?.currentGoal?.checklist.map(\.text) ?? []
        setAgentGoal(statement: statement, items: existingItems)
    }

    /// Replace the internal Goal definition. Empty values clear it.
    /// Preserves existing checklist `done` state when an AI-authored
    /// acceptance criterion remains unchanged across planning rounds.
    func setAgentGoal(
        statement: String,
        items: [String],
        planningProfileID: String? = nil,
        planningFallbackProfileIDs: [String] = [],
        selectedWorkerProfileIDs: [String]? = nil
    ) {
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
            runtime.goalRoadmap = nil
            runtime.goalTurnRecoveryCheckpoint = nil
            if previousGoal != nil {
                runtime.currentGoalEditedAt = Date()
            }
            persistActiveAgentSession()
            enqueueGoalUpdateNoticeIfNeeded(for: runtime, previousGoal: previousGoal, updatedGoal: nil)
            return
        }
        guard runtime.workspaceLocation != nil
                || (runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
            runtime.errorMessage = L10n.Dispatch.workspaceRequired
            return
        }
        if runtime.session.presentationScope == .dispatchBoard,
           let location = runtime.workspaceLocation
                ?? runtime.workspaceRootPath.map({ .local(path: $0) }) {
            agentDispatchCoordinator.synchronize(with: agentSessions)
            let ownProject = agentDispatchCoordinator.goals.first {
                $0.sessionID == runtime.id
            }
            if ownProject?.isPaused != true,
               let conflict = agentDispatchCoordinator.activeGoal(
                    for: location,
                    excluding: runtime.id
               ) {
                runtime.errorMessage = L10n.Dispatch.projectAlreadyRunning(
                    conflict.statement.isEmpty ? conflict.title : conflict.statement
                )
                return
            }
        }
        var priorItemsByText: [String: AgentGoal.Item] = [:]
        for item in runtime.currentGoal?.checklist ?? [] {
            if priorItemsByText[item.text] == nil {
                priorItemsByText[item.text] = item
            }
        }
        let resolvedPlanningProfileID = planningProfileID
            ?? previousGoal?.planningProfileID
            ?? AgentExecutionProfile.recommendedPlannerID
        let resolvedPlanningFallbackProfileIDs = AgentDispatchPlannerSelection
            .normalizedFallbackProfileIDs(
                primaryProfileID: resolvedPlanningProfileID,
                fallbackProfileIDs: planningProfileID == nil
                    ? previousGoal?.planningFallbackProfileIDs ?? []
                    : planningFallbackProfileIDs
            )
        let updatedGoal = AgentGoal(
            statement: trimmedStatement,
            checklist: trimmedItems.map { text in
                if let prior = priorItemsByText[text] {
                    return AgentGoal.Item(id: prior.id, text: text, done: prior.done)
                }
                return AgentGoal.Item(text: text)
            },
            planningProfileID: resolvedPlanningProfileID,
            planningFallbackProfileIDs: resolvedPlanningFallbackProfileIDs,
            planningAttemptedProfileIDs: previousGoal?.planningAttemptedProfileIDs,
            selectedWorkerProfileIDs: selectedWorkerProfileIDs
                ?? previousGoal?.selectedWorkerProfileIDs
                ?? [AgentExecutionProfile.recommendedWorkerID]
        )
        runtime.currentGoal = updatedGoal
        if previousGoal != updatedGoal {
            if let state = runtime.goalPlanningState {
                agentSubagentRegistry.cancelGoalPlanningRuns(Set(state.members.compactMap(\.runID)))
            }
            runtime.currentGoalEditedAt = Date()
            runtime.currentPlan = nil
            runtime.goalPlanningState = nil
            runtime.goalRoadmap = nil
            runtime.goalTurnRecoveryCheckpoint = nil
        }
        persistActiveAgentSession()
        if runtime.session.presentationScope == .dispatchBoard,
           agentPrimaryDestination == .dispatchBoard {
            agentDispatchCoordinator.synchronize(with: agentSessions)
            agentDispatchCoordinator.selectGoal(runtime.id)
            agentPrimaryDestination = .dispatchBoard
        }
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

    /// Stop the newest in-flight turn while preserving streamed output. Work
    /// started by older turns is deliberately out of scope: a long-lived dev
    /// server must not die because the user interrupted a later answer.
    func stopAgentResponse() {
        guard let runtime = activeRuntime else { return }
        stopAgentResponse(for: runtime)
    }

    /// Stop pressed while an ordinary-mode plan was the active execution
    /// contract → the plan is paused, not deleted. Marking it interrupted
    /// releases the contract so the user's next message can start a
    /// different task instead of being pulled back to the old plan (system
    /// prompt, capture guard, delegated-task rewrite, and auto-continuation
    /// all key off this). Goal mode keeps its own recovery machinery.
    private func markCurrentPlanInterruptedByUser(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .normal,
              var plan = runtime.currentPlan,
              plan.status == .approved || plan.status == .executing,
              !plan.isInterrupted else { return }
        plan.interruptedAt = Date()
        runtime.currentPlan = plan
    }

    /// Targeted stop used by the Goal dispatch console. Unlike switching the
    /// selected conversation first, this preserves the user's place in the
    /// console and interrupts only the runtime that owns the selected Goal.
    ///
    /// `pausingOwningDispatchProject` exists for the board's per-node Stop.
    /// Stopping from a chat transcript has no idea which node it is halting,
    /// so it parks the whole project; `stopDispatchTask(goalID:taskID:)`
    /// knows exactly one node and records the outcome itself, and must not
    /// take the project's other nodes down with it.
    func stopAgentResponse(
        for runtime: AgentRuntime,
        pausingOwningDispatchProject: Bool = true
    ) {
        if pausingOwningDispatchProject,
           let projectID = runtime.session.dispatchParentProjectID,
           let taskID = runtime.session.dispatchTaskID {
            // Stop means stop for an unattended dispatch node as well. Without
            // persisting this project-level pause, reopening the board would
            // attach a fresh monitor and quietly continue the task.
            _ = agentDispatchCoordinator.setPaused(true, goalID: projectID)
            agentDispatchCoordinator.updateTaskState(
                goalID: projectID,
                taskID: taskID,
                state: .reviewing
            )
        }
        if let activeTurnID = runtime.activeTurnID,
           runtime.userStoppedTurnID == activeTurnID {
            return
        }
        if runtime.goalTurnRecoveryCheckpoint != nil {
            runtime.goalTurnRecoveryCheckpoint = nil
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        }
        // A request waiting for a provider slot has no requestTask to cancel,
        // but the composer deliberately exposes the same Stop affordance. Drop
        // every queued dispatch owned by this runtime so a stopped request
        // cannot unexpectedly start when another turn releases its slot.
        if runtime.isAwaitingProviderSlot, !runtime.isResponding {
            pendingDispatchQueue.removeAll { $0.runtimeID == runtime.id }
            runtime.isAwaitingProviderSlot = false
            runtime.errorMessage = nil
            runtime.errorDetails = nil
            runtime.errorSeverity = .error
            runtime.errorRequiresSomeIMLogin = false
            markCurrentPlanInterruptedByUser(for: runtime)
            _ = appendStoppedTurnEvent(to: runtime, content: L10n.Composer.stopped)
            return
        }
        let stoppedTurnID = runtime.activeTurnID
        let stoppedTurnStartedAt = runtime.turnStartedAt
        let activeWorkflowIDs = runtime.messages.compactMap { message -> UUID? in
            guard let report = message.workflowReport,
                  report.status == .planning || report.status == .running else { return nil }
            if let stoppedTurnStartedAt, report.startedAt < stoppedTurnStartedAt {
                return nil
            }
            return report.id
        }
        for reportID in activeWorkflowIDs {
            cancelWorkflow(reportID: reportID, runtimeID: runtime.id)
        }
        guard runtime.isResponding else { return }

        markCurrentPlanInterruptedByUser(for: runtime)

        let subagentStopCount: Int
        let liveJobs: [AgentBackgroundJob]
        if let stoppedTurnID {
            subagentStopCount = agentSubagentRegistry.cancelRunning(
                forParentRuntime: runtime.id,
                originatingTurnID: stoppedTurnID
            )
            liveJobs = agentJobRegistry.aliveJobs(
                forRuntime: runtime.id,
                originatingTurnID: stoppedTurnID
            )
            runtime.userStoppedTurnID = stoppedTurnID
        } else {
            subagentStopCount = 0
            liveJobs = []
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.errorSeverity = .error
        runtime.errorRequiresSomeIMLogin = false
        let immediateStoppedCount = activeWorkflowIDs.count + subagentStopCount
        let eventContent: String
        if liveJobs.isEmpty {
            eventContent = immediateStoppedCount > 0
                ? L10n.Composer.stoppedAndCleanedUp(immediateStoppedCount)
                : L10n.Composer.stopped
        } else {
            eventContent = L10n.Composer.stoppedCheckingProcesses(liveJobs.count)
        }
        let stopEventID = appendStoppedTurnEvent(to: runtime, content: eventContent)

        closeBlockingAgentToolDecision(for: runtime, reason: "Response stopped")
        runtime.shouldConsumeQueueAfterStop = !runtime.queuedMessages.isEmpty
        runtime.requestTask?.cancel()
        scheduleQueuedMessageConsumptionAfterCancellation(for: runtime)

        if !liveJobs.isEmpty, let stoppedTurnID {
            let candidates = liveJobs.map {
                AgentStopJobCandidate(
                    id: $0.id,
                    displayHandle: $0.displayHandle,
                    command: $0.command
                )
            }
            let latestRequest = runtime.messages.last(where: { $0.isOperatorInput })?.content ?? ""
            startStoppedTurnProcessCleanup(
                runtime: runtime,
                turnID: stoppedTurnID,
                eventID: stopEventID,
                candidates: candidates,
                configuration: runtime.activeTurnConfiguration,
                userRequest: latestRequest,
                alreadyStoppedCount: immediateStoppedCount
            )
        }
    }

    // 返回内部 Task 供测试显式 await 完成信号(满载并行时盲轮询等不到
    // fallback 扫描跑完);生产调用方直接忽略返回值,行为不变。
    @discardableResult
    func scheduleQueuedMessageConsumptionAfterCancellation(
        for runtime: AgentRuntime,
        fallbackPollAttempts: Int = 20,
        fallbackPollIntervalNanoseconds: UInt64 = 150_000_000
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak runtime] in
            for _ in 0..<fallbackPollAttempts {
                if fallbackPollIntervalNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: fallbackPollIntervalNanoseconds)
                } else {
                    await Task.yield()
                }
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
            runtime.activeTurnID = nil
            runtime.activeTurnConfiguration = nil
            runtime.userStoppedTurnID = nil
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
        var snapshots = agentUsageSnapshots
        if let index = snapshots.firstIndex(where: { $0.id == session.id }) {
            snapshots.remove(at: index)
        }
        // The array stays sorted most-recent-first, so a single ordered
        // insert replaces the previous full re-sort. Mutating a local copy
        // publishes one change per upsert instead of one per array edit.
        let destination = snapshots.firstIndex { $0.updatedAt < snapshot.updatedAt }
            ?? snapshots.count
        snapshots.insert(snapshot, at: destination)
        agentUsageSnapshots = snapshots
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
        let defaultProvider = agentProviderLibrary.active
        // Bind the owning project at creation. Without this the fresh
        // session groups by its raw path and the sidebar shows a second
        // group with the project's name until the next project CRUD
        // triggers rebindAgentSessionsToProjects().
        let sessionRootPath = rootDirectory?.standardizedFileURL.path
        let session = AgentSession(
            workspaceRootPath: sessionRootPath,
            workspaceLocation: sessionRootPath.map { WorkspaceLocation.local(path: $0) },
            projectID: AgentProjectResolver.project(for: sessionRootPath, in: agentProjects)?.id,
            modelID: defaultModelID,
            providerEntryID: defaultProvider?.id,
            providerID: defaultProvider?.providerID,
            providerDisplayName: defaultProvider?.displayName,
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
        let defaultProvider = agentProviderLibrary.active
        // Same at-creation project binding as startNewAgentSession() — the
        // sidebar "+" on a project group hands over the project's primary
        // folder path, and the new session must land in that project's
        // group, not in a freshly-minted path group with the same name.
        let session = AgentSession(
            workspaceRootPath: normalizedPath,
            workspaceLocation: normalizedPath.map { WorkspaceLocation.local(path: $0) },
            projectID: AgentProjectResolver.project(for: normalizedPath, in: agentProjects)?.id,
            modelID: defaultModelID,
            providerEntryID: defaultProvider?.id,
            providerID: defaultProvider?.providerID,
            providerDisplayName: defaultProvider?.displayName,
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
    func selectAgentSession(
        id: AgentSession.ID,
        preservingPrimaryDestination: Bool = false
    ) -> Bool {
        if !preservingPrimaryDestination {
            agentPrimaryDestination = .conversation
        }
        guard let targetSession = agentSessions.first(where: { $0.id == id }) else { return false }
        guard activeAgentSessionID != id else {
            // A previous switch may have selected the row just after a lazy
            // runtime was created but before cache eviction completed. Heal
            // that already-highlighted row on the next click instead of
            // returning success while the transcript delegates read nil and
            // render the new-chat dashboard.
            guard runtime(for: id) != nil else {
                agentSessionLoadFailure = AgentSessionLoadFailure(
                    id: targetSession.id,
                    title: targetSession.title
                )
                return false
            }
            agentSessionLoadFailure = nil
            subscribeToActiveRuntime()
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
        for url in agentWorkspaceRoots(for: session) {
            // Already validated + security-scoped this Project folder on an
            // earlier switch. A Project may contain several repositories.
            if securityScopedAccessURLs.contains(url) { continue }
            guard Self.isExistingDirectory(url) else { continue }
            _ = activateSecurityScope(for: url)
        }
    }

    /// Lazy lookup: returns the existing runtime for `sessionID` or
    /// builds one on demand from the persisted session list. Used by
    /// the session lifecycle hooks below to make sure every selected
    /// session has a runtime entry sitting in `agentRuntimes`. Returns
    /// nil only when the session id doesn't exist anymore (e.g. it was
    /// just deleted on disk).
    @discardableResult
    func runtime(for sessionID: AgentSession.ID) -> AgentRuntime? {
        if let existing = agentRuntimes[sessionID] {
            if existing.isUnattendedDispatchTask {
                _ = autoApplyPendingAgentPatchProposals(for: existing, source: .dispatchTask)
            }
            return existing
        }
        guard let session = materializeAgentSessionIfNeeded(id: sessionID) else { return nil }
        let runtime = AgentRuntime(session: session)
        agentRuntimes[sessionID] = runtime
        if runtime.isUnattendedDispatchTask {
            _ = autoApplyPendingAgentPatchProposals(for: runtime, source: .dispatchTask)
        }
        startAgentKnowledgeFolderWatchers(for: runtime)
        // The caller still needs this runtime after we return. In particular,
        // selectAgentSession flips activeAgentSessionID only after this method
        // succeeds. Without temporary protection an older conversation can be
        // the first cache entry evicted here, leaving a highlighted sidebar
        // row whose transcript reads from a missing runtime.
        evictInactiveAgentRuntimesIfNeeded(protecting: sessionID)
        return runtime
    }

    @discardableResult
    private func materializeAgentSessionIfNeeded(id: AgentSession.ID) -> AgentSession? {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return nil }
        guard agentSessionIsMetadataOnly(id) else {
            return agentSessions[index]
        }
        guard let fullSession = AgentSessionStore.load(id: id) else {
            return nil
        }
        agentSessions[index] = fullSession
        clearAgentSessionMetadataOnlyFlag(id)
        return fullSession
    }

    private func evictInactiveAgentRuntimesIfNeeded(
        protecting additionalProtectedID: AgentSession.ID? = nil
    ) {
        let maximumIdleRuntimes = 6
        var protectedIDs = Set([activeAgentSessionID].compactMap { $0 })
        if let additionalProtectedID {
            protectedIDs.insert(additionalProtectedID)
        }
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
            AgentEmbeddedBrowserController.release(for: runtime.id)
            agentRuntimes.removeValue(forKey: runtime.id)
        }
    }

    func deleteAgentSession(id: AgentSession.ID) {
        let persistedImages = agentRuntimes[id]?.messages.flatMap(\.images)
            ?? AgentSessionStore.load(id: id)?.messages.flatMap(\.images)
            ?? []
        // If the doomed session is currently mid-turn, cancel its
        // in-flight work before tearing down the runtime so the URL
        // session task and tool-decision waiter don't leak. The
        // turn loop's defer will release the provider slot when the
        // cancellation propagates.
        if let doomed = agentRuntimes[id] {
            doomed.requestTask?.cancel()
            for cleanupTask in doomed.stopCleanupTasks.values {
                cleanupTask.cancel()
            }
            doomed.stopCleanupTasks.removeAll()
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
        persistedImages.forEach { $0.removeStoredFileIfNeeded() }
        agentSessions.removeAll { $0.id == id }
        removeAgentUsageSnapshot(id: id)
        cancelAgentKnowledgeFolderWatchers(sessionID: id)
        AgentEmbeddedBrowserController.release(for: id)
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
        let routineProvider = agentProviderLibrary.active
        let session = AgentSession(
            workspaceRootPath: routine.workspaceRootPath,
            modelID: routine.modelID?.isEmpty == false
                ? routine.modelID
                : agentConfiguration.normalized.model(for: .interactive),
            providerEntryID: routineProvider?.id,
            providerID: routineProvider?.providerID,
            providerDisplayName: routineProvider?.displayName
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

        let startedAt = Date()
        agentRoutines[index].lastRunAt = startedAt
        agentRoutines[index].lastSessionID = session.id
        agentRoutines[index].updatedAt = startedAt
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)
        agentRoutineRuns.insert(
            AgentRoutineRunRecord(
                routineID: routine.id,
                routineName: routine.name,
                sessionID: session.id,
                startedAt: startedAt
            ),
            at: 0
        )
        agentRoutineRuns = AgentRoutineRunHistory.recent(
            agentRoutineRuns,
            limit: AgentRoutineRunHistory.maximumStoredRuns
        )
        AgentRoutineRunStore.save(agentRoutineRuns)

        // Scheduled runs have no operator watching their terminal. Give the
        // model a durable least-side-effect execution contract so diagnostic
        // routines naturally choose the statically approvable path (for
        // example, stream journalctl output over SSH instead of creating
        // remote /tmp files). Explicitly requested mutations still go through
        // the normal approval boundary.
        let unattendedGuidance = """
        [周期任务 · 无人值守执行边界]
        本次运行来自后台周期任务。优先使用只读工具和只读命令完成分析；远程日志巡检应直接读取并流式筛选 journalctl/systemctl 输出，不要为了分析创建远端临时文件，也不要重启服务、修改配置、改变权限或删除数据。只有原任务明确要求产生外部副作用时才可提出相应操作；无法在安全边界内完成时，请在结果中说明具体阻塞原因，不要等待无人值守的交互确认。
        """

        // Goal-bearing tasks self-complete: tell this run to evaluate the goal
        // and, if met, call complete_scheduled_task with its own id so the task
        // (and its card) disappears. Plain routines receive the same unattended
        // execution boundary after their saved prompt.
        let dispatchText: String
        if let goal = routine.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            dispatchText = """
            \(prompt)

            \(unattendedGuidance)

            [定时任务 · 自完成判定] 本次运行来自定时任务「\(routine.name)」(task_id: \(routine.id.uuidString))。
            目标:\(goal)
            完成上述工作后,判断该目标是否已达成:
            - 已达成 → 调用 complete_scheduled_task 工具(task_id 传 \(routine.id.uuidString)),移除这个定时任务;它将不再运行,卡片也会消失。
            - 未达成 → 正常简短汇报当前进展即可,不要调用 complete_scheduled_task。
            """
        } else {
            dispatchText = """
            \(prompt)

            \(unattendedGuidance)
            """
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
        let previousModel = previousModelForNotice ?? activeAgentModelSelectionLabel
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard activeAgentProviderEntry?.isUsableForChatSelection(
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
        guard let active = activeAgentProviderEntry,
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
    /// pair in one shot. The provider is pinned only to the current
    /// conversation, leaving the Settings-wide default and other sessions
    /// unchanged. Picking a model
    /// that already matches the route default clears the override so
    /// the chip falls back to displaying the routed name.
    func selectAgentEntryAndModel(entryID: UUID, model: String) {
        let previousModel = activeAgentModelSelectionLabel
        materializeProviderLibraryEntryAPIKey(id: entryID)
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard let entry = agentProviderLibrary.entries.first(where: { $0.id == entryID }),
              entry.isUsableForChatSelection(isSomeIMAuthenticated: authenticated) else {
            return
        }
        ensureActiveAgentSessionForInteractiveControl()
        guard let runtime = activeRuntime else { return }
        runtime.sessionProviderEntryID = entry.id
        runtime.sessionProviderIDOverride = entry.providerID
        runtime.session.providerEntryID = entry.id
        runtime.session.providerID = entry.providerID
        runtime.session.providerDisplayName = entry.displayName
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setAgentSessionModel(nil, previousModelForNotice: previousModel)
            return
        }
        // If the chosen model is already what the route would pick by
        // default, clear the override so the picker shows the natural
        // "Use route default" state instead of a redundant lock.
        let routed = entry.makeConfiguration(
            imageDescription: agentConfiguration.imageDescription
        ).normalized.model(for: .interactive)
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
        guard let someIMEntry = agentProviderLibrary.entries.first(where: {
            $0.providerID == AgentProviderPreset.someIMID
        }) else { return }
        // Model choice comes before workspace choice in the composer. Keep that
        // order valid by creating an empty, workspace-less conversation now;
        // moveActiveAgentSessionToWorkspace will preserve it when a folder is
        // selected later.
        if activeRuntime == nil {
            startNewAgentSession(inWorkspaceAt: nil)
        }
        guard let runtime = activeRuntime else { return }
        runtime.sessionProviderEntryID = someIMEntry.id
        runtime.sessionProviderIDOverride = someIMEntry.providerID
        runtime.session.providerEntryID = someIMEntry.id
        runtime.session.providerID = someIMEntry.providerID
        runtime.session.providerDisplayName = someIMEntry.displayName
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
    func defaultSomeIMManagedRoutingState() -> AgentManagedRoutingState? {
        guard SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults(),
              agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID,
              AgentSettingsStore.loadDefaultModelModePreference().usesManagedRoutingForNewSessions else {
            return nil
        }
        return AgentManagedRoutingState()
    }

    func defaultAgentModelIDForNewSession(
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
        return agentConfiguration.normalized.model(for: .interactive)
    }

    /// Rebuild the runtime-only model override from the persisted session.
    /// Launch recovery uses the same path as an explicit sidebar selection so
    /// a background-resumed Goal continues on its original concrete model.
    func seedPersistedSessionModelOverride(for runtime: AgentRuntime) {
        guard runtime.managedRouting == nil else {
            runtime.sessionModelOverride = nil
            return
        }
        let routedModel = configurationForCurrentTurn(for: runtime).model(for: .interactive)
        runtime.sessionModelOverride = runtime.session.modelID == routedModel
            ? nil
            : runtime.session.modelID
    }

    private func adoptSomeIMManagedRoutingForEmptySessionIfNeeded() {
        guard let runtime = activeRuntime,
              runtime.isEmpty,
              !runtime.isResponding,
              runtime.managedRouting == nil,
              runtime.sessionProviderIDOverride == nil,
              runtime.sessionModelOverride == nil,
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

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
/// On-disk shape of the Debug provider-seed JSON. Only `apiBase` / `apiKey` /
/// `flashModel` are required; the rest are optional. Loaded by
/// `AppState.seedDevProviderIfNeeded()`.
private struct DevProviderSeedConfig: Decodable {
    var providerID: String?
    var displayName: String?
    var apiBase: String
    var apiKey: String
    var flashModel: String?
    var proModel: String?
    var routingMode: String?
    var setActive: Bool?
}
#endif

// MARK: - Import providers from other CLI agents' config files

/// Other local CLI agents whose provider config WillDeep can import, so a
/// dev/debug session can reuse an existing key without re-entering it.
enum ProviderImportSource: String, CaseIterable, Identifiable {
    case claudeCode
    case openclaw
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openclaw: return "openclaw"
        case .hermes: return "hermes"
        }
    }
}

/// One provider parsed out of an external tool's config, ready to upsert.
private struct ImportedProviderDraft {
    var displayName: String
    var providerID: String
    var baseURL: String
    var apiKey: String
    var flashModel: String
    var proModel: String
    var extraModels: [String] = []
    /// Optional caveat surfaced to the user (e.g. openclaw's ambiguous key).
    var note: String?
}

extension AppState {
    /// Import provider(s) from another CLI agent's local config into the library
    /// and activate the first one. Returns a short human summary for the UI.
    /// Never logs API keys.
    @discardableResult
    func importProviders(from source: ProviderImportSource) -> String {
        let drafts: [ImportedProviderDraft]
        switch source {
        case .claudeCode: drafts = Self.importDraftsFromClaudeCode()
        case .openclaw: drafts = Self.importDraftsFromOpenclaw()
        case .hermes: drafts = Self.importDraftsFromHermes()
        }
        guard !drafts.isEmpty else {
            return "\(source.displayName)：未找到可导入的 provider（配置缺失 base/key，或走 OAuth 登录）"
        }

        var activatedFirst = false
        for draft in drafts {
            let existing = agentProviderLibrary.entries.first {
                $0.providerID == draft.providerID
                    && $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == draft.baseURL
            }
            let entryID = existing?.id ?? UUID()
            let entry = AgentProviderEntry(
                id: entryID,
                providerID: draft.providerID,
                displayName: draft.displayName,
                baseURL: draft.baseURL,
                apiKey: draft.apiKey,
                flashPrimary: draft.flashModel,
                flashAlternates: draft.extraModels,
                proPrimary: draft.proModel.nonEmptyOrNil ?? draft.flashModel,
                proAlternates: [],
                routingMode: existing?.routingMode ?? .auto
            )
            agentProviderLibrary.upsert(entry)
            if !activatedFirst {
                agentProviderLibrary.setActive(entryID)
                if agentProviderLibrary.activeID == entryID {
                    applyActiveProviderLibraryEntry()
                }
                activatedFirst = true
            }
        }
        let note = drafts.compactMap(\.note).first.map { "（\($0)）" } ?? ""
        return "\(source.displayName)：已导入 \(drafts.count) 个 provider" + note
    }

    // MARK: parsers (each returns [] when the config is absent/unusable)

    private static func importDraftsFromHermes() -> [ImportedProviderDraft] {
        let env = parseDotenv(("~/.hermes/.env" as NSString).expandingTildeInPath)
        guard let key = env["ANTHROPIC_API_KEY"]?.nonEmptyOrNil else { return [] }
        let preset = AgentProviderPreset.preset(id: "claude")
        return [ImportedProviderDraft(
            displayName: "hermes · Claude",
            providerID: "claude",
            baseURL: env["ANTHROPIC_BASE_URL"]?.nonEmptyOrNil ?? preset?.baseURL ?? "",
            apiKey: key,
            flashModel: env["ANTHROPIC_SMALL_FAST_MODEL"]?.nonEmptyOrNil ?? preset?.defaultFlashModel ?? "",
            proModel: env["ANTHROPIC_MODEL"]?.nonEmptyOrNil ?? preset?.defaultProModel ?? ""
        )]
    }

    private static func importDraftsFromClaudeCode() -> [ImportedProviderDraft] {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any] else { return [] }
        func value(_ name: String) -> String? { (env[name] as? String)?.nonEmptyOrNil }
        guard let key = value("ANTHROPIC_API_KEY") ?? value("ANTHROPIC_AUTH_TOKEN") else { return [] }
        let preset = AgentProviderPreset.preset(id: "claude")
        return [ImportedProviderDraft(
            displayName: "Claude Code",
            providerID: "claude",
            baseURL: value("ANTHROPIC_BASE_URL") ?? preset?.baseURL ?? "",
            apiKey: key,
            flashModel: value("ANTHROPIC_SMALL_FAST_MODEL") ?? preset?.defaultFlashModel ?? "",
            proModel: value("ANTHROPIC_MODEL") ?? preset?.defaultProModel ?? ""
        )]
    }

    private static func importDraftsFromOpenclaw() -> [ImportedProviderDraft] {
        let jsonPath = ("~/.openclaw/openclaw.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any],
              let providers = models["providers"] as? [String: Any] else { return [] }
        // openclaw stores no per-provider key in the JSON; keys live in .env.
        // Best-effort: reuse the single .env key and flag it for the user.
        let env = parseDotenv(("~/.openclaw/.env" as NSString).expandingTildeInPath)
        let fallbackKey = env.values.compactMap(\.nonEmptyOrNil).first ?? ""

        return providers.sorted { $0.key < $1.key }.compactMap { name, raw -> ImportedProviderDraft? in
            guard let provider = raw as? [String: Any],
                  let base = (provider["baseUrl"] as? String)?.nonEmptyOrNil else { return nil }
            let modelIDs = ((provider["models"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["id"] as? String)?.nonEmptyOrNil }
            let flash = modelIDs.first ?? ""
            return ImportedProviderDraft(
                displayName: "openclaw · \(name)",
                providerID: AgentProviderPreset.customID,
                baseURL: base,
                apiKey: fallbackKey,
                flashModel: flash,
                proModel: modelIDs.count > 1 ? modelIDs[1] : flash,
                extraModels: Array(modelIDs.dropFirst()),
                note: fallbackKey.isEmpty
                    ? "openclaw 未存 key，请手动填写"
                    : "openclaw key 取自 .env，请核对是否匹配该 provider"
            )
        }
    }

    /// Minimal dotenv reader: `KEY=VALUE` per line, `#` comments, optional
    /// surrounding quotes stripped. Missing file → empty map.
    private static func parseDotenv(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in content.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
