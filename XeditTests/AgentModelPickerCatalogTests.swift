//
//  AgentModelPickerCatalogTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentModelPickerCatalogTests {
    private let someIM = AgentProviderEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        providerID: AgentProviderPreset.someIMID,
        displayName: "some.im",
        baseURL: "https://some.im/v1",
        flashPrimary: "deepseek-v4-flash",
        proPrimary: "deepseek-v4-pro"
    )

    private let custom = AgentProviderEntry(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        providerID: AgentProviderPreset.customID,
        displayName: "Custom Relay",
        baseURL: "https://example.invalid/v1",
        flashPrimary: "glm-5.2",
        proPrimary: "glm-5.2-pro"
    )

    @Test
    func keepsSameModelAsSeparateRowsAcrossProviders() {
        let items = AgentModelPickerCatalog.items(
            entries: [someIM, custom],
            fetchedByProvider: [someIM.id: ["glm-5.2"]],
            fallbackKnownModels: [],
            activeProviderID: someIM.id
        )
        let results = AgentModelPickerCatalog.search(items, query: "glm-5.2")
        #expect(results.map(\.providerName) == ["some.im", "Custom Relay", "Custom Relay"])
        #expect(Set(results.map(\.id)).count == results.count)
    }

    @Test
    func deduplicatesModelsInsideOneProviderCaseInsensitively() {
        let models = AgentModelPickerCatalog.models(
            for: someIM,
            fetchedModels: ["GLM-5.2", "glm-5.2", " deepseek-v4-flash "],
            fallbackModels: []
        )
        #expect(models == ["deepseek-v4-flash", "deepseek-v4-pro", "GLM-5.2"])
    }

    @Test
    func globalSearchMatchesProviderName() {
        let items = AgentModelPickerCatalog.items(
            entries: [someIM, custom],
            fetchedByProvider: [:],
            fallbackKnownModels: [],
            activeProviderID: someIM.id
        )
        let results = AgentModelPickerCatalog.search(items, query: "custom relay")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.providerEntryID == custom.id })
    }

    @Test
    func tierFilterUsesConfiguredFlashAndProModels() {
        let items = AgentModelPickerCatalog.items(
            entries: [someIM],
            fetchedByProvider: [:],
            fallbackKnownModels: [],
            activeProviderID: someIM.id
        )
        #expect(AgentModelPickerCatalog.filtered(items, by: .flash).map(\.modelID) == ["deepseek-v4-flash"])
        #expect(AgentModelPickerCatalog.filtered(items, by: .pro).map(\.modelID) == ["deepseek-v4-pro"])
    }
}
