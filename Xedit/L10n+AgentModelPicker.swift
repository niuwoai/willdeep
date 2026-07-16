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
        static let managedSelectedTitle = String(localized: "agent-model-picker.managed-selected-title", defaultValue: "Managed Routing is selected")
        static let managedSelectedDescription = String(localized: "agent-model-picker.managed-selected-description", defaultValue: "This conversation uses a judge to choose and validate the working model automatically.")
        static let managedNotSelectedTitle = String(localized: "agent-model-picker.managed-not-selected-title", defaultValue: "Managed Routing is not selected")
        static let managedNotSelectedDescription = String(localized: "agent-model-picker.managed-not-selected-description", defaultValue: "This conversation is using a specific model. Switch back when you want some.im to handle model selection.")
        static let managedLoginRequiredTitle = String(localized: "agent-model-picker.managed-login-required-title", defaultValue: "Sign in to use Managed Routing")
        static let managedLoginRequiredDescription = String(localized: "agent-model-picker.managed-login-required-description", defaultValue: "Sign in to some.im to enable Managed Routing. Coding Plan is optional and is not required.")
        static let selectManaged = String(localized: "agent-model-picker.select-managed", defaultValue: "Select Managed Routing")
        static let signInSomeIM = String(localized: "agent-model-picker.sign-in-some-im", defaultValue: "Sign in to some.im")
        static let managedBenefitsTitle = String(localized: "agent-model-picker.managed-benefits-title", defaultValue: "Two-model collaboration")
        static let managedJudgeTitle = String(localized: "agent-model-picker.managed-judge-title", defaultValue: "Judge: selection and validation")
        static let managedJudgeDescription = String(localized: "agent-model-picker.managed-judge-description", defaultValue: "A judge identifies the task and difficulty, chooses the working model, and validates the result.")
        static let managedWorkerTitle = String(localized: "agent-model-picker.managed-worker-title", defaultValue: "Worker: cost first, capability when needed")
        static let managedWorkerDescription = String(localized: "agent-model-picker.managed-worker-description", defaultValue: "A cost-efficient model tries first. If it cannot finish or validation fails, Managed Routing escalates automatically.")
        static let managedPlanIndependence = String(localized: "agent-model-picker.managed-plan-independence", defaultValue: "Managed Routing works without Coding Plan. Coding Plan is a separate some.im package for coding usage.")
        static let codingPlanTitle = String(localized: "agent-model-picker.coding-plan-title", defaultValue: "Coding Plan (optional package)")
        static let codingPlanBenefit = String(localized: "agent-model-picker.coding-plan-benefit", defaultValue: "A some.im package for frequent coding tasks, with packaged usage and more predictable cost.")
        static let codingPlanSubscribed = String(localized: "agent-model-picker.coding-plan-subscribed", defaultValue: "Subscribed")
        static let codingPlanChecking = String(localized: "agent-model-picker.coding-plan-checking", defaultValue: "Checking Coding Plan…")
        static let codingPlanCheckingHint = String(localized: "agent-model-picker.coding-plan-checking-hint", defaultValue: "Your package name and expiration date will appear here.")
        static let codingPlanCheckFailed = String(localized: "agent-model-picker.coding-plan-check-failed", defaultValue: "Unable to verify Coding Plan")
        static let codingPlanAuthenticationRequired = String(localized: "agent-model-picker.coding-plan-authentication-required", defaultValue: "Your some.im session has expired. Sign in again to verify the package.")
        static let codingPlanUnavailable = String(localized: "agent-model-picker.coding-plan-unavailable", defaultValue: "The package service is temporarily unavailable. Your existing subscription has not been changed.")
        static let codingPlanRetry = String(localized: "agent-model-picker.coding-plan-retry", defaultValue: "Retry")
        static let codingPlanNotPurchased = String(localized: "agent-model-picker.coding-plan-not-purchased", defaultValue: "No active Coding Plan")
        static let codingPlanNotPurchasedDescription = String(localized: "agent-model-picker.coding-plan-not-purchased-description", defaultValue: "You can still use Managed Routing. Buy Coding Plan only when a coding package suits your usage.")
        static let codingPlanLoginDescription = String(localized: "agent-model-picker.coding-plan-login-description", defaultValue: "Sign in to check an existing subscription, or open some.im to learn about and buy Coding Plan.")
        static let manageCodingPlan = String(localized: "agent-model-picker.coding-plan-manage", defaultValue: "Manage Coding Plan")
        static let buyCodingPlan = String(localized: "agent-model-picker.coding-plan-buy", defaultValue: "Learn More and Buy")
        static let codingPlanActive = String(localized: "agent-model-picker.coding-plan-active", defaultValue: "Coding Plan is currently active.")
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

        static func codingPlanExpires(_ date: String) -> String {
            let template = String(localized: "agent-model-picker.coding-plan-expires", defaultValue: "Valid until %@")
            return String(format: template, date)
        }
    }
}
