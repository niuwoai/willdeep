//
//  AgentProviderLibraryTests.swift
//  VeilWriterTests
//
//  Covers the multi-provider library data layer + the
//  AgentConfiguration normalization bug fix that drops stale model
//  names carried over from a previous provider.
//

import Testing
import Foundation
@testable import VeilWriter

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
}
