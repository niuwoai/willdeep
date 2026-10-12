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
        static let managedSubtitle = String(localized: "agent-model-picker.managed-subtitle", defaultValue: "Flash first, task-local recovery")
        static let allModels = String(localized: "agent-model-picker.all-models", defaultValue: "All Models")
        static let codingRecommended = String(localized: "agent-model-picker.coding-recommended", defaultValue: "Coding Picks")
        static let free = String(localized: "agent-model-picker.free", defaultValue: "Free")
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
        static let managedSelectedTitle = String(localized: "agent-model-picker.managed-selected-title", defaultValue: "Managed Routing is selected")
        static let managedSelectedDescription = String(localized: "agent-model-picker.managed-selected-description", defaultValue: "New tasks start on Flash. Only an explicit generation failure switches the current task to another model.")
        static let managedNotSelectedTitle = String(localized: "agent-model-picker.managed-not-selected-title", defaultValue: "Managed Routing is not selected")
        static let managedNotSelectedDescription = String(localized: "agent-model-picker.managed-not-selected-description", defaultValue: "This conversation is using a specific model. Switch back when you want some.im to handle model selection.")
        static let managedLoginRequiredTitle = String(localized: "agent-model-picker.managed-login-required-title", defaultValue: "Sign in to use Managed Routing")
        static let managedLoginRequiredDescription = String(localized: "agent-model-picker.managed-login-required-description", defaultValue: "Sign in to some.im to enable Managed Routing.")
        static let selectManaged = String(localized: "agent-model-picker.select-managed", defaultValue: "Select Managed Routing")
        static let signInSomeIM = String(localized: "agent-model-picker.sign-in-some-im", defaultValue: "Sign in to some.im")
        static let managedBenefitsTitle = String(localized: "agent-model-picker.managed-benefits-title", defaultValue: "How managed tasks run")
        static let managedJudgeTitle = String(localized: "agent-model-picker.managed-judge-title", defaultValue: "Starts on Flash")
        static let managedJudgeDescription = String(localized: "agent-model-picker.managed-judge-description", defaultValue: "No difficulty classification request. Every new task starts on Flash.")
        static let managedWorkerTitle = String(localized: "agent-model-picker.managed-worker-title", defaultValue: "Recover only after explicit failure")
        static let managedWorkerDescription = String(localized: "agent-model-picker.managed-worker-description", defaultValue: "Empty or looping output can trigger one retry per turn. Automatic continuations keep the takeover; a new task returns to Flash.")
        static let managedRule = String(localized: "agent-model-picker.managed-rule", defaultValue: "Starts on Flash; switches models only after an explicit failure, for the current task.")
        static let chooseHelp = String(localized: "agent-model-picker.choose-help", defaultValue: "Choose a model and provider")
        static let someIMDisconnected = String(localized: "agent-model-picker.some-im-disconnected", defaultValue: "some.im is not connected")
        static let someIMConnectHint = String(localized: "agent-model-picker.some-im-connect-hint", defaultValue: "Connect to use Managed Routing and recommendations")
        static let viewPlans = String(localized: "agent-model-picker.view-plans", defaultValue: "View Plans")
        static let autoUpgrade = String(localized: "agent-model-picker.auto-upgrade", defaultValue: "Auto upgraded")
        static let recommended = String(localized: "agent-model-picker.recommended", defaultValue: "Recommended")
        static let coding = String(localized: "agent-model-picker.tag.coding", defaultValue: "Coding")
        static let fast = String(localized: "agent-model-picker.tag.fast", defaultValue: "Fast")
        static let affordable = String(localized: "agent-model-picker.tag.affordable", defaultValue: "Affordable")
        static let localLLM = String(localized: "agent-model-picker.tag.local-llm", defaultValue: "Local LLM")
        static let complexCodingNote = String(localized: "agent-model-picker.note.complex-coding", defaultValue: "Complex refactors, multi-file reasoning, and difficult debugging")
        static let repositoryCodingNote = String(localized: "agent-model-picker.note.repository-coding", defaultValue: "Repository implementation and fixes")
        static let dailyCodingNote = String(localized: "agent-model-picker.note.daily-coding", defaultValue: "Daily coding and quick edits")
        static let fastCodingNote = String(localized: "agent-model-picker.note.fast-coding", defaultValue: "Stable, low-latency daily development")

        static func modelChanged(from oldModel: String, to newModel: String) -> String {
            let template = String(localized: "agent-model-picker.model-changed", defaultValue: "Model changed from %@ to %@.")
            return String(format: template, oldModel, newModel)
        }

        /// 跟在「模型已从 X 改为 Y」后面的一句。说的是事实，不预测秒数——
        /// 冷预填有多慢取决于 provider 的吞吐，给一个站不住的数字比不给更糟。
        static func modelChangedCacheWarning(_ approximateTokens: String) -> String {
            let template = String(
                localized: "agent-model-picker.model-changed-cache-warning",
                defaultValue: "This discards the prompt cache: the next turn reprocesses about %@ tokens cold, so its first response will take noticeably longer."
            )
            return String(format: template, approximateTokens)
        }

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
