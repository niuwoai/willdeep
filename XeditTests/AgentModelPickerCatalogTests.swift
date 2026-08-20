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
            fetchedByProvider: [someIM.id: ["glm-5.2"]]
        )
        let results = AgentModelPickerCatalog.search(items, query: "glm-5.2")
        #expect(results.map(\.providerName) == ["some.im", "Custom Relay", "Custom Relay"])
        #expect(Set(results.map(\.id)).count == results.count)
    }

    @Test
    func deduplicatesModelsInsideOneProviderCaseInsensitively() {
        let models = AgentModelPickerCatalog.models(
            for: someIM,
            fetchedModels: ["GLM-5.2", "glm-5.2", " deepseek-v4-flash "]
        )
        #expect(models == ["deepseek-v4-flash", "deepseek-v4-pro", "GLM-5.2"])
    }

    @Test
    func globalSearchMatchesProviderName() {
        let items = AgentModelPickerCatalog.items(
            entries: [someIM, custom],
            fetchedByProvider: [:]
        )
        let results = AgentModelPickerCatalog.search(items, query: "custom relay")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.providerEntryID == custom.id })
    }

    @Test
    func tierFilterUsesConfiguredFlashAndProModels() {
        let items = AgentModelPickerCatalog.items(
            entries: [someIM],
            fetchedByProvider: [:]
        )
        #expect(AgentModelPickerCatalog.filtered(items, by: .flash).map(\.modelID) == ["deepseek-v4-flash"])
        #expect(AgentModelPickerCatalog.filtered(items, by: .pro).map(\.modelID) == ["deepseek-v4-pro"])
    }

    @Test
    func providerCountContainsOnlyConfiguredAndProviderFetchedModels() {
        let fetched = (1...10).map { "wd/model-\($0)" }
        let entry = AgentProviderEntry(
            providerID: AgentProviderPreset.customID,
            displayName: "wd",
            baseURL: "https://example.invalid/v1",
            flashPrimary: fetched[0],
            proPrimary: fetched[0]
        )

        let items = AgentModelPickerCatalog.items(
            entries: [entry],
            fetchedByProvider: [entry.id: fetched]
        )

        #expect(items.count == 10)
        #expect(items.map(\.modelID) == fetched)
    }

    @Test
    func managedMarketingStatusSeparatesSelectionFromAuthentication() {
        #expect(AgentManagedMarketingStatus.resolve(
            isAuthenticated: true,
            isManagedActive: true
        ) == .selected)
        #expect(AgentManagedMarketingStatus.resolve(
            isAuthenticated: true,
            isManagedActive: false
        ) == .available)
        #expect(AgentManagedMarketingStatus.resolve(
            isAuthenticated: false,
            isManagedActive: true
        ) == .loginRequired)
    }

    @Test
    func managedPillNeverExposesResolvedModelOrTier() {
        let label = AgentModelPickerPresentation.pillLabel(
            managedActive: true,
            currentModelLabel: "some.im · Auto Flash",
            managedLabel: "省心托管",
            selectModelLabel: "选择模型"
        )
        #expect(label == "省心托管")
    }

    @Test
    func codingRecommendationsExposeRequestedSomeIMModelsWithDeepSeekDefaultFirst() {
        let recommendations = ModelPickerPill.codingRecommendations

        #expect(recommendations.first?.providerID == AgentProviderPreset.someIMID)
        #expect(recommendations.first?.model == SomeIMIntegrationSettings.defaultTextModel)
        // glm-5 leads because it is the new-session default; the 1M
        // deepseek-v4-flash stays recommended but no longer first.
        #expect(Set(recommendations.prefix(4).map(\.model)) == [
            "glm-5",
            "deepseek-v4-flash",
            "gpt-5.6-sol",
            "gpt-5.6-luna",
        ])
        #expect(recommendations.prefix(4).allSatisfy {
            $0.providerID == AgentProviderPreset.someIMID
        })
    }
}
