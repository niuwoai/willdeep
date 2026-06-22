//
//  AgentProviderLibraryTests.swift
//  WillDeepTests
//
//  Covers the multi-provider library data layer + the
//  AgentConfiguration normalization bug fix that drops stale model
//  names carried over from a previous provider.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentProviderLibraryTests {
    // MARK: - Provider entry

    @Test
    func entryRebuildsConfigurationWithOverrides() {
        let entry = AgentProviderEntry(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-test",
            flashPrimary: "deepseek-v4-flash",
            flashAlternates: ["deepseek-coder-flash"],
            proPrimary: "deepseek-v4-pro",
            proAlternates: ["deepseek-r1"]
        )
        let cfg = entry.makeConfiguration(routingMode: .pro)
        #expect(cfg.providerID == "deepseek")
        #expect(cfg.apiKey == "sk-test")
        #expect(cfg.proModel == "deepseek-v4-pro")
        #expect(cfg.model == "deepseek-v4-pro")
    }

    @Test
    func entryCleansDuplicateAndEmptyAlternates() {
        let entry = AgentProviderEntry(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            flashPrimary: "gpt-4.1-mini",
            flashAlternates: ["gpt-4.1-mini", "", "gpt-4o-mini", "gpt-4o-mini"],
            proPrimary: "gpt-4.1"
        )
        // Primary is excluded; empties are dropped; later duplicates are
        // squashed.
        #expect(entry.flashAlternates == ["gpt-4o-mini"])
        #expect(entry.allFlashModels == ["gpt-4.1-mini", "gpt-4o-mini"])
    }

    // MARK: - Library

    @Test
    func upsertReplacesByID() {
        let a = AgentProviderEntry(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        var lib = AgentProviderLibrary(entries: [a])
        var updated = a
        updated.flashPrimary = "gpt-4o-mini"
        lib.upsert(updated)
        #expect(lib.entries.count == 1)
        #expect(lib.entries[0].flashPrimary == "gpt-4o-mini")
    }

    @Test
    func removingActiveEntryRepointsToFirst() {
        let a = AgentProviderEntry(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        let b = AgentProviderEntry(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        var lib = AgentProviderLibrary(entries: [a, b], activeID: a.id)
        lib.remove(id: a.id)
        #expect(lib.entries.count == 1)
        #expect(lib.activeID == b.id)
    }

    @Test
    func migrateWrapsLegacyConfigurationAsSingleEntry() {
        let legacy = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            flashModel: "deepseek-v4-flash",
            proModel: "deepseek-v4-pro",
            routingMode: .auto,
            imageDescription: .default,
            apiKey: "sk-legacy"
        )
        let lib = AgentProviderLibrary.migrate(from: legacy)
        #expect(lib.entries.count == 1)
        let only = lib.entries[0]
        #expect(only.providerID == "deepseek")
        #expect(only.flashPrimary == "deepseek-v4-flash")
        #expect(only.proPrimary == "deepseek-v4-pro")
        #expect(only.apiKey == "sk-legacy")
        #expect(lib.activeID == only.id)
    }

    // MARK: - Bug fix: stale model name from previous provider

    @Test
    func normalizedDropsForeignFlashModelAfterProviderSwitch() {
        // Simulate the user-reported state: provider got switched to
        // DeepSeek but flashModel still holds OpenAI's `gpt-3.5-16k`
        // from before. After normalize() the picker should no longer
        // see "Use route default: gpt-3.5-16k".
        let stale = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            flashModel: "gpt-3.5-16k",
            proModel: "gpt-4.1",
            routingMode: .auto,
            imageDescription: .default,
            apiKey: ""
        )
        let n = stale.normalized
        #expect(n.flashModel == "deepseek-v4-flash")
        #expect(n.proModel == "deepseek-v4-pro")
    }

    @Test
    func normalizedKeepsRecognisedCustomModelOnPreset() {
        // A user-fetched model that matches the provider's hint should
        // survive normalize() untouched — we don't want to clobber
        // legitimate model choices.
        let kept = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-coder-33b",
            flashModel: "deepseek-coder-33b",
            proModel: "deepseek-r1",
            routingMode: .auto,
            imageDescription: .default,
            apiKey: ""
        )
        let n = kept.normalized
        #expect(n.flashModel == "deepseek-coder-33b")
        #expect(n.proModel == "deepseek-r1")
    }

    // MARK: - One-shot providerID-vs-baseURL repair (A 方案)

    @Test
    func repairFixesProviderIDWhenBaseURLPointsElsewhere() {
        // 还原 bug 现场：entry 的 baseURL 还是 DeepSeek 的，但 providerID
        // 在某次回灌后被改成了 openai，displayName 也跟着变成 "OpenAI"。
        // 修复函数应当按 baseURL 反推 preset，把 providerID 改回去，
        // 同时把通用 displayName 也一起更正（因为它正好是错误 preset
        // 的默认名）。
        let damaged = AgentProviderEntry(
            providerID: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-deepseek",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let lib = AgentProviderLibrary(entries: [damaged], activeID: damaged.id)
        let fixed = AgentSettingsStore.repairLibraryProviderMismatch(lib)
        #expect(fixed.entries.count == 1)
        #expect(fixed.entries[0].providerID == "deepseek")
        #expect(fixed.entries[0].displayName == "DeepSeek")
        // Key sits on the UUID-keyed Keychain row, the repair never
        // touches it; the in-memory copy should pass through unchanged.
        #expect(fixed.entries[0].apiKey == "sk-deepseek")
    }

    @Test
    func repairLeavesCustomLabelAlone() {
        // 用户自己起的名（不是任何 preset 的默认显示名）应当被保留 —
        // 只修 providerID。
        let damaged = AgentProviderEntry(
            providerID: "openai",
            displayName: "Work DeepSeek",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-deepseek",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let fixed = AgentSettingsStore.repairLibraryProviderMismatch(
            AgentProviderLibrary(entries: [damaged], activeID: damaged.id)
        )
        #expect(fixed.entries[0].providerID == "deepseek")
        #expect(fixed.entries[0].displayName == "Work DeepSeek")
    }

    @Test
    func repairIsNoOpWhenProviderMatchesBaseURL() {
        let clean = AgentProviderEntry(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let fixed = AgentSettingsStore.repairLibraryProviderMismatch(
            AgentProviderLibrary(entries: [clean], activeID: clean.id)
        )
        #expect(fixed.entries[0].providerID == "deepseek")
    }

    @Test
    func repairSkipsCustomBaseURL() {
        // 用户改成了一个未被任何 preset 识别的 base URL —— 修复函数无从
        // 猜测真实归属，必须放任不管。
        let damaged = AgentProviderEntry(
            providerID: "openai",
            displayName: "OpenAI",
            baseURL: "https://my-self-hosted/v1",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        let fixed = AgentSettingsStore.repairLibraryProviderMismatch(
            AgentProviderLibrary(entries: [damaged], activeID: damaged.id)
        )
        #expect(fixed.entries[0].providerID == "openai")
        #expect(fixed.entries[0].displayName == "OpenAI")
    }

    @Test
    func normalizedLeavesCustomProviderAlone() {
        // For the custom provider we have no opinion about model names,
        // so even an "off-brand" string should survive.
        let custom = AgentConfiguration(
            providerID: "custom",
            baseURL: "https://my-host/v1",
            model: "weird-internal-model",
            flashModel: "weird-internal-model",
            proModel: "weird-internal-pro",
            routingMode: .auto,
            imageDescription: .default,
            apiKey: ""
        )
        let n = custom.normalized
        #expect(n.flashModel == "weird-internal-model")
        #expect(n.proModel == "weird-internal-pro")
    }

    @Test
    func someIMPresetDefaultsToDeepSeekChatModels() {
        let preset = AgentProviderPreset.preset(id: "some-im")

        #expect(preset?.defaultModel == "deepseek-v4-flash")
        #expect(preset?.defaultProModel == "deepseek-v4-pro")
    }

    @MainActor
    @Test
    func syncingSomeIMProviderCreatesActiveChatProvider() {
        let sandbox = KeychainSandbox()
        _ = sandbox

        let appState = AppState()
        let settings = SomeIMIntegrationSettings(
            enabled: true,
            baseURL: "https://some.im/v1",
            preferredImageModel: "gpt-image-2",
            preferredImageModels: ["gpt-image-2"],
            preferredVideoModel: "",
            preferredVideoModels: []
        )

        appState.syncSomeIMProvider(settings: settings, apiKey: " sk-some-im ")

        let active = appState.agentProviderLibrary.active
        #expect(active?.providerID == "some-im")
        #expect(active?.baseURL == "https://some.im/v1")
        #expect(active?.apiKey == "sk-some-im")
        #expect(active?.flashPrimary == "deepseek-v4-flash")
        #expect(active?.proPrimary == "deepseek-v4-pro")
        #expect(appState.agentConfiguration.providerID == "some-im")
        #expect(appState.agentConfiguration.apiKey == "sk-some-im")
        #expect(appState.agentConfiguration.flashModel == "deepseek-v4-flash")
        #expect(appState.agentConfiguration.proModel == "deepseek-v4-pro")
    }

    @MainActor
    @Test
    func syncingSomeIMImageUnderstandingUsesDomesticVisionModel() {
        let sandbox = KeychainSandbox()
        _ = sandbox

        let appState = AppState()

        appState.syncSomeIMImageUnderstanding(apiKey: " sk-some-im ")

        let imageDescription = appState.agentConfiguration.imageDescription
        #expect(imageDescription.providerID == "some-im")
        #expect(imageDescription.baseURL == SomeIMRelayRegion.chinaBaseURL)
        #expect(imageDescription.model == SomeIMIntegrationSettings.defaultVisionModel)
        #expect(imageDescription.apiKey == "sk-some-im")
    }
}
