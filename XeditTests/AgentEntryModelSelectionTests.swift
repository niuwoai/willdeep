//
//  AgentEntryModelSelectionTests.swift
//  VeilWriterTests
//
//  Covers AppState.selectAgentEntryAndModel — the one-shot picker
//  primitive used by the chat-mode two-level model menu. Tests run on
//  the main actor because AppState is MainActor-isolated.
//

import Testing
import Foundation
@testable import VeilWriter

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

/// RAII handle that diverts `AgentSettingsStore` Keychain reads/writes
/// to a per-instance sandbox service name. `deinit` wipes the sandbox
/// rows and restores the production service name. Tests instantiate
/// one at the top of each `@Test` function and let the runtime drop it
/// at scope end.
///
/// Why this is necessary: `AppState.agentProviderLibrary`'s `@Published`
/// didSet calls `AgentSettingsStore.saveProviderLibrary`, which is
/// indistinguishable from a production save — it writes API keys to
/// Keychain under the production service name. Before this sandbox
/// existed, every run of these tests planted fixture keys
/// (`test-fixture-openai-key`, `test-fixture-deepseek-key`) into the
/// developer's real Keychain, where they then surfaced inside the
/// running Settings UI alongside the user's real entries.
@MainActor
final class KeychainSandbox {
    let service: String

    init() {
        self.service = "im.some.veilwriter.agent.test.\(UUID().uuidString)"
        AgentSettingsStore._setTestKeychainServiceOverride(service)
    }

    deinit {
        AgentSettingsStore._wipeTestKeychain()
        AgentSettingsStore._setTestKeychainServiceOverride(nil)
    }
}
