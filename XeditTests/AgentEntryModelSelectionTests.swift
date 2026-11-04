//
//  AgentEntryModelSelectionTests.swift
//  WillDeepTests
//
//  Covers AppState.selectAgentEntryAndModel — the one-shot picker
//  primitive used by the chat-mode two-level model menu. Tests run on
//  the main actor because AppState is MainActor-isolated.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEntryModelSelectionTests {
    /// Per-test sandbox handle. Initialise at the top of each `@Test`
    /// function with `let _sandbox = installKeychainSandbox()` and let
    /// it deinit at scope end — `KeychainSandbox.deinit` wipes the
    /// override-service rows and restores the production service name
    /// so a later test, or the running dev app, never sees fixtures.
    private func installKeychainSandbox() -> KeychainSandbox {
        KeychainSandbox()
    }

    /// Returns an AppState seeded with two distinct library entries:
    /// an OpenAI one (active by default) and a DeepSeek one. Tests
    /// then exercise selectAgentEntryAndModel against this setup.
    ///
    /// Caller MUST hold a live `KeychainSandbox` before invoking — the
    /// `agentProviderLibrary` assignment below fires `@Published`
    /// didSet → `AgentSettingsStore.saveProviderLibrary` → real
    /// Keychain write. Without the sandbox those rows land under the
    /// production service name and show up in the running Settings UI
    /// on developer machines.
    private func makeAppStateWithTwoEntries(
        startSession: Bool = true
    ) -> (AppState, AgentProviderEntry, AgentProviderEntry) {
        let app = AppState()
        // NB: assigning `app.agentProviderLibrary = …` below fires its
        // didSet, which writes each entry's apiKey into Keychain. The
        // sandbox above redirects writes to a per-run service name so
        // fixtures never touch the production keychain — but keep them
        // clearly synthetic anyway so a leaked write is obvious.
        let openai = AgentProviderEntry(
            providerID: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            apiKey: "test-fixture-openai-key",
            flashPrimary: "gpt-4.1-mini",
            flashAlternates: ["gpt-4o-mini"],
            proPrimary: "gpt-4.1",
            proAlternates: ["gpt-4-turbo"],
            routingMode: .auto
        )
        let deepseek = AgentProviderEntry(
            providerID: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            apiKey: "test-fixture-deepseek-key",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro",
            routingMode: .auto
        )
        app.agentProviderLibrary = AgentProviderLibrary(
            entries: [openai, deepseek],
            activeID: openai.id
        )
        app.applyActiveProviderLibraryEntry()
        // `agentSessionModelOverride` is delegated to `activeRuntime?.sessionModelOverride`
        // (AppState.swift:204) — without an active runtime every set is
        // a no-op and the picker assertions below would all see nil.
        // Production starts a New Chat on first entry into Agent mode;
        // tests have to do the same handshake.
        if startSession {
            app.startNewAgentSession()
        }
        return (app, openai, deepseek)
    }

    @Test
    func explicitModelCanBeSelectedBeforeWorkspace() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, _, deepseek) = makeAppStateWithTwoEntries(startSession: false)
        #expect(app.activeRuntime == nil)

        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")

        #expect(app.activeRuntime != nil)
        #expect(app.activeRuntime?.workspaceRootPath == nil)
        #expect(app.agentProviderLibrary.activeID != deepseek.id)
        #expect(app.activeRuntime?.sessionProviderEntryID == deepseek.id)
        #expect(app.agentSessionModelOverride == "deepseek-v4-pro")

        let workspacePath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        app.moveActiveAgentSessionToWorkspace(at: workspacePath)
        #expect(app.activeRuntime?.workspaceRootPath == workspacePath)
        #expect(app.agentSessionModelOverride == "deepseek-v4-pro")
    }

    @Test
    func switchingToDifferentEntryPinsOnlyCurrentSession() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, _, deepseek) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        #expect(app.agentProviderLibrary.activeID != deepseek.id)
        #expect(app.agentConfiguration.providerID == "openai")
        let turn = app.configurationForCurrentTurn(for: try #require(app.activeRuntime))
        #expect(turn.providerID == "deepseek")
        #expect(turn.apiKey == "test-fixture-deepseek-key")
        #expect(app.agentSessionModelOverride == "deepseek-v4-pro")
    }

    @Test
    func pickingRouteDefaultClearsOverride() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()
        // First set an explicit override...
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")
        // ...then pick the model that already matches the route's
        // natural Flash pick (entry.routingMode is .auto → flashPrimary).
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4.1-mini")
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func pickedModelsAreTrackedMostRecentlyUsedFirst() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()

        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4-turbo")
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")

        #expect(app.agentRecentlyUsedModelIDs.prefix(2).elementsEqual(["gpt-4o-mini", "gpt-4-turbo"]))
        #expect(AgentSettingsStore.loadRecentlyUsedModelIDs().prefix(2).elementsEqual(["gpt-4o-mini", "gpt-4-turbo"]))
    }

    @Test
    func routeDefaultPickIsAlsoTrackedAsRecentlyUsed() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()

        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4.1-mini")

        #expect(app.agentSessionModelOverride == nil)
        #expect(app.agentRecentlyUsedModelIDs.first == "gpt-4.1-mini")
    }

    @Test
    func modelSwitchAppendsLocalTranscriptNotice() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()

        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")

        let notice = try #require(app.agentMessages.last)
        #expect(notice.role == .system)
        #expect(notice.transcriptEvent == .modelChanged)
        #expect(notice.content == L10n.AgentModelPicker.modelChanged(
            from: "gpt-4.1-mini",
            to: "gpt-4o-mini"
        ))
        #expect(AgentClient.providerReadyMessages(app.agentMessages).isEmpty)
    }

    @Test
    func selectingCurrentModelDoesNotAppendDuplicateNotice() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()

        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4.1-mini")

        #expect(app.agentMessages.isEmpty)
    }

    @Test
    func fetchedModelDiscoveriesPersistHotAndNewFlags() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, _, _) = makeAppStateWithTwoEntries()

        app.recordFetchedAgentModelDiscoveries([
            AgentModelDiscovery(id: "some/hot-model", isHot: true, isNew: false),
            AgentModelDiscovery(id: "some/new-model", isHot: false, isNew: true)
        ])

        #expect(app.agentKnownModelIDs == ["some/hot-model", "some/new-model"])
        #expect(app.agentDiscoveredModelMetadata == [
            AgentModelDiscovery(id: "some/hot-model", isHot: true, isNew: false),
            AgentModelDiscovery(id: "some/new-model", isHot: false, isNew: true)
        ])
        #expect(AgentSettingsStore.loadDiscoveredModelMetadata() == app.agentDiscoveredModelMetadata)
    }

    @Test
    func emptyModelClearsOverride() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")
        app.selectAgentEntryAndModel(entryID: openai.id, model: "")
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func changingSettingsDefaultDoesNotRewritePinnedSession() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, deepseek) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")

        app.setActiveProviderLibraryEntry(id: deepseek.id)

        #expect(app.agentConfiguration.providerID == "deepseek")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")
        #expect(app.activeAgentModelID == "gpt-4o-mini")
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).providerID == "openai")
    }

    /// Regression: before 1.57.0-rc6 the `KeychainSandbox` only
    /// redirected Keychain writes. `saveProviderLibrary` writes the
    /// JSON-encoded entry skeletons (providerID, baseURL, displayName,
    /// model lists) to UserDefaults under
    /// `com.willdeep.agentSettings.providerLibrary.v1`, and that
    /// key still pointed at `UserDefaults.standard`. Every test run
    /// planted two fixture entries — "OpenAI / gpt-4.1-mini" and
    /// "DeepSeek / deepseek-v4-flash" — into the developer's real
    /// defaults, where they then appeared in the running Settings UI
    /// with empty API keys, looking exactly like the new build had
    /// auto-seeded them. This test fails (assertion #2) if the sandbox
    /// loses its grip on UserDefaults again.
    @Test
    func providerLibraryEntriesStayInSandboxedDefaults() {
        let providerLibraryKey = "com.willdeep.agentSettings.providerLibrary.v1"
        let snapshotBefore = UserDefaults.standard.data(forKey: providerLibraryKey)

        let sandbox = installKeychainSandbox()
        _ = makeAppStateWithTwoEntries()

        // (1) The sandboxed suite must actually have received the
        // entries — otherwise we'd be asserting the wrong thing: a
        // silently-dropped write would also leave `.standard` untouched
        // and we'd ship a hollow regression test.
        let sandboxBlob = UserDefaults(suiteName: sandbox.suiteName)?
            .data(forKey: providerLibraryKey)
        #expect(sandboxBlob != nil)

        // (2) The production defaults must NOT have changed during the
        // test. Equality (not just "still has *some* value") catches
        // the case where a prior leak left a stale blob in place and a
        // new test overwrites it with a different one.
        let snapshotDuring = UserDefaults.standard.data(forKey: providerLibraryKey)
        #expect(snapshotDuring == snapshotBefore)

        _ = sandbox // hold the RAII handle until both assertions are made
    }

    @Test
    func entryRoutingModeDrivesEffectiveModel() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        // DeepSeek entry forces Pro — the live config's
        // routingMode should follow when we switch active.
        let (app, _, ds) = makeAppStateWithTwoEntries()
        var deepseek = ds
        deepseek.routingMode = .pro
        app.agentProviderLibrary.upsert(deepseek)
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).routingMode == .pro)
        // No override needed because Pro routing already maps to
        // deepseek-v4-pro.
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func modelAndProviderSelectionDoNotLeakAcrossConversations() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, deepseek) = makeAppStateWithTwoEntries()
        let sessionA = try #require(app.activeAgentSessionID)
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        app.persistActiveAgentSession()

        let sessionB = app.startNewAgentSession()
        #expect(app.activeAgentProviderEntry?.id == openai.id)
        #expect(app.activeAgentModelID == "gpt-4.1-mini")

        #expect(app.selectAgentSession(id: sessionA))
        #expect(app.activeAgentProviderEntry?.id == deepseek.id)
        #expect(app.activeAgentModelID == "deepseek-v4-pro")
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).providerID == "deepseek")

        #expect(app.selectAgentSession(id: sessionB.id))
        #expect(app.activeAgentProviderEntry?.id == openai.id)
        #expect(app.activeAgentModelID == "gpt-4.1-mini")
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).providerID == "openai")
    }

    @Test
    func signedInSomeIMDefaultsNewChatsToAutoFlash() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let app = AppState()
        let previousPreference = AgentSettingsStore.loadDefaultModelModePreference()
        AgentSettingsStore.saveDefaultModelModePreference(.automatic)
        defer { AgentSettingsStore.saveDefaultModelModePreference(previousPreference) }
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))

        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key"
        )
        let session = app.startNewAgentSession()

        #expect(app.agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID)
        #expect(session.modelID == SomeIMManagedModel.autoFlash)
        #expect(session.managedRouting == nil)
        #expect(app.activeRuntime?.managedRouting == nil)
        #expect(app.activeAgentModelID == SomeIMManagedModel.autoFlash)
        #expect(AgentSettingsStore.loadDefaultModelModePreference() == .automatic)
    }

    @Test
    func manualModelChoiceOnlyOverridesCurrentChatManagedDefault() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let app = AppState()
        let previousPreference = AgentSettingsStore.loadDefaultModelModePreference()
        AgentSettingsStore.saveDefaultModelModePreference(.managed)
        defer { AgentSettingsStore.saveDefaultModelModePreference(previousPreference) }
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))
        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key"
        )
        app.startNewAgentSession()

        app.setAgentSessionModel("someim-auto-flash")
        #expect(AgentSettingsStore.loadDefaultModelModePreference() == .managed)
        let managedSession = app.startNewAgentSession()
        #expect(managedSession.modelID == nil)
        #expect(managedSession.managedRouting != nil)
    }

    @Test
    func explicitSomeIMModelSurvivesPersistAndRuntimeRestoration() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let app = AppState()
        let previousPreference = AgentSettingsStore.loadDefaultModelModePreference()
        AgentSettingsStore.saveDefaultModelModePreference(.managed)
        defer { AgentSettingsStore.saveDefaultModelModePreference(previousPreference) }
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))
        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key"
        )
        app.startNewAgentSession()
        #expect(app.activeRuntime?.managedRouting != nil)

        app.setAgentSessionModel("glm-5.2")
        app.persistActiveAgentSession()

        let persisted = try #require(app.activeRuntime?.session)
        #expect(persisted.managedRouting == nil)
        #expect(persisted.modelID == "glm-5.2")
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).model == "glm-5.2")

        let restoredRuntime = AgentRuntime(session: persisted)
        app.seedPersistedSessionModelOverride(for: restoredRuntime)
        #expect(restoredRuntime.managedRouting == nil)
        #expect(restoredRuntime.sessionModelOverride == "glm-5.2")
        #expect(app.configurationForCurrentTurn(for: restoredRuntime).model == "glm-5.2")
    }

    @Test
    func disablingManagedDefaultStartsNewChatsWithSomeIMDeepSeekV4Flash() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let app = AppState()
        let previousPreference = AgentSettingsStore.loadDefaultModelModePreference()
        defer { AgentSettingsStore.saveDefaultModelModePreference(previousPreference) }
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))
        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key"
        )
        AgentSettingsStore.saveDefaultModelModePreference(.explicitModel)

        let session = app.startNewAgentSession()

        #expect(session.managedRouting == nil)
        #expect(session.modelID == SomeIMIntegrationSettings.defaultTextModel)
        #expect(app.agentSessionModelOverride == nil)
        #expect(app.activeAgentModelID == SomeIMIntegrationSettings.defaultTextModel)
    }

    @Test
    func selectingManagedRoutingPinsSomeIMOnlyToCurrentSession() throws {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openAI, _) = makeAppStateWithTwoEntries()
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))
        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key",
            activate: false
        )
        app.setActiveProviderLibraryEntry(id: openAI.id)

        app.selectSomeIMManagedRouting()

        #expect(app.agentProviderLibrary.active?.id == openAI.id)
        #expect(app.agentConfiguration.providerID == openAI.providerID)
        #expect(app.activeAgentProviderEntry?.providerID == AgentProviderPreset.someIMID)
        #expect(app.configurationForCurrentTurn(for: try #require(app.activeRuntime)).providerID == AgentProviderPreset.someIMID)
        #expect(app.activeRuntime?.managedRouting != nil)
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func managedRoutingCanBeSelectedBeforeWorkspace() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let app = AppState()
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }
        #expect(SomeIMIntegrationStore.saveAPIKey("test-fixture-someim-key"))
        app.syncSomeIMProvider(
            settings: SomeIMIntegrationSettings(enabled: true),
            apiKey: "test-fixture-someim-key"
        )
        #expect(app.activeRuntime == nil)

        app.selectSomeIMManagedRouting()

        #expect(app.activeRuntime != nil)
        #expect(app.activeRuntime?.workspaceRootPath == nil)
        #expect(app.activeRuntime?.managedRouting != nil)
        #expect(app.agentSessionModelOverride == nil)

        let workspacePath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        app.moveActiveAgentSessionToWorkspace(at: workspacePath)
        #expect(app.activeRuntime?.workspaceRootPath == workspacePath)
        #expect(app.activeRuntime?.managedRouting != nil)
    }
}

/// RAII handle that diverts `AgentSettingsStore` Keychain *and*
/// UserDefaults reads/writes to a per-instance sandbox. `deinit` wipes
/// both stores and restores the production overrides. Tests instantiate
/// one at the top of each `@Test` function and let the runtime drop it
/// at scope end.
///
/// Why this is necessary: `AppState.agentProviderLibrary`'s `@Published`
/// didSet calls `AgentSettingsStore.saveProviderLibrary`, which is
/// indistinguishable from a production save — it writes API keys to
/// Keychain *and* writes the JSON-encoded entry skeletons (providerID,
/// baseURL, displayName, model lists) into UserDefaults. The original
/// version of this sandbox only sealed the Keychain half; entry
/// skeletons still landed in `UserDefaults.standard` and the dev's
/// running app showed fixture providers (an "OpenAI / gpt-4.1-mini" and
/// a "DeepSeek / deepseek-v4-flash") with empty API keys after every
/// test run, looking for all the world like the new build auto-seeded
/// them. The UserDefaults half now goes through `_setTestDefaultsOverride`
/// into a UUID-suffixed `UserDefaults(suiteName:)`, wiped on deinit.
@MainActor
final class KeychainSandbox {
    let service: String
    let suiteName: String
    var defaults: UserDefaults { sandboxDefaults }
    private let sandboxDefaults: UserDefaults

    init() {
        // 顺手扫掉上一轮测试被 cfprefsd 复活的壳 plist（进程内只跑一次）。
        _ = TestDefaultsHygiene.sweepStaleSuiteFiles
        let id = UUID().uuidString
        self.service = "com.willdeep.agent.test.\(id)"
        self.suiteName = "com.willdeep.agent.test.defaults.\(id)"
        guard let sandbox = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Cannot allocate sandbox UserDefaults suite \(suiteName)")
        }
        // Suite is process-local but persistent across test runs on
        // disk, so clear any stale rows up front before letting the
        // test write into it.
        sandbox.removePersistentDomain(forName: suiteName)
        self.sandboxDefaults = sandbox
        AgentSettingsStore._setTestKeychainServiceOverride(service)
        AgentSettingsStore._setTestDefaultsOverride(sandbox)
    }

    deinit {
        MainActor.assumeIsolated {
            AgentSettingsStore._wipeTestKeychain()
            AgentSettingsStore._setTestKeychainServiceOverride(nil)
            AgentSettingsStore._setTestDefaultsOverride(nil)
        }
        // 完整收尾（清域 + 移出搜索列表 + 删壳文件）走共享工具；
        // cfprefsd 竞态漏掉的壳由下一轮进程启动时的 sweep 兜底，
        // 背景见 TestDefaultsHygiene 的文档注释。
        TestDefaultsHygiene.cleanup(suite: sandboxDefaults, named: suiteName)
    }
}
