//
//  L10n+StatsDashboard.swift
//  WillDeep
//
//  Localized strings for the Agent usage dashboard. Kept separate from
//  L10n.swift so the generated-style catalog facade stays under the
//  repository's hard file-size limit.
//

import Foundation

extension L10n {
    enum StatsDashboard {
        static let activityCumulative = String(localized: "stats-dashboard.activity.cumulative", defaultValue: "Cumulative")
        static let activityDaily = String(localized: "stats-dashboard.activity.daily", defaultValue: "Daily")
        static let activityTitle = String(localized: "stats-dashboard.activity.title", defaultValue: "Token activity")
        static let activityWeekly = String(localized: "stats-dashboard.activity.weekly", defaultValue: "Weekly")
        static let capabilitiesEmpty = String(localized: "stats-dashboard.capabilities.empty", defaultValue: "Use a tool in a chat and your most-used capabilities will appear here.")
        static let capabilitiesTitle = String(localized: "stats-dashboard.capabilities.title", defaultValue: "Most-used capabilities")
        static let capabilityAutomation = String(localized: "stats-dashboard.capability.automation", defaultValue: "Automation")
        static let capabilityBrowser = String(localized: "stats-dashboard.capability.browser", defaultValue: "Browser & computer")
        static let capabilityCoding = String(localized: "stats-dashboard.capability.coding", defaultValue: "Code changes")
        static let capabilityGeneral = String(localized: "stats-dashboard.capability.general", defaultValue: "Other tools")
        static let capabilityIntegration = String(localized: "stats-dashboard.capability.integration", defaultValue: "MCP & integrations")
        static let capabilityMedia = String(localized: "stats-dashboard.capability.media", defaultValue: "Images & media")
        static let capabilityResearch = String(localized: "stats-dashboard.capability.research", defaultValue: "Web research")
        static let capabilityTerminal = String(localized: "stats-dashboard.capability.terminal", defaultValue: "Terminal")
        static let capabilityWorkspace = String(localized: "stats-dashboard.capability.workspace", defaultValue: "Workspace files")

        static func activitySummary(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "stats-dashboard.activity.summary", defaultValue: "%1$@ messages · %2$@ tokens")
            return String(format: template, a1, a2)
        }

        static func callCount(_ a1: String) -> String {
            let template = String(localized: "stats-dashboard.capabilities.call-count", defaultValue: "%@ calls")
            return String(format: template, a1)
        }

        static func dayCount(_ a1: String) -> String {
            let template = String(localized: "stats-dashboard.day-count", defaultValue: "%@ days")
            return String(format: template, a1)
        }

        static func deliverableSessionCount(_ a1: String) -> String {
            let template = String(localized: "stats-dashboard.deliverables.session-count", defaultValue: "%@ chats")
            return String(format: template, a1)
        }

        static let failureDetailUnavailable = String(localized: "stats-dashboard.failure.detail-unavailable", defaultValue: "No error summary recorded")
        static let failureReviewEmpty = String(localized: "stats-dashboard.failure.empty", defaultValue: "No recorded tool failures this week")
        static let failureReviewSubtitle = String(localized: "stats-dashboard.failure.subtitle", defaultValue: "Explicit execution failures only")
        static let failureReviewTitle = String(localized: "stats-dashboard.failure.title", defaultValue: "Failed tool-call review")
        static let insightsTitle = String(localized: "stats-dashboard.insights.title", defaultValue: "Activity insights")
        static let insightActiveDays = String(localized: "stats-dashboard.insight.active-days", defaultValue: "Active days")
        static let insightExploredSkills = String(localized: "stats-dashboard.insight.explored-skills", defaultValue: "Skills explored")
        static let insightPeakHour = String(localized: "stats-dashboard.insight.peak-hour", defaultValue: "Peak time")
        static let insightManagedRouting = String(localized: "stats-dashboard.insight.quick-mode", defaultValue: "Managed-routing chats")
        static let insightReasoningUsage = String(localized: "stats-dashboard.insight.reasoning-strength", defaultValue: "Replies with reasoning output")
        static let insightFavoriteWorker = String(localized: "stats-dashboard.insight.favorite-worker", defaultValue: "Most-used worker")
        static let insightSessions = String(localized: "stats-dashboard.insight.sessions", defaultValue: "Chats")
        static let insightSkillUses = String(localized: "stats-dashboard.insight.skill-uses", defaultValue: "Total skill uses")
        static let insightTasksTotal = String(localized: "stats-dashboard.insight.tasks-total", defaultValue: "Total tasks")
        static let insightWorkflows = String(localized: "stats-dashboard.insight.workflows", defaultValue: "Workflows")
        static let insightWorkspaces = String(localized: "stats-dashboard.insight.workspaces", defaultValue: "Workspaces")
        static let metricArtifacts = String(localized: "stats-dashboard.metric.artifacts", defaultValue: "Artifacts")
        static let metricCurrentStreak = String(localized: "stats-dashboard.metric.current-streak", defaultValue: "Current streak")
        static let metricFilesChanged = String(localized: "stats-dashboard.metric.files-changed", defaultValue: "Files changed")
        static let metricLongestStreak = String(localized: "stats-dashboard.metric.longest-streak", defaultValue: "Longest streak")
        static let metricLongestTask = String(localized: "stats-dashboard.metric.longest-task", defaultValue: "Longest task")
        static let metricLongestTaskHelp = String(localized: "stats-dashboard.metric.longest-task.help", defaultValue: "Time actually spent on the longest conversation. Pauses over 15 minutes are not counted.")
        static let metricPeakTokens = String(localized: "stats-dashboard.metric.peak-tokens", defaultValue: "Peak tokens")
        static let metricTaskTurns = String(localized: "stats-dashboard.metric.task-turns", defaultValue: "Task turns")
        static let metricTotalTokens = String(localized: "stats-dashboard.metric.total-tokens", defaultValue: "Total tokens")
        static let metricToolCalls = String(localized: "stats-dashboard.metric.tool-calls", defaultValue: "Tool calls")
        static let modelsDisclosureHelp = String(localized: "stats-dashboard.models-disclosure.help", defaultValue: "View model usage details")
        static let workersDisclosureHelp = String(localized: "stats-dashboard.workers-disclosure.help", defaultValue: "View worker usage details")

        static func favoriteWorkerValue(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "stats-dashboard.workers.favorite-value", defaultValue: "%1$@ · %2$@ calls")
            return String(format: template, a1, a2)
        }

        static func workerUsageSummary(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "stats-dashboard.workers.usage-summary", defaultValue: "%1$@ calls · %2$@ chats · %3$@")
            return String(format: template, a1, a2, a3)
        }

        static let workersEmpty = String(localized: "stats-dashboard.workers.empty", defaultValue: "No worker calls recorded yet.")
        static let workersProfilesUsed = String(localized: "stats-dashboard.workers.profiles-used", defaultValue: "Workers used")
        static let workersSubtitle = String(localized: "stats-dashboard.workers.subtitle", defaultValue: "Historical spawn_agent calls grouped by worker profile")
        static let workersTitle = String(localized: "stats-dashboard.workers.title", defaultValue: "Worker usage")
        static let workersTotalCalls = String(localized: "stats-dashboard.workers.total-calls", defaultValue: "Worker calls")
        static let workersChats = String(localized: "stats-dashboard.workers.chats", defaultValue: "Chats with workers")

        static func pluginRunCount(_ a1: String) -> String {
            let template = String(localized: "stats-dashboard.plugins.run-count", defaultValue: "%@ runs")
            return String(format: template, a1)
        }

        static let pluginsEmpty = String(localized: "stats-dashboard.plugins.empty", defaultValue: "Your most-used tools will appear here after a few tasks.")
        static let pluginsTitle = String(localized: "stats-dashboard.plugins.title", defaultValue: "Most-used plugins")
        static let profilePlanFree = String(localized: "stats-dashboard.profile.plan-free", defaultValue: "Free")
        static let profilePlanPro = String(localized: "stats-dashboard.profile.plan-pro", defaultValue: "Pro")
        static let reasoningHigh = String(localized: "stats-dashboard.reasoning.high", defaultValue: "High")
        static let reasoningLow = String(localized: "stats-dashboard.reasoning.low", defaultValue: "Low")
        static let reasoningMedium = String(localized: "stats-dashboard.reasoning.medium", defaultValue: "Medium")

        static func reasoningValue(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "stats-dashboard.reasoning.value", defaultValue: "%1$@ · %2$@")
            return String(format: template, a1, a2)
        }

        static func durationMinutes(_ a1: String) -> String {
            let template = String(localized: "stats-dashboard.duration.minutes", defaultValue: "%@ min")
            return String(format: template, a1)
        }

        static let range24h = String(localized: "stats-dashboard.range.24h", defaultValue: "24h")
        static let range30d = String(localized: "stats-dashboard.range.30d", defaultValue: "30d")
        static let range7d = String(localized: "stats-dashboard.range.7d", defaultValue: "7d")
        static let rangeAll = String(localized: "stats-dashboard.range.all", defaultValue: "All")
        static let tabsModels = String(localized: "stats-dashboard.tabs.models", defaultValue: "Models")
        static let tabsOverview = String(localized: "stats-dashboard.tabs.overview", defaultValue: "Overview")
        static let tabsWorkers = String(localized: "stats-dashboard.tabs.workers", defaultValue: "Workers")
        static let weeklyDeliverablesEmpty = String(localized: "stats-dashboard.deliverables.empty", defaultValue: "No artifacts from chats active this week")
        static let weeklyDeliverablesSubtitle = String(localized: "stats-dashboard.deliverables.subtitle", defaultValue: "Artifacts from chats updated this week")
        static let weeklyDeliverablesTitle = String(localized: "stats-dashboard.deliverables.title", defaultValue: "This week’s deliverables")
    }
}
