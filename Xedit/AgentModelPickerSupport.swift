//
//  AgentModelPickerSupport.swift
//  WillDeep
//
//  Pure catalog helpers shared by the Composer model picker and its tests.
//

import Foundation

enum AgentModelPickerSource: Hashable {
    case managed
    case allModels
    case codingRecommended
    case recent
    case provider(UUID)
}

enum AgentManagedMarketingStatus: Equatable {
    case selected
    case available
    case loginRequired

    static func resolve(isAuthenticated: Bool, isManagedActive: Bool) -> Self {
        guard isAuthenticated else { return .loginRequired }
        return isManagedActive ? .selected : .available
    }
}

enum AgentModelPickerPresentation {
    static func pillLabel(
        managedActive: Bool,
        currentModelLabel: String,
        managedLabel: String,
        selectModelLabel: String
    ) -> String {
        if managedActive { return managedLabel }
        return currentModelLabel.isEmpty ? selectModelLabel : currentModelLabel
    }
}

enum AgentModelPickerTierFilter: String, CaseIterable, Identifiable {
    case all
    case flash
    case pro

    var id: String { rawValue }
}

struct AgentModelCatalogItem: Identifiable, Equatable {
    let providerEntryID: UUID
    let providerID: String
    let providerName: String
    let modelID: String
    let tier: AgentModelPickerTierFilter?

    var id: String {
        "\(providerEntryID.uuidString)::\(modelID.lowercased())"
    }
}

enum AgentModelPickerCatalog {
    static func items(
        entries: [AgentProviderEntry],
        fetchedByProvider: [UUID: [String]]
    ) -> [AgentModelCatalogItem] {
        entries.flatMap { entry in
            models(for: entry, fetchedModels: fetchedByProvider[entry.id] ?? [])
                .map { model in
                    AgentModelCatalogItem(
                        providerEntryID: entry.id,
                        providerID: entry.providerID,
                        providerName: entry.displayName,
                        modelID: model,
                        tier: tier(for: model, in: entry)
                    )
                }
        }
    }

    static func models(
        for entry: AgentProviderEntry,
        fetchedModels: [String]
    ) -> [String] {
        deduplicated(
            entry.allFlashModels
                + entry.allProModels
                + fetchedModels
        )
    }

    static func search(_ items: [AgentModelCatalogItem], query: String) -> [AgentModelCatalogItem] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            normalized(item.modelID).contains(needle)
                || normalized(item.providerName).contains(needle)
                || normalized(item.providerID).contains(needle)
        }
    }

    static func filtered(
        _ items: [AgentModelCatalogItem],
        by filter: AgentModelPickerTierFilter
    ) -> [AgentModelCatalogItem] {
        guard filter != .all else { return items }
        return items.filter { $0.tier == filter }
    }

    private static func tier(for model: String, in entry: AgentProviderEntry) -> AgentModelPickerTierFilter? {
        if contains(model, in: entry.allFlashModels) { return .flash }
        if contains(model, in: entry.allProModels) { return .pro }
        return nil
    }

    private static func contains(_ model: String, in models: [String]) -> Bool {
        models.contains { $0.caseInsensitiveCompare(model) == .orderedSame }
    }

    private static func deduplicated(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { raw in
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(normalized(model)).inserted else { return nil }
            return model
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
