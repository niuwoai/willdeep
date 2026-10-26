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
    /// Models the provider's own price list reports at zero cost. Only shown
    /// when a price list actually said so — see `AgentModelCatalogItem.isFree`.
    case free
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
    static let compactLabelMaxWidth: CGFloat = 160

    static func pillLabel(
        managedActive: Bool,
        currentModelLabel: String,
        providerDisplayName: String? = nil,
        managedLabel: String,
        selectModelLabel: String
    ) -> String {
        if managedActive { return currentModelLabel.isEmpty ? managedLabel : currentModelLabel }
        let prefix = providerDisplayName.map { "\($0) · " }
        let modelLabel: String
        if let prefix, currentModelLabel.hasPrefix(prefix) {
            modelLabel = String(currentModelLabel.dropFirst(prefix.count))
        } else {
            modelLabel = currentModelLabel
        }
        return modelLabel.isEmpty ? selectModelLabel : modelLabel
    }
}

/// Identity of the picker's detail scroll view.
///
/// The detail column is one `ScrollView` reused by every source, and its scroll
/// offset does not reset when the content underneath changes. Scroll deep into
/// "All models" (dozens of entries), switch to "Coding picks" (a handful), and
/// the offset stays put — now past the end of the new, much shorter content.
/// The `LazyVStack` inside then has no visible range to populate and builds
/// nothing at all, so the panel goes blank: not even the section header, which
/// is itself just another lazy row.
///
/// Making the scroll view's identity depend on what it is showing rebuilds it
/// on every switch, which puts the offset back at the top where the content is.
struct AgentModelDetailScrollIdentity: Hashable {
    let source: AgentModelPickerSource
    /// Entering or leaving search swaps the whole content set, same as a source
    /// switch. Keystrokes *within* a search do not rebuild — results only get
    /// shorter from an already-topped-out scroll position.
    let isSearching: Bool
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
    let isPrimaryFlashModel: Bool
    /// nil when no price list covered this model. Unknown is deliberately not
    /// folded into false: a free group built from unknowns would advertise paid
    /// models as free.
    var isFree: Bool?

    var id: String {
        "\(providerEntryID.uuidString)::\(modelID.lowercased())"
    }
}

enum AgentModelPickerCatalog {
    static func prefixGroups(_ items: [AgentModelCatalogItem]) -> [(prefix: String, items: [AgentModelCatalogItem])] {
        var orderedPrefixes: [String] = []
        var groupedItems: [String: [AgentModelCatalogItem]] = [:]
        for item in items {
            guard let separator = item.modelID.firstIndex(of: "/") else { continue }
            let prefix = String(item.modelID[..<separator])
            guard !prefix.isEmpty else { continue }
            if groupedItems[prefix] == nil {
                orderedPrefixes.append(prefix)
                groupedItems[prefix] = []
            }
            groupedItems[prefix, default: []].append(item)
        }
        return orderedPrefixes.compactMap { prefix in
            groupedItems[prefix].map { (prefix: prefix, items: $0) }
        }
    }

    static func itemsWithoutPrefix(_ items: [AgentModelCatalogItem]) -> [AgentModelCatalogItem] {
        items.filter { item in
            guard let separator = item.modelID.firstIndex(of: "/") else { return true }
            return separator == item.modelID.startIndex
        }
    }

    static func items(
        entries: [AgentProviderEntry],
        fetchedByProvider: [UUID: [String]],
        freeModelIDs: Set<String> = []
    ) -> [AgentModelCatalogItem] {
        let free = Set(freeModelIDs.map { $0.lowercased() })
        return entries.flatMap { entry in
            models(for: entry, fetchedModels: fetchedByProvider[entry.id] ?? [])
                .map { model in
                    AgentModelCatalogItem(
                        providerEntryID: entry.id,
                        providerID: entry.providerID,
                        providerName: entry.displayName,
                        modelID: model,
                        tier: tier(for: model, in: entry),
                        isPrimaryFlashModel: entry.flashPrimary.caseInsensitiveCompare(model) == .orderedSame,
                        isFree: free.isEmpty ? nil : free.contains(model.lowercased())
                    )
                }
        }
    }

    /// Only the models a price list positively reported as free.
    static func freeItems(_ items: [AgentModelCatalogItem]) -> [AgentModelCatalogItem] {
        items.filter { $0.isFree == true }
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
            guard !model.isEmpty, !SomeIMManagedModel.isRetired(model), seen.insert(normalized(model)).inserted else { return nil }
            return model
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
