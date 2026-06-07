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
    /// Returns an AppState seeded with two distinct library entries:
    /// an OpenAI one (active by default) and a DeepSeek one. Tests
    /// then exercise selectAgentEntryAndModel against this setup.
    private func makeAppStateWithTwoEntries() -> (AppState, AgentProviderEntry, AgentProviderEntry) {
        let app = AppState()
        let openai = AgentProviderEntry(
            providerID: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-openai",
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
            apiKey: "sk-deepseek",
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
        let (app, _, deepseek) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: deepseek.id, model: "deepseek-v4-pro")
        #expect(app.agentProviderLibrary.activeID == deepseek.id)
        #expect(app.agentConfiguration.providerID == "deepseek")
        #expect(app.agentConfiguration.apiKey == "sk-deepseek")
        #expect(app.agentSessionModelOverride == "deepseek-v4-pro")
    }

    @Test
    func pickingRouteDefaultClearsOverride() {
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
        let (app, openai, _) = makeAppStateWithTwoEntries()
        app.selectAgentEntryAndModel(entryID: openai.id, model: "gpt-4o-mini")
        #expect(app.agentSessionModelOverride == "gpt-4o-mini")
        app.selectAgentEntryAndModel(entryID: openai.id, model: "")
        #expect(app.agentSessionModelOverride == nil)
    }

    @Test
    func entryRoutingModeDrivesEffectiveModel() {
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
