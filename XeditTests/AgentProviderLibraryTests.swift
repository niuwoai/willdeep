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
    func entryUsabilityRequiresCredentialsForRemoteProviders() {
        let keylessDeepSeek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            apiKey: "",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let local = AgentProviderEntry(
            providerID: AgentProviderPreset.ollamaID,
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "",
            flashPrimary: "qwen-local",
            proPrimary: "qwen-local"
        )
        let someIM = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            apiKey: "",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )

        #expect(!keylessDeepSeek.isUsableForChatSelection(isSomeIMAuthenticated: false))
        #expect(local.isUsableForChatSelection(isSomeIMAuthenticated: false))
        #expect(!someIM.isUsableForChatSelection(isSomeIMAuthenticated: false))
        #expect(someIM.isUsableForChatSelection(isSomeIMAuthenticated: true))
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

    @Test
    func providerSelectionSuggestsCanonicalEditableDisplayName() {
        #expect(AgentProviderPreset.suggestedDisplayName(providerID: "deepseek") == "DeepSeek")
        #expect(AgentProviderPreset.suggestedDisplayName(providerID: " custom ") == "Custom")
        #expect(AgentProviderPreset.suggestedDisplayName(providerID: "private-relay") == "private-relay")
    }

    @Test
    func modelListFormatErrorDescribesMissingFieldAndActualShape() throws {
        struct ExpectedResponse: Decodable {
            let data: [Model]

            struct Model: Decodable {
                let id: String
            }
        }

        let payload = Data(#"{"models":[{"name":"wrong-shape"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(ExpectedResponse.self, from: payload)
            Issue.record("Expected model-list decoding to fail")
        } catch {
            let wrapped = AgentModelListResponseFormatError.wrapping(
                error,
                data: payload,
                expectedSchema: #"{"data":[{"id":"model-id"}]}"#
            )
            #expect(wrapped.decodingIssue.contains("missing required key \"data\""))
            #expect(wrapped.payloadShape.contains("\"models\""))
            #expect(wrapped.expectedSchema.contains("\"data\""))
        }
    }

    @Test
    func modelListFormatErrorIdentifiesNonJSONResponseWithoutEchoingBody() {
        let payload = Data("<html>upstream login page</html>".utf8)
        let wrapped = AgentModelListResponseFormatError.wrapping(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON")),
            data: payload,
            expectedSchema: #"{"data":[{"id":"model-id"}]}"#
        )
        #expect(wrapped.payloadShape == "not valid JSON")
        #expect(!wrapped.localizedDescription.contains("upstream login page"))
    }

    @Test
    func openAIBaseURLProbeAdjustsV1InBothDirections() {
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://hub.example.com",
            providerKind: .openAIChat
        ) == AgentProviderBaseURLV1Candidate(baseURL: "https://hub.example.com/v1", adjustment: .append))
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://hub.example.com/gateway/",
            providerKind: .openAIResponses
        ) == AgentProviderBaseURLV1Candidate(baseURL: "https://hub.example.com/gateway/v1", adjustment: .append))
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://hub.example.com/v1/",
            providerKind: .openAIChat
        ) == AgentProviderBaseURLV1Candidate(baseURL: "https://hub.example.com", adjustment: .remove))
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://hub.example.com/gateway/v1",
            providerKind: .openAIResponses
        ) == AgentProviderBaseURLV1Candidate(baseURL: "https://hub.example.com/gateway", adjustment: .remove))
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://api.anthropic.com",
            providerKind: .anthropicMessages
        ) == nil)
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "https://hub.example.com/chat/completions",
            providerKind: .openAIChat
        ) == nil)
        #expect(AgentProviderBaseURLV1Probe.candidate(
            baseURL: "not-a-url",
            providerKind: .openAIChat
        ) == nil)
    }

    @Test
    func openAIBaseURLProbeOnlyRetriesNotFoundResponses() {
        let notFound = AgentClientError.serverStatus(AgentProviderHTTPError(
            statusCode: 404,
            method: "GET",
            url: "https://hub.example.com/models",
            providerID: "custom",
            model: "",
            requestSummary: "",
            requestBody: "",
            responseBody: ""
        ))
        #expect(AgentProviderBaseURLV1Probe.shouldRetry(after: notFound))
        #expect(!AgentProviderBaseURLV1Probe.shouldRetry(after: AgentClientError.invalidResponse))
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

    @MainActor
    @Test
    func providerLibrarySavePreservesUnloadedAPIKeys() {
        let sandbox = KeychainSandbox()
        _ = sandbox

        let active = AgentProviderEntry(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-active",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        let inactive = AgentProviderEntry(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-inactive",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )

        AgentSettingsStore.saveProviderLibrary(
            AgentProviderLibrary(entries: [active, inactive], activeID: active.id)
        )

        var loaded = AgentSettingsStore.loadProviderLibrary()
        #expect(loaded.entries.first(where: { $0.id == active.id })?.apiKey == "sk-active")
        #expect(loaded.entries.first(where: { $0.id == inactive.id })?.apiKey == "")
        #expect(loaded.entries.first(where: { $0.id == inactive.id })?.apiKeyLoaded == false)

        AgentSettingsStore.saveProviderLibrary(loaded)
        AgentSettingsStore.materializeProviderLibraryAPIKey(in: &loaded, id: inactive.id)

        #expect(loaded.entries.first(where: { $0.id == inactive.id })?.apiKey == "sk-inactive")
        #expect(loaded.entries.first(where: { $0.id == inactive.id })?.apiKeyLoaded == true)
    }

    @MainActor
    @Test("usable active provider does not materialize inactive credentials")
    func activeProviderSelectionKeepsInactiveCredentialsLazy() throws {
        let sandbox = KeychainSandbox()
        _ = sandbox

        let active = AgentProviderEntry(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-active",
            flashPrimary: "gpt-4.1-mini",
            proPrimary: "gpt-4.1"
        )
        let inactive = AgentProviderEntry(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            apiKey: "sk-inactive",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        AgentSettingsStore.saveProviderLibrary(
            AgentProviderLibrary(entries: [active, inactive], activeID: active.id)
        )

        let appState = AppState()
        #expect(appState.agentProviderLibrary.active?.id == active.id)
        #expect(try #require(appState.agentProviderLibrary.entries.first {
            $0.id == inactive.id
        }).apiKeyLoaded == false)

        #expect(!appState.ensureActiveProviderIsUsableForChatSelection())
        #expect(try #require(appState.agentProviderLibrary.entries.first {
            $0.id == inactive.id
        }).apiKeyLoaded == false)
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

    @Test
    func ollamaPresetAllowsEmptyAPIKey() {
        let local = AgentConfiguration(
            providerID: AgentProviderPreset.ollamaID,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "qwen3.5-4b-q4_k_m",
            flashModel: "qwen3.5-4b-q4_k_m",
            proModel: "qwen3.5-4b-q4_k_m",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: ""
        ).normalized

        #expect(local.providerID == AgentProviderPreset.ollamaID)
        #expect(local.requiresAPIKey == false)
        #expect(local.providerKind == .openAIChat)
    }

    @Test
    func localModelSettingsNormalizeEmptyFields() {
        let settings = AgentLocalModelSettings(
            enabled: true,
            baseURL: " \n ",
            visionModel: "",
            summaryModel: "",
            preferForImageUnderstanding: true,
            preferForTitles: true,
            preferForContextSummaries: false,
            exposeAsComposerModel: false,
            composerDisplayName: " "
        ).normalized

        #expect(settings.baseURL == AgentLocalModelSettings.defaultBaseURL)
        #expect(settings.visionModel == AgentLocalModelSettings.defaultVisionModelID)
        #expect(settings.summaryModel == AgentLocalModelSettings.defaultSummaryModelID)
        #expect(settings.composerDisplayName == AgentLocalModelSettings.defaultComposerDisplayName)
    }

    @Test
    func localModelSettingsMigrateOldTextVisionDefaultToVL() {
        let settings = AgentLocalModelSettings(
            enabled: true,
            baseURL: AgentLocalModelSettings.defaultBaseURL,
            visionModel: AgentLocalModelSettings.defaultSummaryModelID,
            summaryModel: AgentLocalModelSettings.defaultSummaryModelID,
            preferForImageUnderstanding: true,
            preferForTitles: true,
            preferForContextSummaries: false,
            exposeAsComposerModel: false,
            composerDisplayName: AgentLocalModelSettings.defaultComposerDisplayName
        ).normalized

        #expect(settings.visionModel == AgentLocalModelSettings.defaultVisionModelID)
        #expect(settings.summaryModel == AgentLocalModelSettings.defaultSummaryModelID)
    }

    @Test
    func localModelSettingsDecodeLegacySummaryPreferenceKeepsContextCompressionRemoteByDefault() throws {
        let data = Data("""
        {
          "enabled": true,
          "baseURL": "\(AgentLocalModelSettings.defaultBaseURL)",
          "visionModel": "\(AgentLocalModelSettings.defaultVisionModelID)",
          "summaryModel": "\(AgentLocalModelSettings.defaultSummaryModelID)",
          "preferForImageUnderstanding": true,
          "preferForSummaries": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AgentLocalModelSettings.self, from: data).normalized

        #expect(settings.preferForTitles == true)
        #expect(settings.preferForContextSummaries == false)
        #expect(settings.exposeAsComposerModel == false)
    }

    @Test
    func localModelFileMatchQualityUsesApproximateSize() {
        let expected: Int64 = 1_000

        #expect(AgentLocalModelFileMatch.quality(bytes: 950, expectedBytes: expected) == .matched)
        #expect(AgentLocalModelFileMatch.quality(bytes: 1_250, expectedBytes: expected) == .close)
        #expect(AgentLocalModelFileMatch.quality(bytes: 1_600, expectedBytes: expected) == .mismatch)
    }

    @Test
    func localModelPromptingAddsLanguagePreferenceOnlyForLocalProviders() {
        let ollama = AgentConfiguration(
            providerID: AgentProviderPreset.ollamaID,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "qwen3.5-4b-q4_k_m",
            flashModel: "qwen3.5-4b-q4_k_m",
            proModel: "qwen3.5-4b-q4_k_m",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: ""
        )
        let lmStudio = AgentConfiguration(
            providerID: "custom-local",
            baseURL: "http://localhost:1234/v1",
            model: "local-model",
            flashModel: "local-model",
            proModel: "local-model",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: ""
        )
        let remote = AgentConfiguration(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini",
            flashModel: "gpt-4.1-mini",
            proModel: "gpt-4.1",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: "sk-test"
        )

        let ollamaPrompt = AgentLocalModelPrompting.applyLanguageInstruction(to: "BASE", configuration: ollama)
        let lmStudioPrompt = AgentLocalModelPrompting.applyLanguageInstruction(to: "BASE", configuration: lmStudio)
        let remotePrompt = AgentLocalModelPrompting.applyLanguageInstruction(to: "BASE", configuration: remote)

        #expect(ollamaPrompt.contains("LOCAL MODEL LANGUAGE PREFERENCE"))
        #expect(ollamaPrompt.contains("请优先使用"))
        #expect(lmStudioPrompt.contains("LOCAL MODEL LANGUAGE PREFERENCE"))
        #expect(remotePrompt == "BASE")
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
    func someIMPresetDefaultsToTheStandardTierForChat() {
        let preset = AgentProviderPreset.preset(id: "some-im")

        #expect(preset?.displayName == "some.im")
        // The flash/default slot is the 256K M tier; pro stays DeepSeek.
        #expect(preset?.defaultModel == "glm-5")
        #expect(preset?.defaultProModel == "deepseek-v4-pro")
    }

    @Test
    func someIMProviderEntryNormalizesLegacyDisplayName() {
        let entry = AgentProviderEntry(
            providerID: "some-im",
            displayName: "some.im (Rocky's relay)",
            baseURL: "https://some.im/v1",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )

        #expect(entry.displayName == "some.im")
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
        #expect(active?.flashPrimary == SomeIMIntegrationSettings.defaultTextModel)
        #expect(active?.proPrimary == SomeIMIntegrationSettings.defaultTextModel)
        #expect(appState.agentConfiguration.providerID == "some-im")
        #expect(appState.agentConfiguration.apiKey == "sk-some-im")
        #expect(appState.agentConfiguration.flashModel == SomeIMIntegrationSettings.defaultTextModel)
        #expect(appState.agentConfiguration.proModel == SomeIMIntegrationSettings.defaultTextModel)
    }

    @MainActor
    @Test("shared some.im login repairs an active provider with an empty library key")
    func sharedSessionReconciliationRepairsEmptyProviderKey() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        installEmptyActiveSomeIMProvider(in: appState)
        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("shared-login-key")

        #expect(appState.reconcileSomeIMProviderFromSharedSession())
        #expect(appState.agentProviderLibrary.active?.apiKey == "shared-login-key")
        #expect(appState.agentConfiguration.apiKey == "shared-login-key")
    }

    @MainActor
    @Test("turn preflight self-heals a missing some.im provider key")
    func turnPreflightRepairsSomeIMCredentialSplitBrain() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        installEmptyActiveSomeIMProvider(in: appState)
        let runtime = AgentRuntime(session: appState.startNewAgentSession())
        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("turn-repair-key")

        #expect(appState.repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime))
        #expect(appState.configurationForCurrentTurn(for: runtime).apiKey == "turn-repair-key")
    }

    @MainActor
    @Test("keyless active DeepSeek provider falls back to signed-in some.im")
    func keylessActiveProviderFallsBackToUsableSomeIM() throws {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let deepSeek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            apiKey: "",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let appState = AppState()
        appState.agentProviderLibrary = AgentProviderLibrary(entries: [deepSeek], activeID: deepSeek.id)
        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("shared-login-key")

        #expect(appState.reconcileSomeIMProviderFromSharedSession())
        #expect(appState.agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID)
        appState.startNewAgentSession()
        let runtime = try #require(appState.activeRuntime)
        #expect(appState.configurationForCurrentTurn(for: runtime).providerID == AgentProviderPreset.someIMID)
        #expect(appState.agentConfiguration.apiKey == "shared-login-key")
    }

    @MainActor
    @Test("model picker cannot activate a keyless provider entry")
    func selectingModelFromKeylessProviderIsIgnored() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let deepSeek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            apiKey: "",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let someIM = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            apiKey: "shared-login-key",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-pro"
        )
        let appState = AppState()
        appState.agentProviderLibrary = AgentProviderLibrary(entries: [deepSeek, someIM], activeID: someIM.id)

        appState.selectAgentEntryAndModel(entryID: deepSeek.id, model: "deepseek-v4-pro")

        #expect(appState.agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID)
        #expect(appState.agentConfiguration.providerID == AgentProviderPreset.someIMID)
    }

    @MainActor
    @Test("dispatch Worker pins some.im provider and Flash Responses independently of global provider")
    func dispatchWorkerPinsProviderAndResponsesTransport() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        let deepSeek = AgentProviderEntry(
            providerID: AgentProviderPreset.deepSeekID,
            baseURL: "https://api.deepseek.com",
            apiKey: "fixture-deepseek-key",
            flashPrimary: "deepseek-chat",
            proPrimary: "deepseek-reasoner"
        )
        let someIM = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: "https://some.im/v1",
            apiKey: "fixture-someim-key",
            flashPrimary: "deepseek-v4-flash",
            proPrimary: "deepseek-v4-flash",
            routingMode: .flash
        )
        let appState = AppState()
        appState.agentProviderLibrary = AgentProviderLibrary(
            entries: [deepSeek, someIM],
            activeID: deepSeek.id
        )
        let runtime = AgentRuntime(session: AgentSession())
        runtime.sessionProviderIDOverride = AgentProviderPreset.someIMID
        runtime.sessionModelOverride = "deepseek-v4-flash"

        let configuration = appState.configurationForCurrentTurn(for: runtime)

        #expect(configuration.providerID == AgentProviderPreset.someIMID)
        #expect(configuration.model == "deepseek-v4-flash")
        #expect(configuration.inferenceProviderKind == .openAIResponses)
        #expect(configuration.usesWillDeepGatewayResponsesState)
    }

    @MainActor
    @Test("relay location probe failure keeps the shared credential usable")
    func failedRelayProbeDoesNotBlockCredentialSync() async {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        installEmptyActiveSomeIMProvider(in: appState)
        let originalBaseURL = appState.agentConfiguration.baseURL
        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("offline-startup-key")

        await appState.refreshSomeIMRelayRouting {
            throw AgentClientError.invalidResponse
        }

        #expect(appState.agentConfiguration.apiKey == "offline-startup-key")
        #expect(appState.agentConfiguration.baseURL == originalBaseURL)
    }

    @Test("app startup reconciles shared credentials before async relay probing")
    func startupReconciliationPrecedesRelayProbe() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AppState.swift"),
            encoding: .utf8
        )
        let startupSequence = """
        reconcileSomeIMProviderFromSharedSession()
                Task { @MainActor [weak self] in
        """

        #expect(source.contains(startupSequence))
    }

    @Test("every Agent request entry point runs the some.im credential repair")
    func requestEntryPointsRepairSomeIMCredentials() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let loopSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AppStateAgentLoop.swift"),
            encoding: .utf8
        )
        let retrySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AppStateAgentErrors.swift"),
            encoding: .utf8
        )
        let repairBeforeSnapshot = """
        repairSomeIMProviderCredentialsForTurnIfNeeded(for: runtime)
                let configuration = configurationForCurrentTurn(for: runtime)
        """

        #expect(loopSource.components(separatedBy: repairBeforeSnapshot).count - 1 == 2)
        #expect(retrySource.contains(repairBeforeSnapshot))
    }

    @Test("managed routing pre-describes images before selecting a text-only tier")
    func managedRoutingPreparesImageDescriptionsBeforeRouteSelection() {
        #expect(AgentImagePreparationPolicy.requiresTextDescription(
            mainModelSupportsImages: true,
            usesManagedRouting: true
        ))
        #expect(AgentImagePreparationPolicy.requiresTextDescription(
            mainModelSupportsImages: false,
            usesManagedRouting: false
        ))
        #expect(!AgentImagePreparationPolicy.requiresTextDescription(
            mainModelSupportsImages: true,
            usesManagedRouting: false
        ))
    }

    @MainActor
    @Test
    func syncingSomeIMImageUnderstandingUsesResolvedRelayRoute() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        let settings = SomeIMIntegrationSettings(baseURL: SomeIMRelayRegion.internationalBaseURL)

        let appState = AppState()

        appState.syncSomeIMImageUnderstanding(apiKey: " sk-some-im ", settings: settings)

        let imageDescription = appState.agentConfiguration.imageDescription
        #expect(imageDescription.providerID == "some-im")
        #expect(imageDescription.baseURL == SomeIMRelayRegion.internationalBaseURL)
        #expect(imageDescription.model == SomeIMIntegrationSettings.defaultVisionModel)
        #expect(imageDescription.apiKey == "sk-some-im")
    }

    @MainActor
    /// Installs a some.im entry carrying the kind of state a user accumulates:
    /// a chosen pro model, alternates, a routing mode. All of it is lost if the
    /// entry is destroyed and rebuilt, because the rebuild finds no existing
    /// entry to inherit from — it draws a fresh UUID and falls back to preset
    /// defaults. (`displayName` is deliberately not part of this: some.im's is
    /// force-normalized to the preset name and was never the user's to keep.)
    @discardableResult
    private func installCustomizedSomeIMProvider(in appState: AppState) -> AgentProviderEntry {
        let entry = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: SomeIMRelayRegion.internationalBaseURL,
            apiKey: "entry-key",
            flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
            flashAlternates: ["deepseek-v4-flash"],
            proPrimary: "glm-5",
            routingMode: .pro
        )
        appState.agentProviderLibrary = AgentProviderLibrary(entries: [entry], activeID: entry.id)
        return entry
    }

    /// The reported bug: the model picker would empty out for a few seconds and
    /// then refill. A routine reconcile read the shared session, got nothing
    /// back, and treated that as a sign-out — deleting the provider entry and
    /// its Keychain row. An empty read is not proof of a sign-out; it is also
    /// what a reader sees when it races a concurrent Keychain write.
    @MainActor
    @Test("a routine empty shared-session read leaves the some.im provider intact")
    func routineReconcileDoesNotDestroyProviderOnEmptyRead() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        let entry = installCustomizedSomeIMProvider(in: appState)
        defer { appState.cancelSomeIMSignOutConfirmation() }

        // Shared session reads empty — no key was ever put in the override.
        #expect(appState.reconcileSomeIMProviderFromSharedSession() == false)

        let survivor = appState.agentProviderLibrary.entries.first
        #expect(appState.agentProviderLibrary.entries.count == 1)
        #expect(survivor?.id == entry.id)              // same UUID: overrides still resolve
        #expect(survivor?.proPrimary == "glm-5")
        #expect(survivor?.flashAlternates == ["deepseek-v4-flash"])
        #expect(survivor?.routingMode == .pro)
        // The entry carries its own key, so the picker still lists its models.
        #expect(survivor?.isUsableForChatSelection(isSomeIMAuthenticated: false) == true)
    }

    /// The counterpart: an actual sign-out must still take effect immediately,
    /// which is why the trigger is explicit rather than inferred from the read.
    @MainActor
    @Test("an explicit sign-out drops the some.im provider right away")
    func signOutTriggerClearsProviderImmediately() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        installCustomizedSomeIMProvider(in: appState)
        defer { appState.cancelSomeIMSignOutConfirmation() }

        #expect(appState.reconcileSomeIMProviderFromSharedSession(trigger: .signOut) == false)
        #expect(appState.agentProviderLibrary.entries.isEmpty)
    }

    /// A shared session that reads back fine must cancel any pending
    /// confirmation, or a sign-out scheduled a moment earlier would fire after
    /// the user is already signed back in.
    @MainActor
    @Test("a successful read cancels a pending sign-out confirmation")
    func successfulReadCancelsPendingSignOutConfirmation() {
        let sandbox = KeychainSandbox()
        _ = sandbox
        SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: true)
        defer { SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false) }

        let appState = AppState()
        installCustomizedSomeIMProvider(in: appState)
        defer { appState.cancelSomeIMSignOutConfirmation() }

        #expect(appState.reconcileSomeIMProviderFromSharedSession() == false)
        #expect(appState.someIMSignOutConfirmationTask != nil)

        SomeIMIntegrationStore._setTestSharedAPIKeyWithoutNotification("back-again-key")
        #expect(appState.reconcileSomeIMProviderFromSharedSession())
        #expect(appState.someIMSignOutConfirmationTask == nil)
        #expect(appState.agentProviderLibrary.entries.count == 1)
    }

    private func installEmptyActiveSomeIMProvider(in appState: AppState) {
        let entry = AgentProviderEntry(
            providerID: AgentProviderPreset.someIMID,
            baseURL: SomeIMRelayRegion.internationalBaseURL,
            apiKey: "",
            flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
            proPrimary: SomeIMIntegrationSettings.defaultTextModel,
            routingMode: .flash
        )
        appState.agentProviderLibrary = AgentProviderLibrary(entries: [entry], activeID: entry.id)
        #expect(appState.agentConfiguration.providerID == AgentProviderPreset.someIMID)
        #expect(appState.agentConfiguration.apiKey.isEmpty)
    }

    @MainActor
    @Test
    func syncingLocalModelComposerProviderAddsAndRemovesBackupEntry() {
        let sandbox = KeychainSandbox()
        _ = sandbox

        let appState = AppState()
        let settings = AgentLocalModelSettings(
            enabled: true,
            baseURL: " http://127.0.0.1:11434/v1 ",
            visionModel: "qwen-vl-local",
            summaryModel: "qwen-chat-local",
            preferForImageUnderstanding: true,
            preferForTitles: true,
            preferForContextSummaries: false,
            exposeAsComposerModel: true,
            composerDisplayName: " Offline Local "
        )

        appState.syncLocalModelComposerProvider(settings: settings)

        let entry = appState.agentProviderLibrary.entries.first {
            $0.id == AgentLocalModelSettings.composerProviderEntryID
        }
        #expect(entry?.providerID == AgentProviderPreset.ollamaID)
        #expect(entry?.displayName == "Offline Local")
        #expect(entry?.baseURL == AgentLocalModelSettings.defaultBaseURL)
        #expect(entry?.flashPrimary == "qwen-chat-local")
        #expect(entry?.flashAlternates == ["qwen-vl-local"])
        #expect(entry?.apiKey == "")

        var disabled = settings
        disabled.exposeAsComposerModel = false
        appState.syncLocalModelComposerProvider(settings: disabled)

        #expect(!appState.agentProviderLibrary.entries.contains {
            $0.id == AgentLocalModelSettings.composerProviderEntryID
        })
    }

    // MARK: - Bug fix: image_url sent to text-only model through a relay

    @Test
    func textOnlyModelsRejectImageInputEvenOnImageCapableProvider() {
        // Bug 现场：some.im 是多模型中转，provider 级 supportsImageInput
        // 为 true；但用户实际跑的是纯文本的 deepseek-v4-flash，历史消息里
        // 的图片被编码成 image_url part，整个请求被 API 以
        // "unknown variant `image_url`, expected `text`" 400 掉。
        // 修复后 supportsImageInput 必须叠加模型级判断。
        #expect(!AgentConfiguration.modelAcceptsImageInput("deepseek-v4-flash"))
        #expect(!AgentConfiguration.modelAcceptsImageInput("deepseek-v4-pro"))
        #expect(!AgentConfiguration.modelAcceptsImageInput("DeepSeek-Coder-33B"))
        #expect(!AgentConfiguration.modelAcceptsImageInput("someim-auto-flash"))
        // 视觉家族与未知模型保持支持，不误伤多模态自定义模型。
        #expect(AgentConfiguration.modelAcceptsImageInput("deepseek-vl2"))
        #expect(AgentConfiguration.modelAcceptsImageInput("gpt-4o"))
        #expect(AgentConfiguration.modelAcceptsImageInput("qwen3-vl-plus"))

        let someIMTextConfig = AgentConfiguration(
            providerID: "some-im",
            baseURL: "https://some.im/v1",
            model: "deepseek-v4-flash",
            flashModel: "deepseek-v4-flash",
            proModel: "deepseek-v4-pro",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: "sk-test"
        )
        #expect(!someIMTextConfig.supportsImageInput)

        let someIMVisionConfig = AgentConfiguration(
            providerID: "some-im",
            baseURL: "https://some.im/v1",
            model: "gpt-4o",
            flashModel: "gpt-4o",
            proModel: "gpt-4o",
            routingMode: .flash,
            imageDescription: .default,
            apiKey: "sk-test"
        )
        #expect(someIMVisionConfig.supportsImageInput)
    }

    @Test("image route retry is bounded to three exponential retries for one exact transient 422")
    func imageRouteRetryIsStrictlyBounded() {
        let routeError = AgentClientError.serverStatus(
            AgentProviderHTTPError(
                statusCode: 422,
                method: "POST",
                url: "https://relay.example/v1/chat/completions",
                providerID: "some-im",
                model: "qwen3-vl-plus",
                requestSummary: "",
                requestBody: "",
                responseBody: #"{"message":"no route can preserve requested chat_completions capabilities: input_modality:image"}"#
            )
        )

        #expect(AgentImageDescriptionRetryPolicy.shouldRetry(routeError, retryCount: 0))
        #expect(AgentImageDescriptionRetryPolicy.shouldRetry(routeError, retryCount: 1))
        #expect(AgentImageDescriptionRetryPolicy.shouldRetry(routeError, retryCount: 2))
        #expect(!AgentImageDescriptionRetryPolicy.shouldRetry(routeError, retryCount: 3))
        #expect(AgentImageDescriptionRetryPolicy.maximumRetryCount == 3)
        #expect(AgentImageDescriptionRetryPolicy.retryDelayNanoseconds(for: 0) == 800_000_000)
        #expect(AgentImageDescriptionRetryPolicy.retryDelayNanoseconds(for: 1) == 1_600_000_000)
        #expect(AgentImageDescriptionRetryPolicy.retryDelayNanoseconds(for: 2) == 3_200_000_000)

        let unrelated422 = AgentClientError.serverStatus(
            AgentProviderHTTPError(
                statusCode: 422,
                method: "POST",
                url: "https://relay.example/v1/chat/completions",
                providerID: "some-im",
                model: "qwen3-vl-plus",
                requestSummary: "",
                requestBody: "",
                responseBody: #"{"message":"invalid request body"}"#
            )
        )
        #expect(!AgentImageDescriptionRetryPolicy.shouldRetry(unrelated422, retryCount: 0))
    }

    @Test("image description errors identify the vision stage")
    func imageDescriptionErrorsIdentifyVisionStage() {
        let providerError = AgentProviderHTTPError(
            statusCode: 422,
            method: "POST",
            url: "https://relay.example/v1/chat/completions",
            providerID: "some-im",
            model: "qwen3-vl-plus",
            requestSummary: "",
            requestBody: "",
            responseBody: #"{"message":"no route can preserve requested chat_completions capabilities: input_modality:image"}"#
        )
        let error = AgentClientError.imageDescriptionServerStatus(providerError)
        let message = AppState.friendlyMessage(for: error)
        let details = AppState.details(for: error)

        #expect(message.contains("视觉模型 qwen3-vl-plus"))
        #expect(message.contains("图片尚未交给纯文本主模型"))
        #expect(details?.sections.first?.title == "Image Understanding Request")
    }
}
