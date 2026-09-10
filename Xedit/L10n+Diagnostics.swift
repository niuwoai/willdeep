import Foundation

nonisolated extension L10n {
    /// The diagnostics export page. Wording carries one job beyond naming
    /// things: the user is about to hand logs to someone else, so the screen
    /// has to say what is in the envelope in words, not just list file names.
    enum Diagnostics {
        static let tabTitle = String(localized: "diagnostics.tab-title", defaultValue: "Diagnostics")
        static let pageTitle = String(localized: "diagnostics.page-title", defaultValue: "Export a diagnostics bundle")
        static let pageSubtitle = String(
            localized: "diagnostics.page-subtitle",
            defaultValue: "Pick what the export covers, check what it contains, then save the zip and send it on."
        )

        static let scopeSection = String(localized: "diagnostics.scope-section", defaultValue: "What to cover")
        static let scopeProject = String(localized: "diagnostics.scope-project", defaultValue: "A project")
        static let scopeSession = String(localized: "diagnostics.scope-session", defaultValue: "One conversation")
        static let scopeProjectPicker = String(localized: "diagnostics.scope-project-picker", defaultValue: "Project")
        static let scopeSessionPicker = String(localized: "diagnostics.scope-session-picker", defaultValue: "Conversation")
        static let scopeEmpty = String(
            localized: "diagnostics.scope-empty",
            defaultValue: "Nothing to export yet — this needs at least one conversation."
        )

        static let levelSection = String(localized: "diagnostics.level-section", defaultValue: "How much to include")
        static let levelTimingOnly = String(localized: "diagnostics.level-timing-only", defaultValue: "Timings only")
        static let levelFull = String(localized: "diagnostics.level-full", defaultValue: "Everything")
        static let levelTimingOnlyHelp = String(
            localized: "diagnostics.level-timing-only-help",
            defaultValue: "Per-turn timings and counts. No conversation text and no commands — the timing log records none. This is what answers \"why was it slow\"."
        )
        static let levelFullHelp = String(
            localized: "diagnostics.level-full-help",
            defaultValue: "Also includes the selected conversations in full, and the sandbox and judge logs for the time span they cover. Those logs hold the commands that ran. Send this only to someone you would show that to."
        )

        static let contentsSection = String(localized: "diagnostics.contents-section", defaultValue: "What goes in")
        static func sessions(_ count: Int) -> String {
            let template = String(localized: "diagnostics.count-sessions", defaultValue: "Conversations: %d")
            return String(format: template, count)
        }
        static func timingLines(_ count: Int) -> String {
            let template = String(localized: "diagnostics.count-timing", defaultValue: "Timing records: %d")
            return String(format: template, count)
        }
        static func sandboxLines(_ count: Int) -> String {
            let template = String(localized: "diagnostics.count-sandbox", defaultValue: "Command records: %d")
            return String(format: template, count)
        }
        static func judgeLines(_ count: Int) -> String {
            let template = String(localized: "diagnostics.count-judge", defaultValue: "Approval records: %d")
            return String(format: template, count)
        }
        static func window(_ range: String) -> String {
            let template = String(localized: "diagnostics.window", defaultValue: "Time span: %@")
            return String(format: template, range)
        }
        static let noUserContent = String(
            localized: "diagnostics.no-user-content",
            defaultValue: "Contains no conversation text and no commands."
        )
        static let hasUserContent = String(
            localized: "diagnostics.has-user-content",
            defaultValue: "Contains your conversations and the commands that ran."
        )
        static let noTimingRecords = String(
            localized: "diagnostics.no-timing-records",
            defaultValue: "No timing records for this selection yet. Timings are written when a turn finishes, so a conversation from before this build may have none."
        )

        static let exportButton = String(localized: "diagnostics.export-button", defaultValue: "Export…")
        static let exporting = String(localized: "diagnostics.exporting", defaultValue: "Exporting…")
        static let revealButton = String(localized: "diagnostics.reveal-button", defaultValue: "Show in Finder")
        static func exported(_ name: String) -> String {
            let template = String(localized: "diagnostics.exported", defaultValue: "Saved %@")
            return String(format: template, name)
        }
        static func exportFailed(_ reason: String) -> String {
            let template = String(localized: "diagnostics.export-failed", defaultValue: "Export failed: %@")
            return String(format: template, reason)
        }
        static let savePanelTitle = String(localized: "diagnostics.save-panel-title", defaultValue: "Save diagnostics bundle")

        static let logLocation = String(
            localized: "diagnostics.log-location",
            defaultValue: "The underlying logs live in ~/Library/Application Support/WillDeep/AgentAudit."
        )
    }
}
