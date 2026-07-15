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
        fetchedByProvider: [UUID: [String]],
        fallbackKnownModels: [String],
        activeProviderID: UUID?
    ) -> [AgentModelCatalogItem] {
        entries.flatMap { entry in
            let fallback = entry.id == activeProviderID ? fallbackKnownModels : []
            return models(for: entry, fetchedModels: fetchedByProvider[entry.id] ?? [], fallbackModels: fallback)
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
        fetchedModels: [String],
        fallbackModels: [String]
    ) -> [String] {
        deduplicated(
            entry.allFlashModels
                + entry.allProModels
                + fetchedModels
                + fallbackModels.filter { modelIsCompatible($0, with: entry) }
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

    private static func modelIsCompatible(_ model: String, with entry: AgentProviderEntry) -> Bool {
        guard let preset = AgentProviderPreset.preset(id: entry.providerID),
              preset.id != AgentProviderPreset.customID else {
            return true
        }
        return preset.recognizesModelID(model)
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
