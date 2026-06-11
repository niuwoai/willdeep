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

@Suite
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
    private func makeAppStateWithTwoEntries() -> (AppState, AgentProviderEntry, AgentProviderEntry) {
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
        app.startNewAgentSession()
        return (app, openai, deepseek)
    }

    @Test
    func switchingToDifferentEntryFlipsActiveAndConfig() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, _, deepseek) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        #expect(app.agentProviderLibrary.activeID == deepseek.id)
        #expect(app.agentConfiguration.providerID == "deepseek")
        #expect(app.agentConfiguration.apiKey == "test-fixture-deepseek-key")
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
    func emptyModelClearsOverride() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, _) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")
        app.selectAgentEntryAndModel(entryID: openai.id, model: "")
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func switchingProviderClearsForeignSessionOverride() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        let (app, openai, deepseek) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")

        app.setActiveProviderLibraryEntry(id: deepseek.id)

        #expect(app.agentConfiguration.providerID == "deepseek")
        #expect(app.agentSessionModelOverride == nil)
        #expect(app.activeAgentModelID == "deepseek-v4-flash")
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
    func entryRoutingModeDrivesEffectiveModel() {
        let _sandbox = installKeychainSandbox(); _ = _sandbox
        // DeepSeek entry forces Pro — the live config's
        // routingMode should follow when we switch active.
        let (app, _, ds) = makeAppStateWithTwoEntries()
        var deepseek = ds
        deepseek.routingMode = .pro
        app.agentProviderLibrary.upsert(deepseek)
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        #expect(app.agentConfiguration.routingMode == .pro)
        // No override needed because Pro routing already maps to
        // deepseek-v4-pro.
        #expect(app.agentSessionModelOverride == nil)
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
    private let sandboxDefaults: UserDefaults

    init() {
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
        AgentSettingsStore._wipeTestKeychain()
        AgentSettingsStore._setTestKeychainServiceOverride(nil)
        sandboxDefaults.removePersistentDomain(forName: suiteName)
        AgentSettingsStore._setTestDefaultsOverride(nil)
    }
}
