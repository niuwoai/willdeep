//
//  AgentModelSelectionTests.swift
//  WillDeepTests
//
//  Regression coverage for model-selection paths that used to run a
//  different model than the one configured: session overrides reset by
//  `.normalized`, auxiliary requests reading the Settings provider instead
//  of the session's, verdict trades bound to a provider but no model, and
//  worker-tier fallbacks that left no reason behind.
//

import Testing
import Foundation
@testable import WillDeep

@MainActor
@Suite
struct AgentModelSelectionTests {

    private var openAI: AgentConfiguration {
        AgentConfiguration(
            providerID: AgentProviderPreset.openAIID,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini",
            flashModel: "gpt-4.1-mini",
            proModel: "gpt-4.1",
            routingMode: .flash,
            apiKey: "sk-test"
        )
    }

    @Test("an explicit session model survives normalisation even when the preset doesn't recognise it")
    func sessionOverrideIsNotResetByNormalized() {
        let resolved = AppState.applyingSessionModelOverride("vendor-preview-7", to: openAI)
        #expect(resolved.model == "vendor-preview-7")
        // Settings-level stale-model protection still applies to the route models.
        #expect(resolved.flashModel == "gpt-4.1-mini")
    }

    @Test("a blank override keeps the routed model")
    func blankOverrideKeepsRoute() {
        let resolved = AppState.applyingSessionModelOverride("  ", to: openAI)
        #expect(resolved.model == "gpt-4.1-mini")
    }

    @Test("OpenAI preset recognises o4 models")
    func openAIRecognisesO4() throws {
        let preset = try #require(AgentProviderPreset.preset(id: AgentProviderPreset.openAIID))
        #expect(preset.recognizesModelID("o4-mini"))
    }

    @Test("auxiliary requests follow a session pinned to another provider")
    func auxiliaryFollowsSessionProvider() {
        var global = openAI
        global.compressionModel = "gpt-4.1-nano"
        let session = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            flashModel: "deepseek-chat",
            proModel: "deepseek-reasoner",
            routingMode: .flash,
            apiKey: "sk-ds"
        )
        let base = AppState.auxiliaryBaseConfiguration(global: global, session: session)
        #expect(base.providerID == "deepseek")
        #expect(base.apiKey == "sk-ds")
        // The Settings compression model belongs to the other provider and must not leak across.
        #expect(base.contextCompressionModel() == "deepseek-chat")
        #expect(base.titleSummaryModel() == "deepseek-chat")
    }

    @Test("auxiliary requests keep Settings' explicit models when the session uses the same provider")
    func auxiliaryKeepsSettingsForSameProvider() {
        var global = openAI
        global.compressionModel = "gpt-4.1-nano"
        let base = AppState.auxiliaryBaseConfiguration(global: global, session: openAI)
        #expect(base.contextCompressionModel() == "gpt-4.1-nano")
    }

    @Test("verdict trades bind the some.im judge model, not just the provider")
    func verdictTradesBindJudgeModel() {
        for profile in [AgentSubagentProfileCatalog.judge, AgentSubagentProfileCatalog.securityGuard] {
            #expect(profile.modelBinding.preferredProviderID == AgentProviderPreset.someIMID)
            #expect(profile.modelBinding.model == SomeIMManagedModel.judge)
        }
    }

    @Test("a verdict trade under a private parent stays on the parent")
    func verdictTradeKeepsPrivateParent() {
        var privateParent = openAI
        privateParent.providerID = AgentProviderPreset.customID
        privateParent.baseURL = "http://localhost:8000/v1"
        let resolved = AppState().resolvedSubagentConfiguration(
            for: AgentSubagentProfileCatalog.judge,
            parentConfiguration: privateParent
        )
        #expect(resolved.baseURL == privateParent.baseURL)
    }

    @Test("worker tier fallback reports why it fell back")
    func workerTierFallbackReason() {
        var privateParent = openAI
        privateParent.providerID = AgentProviderPreset.customID
        privateParent.baseURL = "http://localhost:8000/v1"
        var models = AgentWorkerTierModels()
        models[.standard] = .init(preferredProviderID: AgentProviderPreset.someIMID, model: "someim-32b")
        let result = AppState().workerTierResolution(.standard, parent: privateParent, models: models)
        #expect(result == .failure(AgentWorkerTierUnavailable(reason: .privateParentKeepsProvider)))

        var unconfigured = AgentWorkerTierModels()
        unconfigured[.standard] = .init(model: nil)
        #expect(AppState().workerTierResolution(.standard, parent: privateParent, models: unconfigured)
            == .failure(AgentWorkerTierUnavailable(reason: .bindingUnconfigured)))
    }

    @Test("an unreachable quality judge is marked unavailable")
    func qualityJudgeUnavailableIsFlagged() async {
        let decision = await SomeIMManagedRouting.outputQuality(
            assistantText: "a perfectly ordinary answer",
            reasoningText: nil,
            latestUserMessage: "q",
            model: "someim-code-low",
            finishReason: "stop"
        ) { _, _, _ in nil }
        #expect(decision.judgeAvailable == false)
        #expect(decision.shouldRetry == false)
    }

    @Test("a model-route entry encodes without message content and bounds the detail")
    func routeLogEntryEncoding() throws {
        let entry = AgentModelRouteLog.Entry(
            surface: .workerBinding,
            sessionID: nil,
            subject: "scout",
            requested: "tier:standard",
            providerID: "custom",
            model: "local-model",
            fallback: true,
            reason: .privateParentKeepsProvider,
            detail: String(repeating: "x", count: 1_000)
        )
        #expect(entry.detail?.count == AgentModelRouteLog.detailCharacterLimit)
        let line = try #require(AgentWorkerTimingLog.encodeLine(entry))
        #expect(line.contains(#""reason":"private_parent_keeps_provider""#))
        #expect(line.contains(#""kind":"model_route""#))
    }
}
