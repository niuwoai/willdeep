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
    /// Why the history could not be materialized. The alert copy differs:
    /// a missing file asks for a backup restore, an unreadable one says the
    /// file is still there (and untouched) and carries the decode error.
    enum Reason: Equatable {
        case missing
        case unreadable(String)
    }

    let id: AgentSession.ID
    let title: String
    let reason: Reason

    static func probing(_ session: AgentSession) -> AgentSessionLoadFailure {
        let reason: Reason
        switch AgentSessionStore.storedSessionFileState(id: session.id) {
        case .undecodable(let error):
            reason = .unreadable(error)
        case .missing, .ok:
            // `.ok` only happens when a runtime failed to build for reasons
            // other than the file (eviction race); the missing-file wording
            // is the closest honest fallback the alert has.
            reason = .missing
        }
        return AgentSessionLoadFailure(id: session.id, title: session.title, reason: reason)
    }
}

/// Why the some.im provider is being reconciled against the shared session.
///
/// Only matters when the shared session reads back empty: that is either a real
/// sign-out or a read that raced a concurrent Keychain write, and the two are
/// indistinguishable at the read itself.
enum SomeIMReconcileTrigger {
    /// Launch, panel open, turn start, or a cross-app session notification.
    /// An empty read here is treated as suspect and re-checked before anything
    /// is destroyed.
    case routine
    /// This app just signed the user out. An empty read is the expected result
    /// and the provider entry is dropped immediately.
    case signOut
}

extension AppState {

    /// How long to wait before re-reading a shared session that came back empty.
    /// Comfortably longer than a Keychain delete+add window, short enough that a
    /// genuine sign-out still clears the provider promptly.
    static let someIMSignOutConfirmationDelay: TimeInterval = 0.6

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
        // Same two moments — launch and every save — decide whether the local
        // LLM is kept resident, so the keeper rides along here instead of
        // growing a second observer of the settings store.
        AgentLocalModelResidencyKeeper.shared.apply(settings: settings)
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
            flashAlternates: [],
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
    func reconcileSomeIMProviderFromSharedSession(
        trigger: SomeIMReconcileTrigger = .routine
    ) -> Bool {
        let outcome = SomeIMIntegrationStore.currentSessionOutcome()
        let apiKey = outcome.apiKey
        if apiKey.isEmpty {
            // The read never landed — missing entitlement, locked Keychain, busy
            // securityd, a payload from a newer schema. It says nothing about
            // whether the user is signed in, so it may not drive anything
            // destructive. Leave everything alone and let the next read decide.
            guard outcome != .unavailable else { return false }

            switch trigger {
            case .signOut:
                // The user signed out here. Empty is the expected answer.
                cancelSomeIMSignOutConfirmation()
                clearSomeIMProvider()
                ensureActiveProviderIsUsableForChatSelection()
            case .routine:
                // Confirmed-absent still is not proof of a sign-out: writes fall
                // back to `SecItemDelete` + `SecItemAdd`, and a reader landing
                // between the two sees a genuine "no such item". Meanwhile
                // `clearSomeIMProvider` deletes the library entry *and* its
                // Keychain row, and the rebuild draws a fresh UUID with default
                // settings — losing the user's tier models and routing mode,
                // orphaning per-session provider overrides, and blanking the
                // model picker. Too destructive to hang on one read. Confirm.
                scheduleSomeIMSignOutConfirmation()
            }
            return false
        } else {
            cancelSomeIMSignOutConfirmation()
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

    /// Re-reads the shared session after a short delay and only then, if it is
    /// still empty, drops the some.im provider. Bypasses the memo cache so the
    /// re-read actually reaches the Keychain rather than being served the same
    /// empty answer that got us here.
    ///
    /// A real sign-out stays empty and lands here a beat later; a read that
    /// merely raced a write resolves itself and the entry is left untouched.
    func scheduleSomeIMSignOutConfirmation() {
        // Nothing to protect — no entry to lose.
        guard agentProviderLibrary.entries.contains(where: {
            $0.providerID == AgentProviderPreset.someIMID
        }) else { return }
        // A confirmation is already in flight; let it finish.
        guard someIMSignOutConfirmationTask == nil else { return }

        someIMSignOutConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.someIMSignOutConfirmationDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.someIMSignOutConfirmationTask = nil
            SomeIMIntegrationStore.invalidateSharedSessionCache()
            let outcome = SomeIMIntegrationStore.currentSessionOutcome()
            let confirmed = outcome.apiKey
            if confirmed.isEmpty {
                // Still nothing — but only a confirmed absence may destroy the
                // entry. An unavailable re-read leaves it standing.
                guard outcome == .signedOut else { return }
                self.clearSomeIMProvider()
                self.ensureActiveProviderIsUsableForChatSelection()
            } else {
                self.syncSomeIMProvider(
                    settings: SomeIMIntegrationStore.loadSettings(),
                    apiKey: confirmed,
                    activate: false
                )
                self.syncSomeIMImageUnderstanding(apiKey: confirmed)
                self.ensureActiveProviderIsUsableForChatSelection()
            }
        }
    }

    func cancelSomeIMSignOutConfirmation() {
        someIMSignOutConfirmationTask?.cancel()
        someIMSignOutConfirmationTask = nil
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
            prompt = "Please revise the execution plan. Emit one complete replacement ```plan``` block only when at least \(AgentPlanOnDemandPolicy.minimumVisibleStepCount) independent execution steps remain; otherwise give a concise prose outline. Continue executing without waiting for plan approval."
        } else {
            prompt = """
            Please revise the plan with this guidance from me:

            \(trimmed)

            Emit one complete replacement ```plan``` block only when at least \(AgentPlanOnDemandPolicy.minimumVisibleStepCount) independent execution steps remain; otherwise give a concise prose outline. Continue executing without waiting for plan approval.
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
        guard last.origin != .hostGenerated else { return .noProposal }
        if runtime.interactionMode == .goal,
           runtime.goalPlanningState?.phase == .readyForProposal,
           let generationID = runtime.goalPlanningState?.generationID,
           !last.content.contains("<!-- goal-planning-generation:\(generationID.uuidString) -->") {
            return .noProposal
        }
        let extractionScope: AgentPlanParser.ExtractionScope = runtime.interactionMode == .goal
            ? .firstPhase
            : .entireBlock
        let minimumStepCount = runtime.interactionMode == .normal
            ? AgentPlanOnDemandPolicy.minimumVisibleStepCount
            : 1
        if let parsed = AgentPlanParser.extract(
            from: last.content,
            scope: extractionScope,
            minimumStepCount: minimumStepCount
        ) {
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
                    // The planning reply for this phase was asked to open with a
                    // `receipt` block for the phase that just closed. Fold its
                    // wording into the host's receipt; timing stays the host's.
                    let previousIndex = roadmap.activePhaseIndex - 1
                    if roadmap.phases.indices.contains(previousIndex),
                       let hostReceipt = roadmap.phases[previousIndex].receipt,
                       hostReceipt.author == .host,
                       let modelReceipt = AgentPhaseReceipt.parse(from: last.content) {
                        roadmap.phases[previousIndex].receipt = hostReceipt.refined(with: modelReceipt)
                    }
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
        // 扫描本回合的每一条助手消息，按时间顺序逐条应用（后报的状态覆盖
        // 先报的）。只看"最后一条非空助手消息"会漏掉回合中段的 progress
        // 块：模型常在两轮工具调用之间上报进度，而收尾那条是纯叙述——实测
        // 一个会话里 7 个 progress 块有 2 个正是这样被丢掉的。
        var next = existingPlan
        var didApply = false
        let settledByTool = runtime.planStepsSettledByToolThisTurn
        for message in assistantMessagesInLatestTurn(of: runtime) {
            var updates = AgentPlanParser.progressUpdates(in: message.content, plan: next)
            // `update_plan` reports made earlier in this turn win over a
            // fence that arrives later (LONG_HORIZON_AUTONOMY.md §4.3). The
            // realistic conflict is a closing recap assembled from a stale
            // mental model reverting a step the tool already closed. Steps
            // the tool never touched are untouched by this filter, so the
            // recap can still contribute everything else.
            if !settledByTool.isEmpty {
                updates = updates.filter { !settledByTool.contains($0.key) }
            }
            guard !updates.isEmpty else { continue }
            next = AgentPlanProgressApplier.apply(updates, to: next)
            didApply = true
        }
        guard didApply else { return }
        // A progress report against an interrupted plan is the model
        // resuming it (the interrupted-plan prompt only allows progress
        // blocks on resume) — restore it as the execution contract.
        next.interruptedAt = nil
        runtime.currentPlan = next
    }

    /// 当前回合内**已发出**的助手消息里，是否出现过"有 `progress` 围栏、却
    /// 一行都解析不出"的情况。为真时下一轮请求的系统提示词追加纠偏，把静默
    /// 失败变成可自愈的显式反馈。
    ///
    /// 作用窗口是回合内：一个回合里模型会多轮工具调用、每轮重新组装请求，
    /// 所以第一次发错格式后，下一轮就能收到纠偏，不必等到回合结束。任何
    /// 一条能解析的块都算模型守约，本回合不再纠偏。
    func latestTurnHasUnparsableProgressBlock(for runtime: AgentRuntime) -> Bool {
        guard let plan = runtime.currentPlan, !plan.steps.isEmpty else { return false }
        var sawProgressBlock = false
        for message in assistantMessagesInLatestTurn(of: runtime)
        where AgentPlanParser.containsProgressBlock(message.content) {
            sawProgressBlock = true
            if AgentPlanParser.applyProgress(to: plan, from: message.content) != nil {
                return false
            }
        }
        return sawProgressBlock
    }

    /// 本回合（最后一条用户消息之后）的非空助手消息，保持原始顺序。
    func assistantMessagesInLatestTurn(of runtime: AgentRuntime) -> [AgentMessage] {
        let messages = runtime.messages
        let start = messages.lastIndex { $0.role == .user }
            .map { messages.index(after: $0) } ?? messages.startIndex
        guard start < messages.endIndex else { return [] }
        return messages[start...].filter { $0.role == .assistant && !$0.content.isEmpty }
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
              last.origin != .hostGenerated,
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
        guard last.origin != .hostGenerated else { return false }
        if runtime.session.dispatchTaskID == nil {
            return captureNativeGoalCompletionCandidate(goal: goal, message: last, runtime: runtime, finishReason: finishReason)
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
            synchronizeDispatchBoard()
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
                    return AgentGoal.Item(id: prior.id, text: text, done: runtime.session.dispatchTaskID != nil && previousGoal?.statement == trimmedStatement && prior.done)
                }
                return AgentGoal.Item(text: text)
            },
            planningProfileID: resolvedPlanningProfileID,
            planningFallbackProfileIDs: resolvedPlanningFallbackProfileIDs,
            planningAttemptedProfileIDs: previousGoal?.planningAttemptedProfileIDs,
            selectedWorkerProfileIDs: selectedWorkerProfileIDs
                ?? previousGoal?.selectedWorkerProfileIDs
                ?? [AgentExecutionProfile.recommendedWorkerID],
            continuationBudget: previousGoal?.continuationBudget
        )
        runtime.currentGoal = updatedGoal
        runtime.goalAuthorizationRevision = UUID()
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
            synchronizeDispatchBoard()
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
        cancelPendingGoalLaunchRecovery(for: runtime)
        cancelGoalWakeForUserStop(runtime)
        runtime.goalAuthorizationRevision = UUID()
        if runtime.currentGoal?.taskAuthorizations != nil {
            runtime.currentGoal?.taskAuthorizations = nil
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        }
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
        let stopPersisted = runtime.activeTurnID.map {
            agentJobRegistry.revokeTurn(runtimeID: runtime.id, turnID: $0)
        } ?? true
        reconcileRevokedKernelDeliveries(for: runtime)
        defer {
            if !stopPersisted { runtime.errorMessage = L10n.JobReceipt.recoveryUnavailable }
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
            runtime.clearTurnError()
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

        let liveJobs: [AgentBackgroundJob]
        if let stoppedTurnID {
            _ = agentSubagentRegistry.cancelRunning(
                forParentRuntime: runtime.id,
                originatingTurnID: stoppedTurnID
            )
            liveJobs = agentJobRegistry.aliveJobs(
                forRuntime: runtime.id,
                originatingTurnID: stoppedTurnID
            )
            runtime.userStoppedTurnID = stoppedTurnID
        } else {
            liveJobs = []
        }

        runtime.clearTurnError()
        let stopEventID = appendStoppedTurnEvent(to: runtime, content: L10n.Composer.stopped)

        closeBlockingAgentToolDecision(for: runtime, reason: "Response stopped")
        runtime.shouldConsumeQueueAfterStop = !runtime.queuedMessages.isEmpty
        runtime.requestTask?.cancel()
        scheduleQueuedMessageConsumptionAfterCancellation(for: runtime)

        if !liveJobs.isEmpty, let stoppedTurnID {
            startStoppedTurnProcessCleanup(
                runtime: runtime,
                turnID: stoppedTurnID,
                eventID: stopEventID
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
        let turnID = runtime.activeTurnID
        let claimID = runtime.currentProviderSlotClaim?.id
        let cancellationRequested = runtime.isStoppingResponse || runtime.requestTask?.isCancelled == true
        return Task { @MainActor [weak self, weak runtime] in
            for _ in 0..<fallbackPollAttempts {
                if fallbackPollIntervalNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: fallbackPollIntervalNanoseconds)
                } else {
                    await Task.yield()
                }
                guard let self, let runtime else { return }
                guard runtime.activeTurnID == turnID,
                      runtime.currentProviderSlotClaim?.id == claimID,
                      cancellationRequested || runtime.shouldConsumeQueueAfterStop else { return }
                if !runtime.isResponding, runtime.requestTask == nil {
                    runtime.shouldConsumeQueueAfterStop = false
                    self.consumeNextQueuedMessageIfNeeded(for: runtime)
                    return
                }
            }
            guard let self, let runtime else { return }
            guard runtime.activeTurnID == turnID,
                  runtime.currentProviderSlotClaim?.id == claimID,
                  cancellationRequested || runtime.shouldConsumeQueueAfterStop,
                  runtime.isResponding else { return }
            let claim = runtime.currentProviderSlotClaim
            runtime.requestTask?.cancel()
            if let turnID {
                self.finalizeTurnTiming(for: runtime, turnID: turnID, outcome: "cancelled")
            }
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            runtime.activeTurnID = nil
            runtime.activeTurnConfiguration = nil
            if let turnID, runtime.userStoppedTurnID == turnID {
                self.noteAgentTurnEnded(for: runtime, turnID: turnID)
            }
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
        runtime.cancelToolDecisions(reason: reason)
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
        stageQueuedMessage(message, in: runtime)
    }

    /// Moves one queued direction into a fresh sidebar conversation while
    /// preserving the current task. The new chat opens with the message staged
    /// in its composer so the operator can review it before sending.
    func openQueuedAgentMessageInSideChat(id: AgentQueuedMessage.ID) {
        guard let sourceRuntime = activeRuntime,
              let index = sourceRuntime.queuedMessages.firstIndex(where: { $0.id == id })
        else { return }

        let message = sourceRuntime.queuedMessages.remove(at: index)
        let newSession = startNewAgentSession(
            inWorkspaceAt: sourceRuntime.session.workspaceRootPath
        )
        guard let destinationRuntime = agentRuntimes[newSession.id] else {
            sourceRuntime.queuedMessages.insert(message, at: index)
            return
        }
        stageQueuedMessage(message, in: destinationRuntime)
    }

    private func stageQueuedMessage(_ message: AgentQueuedMessage, in runtime: AgentRuntime) {
        // Queued text is the composed prompt; the prelude is rebuilt on send
        // from the restored pendingSkills.
        runtime.input = AgentAttachedPromptDisplay.composerText(of: message.text)
        runtime.pendingImages = message.images
        runtime.pendingTextAttachments = message.textAttachments
        runtime.pendingSkills = message.attachedSkills
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false
        runtime.executionAgent = message.executionAgent
        runtime.pendingDelegationPolicy = message.delegationPolicy
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
            activeRuntime?.clearTurnError()
            isAgentResponding = false
            agentTurnStartedAt = nil
            startNewAgentSession()
        }
    }

    func toggleAppMode() {
        setAppMode(appMode == .agent ? .editor : .agent)
    }

    func upsertAgentUsageSnapshot(for session: AgentSession) {
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
        AppStartupTimingLog.record(.usageDashboardRequested)
        let usageLoadStartedAt = Date()

        // `.userInitiated`, not `.utility`: nothing schedules this except a
        // user opening the stats panel, and until it lands the panel shows
        // zeroes. The scan itself now fans out across cores.
        let persisted = await Task.detached(priority: .userInitiated) {
            await AgentSessionStore.loadUsageSnapshotsConcurrently()
        }.value
        // 刻意不看 `Task.isCancelled`：扫描跑在 detached 任务里，面板消失也会
        // 跑完。以前在这里丢掉结果，用户切走再切回「新会话」就把全盘扫描
        // 重做一遍——这正是切到新会话 CPU 就涨的来源之一。算完的就收下。

        var snapshotsByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        for snapshot in agentUsageSnapshots {
            snapshotsByID[snapshot.id] = snapshot
        }
        agentUsageSnapshots = snapshotsByID.values.sorted { $0.updatedAt > $1.updatedAt }
        await refreshAgentCLIUsageRecords()
        hasLoadedAgentUsageSnapshots = true
        AppStartupTimingLog.record(
            .usageDashboardReady,
            durationSeconds: Date().timeIntervalSince(usageLoadStartedAt),
            count: agentUsageSnapshots.count
        )
    }

    private func removeAgentUsageSnapshot(id: AgentSession.ID) {
        agentUsageSnapshots.removeAll { $0.id == id }
    }

    /// Whether there is an open conversation to go back to.
    ///
    /// `activeAgentSessionID` alone is not enough — it can outlive the session
    /// it names (deleted from the sidebar, dropped by a catalog reload), and
    /// navigating to a conversation that no longer exists shows an empty shell.
    var hasResumableAgentConversation: Bool {
        guard let id = activeAgentSessionID else { return false }
        return agentSessions.contains { $0.id == id }
    }

    /// Whether the open conversation is still untouched — a chat that was
    /// started but never used. Starting a "new" one from here would produce
    /// something indistinguishable from what is already on screen.
    ///
    /// Deliberately ignores the composer draft: half-typed input means the
    /// chat is in use even with no messages committed yet, and replacing it
    /// would throw that text away.
    /// Checks both the live runtime and the stored session. Live messages are
    /// the truth for a chat in progress (`agentMessages` delegates to
    /// `activeRuntime`, and the session's own copy only catches up when it is
    /// persisted), while the stored copy covers a session whose runtime has not
    /// replayed its history yet. Either one non-empty means "in use" — erring
    /// toward creating a new chat rather than leaving the click doing nothing.
    var activeAgentConversationIsUnused: Bool {
        guard let id = activeAgentSessionID,
              let session = agentSessions.first(where: { $0.id == id }) else { return false }
        return agentMessages.isEmpty && session.messages.isEmpty
    }

    /// The sidebar's chat row. Context-dependent by design:
    ///
    /// - Away from the conversation, it means "take me back" — to the chat that
    ///   is already open, not a new one. Switching destinations never tore the
    ///   conversation down; the sidebar simply had no entry that meant "back to
    ///   it", so the only way in used to be "New Chat", which did exactly what
    ///   it said and left the previous conversation behind.
    /// - Already on the conversation, going back is a no-op, so the only thing
    ///   the click can mean is "start a new one".
    ///
    /// The one exception is an untouched chat: repeated clicks would otherwise
    /// pile up empty sessions in the sidebar, each identical to the last. There
    /// the click just returns focus to the composer, so it still does something.
    /// 侧栏首行的说法随场景变：在聊天页里它是「新会话」（点击开新的），
    /// 在调度台 / 插件这些页面里它是「会话」（点击回到最近那一次）。
    /// 行为一直是这么分叉的，这里只是把同一个判断挪到能被测到的地方。
    var agentConversationEntryTitle: String {
        agentPrimaryDestination == .conversation
            ? L10n.Sidebar.newSessionAction
            : L10n.Sidebar.sessionAction
    }

    func activateAgentConversationEntry() {
        agentSidePanelKind = nil
        agentSidePanelRequest = nil

        guard hasResumableAgentConversation else {
            startNewAgentSession()
            agentComposerFocusRevision += 1
            return
        }
        guard agentPrimaryDestination == .conversation else {
            agentPrimaryDestination = .conversation
            return
        }
        guard !activeAgentConversationIsUnused else {
            agentComposerFocusRevision += 1
            return
        }
        startNewAgentSession()
        agentComposerFocusRevision += 1
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
        // Deliberately NOT written to disk here — see the MARK block below.
        upsertAgentUsageSnapshot(for: session)
        refreshAgentGitWorktrees()
        return session
    }

    // MARK: - Why a brand-new session is not written to disk at creation
    //
    // Until 1.167.0-rc5 an empty "新对话" row was saved immediately and
    // `pruneEmptyAgentSessions()` garbage-collected the leftovers on the next
    // creation. That prune was removed because it could permanently delete a
    // session whose file merely failed to decode, and the replacement only hid
    // empty rows behind `AgentSidebarVisibility.visibleSessions`. Nothing
    // stopped them accumulating: on a real install 221 of 474 session files
    // (47%) were zero-message, workspace-less shells the user could neither
    // see nor delete, and every launch paid a stat + sidecar decode for each.
    //
    // Creating the row in memory and letting the FIRST real persist write it
    // removes the shells at the source without reintroducing a delete path —
    // a session that was never written cannot be lost by deleting it. Every
    // route that gives a session substance (a user message, a workspace
    // binding, a rename, a pin, being evicted from the runtime cache, being
    // switched away from) already funnels through `persistAgentSession`, which
    // calls `AgentRuntime.persist()` and saves unconditionally.
    //
    // The launch catalog merge in `AppState` treats in-memory sessions as
    // newer than disk on ID collision, so a session created while the catalog
    // is still loading survives the merge even with no file behind it.

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
    func startNewAgentSession(
        inWorkspaceAt workspacePath: String?,
        makeActive: Bool = true,
        presentationScope: AgentSessionPresentationScope = .workspace,
        dispatchParentProjectID: UUID? = nil,
        dispatchTaskID: UUID? = nil,
        isManagedBackgroundWorkspace: Bool = false
    ) -> AgentSession {
        if makeActive {
            agentPrimaryDestination = .conversation
        }
        let normalizedPath: String?
        if let workspacePath, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
            if Self.isExistingDirectory(url) {
                _ = activateSecurityScope(for: url)
                if !isManagedBackgroundWorkspace {
                    registerRecentFolder(url)
                }
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
            projectID: isManagedBackgroundWorkspace
                ? nil
                : AgentProjectResolver.project(for: normalizedPath, in: agentProjects)?.id,
            presentationScope: presentationScope,
            dispatchParentProjectID: dispatchParentProjectID,
            dispatchTaskID: dispatchTaskID,
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
        if makeActive {
            activeAgentSessionID = session.id
            subscribeToActiveRuntime()
            evictInactiveAgentRuntimesIfNeeded()
            agentSessionDidEditFiles = false
            agentInteractionMode = .normal
            agentApprovalMode = .smart
            agentCurrentPlan = nil
            agentCurrentGoal = nil
        } else {
            // Scheduler-owned sessions run in the background. Protect both the
            // new runtime and the operator's currently selected runtime from
            // cache eviction without redirecting the chat/composer to this
            // internal dispatch task.
            evictInactiveAgentRuntimesIfNeeded(protecting: session.id)
        }
        // Deliberately NOT written to disk here — see the MARK block above.
        //
        // Non-workspace scopes are the exception. A dispatch task or roundtable
        // seat is not "a chat the user might never type into": it represents
        // work already committed to by the orchestrator, it never reaches the
        // sidebar's empty-row filter, and it should survive a crash between
        // creation and its first turn. Empirically these are also not the
        // problem — of 266 zero-message files on the reference install, 7 were
        // dispatchBoard and 0 roundtable, against 220 workspace shells.
        if presentationScope != .workspace {
            // saveAsync, not save: sync save can beachball behind another
            // instance's NSFileCoordinator hold on the session directory.
            AgentSessionStore.saveAsync(session)
        }
        upsertAgentUsageSnapshot(for: session)
        if !isManagedBackgroundWorkspace {
            unhideWorkspace(key: session.workspaceSidebarGroupKey)
        }
        if makeActive {
            refreshAgentGitWorktrees()
        }
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
            confirmWorkspaceTrustIfNeeded(for: url)
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
                let owner = AgentProjectResolver.projectID(for: runtime.session, in: agentProjects)
                if runtime.session.projectID != owner {
                    runtime.session.projectID = owner
                    persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
                }
                unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
                return runtime.session
            }
        }

        if let runtime = activeRuntime, canRebindActiveRuntimeInPlace(runtime) {
            runtime.rebindWorkspace(to: url.path)
            runtime.worktreeChanges = .init()
            runtime.agentArtifactPaths = []
            persistAgentSession(runtime: runtime)
            agentWorktreeRecoveryState = .none
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
            sidebarWorkspaceRootPath: sidebarURL.path,
            recoveryInfo: Self.worktreeRecoveryInfo(
                worktreePath: worktreeURL.path,
                repositoryHint: sidebarURL
            )
        )
        runtime.worktreeChanges = .init()
        runtime.agentArtifactPaths = []
        persistAgentSession(runtime: runtime)
        agentWorktreeRecoveryState = .none
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
        if activeAgentSessionID == runtimeID {
            agentWorktreeRecoveryState = .none
        }
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
            agentWorktreeRecoveryState = .none
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
                agentSessionLoadFailure = .probing(targetSession)
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
            agentSessionLoadFailure = .probing(targetSession)
            return false
        }
        agentSessionLoadFailure = nil
        // Projects that predate folder trust have no answer on record. The
        // first time the user actually enters one is when to ask; doing it on
        // the catalog load instead would greet a launch with a queue of
        // prompts for every folder the app has ever seen.
        confirmWorkspaceTrustIfNeeded(
            forRoots: agentWorkspaceRoots(for: targetSession).filter { Self.isExistingDirectory($0) }
        )
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

    /// Selects a conversation and asks the left sidebar to reveal its row in
    /// the viewport centre. Kept as one operation so title-search callers do
    /// not accidentally emit a reveal for a session that failed to load.
    @discardableResult
    func selectAndRevealAgentSessionInSidebar(id: AgentSession.ID) -> Bool {
        guard selectAgentSession(id: id) else { return false }
        agentSidebarRevealRequest = AgentSidebarRevealRequest(target: .session(id))
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
    func materializeAgentSessionIfNeeded(id: AgentSession.ID) -> AgentSession? {
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

    func evictInactiveAgentRuntimesIfNeeded(
        protecting additionalProtectedID: AgentSession.ID? = nil
    ) {
        let maximumIdleRuntimes = 6
        var protectedIDs = Set([activeAgentSessionID].compactMap { $0 })
        if let additionalProtectedID {
            protectedIDs.insert(additionalProtectedID)
        }
        protectedIDs.formUnion(pendingDispatchQueue.map(\.runtimeID))
        protectedIDs.formUnion(titleSummarizationsInFlight)
        // A Goal waiting to resume is not idle; its wait lives on this runtime.
        protectedIDs.formUnion(agentRuntimes.values.filter { $0.currentGoal?.scheduledWake != nil }.map(\.id))
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
            guard !AgentDetachedPanelRegistry.shared.hasWindow(sessionID: runtime.id) else { continue }
            persistAgentSession(runtime: runtime)
            cancelAllWorkflows(for: runtime)
            agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
            cancelAgentKnowledgeFolderWatchers(sessionID: runtime.id)
            AgentDetachedPanelRegistry.shared.releaseSession(runtime.id)
            AgentEmbeddedBrowserController.release(for: runtime.id)
            agentRuntimes.removeValue(forKey: runtime.id)
        }
    }

    @discardableResult
    func deleteAgentSession(id: AgentSession.ID, removeFromStore: Bool = true) -> Bool {
        AgentGoalLaunchRecoveryCoordinator.shared.finish(id)
        AgentDetachedPanelRegistry.shared.releaseSession(id)
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
            for observer in doomed.stopCleanupObservers.values {
                observer.cancel()
            }
            doomed.stopCleanupObservers.removeAll()
            cancelAllWorkflows(for: doomed)
            doomed.cancelToolDecisions(reason: "Session deleted")
            doomed.pendingToolDecisions.removeAll()
        }
        // Orphaned background subagents must not keep burning tokens
        // for a session that no longer exists.
        agentSubagentRegistry.cancelAll(forParentRuntime: id)
        // Drop any not-yet-started dispatches queued for this session
        // so they don't fire after the session is gone.
        pendingDispatchQueue.removeAll { $0.runtimeID == id }

        if removeFromStore, !AgentSessionStore.delete(id: id) { return false }
        if removeFromStore {
            agentRuntimeKernel.removeEvents(for: id)
            agentExternalWakeRetryTasks.removeValue(forKey: id)?.cancel()
            agentKernelPreemptedRuntimeIDs.remove(id)
        }
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
        return true
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

    // MARK: - Model selection

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
        AgentModelContextWindowCatalog.merge(models)
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
        // 换模型会让 provider 的提示缓存作废，下一轮整段历史冷预填。切换那一刻
        // 看起来是免费的，代价一轮之后才到，用户没法把两件事连起来——所以在
        // 这里就说清楚。锚定 provider 报的 prompt_tokens：本地字符估算会把一个
        // 真实 58 万 token 的会话读到阈值以下，等于这句话永远不出现。
        let cacheWarning = AgentModelSwitchCachePolicy.cacheWarning(
            usedTokens: Self.providerAnchoredUsedTokens(
                messages: runtime.messages,
                contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID,
                contextSummaryInstalledAt: runtime.contextSummaryInstalledAt
            )
        )
        let notice = [L10n.AgentModelPicker.modelChanged(from: old, to: new), cacheWarning]
            .compactMap { $0 }
            .joined(separator: " ")
        runtime.messages.append(
            AgentMessage(
                role: .system,
                content: notice,
                transcriptEvent: .modelChanged
            )
        )
        persistActiveAgentSession()
        // 上报的是模型标识，不是界面上那个已本地化的名字——「省心托管」四个字
        // 进不了标识符字符集，也没法跨语言聚合。
        AgentTelemetry.recordModelSelected(
            providerID: runtime.sessionProviderIDOverride ?? agentConfiguration.providerID,
            model: runtime.managedRouting == nil ? new : "managed",
            surface: .picker
        )
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
