//
//  L10n+ScheduledTasksPage.swift
//  WillDeep
//
//  Dedicated-page copy is split from L10n.swift to keep the shared catalog
//  wrapper below the repository's hard file-size limit.
//

import Foundation

extension L10n.Automation {
    static let navigationTitle = String(localized: "automation.navigation-title", defaultValue: "Scheduled")
    static let pageEmptySearch = String(localized: "automation.page.empty-search", defaultValue: "No scheduled tasks match your search")
    static let pageNewTask = String(localized: "automation.page.new-task", defaultValue: "New task")
    static let pageNoRecentRuns = String(localized: "automation.page.no-recent-runs", defaultValue: "No scheduled task runs yet")
    static let pageRecentRuns = String(localized: "automation.page.recent-runs", defaultValue: "Recent runs")
    static let pageSearchPlaceholder = String(localized: "automation.page.search-placeholder", defaultValue: "Search scheduled tasks")
    static let pageSubtitle = String(localized: "automation.page.subtitle", defaultValue: "Let WillDeep run recurring prompts, reminders, and project checks for you")
    static let pageSuggestions = String(localized: "automation.page.suggestions", defaultValue: "Suggestions")
    static let pageTitle = String(localized: "automation.page.title", defaultValue: "Scheduled tasks")
    static let pageYourTasks = String(localized: "automation.page.your-tasks", defaultValue: "Your tasks")
    static let pagePaused = String(localized: "automation.page.paused", defaultValue: "Paused")
    /// When this task fires next — the one thing someone opening this page
    /// actually wants and the page never showed, though `nextFireDate()`
    /// has been sitting there computing it the whole time.
    static func pageNextRun(_ when: String) -> String {
        let template = String(localized: "automation.page.next-run", defaultValue: "Next %@")
        return String(format: template, when)
    }
    static let helpOpenRecentRun = String(localized: "automation.help.open-recent-run", defaultValue: "Open this run's conversation")
    static let recentRunUnavailable = String(localized: "automation.page.recent-run-unavailable", defaultValue: "This conversation is no longer available")
}
