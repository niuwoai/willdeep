//
//  L10n+AgentModelPicker.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum AgentModelPicker {
        static let selectModel = String(localized: "agent-model-picker.title", defaultValue: "Select Model")
        static let searchPlaceholder = String(localized: "agent-model-picker.search-placeholder", defaultValue: "Search models or providers")
        static let managed = String(localized: "agent-model-picker.managed", defaultValue: "Managed")
        static let managedSubtitle = String(localized: "agent-model-picker.managed-subtitle", defaultValue: "Automatically select a model")
        static let allModels = String(localized: "agent-model-picker.all-models", defaultValue: "All Models")
        static let codingRecommended = String(localized: "agent-model-picker.coding-recommended", defaultValue: "Coding Picks")
        static let recent = String(localized: "agent-model-picker.recent", defaultValue: "Recently Used")
        static let providers = String(localized: "agent-model-picker.providers", defaultValue: "Providers")
        static let current = String(localized: "agent-model-picker.current", defaultValue: "Current")
        static let generalTask = String(localized: "agent-model-picker.general-task", defaultValue: "General task")
        static let codingTask = String(localized: "agent-model-picker.coding-task", defaultValue: "Coding task")
        static let resetToFlash = String(localized: "agent-model-picker.reset-flash", defaultValue: "Reset to Flash")
        static let codingPicks = String(localized: "agent-model-picker.coding-picks", defaultValue: "Coding Picks")
        static let viewAll = String(localized: "agent-model-picker.view-all", defaultValue: "View all models")
        static let selectionFooter = String(localized: "agent-model-picker.selection-footer", defaultValue: "Selecting a model switches the provider and model for this conversation")
        static let routeDefault = String(localized: "agent-model-picker.route-default", defaultValue: "Provider Default")
        static let all = String(localized: "agent-model-picker.filter.all", defaultValue: "All")
        static let flash = String(localized: "agent-model-picker.filter.flash", defaultValue: "Flash")
        static let pro = String(localized: "agent-model-picker.filter.pro", defaultValue: "Pro")
        static let loadingModels = String(localized: "agent-model-picker.loading", defaultValue: "Loading model catalog…")
        static let retryCatalog = String(localized: "agent-model-picker.retry-catalog", defaultValue: "Retry catalog refresh")
        static let noModels = String(localized: "agent-model-picker.no-models", defaultValue: "No models are available from this provider")
        static let noResults = String(localized: "agent-model-picker.no-results", defaultValue: "No matching models")
        static let clearSearch = String(localized: "agent-model-picker.clear-search", defaultValue: "Clear Search")
        static let enableManaged = String(localized: "agent-model-picker.enable-managed", defaultValue: "Enable Managed Routing")
        static let managedRule = String(localized: "agent-model-picker.managed-rule", defaultValue: "General tasks always use someim-auto-*; Coding Plan is used only for coding tasks")
        static let chooseHelp = String(localized: "agent-model-picker.choose-help", defaultValue: "Choose a model and provider")
        static let someIMDisconnected = String(localized: "agent-model-picker.some-im-disconnected", defaultValue: "some.im is not connected")
        static let someIMConnectHint = String(localized: "agent-model-picker.some-im-connect-hint", defaultValue: "Connect to use Managed Routing, Coding Plan, and recommendations")
        static let viewPlans = String(localized: "agent-model-picker.view-plans", defaultValue: "View Plans")
        static let autoUpgrade = String(localized: "agent-model-picker.auto-upgrade", defaultValue: "Auto upgraded")
        static let recommended = String(localized: "agent-model-picker.recommended", defaultValue: "Recommended")
        static let coding = String(localized: "agent-model-picker.tag.coding", defaultValue: "Coding")
        static let fast = String(localized: "agent-model-picker.tag.fast", defaultValue: "Fast")
        static let affordable = String(localized: "agent-model-picker.tag.affordable", defaultValue: "Affordable")
        static let complexCodingNote = String(localized: "agent-model-picker.note.complex-coding", defaultValue: "Complex refactors, multi-file reasoning, and difficult debugging")
        static let repositoryCodingNote = String(localized: "agent-model-picker.note.repository-coding", defaultValue: "Repository implementation and fixes")
        static let dailyCodingNote = String(localized: "agent-model-picker.note.daily-coding", defaultValue: "Daily coding and quick edits")
        static let fastCodingNote = String(localized: "agent-model-picker.note.fast-coding", defaultValue: "Stable, low-latency daily development")

        static func modelCount(_ count: Int) -> String {
            let template = String(localized: "agent-model-picker.model-count", defaultValue: "%lld models")
            return String(format: template, Int64(count))
        }

        static func resultCount(_ count: Int) -> String {
            let template = String(localized: "agent-model-picker.result-count", defaultValue: "%lld results")
            return String(format: template, Int64(count))
        }

        static func upgradeTo(_ tier: String) -> String {
            let template = String(localized: "agent-model-picker.upgrade-to", defaultValue: "Upgrade this conversation to %@")
            return String(format: template, tier)
        }
    }
}
