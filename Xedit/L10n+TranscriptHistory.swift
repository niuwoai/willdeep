//
//  L10n+TranscriptHistory.swift
//  WillDeep
//
//  Transcript search, pagination, truncation, and running-task strings.
//

import Foundation

extension L10n.Transcript {
    static let messageTruncatedHelp = String(localized: "transcript.message-truncated.help", defaultValue: "Open in standalone window to view full message content")
    static func messageTruncatedText(_ a1: String, _ a2: String) -> String {
        let template = String(localized: "transcript.message-truncated.text", defaultValue: "Message preview keeps start and end (%@ chars max, %@ omitted)")
        return String(format: template, a1, a2)
    }
    static func messageMiddleOmittedText(_ a1: String) -> String {
        let template = String(localized: "transcript.message-middle-omitted.text", defaultValue: "… %@ characters omitted; showing message start and end …")
        return String(format: template, a1)
    }
    static let searchPlaceholder = String(localized: "transcript.search.placeholder", defaultValue: "Search conversation...")
    static let searchNoResults = String(localized: "transcript.search.no-results", defaultValue: "No results")
    static func searchResultPosition(_ a1: String, _ a2: String) -> String {
        let template = String(localized: "transcript.search.result-position", defaultValue: "%1$@ / %2$@ results")
        return String(format: template, a1, a2)
    }
    static let searchPreviousHelp = String(localized: "transcript.search.previous-help", defaultValue: "Previous result")
    static let searchNextHelp = String(localized: "transcript.search.next-help", defaultValue: "Next result")
    static let searchCloseHelp = String(localized: "transcript.search.close-help", defaultValue: "Close conversation search")
    static let olderHistoryHelp = String(localized: "transcript.older-history.help", defaultValue: "Open in standalone window to view full conversation history")
    static func olderHistoryText(_ a1: String) -> String {
        let template = String(localized: "transcript.older-history.text", defaultValue: "More messages earlier in conversation")
        return String(format: template, a1)
    }
    static let olderHistoryPreviewHelp = String(localized: "transcript.older-history.preview-help", defaultValue: "Show a lightweight text-only preview of older messages")
    static func olderHistoryPreviewLimit(_ a1: String) -> String {
        let template = String(localized: "transcript.older-history.preview-limit", defaultValue: "Text preview · %@ chars max")
        return String(format: template, a1)
    }
    static func olderHistoryPreviewSummary(_ a1: String, _ a2: String, _ a3: String) -> String {
        let template = String(localized: "transcript.older-history.preview-summary", defaultValue: "Showing %@ of %@ text chars · %@ omitted")
        return String(format: template, a1, a2, a3)
    }
    static func olderHistoryOmittedText(_ a1: String) -> String {
        let template = String(localized: "transcript.older-history.omitted", defaultValue: "… %@ older text characters omitted …")
        return String(format: template, a1)
    }
    static let olderHistoryNoText = String(localized: "transcript.older-history.no-text", defaultValue: "Older messages have no plain text preview.")
    static let olderHistoryOpenFull = String(localized: "transcript.older-history.open-full", defaultValue: "Full details")
    static let olderHistoryRoleSystem = String(localized: "transcript.older-history.role.system", defaultValue: "System")
    static let olderHistoryRoleUser = String(localized: "transcript.older-history.role.user", defaultValue: "User")
    static let olderHistoryRoleAssistant = String(localized: "transcript.older-history.role.assistant", defaultValue: "Assistant")
    static let olderHistoryRoleTool = String(localized: "transcript.older-history.role.tool", defaultValue: "Tool")
    static let olderHistoryRoleWorkflow = String(localized: "transcript.older-history.role.workflow", defaultValue: "Workflow")
    static let olderHistoryRoleWidget = String(localized: "transcript.older-history.role.widget", defaultValue: "Widget")
    static let olderHistoryRoleScheduledTask = String(localized: "transcript.older-history.role.scheduled-task", defaultValue: "Scheduled task")
    static let minimapEmptyUserText = String(localized: "transcript.minimap.empty-user-text", defaultValue: "(no text)")
    static let runningTaskOne = String(localized: "transcript.running-tasks.one", defaultValue: "1 running task")
    static func runningTasksMany(_ a1: String) -> String {
        let template = String(localized: "transcript.running-tasks.many", defaultValue: "%@ running tasks")
        return String(format: template, a1)
    }
    static let backgroundTaskOne = String(localized: "transcript.background-tasks.one", defaultValue: "Turn ended · 1 background task running")
    static func backgroundTasksMany(_ a1: String) -> String {
        let template = String(localized: "transcript.background-tasks.many", defaultValue: "Turn ended · %@ background tasks running")
        return String(format: template, a1)
    }
    static let runningTasksHelp = String(localized: "transcript.running-tasks.help", defaultValue: "Tasks are still running — output resumes when they finish")
}
