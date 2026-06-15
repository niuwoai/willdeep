import Foundation

// Generated façade over Localizable.xcstrings.
// Each `static let` reads from the String Catalog at runtime with a baked-in en defaultValue
// (so missing entries fall back gracefully). Interpolated entries are exposed as `static func`
// taking String args; the catalog template uses %@ placeholders.
//
// To regenerate: see scripts/i18n_regenerate.rb (TODO if we ever automate this).

enum L10n {
    enum AppUpdate {
        static let download = String(localized: "app-update.download", defaultValue: "Download")
        static let later = String(localized: "app-update.later", defaultValue: "Later")
        static let releaseNotes = String(localized: "app-update.release-notes", defaultValue: "Release Notes")
        static func message(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "app-update.message", defaultValue: "Current version: %@\nLatest version: %@")
            return String(format: template, a1, a2)
        }
        static func minimumSystem(_ a1: String) -> String {
            let template = String(localized: "app-update.minimum-system", defaultValue: "Requires macOS %@ or later.")
            return String(format: template, a1)
        }
        static func title(_ a1: String) -> String {
            let template = String(localized: "app-update.title", defaultValue: "WillDeep %@ is available")
            return String(format: template, a1)
        }
    }

    enum Alert {
        static let binaryFileButtonOk = String(localized: "alert.binary-file.button.ok", defaultValue: "OK")
        static func binaryFileMessage(_ a1: String) -> String {
            let template = String(localized: "alert.binary-file.message", defaultValue: "appears to be a binary file and cannot be opened in the editor.")
            return String(format: template, a1)
        }
        static let binaryFileTitle = String(localized: "alert.binary-file.title", defaultValue: "Cannot Open Binary File")
        static let largeFileButtonCancel = String(localized: "alert.large-file.button.cancel", defaultValue: "Cancel")
        static let largeFileButtonOpenAnyway = String(localized: "alert.large-file.button.open-anyway", defaultValue: "Open Anyway")
        static func largeFileMessage(_ a1: String) -> String {
            let template = String(localized: "alert.large-file.message", defaultValue: "is larger than 1 MB and may take time to load or become unresponsive.")
            return String(format: template, a1)
        }
        static let largeFileTitle = String(localized: "alert.large-file.title", defaultValue: "Large File")
    }

    enum AgentTextAttachment {
        static let pastedFilename = String(localized: "agent-text-attachment.pasted-filename", defaultValue: "Pasted text.txt")
        static let removeHelp = String(localized: "agent-text-attachment.remove-help", defaultValue: "Remove pasted text")
    }

    enum AgentSelection {
        static let addToConversation = String(localized: "agent-selection.add-to-conversation", defaultValue: "Add to Conversation")
        static let askInSidebar = String(localized: "agent-selection.ask-in-sidebar", defaultValue: "Ask in Side Agent")
        static let askPrompt = String(localized: "agent-selection.ask-prompt", defaultValue: "Ask about the attached selection: ")
        static let filenamePrefix = String(localized: "agent-selection.filename-prefix", defaultValue: "Selection")
        static let selectionAttachedHint = String(localized: "agent-selection.selection-attached-hint", defaultValue: "Selection attached · Tools available")
        static let untitledFile = String(localized: "agent-selection.untitled-file", defaultValue: "Untitled")
    }

    enum ApprovalMode {
        static let pickerHelp = String(localized: "approval-mode.picker-help", defaultValue: "Choose how this session approves Agent tool calls.")
        static let requestEveryTime = String(localized: "approval-mode.request-every-time", defaultValue: "Ask every time")
        static let requestEveryTimeSummary = String(localized: "approval-mode.request-every-time.summary", defaultValue: "Ask before write, command, network, or remote actions.")
        static let smart = String(localized: "approval-mode.smart", defaultValue: "Smart approval")
        static let smartSummary = String(localized: "approval-mode.smart.summary", defaultValue: "Auto-run low-risk calls; ask for risky actions.")
        static let workspaceAccess = String(localized: "approval-mode.workspace-access", defaultValue: "Workspace access")
        static let workspaceAccessSummary = String(localized: "approval-mode.workspace-access.summary", defaultValue: "Allow current workspace actions; keep hard safety gates.")
    }

    enum Automation {
        static let cancel = String(localized: "automation.cancel", defaultValue: "Cancel")
        static let createTitle = String(localized: "automation.create-title", defaultValue: "New Automation")
        static let defaultName = String(localized: "automation.default-name", defaultValue: "Untitled Automation")
        static let delete = String(localized: "automation.delete", defaultValue: "Delete Automation")
        static let edit = String(localized: "automation.edit", defaultValue: "Edit…")
        static let editTitle = String(localized: "automation.edit-title", defaultValue: "Edit Automation")
        static let emptyState = String(localized: "automation.empty-state", defaultValue: "Create your first automation")
        static let enabled = String(localized: "automation.enabled", defaultValue: "Enabled")
        static let followCurrentRoute = String(localized: "automation.follow-current-route", defaultValue: "Follow current Flash / Pro route")
        static let followCurrentRouteShort = String(localized: "automation.follow-current-route.short", defaultValue: "Follow current route")
        static let header = String(localized: "automation.header", defaultValue: "Automations")
        static let helpCreate = String(localized: "automation.help.create", defaultValue: "New Automation")
        static let helpRunNow = String(localized: "automation.help.run-now", defaultValue: "Run once now")
        static let helpRunOnce = String(localized: "automation.help.run-once", defaultValue: "Does not affect the schedule. Disabled automations can still run once manually.")
        static let labelEvery = String(localized: "automation.label.every", defaultValue: "Every")
        static let labelModel = String(localized: "automation.label.model", defaultValue: "Model")
        static let labelName = String(localized: "automation.label.name", defaultValue: "Name")
        static let labelPrompt = String(localized: "automation.label.prompt", defaultValue: "Prompt (sent as the first user message each run)")
        static let labelSchedule = String(localized: "automation.label.schedule", defaultValue: "Schedule")
        static let labelScheduleType = String(localized: "automation.label.schedule-type", defaultValue: "Schedule type")
        static let labelWorkspace = String(localized: "automation.label.workspace", defaultValue: "Workspace")
        static let menuDisable = String(localized: "automation.menu.disable", defaultValue: "Disable")
        static let menuEnable = String(localized: "automation.menu.enable", defaultValue: "Enable")
        static let noWorkspace = String(localized: "automation.no-workspace", defaultValue: "No workspace")
        static let placeholderName = String(localized: "automation.placeholder.name", defaultValue: "e.g. Daily PR summary")
        static let runNow = String(localized: "automation.run-now", defaultValue: "Run once now")
        static let save = String(localized: "automation.save", defaultValue: "Save")
        static let scheduleDaily = String(localized: "automation.schedule.daily", defaultValue: "Daily")
        static let scheduleInterval = String(localized: "automation.schedule.interval", defaultValue: "Interval")
        static let scheduleNextPrefix = String(localized: "automation.schedule.next-prefix", defaultValue: "Next:")
        static let scheduleWeekdays = String(localized: "automation.schedule.weekdays", defaultValue: "Weekdays")
        static let scheduleWeekdaysDetail = String(localized: "automation.schedule.weekdays-detail", defaultValue: "Weekdays (Mon-Fri)")
        static let scheduleWeekly = String(localized: "automation.schedule.weekly", defaultValue: "Weekly")
        static let templateDailyBriefName = String(localized: "automation.template.daily-brief.name", defaultValue: "Daily Brief")
        static let templateDailyBriefPrompt = String(localized: "automation.template.daily-brief.prompt", defaultValue: "Generate a morning brief for the current project: inspect git status, recent changes, TODO clues, and risks that need attention today. Return prioritized action items.")
        static let templateProjectMonitorName = String(localized: "automation.template.project-monitor.name", defaultValue: "Project Monitor")
        static let templateProjectMonitorPrompt = String(localized: "automation.template.project-monitor.prompt", defaultValue: "Inspect the current project for obvious risks: uncommitted changes, TODO/FIXME markers, recently edited key files, and anything that may need my attention. Summarize findings and next actions.")
        static let templateWeeklyReviewName = String(localized: "automation.template.weekly-review.name", defaultValue: "Weekly Review")
        static let templateWeeklyReviewPrompt = String(localized: "automation.template.weekly-review.prompt", defaultValue: "Review the current project for the week: summarize major changes, completed work, remaining risks, and suggested next-week focus. Keep it concise.")
        static let weekdayFriday = String(localized: "automation.weekday.friday", defaultValue: "Fri")
        static let weekdayMonday = String(localized: "automation.weekday.monday", defaultValue: "Mon")
        static let weekdaySaturday = String(localized: "automation.weekday.saturday", defaultValue: "Sat")
        static let weekdaySunday = String(localized: "automation.weekday.sunday", defaultValue: "Sun")
        static let weekdayThursday = String(localized: "automation.weekday.thursday", defaultValue: "Thu")
        static let weekdayTuesday = String(localized: "automation.weekday.tuesday", defaultValue: "Tue")
        static let weekdayWednesday = String(localized: "automation.weekday.wednesday", defaultValue: "Wed")
        static func intervalHours(_ a1: String) -> String {
            let template = String(localized: "automation.interval.hours", defaultValue: "Every %@ hours")
            return String(format: template, a1)
        }
        static let intervalOneHour = String(localized: "automation.interval.one-hour", defaultValue: "Every hour")
        static func intervalMinutes(_ a1: String) -> String {
            let template = String(localized: "automation.interval.minutes", defaultValue: "Every %@ minutes")
            return String(format: template, a1)
        }
        static func notificationBodyCatchUp(_ a1: String) -> String {
            let template = String(localized: "automation.notification.body.catch-up", defaultValue: "%@ caught up after wake")
            return String(format: template, a1)
        }
        static func notificationBodyStarted(_ a1: String) -> String {
            let template = String(localized: "automation.notification.body.started", defaultValue: "%@ started")
            return String(format: template, a1)
        }
        static let notificationTitle = String(localized: "automation.notification.title", defaultValue: "Automation started")
        static func scheduleDailySummary(_ a1: String) -> String {
            let template = String(localized: "automation.schedule.daily.summary", defaultValue: "Daily %@")
            return String(format: template, a1)
        }
        static func scheduleWeekdaySummary(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "automation.schedule.weekday.summary", defaultValue: "%@ %@")
            return String(format: template, a1, a2)
        }
        static func scheduleWeekdaysSummary(_ a1: String) -> String {
            let template = String(localized: "automation.schedule.weekdays.summary", defaultValue: "Weekdays %@")
            return String(format: template, a1)
        }
    }

    enum PluginPicker {
        static let help = String(localized: "plugin-picker.help", defaultValue: "Browse installed plugin skills and MCP capabilities.")
        static func installedPlugins(_ a1: String) -> String {
            let template = String(localized: "plugin-picker.installed-plugins", defaultValue: "%@ installed plugins")
            return String(format: template, a1)
        }
        static let label = String(localized: "plugin-picker.label", defaultValue: "Plugins")
        static func mcpServers(_ a1: String) -> String {
            let template = String(localized: "plugin-picker.mcp-servers", defaultValue: "%@ MCP servers")
            return String(format: template, a1)
        }
        static let none = String(localized: "plugin-picker.none", defaultValue: "No plugin capabilities found.")
    }

    enum Composer {
        static let queueSendHelp = String(localized: "composer.queue-send.help", defaultValue: "Queue this message after the current turn")
        static let sendHelp = String(localized: "composer.send.help", defaultValue: "Send")
        static let stopHelp = String(localized: "composer.stop.help", defaultValue: "Stop the current Agent turn")
    }

    enum Command {
        static let closeTabShortcut = String(localized: "command.close-tab.shortcut", defaultValue: "⌘W")
        static let closeTabSubtitle = String(localized: "command.close-tab.subtitle", defaultValue: "Close the active tab")
        static let closeTabTitle = String(localized: "command.close-tab.title", defaultValue: "Close Tab")
        static let copyFilePathSubtitle = String(localized: "command.copy-file-path.subtitle", defaultValue: "Copy the active file path")
        static let copyFilePathTitle = String(localized: "command.copy-file-path.title", defaultValue: "Copy File Path")
        static let copyRelativeFilePathSubtitle = String(localized: "command.copy-relative-file-path.subtitle", defaultValue: "Copy the active file path relative to the current folder")
        static let copyRelativeFilePathTitle = String(localized: "command.copy-relative-file-path.title", defaultValue: "Copy Relative File Path")
        static let duplicateLineSubtitle = String(localized: "command.duplicate-line.subtitle", defaultValue: "Copy the current line below")
        static let duplicateLineTitle = String(localized: "command.duplicate-line.title", defaultValue: "Duplicate Line")
        static let findShortcut = String(localized: "command.find.shortcut", defaultValue: "⌘F")
        static let findSubtitle = String(localized: "command.find.subtitle", defaultValue: "Show find and replace")
        static let findTitle = String(localized: "command.find.title", defaultValue: "Find")
        static let goToLineShortcut = String(localized: "command.go-to-line.shortcut", defaultValue: "⌘L")
        static let goToLineSubtitle = String(localized: "command.go-to-line.subtitle", defaultValue: "Jump to a line in the active tab")
        static let goToLineTitle = String(localized: "command.go-to-line.title", defaultValue: "Go to Line")
        static let goToSymbolSubtitle = String(localized: "command.go-to-symbol.subtitle", defaultValue: "Search symbols in the active tab")
        static let goToSymbolTitle = String(localized: "command.go-to-symbol.title", defaultValue: "Go to Symbol")
        static let moveLineDownSubtitle = String(localized: "command.move-line-down.subtitle", defaultValue: "Move the current line downward")
        static let moveLineDownTitle = String(localized: "command.move-line-down.title", defaultValue: "Move Line Down")
        static let moveLineUpSubtitle = String(localized: "command.move-line-up.subtitle", defaultValue: "Move the current line upward")
        static let moveLineUpTitle = String(localized: "command.move-line-up.title", defaultValue: "Move Line Up")
        static let nextTabShortcut = String(localized: "command.next-tab.shortcut", defaultValue: "⌘}")
        static let nextTabSubtitle = String(localized: "command.next-tab.subtitle", defaultValue: "Activate the tab to the right")
        static let nextTabTitle = String(localized: "command.next-tab.title", defaultValue: "Next Tab")
        static let openContainingFolderSubtitle = String(localized: "command.open-containing-folder.subtitle", defaultValue: "Reveal the active file in Finder")
        static let openContainingFolderTitle = String(localized: "command.open-containing-folder.title", defaultValue: "Open Containing Folder")
        static let openFileShortcut = String(localized: "command.open-file.shortcut", defaultValue: "⌘O")
        static let openFileSubtitle = String(localized: "command.open-file.subtitle", defaultValue: "Choose a file from disk")
        static let openFileTitle = String(localized: "command.open-file.title", defaultValue: "Open File")
        static let openFolderSubtitle = String(localized: "command.open-folder.subtitle", defaultValue: "Choose a folder for the sidebar")
        static let openFolderTitle = String(localized: "command.open-folder.title", defaultValue: "Open Folder")
        static let openSplitFileSubtitle = String(localized: "command.open-split-file.subtitle", defaultValue: "Show another text file beside the editor")
        static let openSplitFileTitle = String(localized: "command.open-split-file.title", defaultValue: "Open Split File")
        static let openTerminalHereSubtitle = String(localized: "command.open-terminal-here.subtitle", defaultValue: "Open Terminal at the project or active file location")
        static let openTerminalHereTitle = String(localized: "command.open-terminal-here.title", defaultValue: "Open Terminal Here")
        static let previousTabShortcut = String(localized: "command.previous-tab.shortcut", defaultValue: "⌘{")
        static let previousTabSubtitle = String(localized: "command.previous-tab.subtitle", defaultValue: "Activate the tab to the left")
        static let previousTabTitle = String(localized: "command.previous-tab.title", defaultValue: "Previous Tab")
        static let quickOpenShortcut = String(localized: "command.quick-open.shortcut", defaultValue: "⌘P")
        static let quickOpenSubtitle = String(localized: "command.quick-open.subtitle", defaultValue: "Search files in the current folder")
        static let quickOpenTitle = String(localized: "command.quick-open.title", defaultValue: "Quick Open")
        static let refreshGitStatusSubtitle = String(localized: "command.refresh-git-status.subtitle", defaultValue: "Refresh branch and file status markers")
        static let refreshGitStatusTitle = String(localized: "command.refresh-git-status.title", defaultValue: "Refresh Git Status")
        static let reopenClosedTabSubtitle = String(localized: "command.reopen-closed-tab.subtitle", defaultValue: "Restore the most recently closed tab")
        static let reopenClosedTabTitle = String(localized: "command.reopen-closed-tab.title", defaultValue: "Reopen Closed Tab")
        static let saveShortcut = String(localized: "command.save.shortcut", defaultValue: "⌘S")
        static let saveSubtitle = String(localized: "command.save.subtitle", defaultValue: "Write the active file")
        static let saveTitle = String(localized: "command.save.title", defaultValue: "Save")
        static let toggleAgentSubtitle = String(localized: "command.toggle-agent.subtitle", defaultValue: "Show or hide the project agent")
        static let toggleAgentTitle = String(localized: "command.toggle-agent.title", defaultValue: "Toggle Agent")
        static let toggleFocusModeSubtitle = String(localized: "command.toggle-focus-mode.subtitle", defaultValue: "Hide chrome and keep only the editor")
        static let toggleFocusModeTitle = String(localized: "command.toggle-focus-mode.title", defaultValue: "Toggle Focus Mode")
        static let toggleInspectorSubtitle = String(localized: "command.toggle-inspector.subtitle", defaultValue: "Show or hide minimap and structure")
        static let toggleInspectorTitle = String(localized: "command.toggle-inspector.title", defaultValue: "Toggle Inspector")
        static let togglePreviewSubtitle = String(localized: "command.toggle-preview.subtitle", defaultValue: "Show or hide Markdown and HTML preview")
        static let togglePreviewTitle = String(localized: "command.toggle-preview.title", defaultValue: "Toggle Preview")
    }

    enum CommandPalette {
        static let placeholder = String(localized: "command-palette.placeholder", defaultValue: "Command Palette")
    }

    enum EditorStatusBar {
        static func cursorPosition(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "editor-status-bar.cursor-position", defaultValue: "Ln")
            return String(format: template, a1, a2)
        }
        static let cursorPositionCol = String(localized: "editor-status-bar.cursor-position.col", defaultValue: "Col")
        static let externalChanges = String(localized: "editor-status-bar.external-changes", defaultValue: "External changes")
        static func gitBranch(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.git-branch", defaultValue: "Git")
            return String(format: template, a1)
        }
        static let modified = String(localized: "editor-status-bar.modified", defaultValue: "Modified")
        static let plainText = String(localized: "editor-status-bar.plain-text", defaultValue: "Plain Text")
        static let reloadButton = String(localized: "editor-status-bar.reload-button", defaultValue: "Reload")
        static let saved = String(localized: "editor-status-bar.saved", defaultValue: "Saved")
        static func selection(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.selection", defaultValue: "chars")
            return String(format: template, a1)
        }
        static func selectionLines(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.selection.lines", defaultValue: "lines selected")
            return String(format: template, a1)
        }
    }

    enum EditorStructure {
        static let noStructure = String(localized: "editor-structure.no-structure", defaultValue: "No Structure")
    }

    enum EditorTabBar {
        static func closeTab(_ a1: String) -> String {
            let template = String(localized: "editor-tab-bar.close-tab", defaultValue: "Close")
            return String(format: template, a1)
        }
    }

    enum EmptyState {
        static let agentMode = String(localized: "empty-state.agent-mode", defaultValue: "Agent Mode")
        static let agentModeAccessibilityLabel = String(localized: "empty-state.agent-mode.accessibility-label", defaultValue: "Enter Agent Mode")
        static let agentModeHelp = String(localized: "empty-state.agent-mode.help", defaultValue: "Enter Agent mode (⌘⇧A)")
        static func hero(_ a1: String) -> String {
            let template = String(localized: "empty-state.hero", defaultValue: "What's up next")
            return String(format: template, a1)
        }
        static let noFileOpenSubtitle = String(localized: "empty-state.no-file-open.subtitle", defaultValue: "Select a file from the sidebar to start editing.")
        static let noFileOpenTitle = String(localized: "empty-state.no-file-open.title", defaultValue: "No File Open")
        static let noFolderOpenSubtitle = String(localized: "empty-state.no-folder-open.subtitle", defaultValue: "Choose a file or folder to start editing — or jump straight into Agent mode for a workspace-free chat.")
        static let noFolderOpenTitle = String(localized: "empty-state.no-folder-open.title", defaultValue: "No Folder Open")
        static let openFile = String(localized: "empty-state.open-file", defaultValue: "Open File")
        static let openFileAccessibilityLabel = String(localized: "empty-state.open-file.accessibility-label", defaultValue: "Open File")
        static let openFileHelp = String(localized: "empty-state.open-file.help", defaultValue: "Open File")
        static let openFolder = String(localized: "empty-state.open-folder", defaultValue: "Open Folder")
        static let openFolderAccessibilityLabel = String(localized: "empty-state.open-folder.accessibility-label", defaultValue: "Open Folder")
        static let openFolderHelp = String(localized: "empty-state.open-folder.help", defaultValue: "Open Folder")
        static let quickOpen = String(localized: "empty-state.quick-open", defaultValue: "Quick Open")
        static let quickOpenAccessibilityLabel = String(localized: "empty-state.quick-open.accessibility-label", defaultValue: "Quick Open")
        static let quickOpenHelp = String(localized: "empty-state.quick-open.help", defaultValue: "Quick Open")
        static let recentFiles = String(localized: "empty-state.recent-files", defaultValue: "Recent Files")
        static let recentFolders = String(localized: "empty-state.recent-folders", defaultValue: "Recent Folders")
        static let subtitleNoFolder = String(localized: "empty-state.subtitle.no-folder", defaultValue: "Open a folder from the menu to chat about a project.")
        static func subtitleWithFolder(_ a1: String) -> String {
            let template = String(localized: "empty-state.subtitle.with-folder", defaultValue: "Paste images switch models queue follow-ups.")
            return String(format: template, a1)
        }
    }

    enum EnterAgentModeButton {
        static let help = String(localized: "enter-agent-mode-button.help", defaultValue: "Switch this window into Agent mode (⌘⇧A)")
        static let label = String(localized: "enter-agent-mode-button.label", defaultValue: "Agent")
    }

    enum FindReplaceBar {
        static let closeButton = String(localized: "find-replace-bar.close-button", defaultValue: "Close Find")
        static let findPlaceholder = String(localized: "find-replace-bar.find-placeholder", defaultValue: "Find")
        static func matchCount(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "find-replace-bar.match-count", defaultValue: "of")
            return String(format: template, a1, a2)
        }
        static let nextMatchButton = String(localized: "find-replace-bar.next-match-button", defaultValue: "Next Match")
        static let noMatches = String(localized: "find-replace-bar.no-matches", defaultValue: "No matches")
        static let previousMatchButton = String(localized: "find-replace-bar.previous-match-button", defaultValue: "Previous Match")
        static let replaceAllButton = String(localized: "find-replace-bar.replace-all-button", defaultValue: "All")
        static let replaceButton = String(localized: "find-replace-bar.replace-button", defaultValue: "Replace")
        static let replacePlaceholder = String(localized: "find-replace-bar.replace-placeholder", defaultValue: "Replace")
    }

    enum GoToLine {
        static let placeholder = String(localized: "go-to-line.placeholder", defaultValue: "Go to Line")
    }

    enum GoalCard {
        static let editButtonHelp = String(localized: "goal-card.edit-button.help", defaultValue: "Edit goal")
        static let header = String(localized: "goal-card.header", defaultValue: "Goal")
    }

    enum GoalStatusBar {
        static func progressHelp(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "goal-status-bar.progress-help", defaultValue: "%@/%@ checklist items done")
            return String(format: template, a1, a2)
        }
        static let runningPrefix = String(localized: "goal-status-bar.running-prefix", defaultValue: "Goal in progress")
        static let untitled = String(localized: "goal-status-bar.untitled", defaultValue: "Untitled goal")
    }

    enum GoalEditorSheet {
        static let cancel = String(localized: "goal-editor-sheet.cancel", defaultValue: "Cancel")
        static let checklistLabel = String(localized: "goal-editor-sheet.checklist-label", defaultValue: "Acceptance checklist one per line")
        static let save = String(localized: "goal-editor-sheet.save", defaultValue: "Save")
        static let statementLabel = String(localized: "goal-editor-sheet.statement-label", defaultValue: "Goal statement")
        static let statementPlaceholder = String(localized: "goal-editor-sheet.statement-placeholder", defaultValue: "What are we trying to accomplish")
        static let title = String(localized: "goal-editor-sheet.title", defaultValue: "Define Goal")
    }

    enum Header {
        static let newChat = String(localized: "header.new-chat", defaultValue: "New Chat")
        static let switchToEditor = String(localized: "header.switch-to-editor", defaultValue: "Switch to Editor Mode")
    }

    enum HeatmapCell {
        static func tooltip(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "heatmap-cell.tooltip", defaultValue: "Message count on date")
            return String(format: template, a1, a2)
        }
    }

    enum ImageDescription {
        static let help = String(localized: "image-description.help", defaultValue: "Click to expand collapse AI-generated image description")
        static let hide = String(localized: "image-description.hide", defaultValue: "Hide image description")
        static let show = String(localized: "image-description.show", defaultValue: "Image AI description")
    }

    enum ImagePreview {
        static let cannotPreview = String(localized: "image-preview.cannot-preview", defaultValue: "Cannot Preview Image")
        static let closeButton = String(localized: "image-preview.close-button", defaultValue: "Close Preview")
    }

    enum Inspector {
        static let hideButton = String(localized: "inspector.hide-button", defaultValue: "Hide Inspector")
        static let showButton = String(localized: "inspector.show-button", defaultValue: "Show Inspector")
    }

    enum Menu {
        static let editCommandPalette = String(localized: "menu.edit.command-palette", defaultValue: "Command Palette")
        static let editDuplicateLine = String(localized: "menu.edit.duplicate-line", defaultValue: "Duplicate Line")
        static let editFind = String(localized: "menu.edit.find", defaultValue: "Find")
        static let editFindNext = String(localized: "menu.edit.find-next", defaultValue: "Find Next")
        static let editFindPrevious = String(localized: "menu.edit.find-previous", defaultValue: "Find Previous")
        static let editGoToLine = String(localized: "menu.edit.go-to-line", defaultValue: "Go to Line")
        static let editGoToSymbol = String(localized: "menu.edit.go-to-symbol", defaultValue: "Go to Symbol")
        static let editMoveLineDown = String(localized: "menu.edit.move-line-down", defaultValue: "Move Line Down")
        static let editMoveLineUp = String(localized: "menu.edit.move-line-up", defaultValue: "Move Line Up")
        static let editQuickOpen = String(localized: "menu.edit.quick-open", defaultValue: "Quick Open")
        static let fileNewTab = String(localized: "menu.file.new-tab", defaultValue: "New Tab")
        static let fileNewWindow = String(localized: "menu.file.new-window", defaultValue: "New Window…")
        static let fileOpenFile = String(localized: "menu.file.open-file", defaultValue: "Open File…")
        static let fileOpenFolder = String(localized: "menu.file.open-folder", defaultValue: "Open Folder…")
        static let fileSave = String(localized: "menu.file.save", defaultValue: "Save")
        static let fileSaveAs = String(localized: "menu.file.save-as", defaultValue: "Save As…")
        static let viewOpenContainingFolder = String(localized: "menu.view.open-containing-folder", defaultValue: "Open Containing Folder")
        static let viewOpenSplitFile = String(localized: "menu.view.open-split-file", defaultValue: "Open Split File…")
        static let viewSwitchToAgentMode = String(localized: "menu.view.switch-to-agent-mode", defaultValue: "Switch to Agent Mode")
        static let viewSwitchToEditorMode = String(localized: "menu.view.switch-to-editor-mode", defaultValue: "Switch to Editor Mode")
        static let viewToggleAgent = String(localized: "menu.view.toggle-agent", defaultValue: "Toggle Agent")
        static let viewToggleFocusMode = String(localized: "menu.view.toggle-focus-mode", defaultValue: "Toggle Focus Mode")
        static let viewToggleInspector = String(localized: "menu.view.toggle-inspector", defaultValue: "Toggle Inspector")
        static let viewTogglePreview = String(localized: "menu.view.toggle-preview", defaultValue: "Toggle Preview")
        static let windowCloseTab = String(localized: "menu.window.close-tab", defaultValue: "Close Tab")
        static let windowNextTab = String(localized: "menu.window.next-tab", defaultValue: "Next Tab")
        static let windowPreviousTab = String(localized: "menu.window.previous-tab", defaultValue: "Previous Tab")
        static let windowReopenClosedTab = String(localized: "menu.window.reopen-closed-tab", defaultValue: "Reopen Closed Tab")
        static func windowSelectTabIndex(_ a1: String) -> String {
            let template = String(localized: "menu.window.select-tab-index", defaultValue: "Select Tab %@")
            return String(format: template, a1)
        }
    }

    enum MessageFooter {
        static let copied = String(localized: "message-footer.copied", defaultValue: "Copied")
        static let copy = String(localized: "message-footer.copy", defaultValue: "Copy message")
        static let copyAccessibility = String(localized: "message-footer.copy-accessibility", defaultValue: "Copy message")
    }

    enum ModelUsage {
        static let cached = { (a1: String) -> String in
            let template = String(localized: "model-usage.cached", defaultValue: "%@ cached")
            return String(format: template, a1)
        }
        static let costUnknown = String(localized: "model-usage.cost-unknown", defaultValue: "n/a")
        static let empty = String(localized: "model-usage.empty", defaultValue: "No model usage in this range yet.")
        static let footnoteEstimatedUsage = String(localized: "model-usage.footnote.estimated-usage", defaultValue: "≈ means token split was estimated from older session data.")
        static let footnoteUnknownAndEstimated = String(localized: "model-usage.footnote.unknown-and-estimated", defaultValue: "n/a means no built-in price for that model; ≈ means older token data was estimated.")
        static let footnoteUnknownPrice = String(localized: "model-usage.footnote.unknown-price", defaultValue: "n/a means no built-in price for that model or relay.")
        static let headerCache = String(localized: "model-usage.header.cache", defaultValue: "Cache")
        static let headerCost = String(localized: "model-usage.header.cost", defaultValue: "Cost")
        static let headerModel = String(localized: "model-usage.header.model", defaultValue: "Provider / model")
        static let headerTokens = String(localized: "model-usage.header.tokens", defaultValue: "In / out")
        static let messages = { (a1: String) -> String in
            let template = String(localized: "model-usage.messages", defaultValue: "%@ messages")
            return String(format: template, a1)
        }
        static let reasoning = { (a1: String) -> String in
            let template = String(localized: "model-usage.reasoning", defaultValue: "%@ reasoning")
            return String(format: template, a1)
        }
        static let sessions = { (a1: String) -> String in
            let template = String(localized: "model-usage.sessions", defaultValue: "%@ sessions")
            return String(format: template, a1)
        }
        static let tokensHelp = { (a1: String, a2: String) -> String in
            let template = String(localized: "model-usage.tokens-help", defaultValue: "%@ input tokens, %@ output tokens")
            return String(format: template, a1, a2)
        }
    }

    enum PlanCard {
        static let approveButton = String(localized: "plan-card.approve-button", defaultValue: "Approve")
        static let header = String(localized: "plan-card.header", defaultValue: "Plan")
        static let infoText = String(localized: "plan-card.info-text", defaultValue: "Plan mode blocks writes until you Approve.")
        static let markCompleteButton = String(localized: "plan-card.mark-complete-button", defaultValue: "Mark plan complete")
        static let rejectButton = String(localized: "plan-card.reject-button", defaultValue: "Reject")
    }

    enum PlanRevision {
        static let cancelButtonHelp = String(localized: "plan-revision.cancel-button.help", defaultValue: "Cancel")
        static let placeholder = String(localized: "plan-revision.placeholder", defaultValue: "Revision note optional e.g. skip step 2 use sed instead")
        static let queueNotice = String(localized: "plan-revision.queue-notice", defaultValue: "Note will queue until the current turn finishes.")
        static let replanButton = String(localized: "plan-revision.replan-button", defaultValue: "Replan")
        static let replanTooltip = String(localized: "plan-revision.replan-tooltip", defaultValue: "Ask the agent to revise the plan optionally with a note")
        static let sendButton = String(localized: "plan-revision.send-button", defaultValue: "Send")
    }

    enum PlanStatus {
        static let approved = String(localized: "plan-status.approved", defaultValue: "Approved")
        static let done = String(localized: "plan-status.done", defaultValue: "Done")
        static let executing = String(localized: "plan-status.executing", defaultValue: "Executing")
        static let proposed = String(localized: "plan-status.proposed", defaultValue: "Awaiting Approval")
        static let rejected = String(localized: "plan-status.rejected", defaultValue: "Rejected")
    }

    enum PlanStep {
        static let cycleStatusHelp = String(localized: "plan-step.cycle-status.help", defaultValue: "Approve the plan to track step progress")
        static let menuEdit = String(localized: "plan-step.menu.edit", defaultValue: "Edit step…")
        static let menuInsertAbove = String(localized: "plan-step.menu.insert-above", defaultValue: "Insert step above…")
        static let menuInsertBelow = String(localized: "plan-step.menu.insert-below", defaultValue: "Insert step below…")
        static let menuRemove = String(localized: "plan-step.menu.remove", defaultValue: "Remove step")
        static let menuRestart = String(localized: "plan-step.menu.restart", defaultValue: "Restart from this step…")
    }

    enum PlanStepSheet {
        static let cancel = String(localized: "plan-step-sheet.cancel", defaultValue: "Cancel")
        static let insertAbovePlaceholder = String(localized: "plan-step-sheet.insert-above.placeholder", defaultValue: "New step description")
        static let insertBelowPlaceholder = String(localized: "plan-step-sheet.insert-below.placeholder", defaultValue: "New step description")
        static let placeholder = String(localized: "plan-step-sheet.placeholder", defaultValue: "Step description")
        static let restartPlaceholder = String(localized: "plan-step-sheet.restart.placeholder", defaultValue: "Optional note for the agent e.g. use sed instead")
    }

    enum PreviewPane {
        static let title = String(localized: "preview-pane.title", defaultValue: "Preview")
    }

    enum ProviderStatus {
        static let help = String(localized: "provider-status.help", defaultValue: "Active provider driving the next chat turn. Click to switch.")
    }

    enum QueuedMessage {
        static let actionsButton = String(localized: "queued-message.actions-button", defaultValue: "Queued message actions")
        static let actionsButtonHelp = String(localized: "queued-message.actions-button.help", defaultValue: "Show queued message actions")
        static let deleteButton = String(localized: "queued-message.delete-button", defaultValue: "Delete")
        static let deleteButtonHelp = String(localized: "queued-message.delete-button.help", defaultValue: "Delete this queued message")
        static let editButton = String(localized: "queued-message.edit-button", defaultValue: "Edit queued message")
        static let editButtonHelp = String(localized: "queued-message.edit-button.help", defaultValue: "Edit this queued message in the composer")
        static let emptyPreview = String(localized: "queued-message.empty-preview", defaultValue: "Queued message")
        static func imageCount(_ a1: String) -> String {
            let template = String(localized: "queued-message.image-count", defaultValue: "%@ images")
            return String(format: template, a1)
        }
        static let label = String(localized: "queued-message.label", defaultValue: "Queued")
        static let sendNowButton = String(localized: "queued-message.send-now-button", defaultValue: "Send queued message now")
        static let sendNowButtonHelp = String(localized: "queued-message.send-now-button.help", defaultValue: "Send this queued message now")
        static func textAttachmentCount(_ a1: String) -> String {
            let template = String(localized: "queued-message.text-attachment-count", defaultValue: "%@ text attachments")
            return String(format: template, a1)
        }
    }

    enum QuickOpen {
        static let noFiles = String(localized: "quick-open.no-files", defaultValue: "No Files")
        static let placeholder = String(localized: "quick-open.placeholder", defaultValue: "Quick Open")
    }

    enum Sidebar {
        static func archivedSessionsHeader(_ a1: String) -> String {
            let template = String(localized: "sidebar.archived-sessions.header", defaultValue: "Archived count")
            return String(format: template, a1)
        }
        static let chatsHeader = String(localized: "sidebar.chats-header", defaultValue: "Chats")
        static let emptyState = String(localized: "sidebar.empty-state", defaultValue: "Sessions you start will appear here.")
        static let newChatAction = String(localized: "sidebar.new-chat-action", defaultValue: "New Chat")
        static let sessionListSeeMore = String(localized: "sidebar.session-list.see-more", defaultValue: "See more")
        static let sessionListShowLess = String(localized: "sidebar.session-list.show-less", defaultValue: "Show less")
        static let sessionMenuArchive = String(localized: "sidebar.session-menu.archive", defaultValue: "Archive")
        static let sessionMenuDelete = String(localized: "sidebar.session-menu.delete", defaultValue: "Delete session")
        static let sessionMenuPin = String(localized: "sidebar.session-menu.pin", defaultValue: "Pin")
        static let sessionMenuRename = String(localized: "sidebar.session-menu.rename", defaultValue: "Rename…")
        static let sessionMenuSummarizeTitle = String(localized: "sidebar.session-menu.summarize-title", defaultValue: "Summarize with AI")
        static let sessionMenuUnarchive = String(localized: "sidebar.session-menu.unarchive", defaultValue: "Unarchive")
        static let sessionMenuUnpin = String(localized: "sidebar.session-menu.unpin", defaultValue: "Unpin")
        static let renameSessionAlertTitle = String(localized: "sidebar.rename-session.alert-title", defaultValue: "Rename Session")
        static let renameSessionAlertMessage = String(localized: "sidebar.rename-session.alert-message", defaultValue: "Give this conversation a new name.")
        static let renameSessionConfirm = String(localized: "sidebar.rename-session.confirm", defaultValue: "Save")
        static let renameSessionCancel = String(localized: "sidebar.rename-session.cancel", defaultValue: "Cancel")
        static let sessionRowArchiveTooltip = String(localized: "sidebar.session-row.archive-tooltip", defaultValue: "Archive")
        static let sessionRowPinTooltip = String(localized: "sidebar.session-row.pin-tooltip", defaultValue: "Pin")
        static let sessionRowUnarchiveTooltip = String(localized: "sidebar.session-row.unarchive-tooltip", defaultValue: "Unarchive")
        static let sessionRowUnpinTooltip = String(localized: "sidebar.session-row.unpin-tooltip", defaultValue: "Unpin")
        static func sessionUpdatedTooltip(_ a1: String) -> String {
            let template = String(localized: "sidebar.session-row.updated-tooltip", defaultValue: "Updated %@ ago")
            return String(format: template, a1)
        }
        static let workspaceHeader = String(localized: "sidebar.workspace-header", defaultValue: "Workspaces")
        static let workspaceHeaderOpenTooltip = String(localized: "sidebar.workspace-header.open-tooltip", defaultValue: "Open another folder as a new workspace")
        static let workspaceMenuNewChat = String(localized: "sidebar.workspace-menu.new-chat", defaultValue: "New Chat in this Workspace")
        static let workspaceToggleCollapseTooltip = String(localized: "sidebar.workspace-toggle.collapse-tooltip", defaultValue: "Collapse session list")
        static let workspaceToggleExpandTooltip = String(localized: "sidebar.workspace-toggle.expand-tooltip", defaultValue: "Expand session list")
    }

    enum SplitEditor {
        static let defaultTitle = String(localized: "split-editor.default-title", defaultValue: "Split")
    }

    enum StatCell {
        static let activeDays = String(localized: "stat-cell.active-days", defaultValue: "Active days")
        static let currentStreak = String(localized: "stat-cell.current-streak", defaultValue: "Current streak")
        static let favoriteModel = String(localized: "stat-cell.favorite-model", defaultValue: "Favorite model")
        static let longestStreak = String(localized: "stat-cell.longest-streak", defaultValue: "Longest streak")
        static let messages = String(localized: "stat-cell.messages", defaultValue: "Messages")
        static let peakHour = String(localized: "stat-cell.peak-hour", defaultValue: "Peak hour")
        static let sessions = String(localized: "stat-cell.sessions", defaultValue: "Sessions")
        static let tokens = String(localized: "stat-cell.tokens", defaultValue: "Tokens")
        static let tokensEstimated = String(localized: "stat-cell.tokens-estimated", defaultValue: "Tokens (est.)")
    }

    enum StatsDashboard {
        static let range30d = String(localized: "stats-dashboard.range.30d", defaultValue: "30d")
        static let range7d = String(localized: "stats-dashboard.range.7d", defaultValue: "7d")
        static let rangeAll = String(localized: "stats-dashboard.range.all", defaultValue: "All")
        static let tabsModels = String(localized: "stats-dashboard.tabs.models", defaultValue: "Models")
        static let tabsOverview = String(localized: "stats-dashboard.tabs.overview", defaultValue: "Overview")
    }

    enum SymbolJump {
        static let noSymbols = String(localized: "symbol-jump.no-symbols", defaultValue: "No Symbols")
        static let placeholder = String(localized: "symbol-jump.placeholder", defaultValue: "Go to Symbol")
        static func symbolKindLine(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "symbol-jump.symbol-kind.line", defaultValue: "line")
            return String(format: template, a1, a2)
        }
    }

    enum ToolCard {
        static let allow = String(localized: "tool-card.allow", defaultValue: "Allow")
        static let alwaysAllow = String(localized: "tool-card.always-allow", defaultValue: "Always Allow")
        static func alwaysAllowHelp(_ a1: String) -> String {
            let template = String(localized: "tool-card.always-allow.help", defaultValue: "Always allow future %@ commands")
            return String(format: template, a1)
        }
        static let deny = String(localized: "tool-card.deny", defaultValue: "Deny")
        static let confirmRun = String(localized: "tool-card.confirm-run", defaultValue: "Confirm and Run")
        static let destructiveWarning = String(localized: "tool-card.destructive-warning", defaultValue: "This command is destructive. Confirm before it runs.")
        static let command = String(localized: "tool-card.command", defaultValue: "Command")
        static let arguments = String(localized: "tool-card.arguments", defaultValue: "Arguments")
        static let output = String(localized: "tool-card.output", defaultValue: "Output")
        static let error = String(localized: "tool-card.error", defaultValue: "Error")
        static let collapse = String(localized: "tool-card.collapse", defaultValue: "Collapse")
        static let expand = String(localized: "tool-card.expand", defaultValue: "Expand")
        static let statusAwaitingApproval = String(localized: "tool-card.status.awaiting-approval", defaultValue: "Awaiting approval")
        static let statusConfirmRequired = String(localized: "tool-card.status.confirm-required", defaultValue: "Confirm required")
        static let statusAskingYou = String(localized: "tool-card.status.asking-you", defaultValue: "Asking you")
        static let statusRunning = String(localized: "tool-card.status.running", defaultValue: "Running…")
        static let statusDone = String(localized: "tool-card.status.done", defaultValue: "Done")
        static let statusFailed = String(localized: "tool-card.status.failed", defaultValue: "Failed")
        static let statusDenied = String(localized: "tool-card.status.denied", defaultValue: "Denied")
    }

    enum AgentJobs {
        static let title = String(localized: "agent-jobs.title", defaultValue: "Background Jobs")
        static let toggleHelp = String(localized: "agent-jobs.toggle-help", defaultValue: "Show background jobs panel")
        static let collapseHelp = String(localized: "agent-jobs.collapse-help", defaultValue: "Hide background jobs panel")
        static let empty = String(localized: "agent-jobs.empty", defaultValue: "No background jobs in this session.")
        static let kill = String(localized: "agent-jobs.kill", defaultValue: "Kill job")
        static let noOutput = String(localized: "agent-jobs.no-output", defaultValue: "(no output captured yet)")
        static let statusRunning = String(localized: "agent-jobs.status.running", defaultValue: "running")
        static let statusCompleted = String(localized: "agent-jobs.status.completed", defaultValue: "completed")
        static let statusFailed = String(localized: "agent-jobs.status.failed", defaultValue: "failed")
        static let statusKilled = String(localized: "agent-jobs.status.killed", defaultValue: "killed")
        static let statusTimedOut = String(localized: "agent-jobs.status.timed-out", defaultValue: "timed out")
        static let statusLaunchFailed = String(localized: "agent-jobs.status.launch-failed", defaultValue: "launch failed")
        static let notificationTitle = String(localized: "agent-jobs.notification.title", defaultValue: "Background job finished")
    }

    enum Settings {
        static let windowTitle = String(localized: "settings.window.title", defaultValue: "Settings")
        static let tabTypography = String(localized: "settings.tab.typography", defaultValue: "Font")
        static let tabAppearance = String(localized: "settings.tab.appearance", defaultValue: "Format")
        static let tabWorkspace = String(localized: "settings.tab.workspace", defaultValue: "Workspace")
        static let tabAgent = String(localized: "settings.tab.agent", defaultValue: "AI Providers")
        static let tabMemory = String(localized: "settings.tab.memory", defaultValue: "Memory")
        static let tabRules = String(localized: "settings.tab.rules", defaultValue: "Rules")
        static let tabSkills = String(localized: "settings.tab.skills", defaultValue: "Skills")
        static let tabMcp = String(localized: "settings.tab.mcp", defaultValue: "MCP")
        static let tabTools = String(localized: "settings.tab.tools", defaultValue: "Tools")
        static let tabLocalAgents = String(localized: "settings.tab.local-agents", defaultValue: "Local Agents")
        static let tabRemoteRuntimes = String(localized: "settings.tab.remote-runtimes", defaultValue: "Runtimes")
        static let tabMobileGateway = String(localized: "settings.tab.mobile-gateway", defaultValue: "Mobile Gateway")

        static let sectionTypography = String(localized: "settings.section.typography", defaultValue: "Typography")
        static let sectionEditorText = String(localized: "settings.section.editor-text", defaultValue: "Editor Text")
        static let sectionWorkspaceText = String(localized: "settings.section.workspace-text", defaultValue: "Workspace List")
        static let sectionColorStyle = String(localized: "settings.section.color-style", defaultValue: "Color Style")
        static let sectionEditorBackground = String(localized: "settings.section.editor-background", defaultValue: "Editor Background")
        static let sectionEditor = String(localized: "settings.section.editor", defaultValue: "Editor")
        static let sectionSidebar = String(localized: "settings.section.sidebar", defaultValue: "Sidebar")
        static let sectionInspector = String(localized: "settings.section.inspector", defaultValue: "Inspector")
        static let sectionSave = String(localized: "settings.section.save", defaultValue: "Save")
        static let sectionAgentProviders = String(localized: "settings.section.agent-providers", defaultValue: "Agent Providers")
        static let sectionImageUnderstanding = String(localized: "settings.section.image-understanding", defaultValue: "Image Understanding")
        static let sectionConversationTitle = String(localized: "settings.section.conversation-title", defaultValue: "Conversation Title")
        static let sectionToolApproval = String(localized: "settings.section.tool-approval", defaultValue: "Tool approval")
        static let sectionConcurrency = String(localized: "settings.section.concurrency", defaultValue: "Concurrency")
        static let sectionAgentAppearance = String(localized: "settings.section.agent-appearance", defaultValue: "Appearance")
        static let sectionAgentAlwaysAllow = String(localized: "settings.section.agent-always-allow", defaultValue: "Agent Always Allow")
        static let sectionWebTools = String(localized: "settings.section.web-tools", defaultValue: "Web tools")

        static let toggleShowLineNumbers = String(localized: "settings.toggle.show-line-numbers", defaultValue: "Show Line Numbers")
        static let toggleHighlightCurrentLine = String(localized: "settings.toggle.highlight-current-line", defaultValue: "Highlight Current Line")
        static let toggleGlassEditorBackground = String(localized: "settings.toggle.glass-editor-background", defaultValue: "Glass Editor Background")
        static let toggleTrimTrailingWhitespace = String(localized: "settings.toggle.trim-trailing-whitespace", defaultValue: "Trim Trailing Whitespace")
        static let toggleEnsureFinalNewline = String(localized: "settings.toggle.ensure-final-newline", defaultValue: "Ensure Final Newline")
        static let toggleAutoApproveSafe = String(localized: "settings.toggle.auto-approve-safe", defaultValue: "Auto-approve safe commands")

        static let buttonChoose = String(localized: "settings.button.choose", defaultValue: "Choose…")
        static let buttonClear = String(localized: "settings.button.clear", defaultValue: "Clear")
        static let buttonSave = String(localized: "settings.button.save", defaultValue: "Save")
        static let buttonRevert = String(localized: "settings.button.revert", defaultValue: "Revert")

        static let perProviderConcurrency = String(localized: "settings.per-provider-concurrency", defaultValue: "Per-provider concurrency")
        static let chatBaseFontSize = String(localized: "settings.chat-base-font-size", defaultValue: "Chat base font size")
        static let noAlwaysAllowed = String(localized: "settings.no-always-allowed", defaultValue: "No commands are always allowed.")

        // MARK: Generic appearance/editor labels reused across tabs.
        static let labelFont = String(localized: "settings.label.font", defaultValue: "Font")
        static let labelTheme = String(localized: "settings.label.theme", defaultValue: "Theme")
        static let labelImage = String(localized: "settings.label.image", defaultValue: "Image")
        static let labelImageMode = String(localized: "settings.label.image-mode", defaultValue: "Image Mode")
        static let labelImageSize = String(localized: "settings.label.image-size", defaultValue: "Image Size")
        static let labelImageOpacity = String(localized: "settings.label.image-opacity", defaultValue: "Image Opacity")
        static let labelGlassMaterial = String(localized: "settings.label.glass-material", defaultValue: "Glass Material")
        static let labelGlassStrength = String(localized: "settings.label.glass-strength", defaultValue: "Glass Strength")
        static let labelEditorSurface = String(localized: "settings.label.editor-surface", defaultValue: "Editor Surface")
        static let labelTextSize = String(localized: "settings.label.text-size", defaultValue: "Text Size")
        static let labelLineHeight = String(localized: "settings.label.line-height", defaultValue: "Line Height")
        static let labelDefaultView = String(localized: "settings.label.default-view", defaultValue: "Default View")
        static let labelViewOrder = String(localized: "settings.label.view-order", defaultValue: "View Order")
        static let noImageSelected = String(localized: "settings.no-image-selected", defaultValue: "No image selected")
        static let chooseBackgroundImageTitle = String(localized: "settings.choose-background-image.title", defaultValue: "Choose Editor Background Image")
        static let savedStatus = String(localized: "settings.saved-status", defaultValue: "Saved.")
        static let allChangesSaved = String(localized: "settings.all-changes-saved", defaultValue: "All changes saved")

        enum WebTools {
            static let braveKeyLabel = String(localized: "settings.web-tools.brave-api-key", defaultValue: "Brave Search API Key")
            static let description = String(localized: "settings.web-tools.description", defaultValue: "Enables the built-in web_search tool. Get a free key at brave.com/search/api — it is stored in the macOS Keychain. web_fetch needs no key and asks for approval per domain.")
        }

        enum ImageUnderstanding {
            static let providerLabel = String(localized: "settings.image-understanding.provider", defaultValue: "Provider")
            static let baseURLLabel = String(localized: "settings.image-understanding.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.image-understanding.api-key", defaultValue: "API Key")
            static let visionModelLabel = String(localized: "settings.image-understanding.vision-model", defaultValue: "Vision Model")
            static let description = String(localized: "settings.image-understanding.description", defaultValue: "Used only when the active Agent provider cannot accept images directly. Multiple attached images are described in one request, then the description is sent to the main model.")
            static let fetchModels = String(localized: "settings.image-understanding.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.image-understanding.fetching-models", defaultValue: "Fetching...")
            static let fetchImageModels = String(localized: "settings.image-understanding.fetch-image-models", defaultValue: "Fetch Image Models")
            static let fetchingImages = String(localized: "settings.image-understanding.fetching-images", defaultValue: "Fetching Images...")
            static let fetchedModelsLabel = String(localized: "settings.image-understanding.fetched-models", defaultValue: "Fetched Models")
        }

        enum AgentBehavior {
            static let saveBehaviorNote = String(localized: "settings.agent-behavior.save-note", defaultValue: "Keystrokes stay local until you press Save (⌘↩). API keys are stored separately in Keychain.")
            static let titleModelLabel = String(localized: "settings.agent-behavior.title-model", defaultValue: "Title Model")
            static let titleModelPlaceholder = String(localized: "settings.agent-behavior.title-model-placeholder", defaultValue: "(leave empty → use Flash model)")
            static let titleModelDescription = String(localized: "settings.agent-behavior.title-model-description", defaultValue: "A short one-shot completion summarizes each new chat into a ≤12-char title after the first assistant reply. Set a cheap/fast model here (e.g. `deepseek-chat`, `gpt-4o-mini`, `qwen-turbo`) to avoid burning Pro tokens on titling. Empty → falls back to the active provider's Flash model.")
            static let toolApprovalDescription = String(localized: "settings.agent-behavior.tool-approval-description", defaultValue: "Read-only shell commands in the built-in allowlist (cat, head, tail, ls, find without -delete/-exec, git diff/log/status/show, rg, grep, wc, file, stat, which, pwd, echo, …) run without asking. Commands outside the allowlist are passed to a one-shot LLM judge running on the active provider's **Flash** model (cheap & fast — never Pro), and only YES verdicts auto-run. Destructive patterns (rm, sudo, git push --force, git reset --hard, …) still require typing \"confirm\".")
            static let concurrencyDescription = String(localized: "settings.agent-behavior.concurrency-description", defaultValue: "Cap on simultaneous Agent turns per provider. Each provider has its own quota — running 3 DashScope sessions doesn't block OpenAI sessions. When the cap is hit, new dispatches queue (FIFO) and drain as turns finish. Raising the cap immediately promotes queued work; lowering it just stops promoting new ones (running turns are never aborted). Default 3 is conservative — bump up if your provider's rate limit comfortably allows.")
            static func agentAppearanceDescription(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.agent-behavior.appearance-description", defaultValue: "Base size (pt) for Agent chat message body and rendered Markdown blocks (paragraphs, lists, quotes, fenced code, tables). Tool-call summaries, footers, message headers, and composer chrome keep their fixed sizes — this knob is about reading the conversation, not resizing the whole UI. Default is 13 pt; range %1$@ – %2$@ pt.")
                return String(format: template, a1, a2)
            }
        }

        enum Tools {
            static let alwaysAllowNote = String(localized: "settings.tools.always-allow-note", defaultValue: "Rules apply to command families such as `git push`; dangerous commands still require confirmation.")
            static let removeButton = String(localized: "settings.tools.remove", defaultValue: "Remove")
            static let clearAllButton = String(localized: "settings.tools.clear-all", defaultValue: "Clear All")
            static let cliSection = String(localized: "settings.tools.cli-section", defaultValue: "Command Line Tool")
            static func installedAt(_ a1: String) -> String {
                let template = String(localized: "settings.tools.cli-installed-at", defaultValue: "Installed at %@")
                return String(format: template, a1)
            }
            static func needsUpdateAt(_ a1: String) -> String {
                let template = String(localized: "settings.tools.cli-needs-update", defaultValue: "A command exists at %@ and can be updated.")
                return String(format: template, a1)
            }
            static let notInstalled = String(localized: "settings.tools.cli-not-installed", defaultValue: "Install the willdeep command for Terminal.")
            static let installingButton = String(localized: "settings.tools.cli-installing", defaultValue: "Installing...")
            static let reinstallButton = String(localized: "settings.tools.cli-reinstall", defaultValue: "Reinstall")
            static let updateButton = String(localized: "settings.tools.cli-update", defaultValue: "Update")
            static let installButton = String(localized: "settings.tools.cli-install", defaultValue: "Install")
            static let installingMessage = String(localized: "settings.tools.cli-installing-message", defaultValue: "Installing without administrator privileges.")
            static let installedMessage = String(localized: "settings.tools.cli-installed-message", defaultValue: "Installed. Try: willdeep . Add ~/.local/bin to PATH if needed.")
        }

        enum LocalAgents {
            static let discoveredSection = String(localized: "settings.local-agents.discovered-section", defaultValue: "Discovered CLI Agents")
            static let description = String(localized: "settings.local-agents.description", defaultValue: "Scans common install paths and PATH without launching the tools.")
            static let refreshButton = String(localized: "settings.local-agents.refresh", defaultValue: "Refresh")
            static let notFound = String(localized: "settings.local-agents.not-found", defaultValue: "Not found on this Mac")
            static let integrationSection = String(localized: "settings.local-agents.integration-section", defaultValue: "WillDeep Integration")
            static let integrationDescription = String(localized: "settings.local-agents.integration-description", defaultValue: "Discovery means the CLI exists locally. Direct delegation means the current Agent tool surface can invoke it after user approval.")
            static let discoveryOnly = String(localized: "settings.local-agents.discovery-only", defaultValue: "Discovered only — not yet exposed as a callable Agent tool.")
            static func summary(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.local-agents.summary", defaultValue: "%1$@ of %2$@ known CLI agents found")
                return String(format: template, a1, a2)
            }
            static func directTool(_ a1: String) -> String {
                let template = String(localized: "settings.local-agents.direct-tool", defaultValue: "Direct delegation available through `%@`.")
                return String(format: template, a1)
            }
        }

        enum MobileGateway {
            static let controlSection = String(localized: "settings.mobile-gateway.control-section", defaultValue: "LAN Access")
            static let listenSection = String(localized: "settings.mobile-gateway.listen-section", defaultValue: "Gateway")
            static let pairingSection = String(localized: "settings.mobile-gateway.pairing-section", defaultValue: "Pairing")
            static let devicesSection = String(localized: "settings.mobile-gateway.devices-section", defaultValue: "Paired Devices")
            static let enableToggle = String(localized: "settings.mobile-gateway.enable-toggle", defaultValue: "Enable LAN Mobile Gateway")
            static let allowPairingToggle = String(localized: "settings.mobile-gateway.allow-pairing-toggle", defaultValue: "Allow new device pairing")
            static let statusLabel = String(localized: "settings.mobile-gateway.status", defaultValue: "Status")
            static let addressLabel = String(localized: "settings.mobile-gateway.address", defaultValue: "LAN address")
            static let protocolLabel = String(localized: "settings.mobile-gateway.protocol", defaultValue: "Protocol")
            static let desktopPeerLabel = String(localized: "settings.mobile-gateway.desktop-peer", defaultValue: "Desktop peer")
            static let pairingBaseURLLabel = String(localized: "settings.mobile-gateway.pairing-base-url", defaultValue: "Pairing URL")
            static let expiresLabel = String(localized: "settings.mobile-gateway.expires", defaultValue: "Expires")
            static let hostPrompt = String(localized: "settings.mobile-gateway.host-prompt", defaultValue: "0.0.0.0")
            static let portInputLabel = String(localized: "settings.mobile-gateway.port-input", defaultValue: "Port")
            static let portPrompt = String(localized: "settings.mobile-gateway.port-prompt", defaultValue: "8877")
            static let desktopNamePrompt = String(localized: "settings.mobile-gateway.desktop-name-prompt", defaultValue: "Desktop name shown on Android")
            static let executablePathPrompt = String(localized: "settings.mobile-gateway.executable-path-prompt", defaultValue: "Optional willdeep-agent executable path")
            static let startButton = String(localized: "settings.mobile-gateway.start", defaultValue: "Start")
            static let stopButton = String(localized: "settings.mobile-gateway.stop", defaultValue: "Stop")
            static let restartButton = String(localized: "settings.mobile-gateway.restart", defaultValue: "Apply & Restart")
            static let refreshButton = String(localized: "settings.mobile-gateway.refresh", defaultValue: "Refresh")
            static let copyPayloadButton = String(localized: "settings.mobile-gateway.copy-payload", defaultValue: "Copy pairing payload")
            static let refreshPairingButton = String(localized: "settings.mobile-gateway.refresh-pairing", defaultValue: "Refresh pairing QR")
            static let revokeButton = String(localized: "settings.mobile-gateway.revoke", defaultValue: "Revoke")
            static let notRunning = String(localized: "settings.mobile-gateway.not-running", defaultValue: "Not running")
            static let connected = String(localized: "settings.mobile-gateway.connected", defaultValue: "Connected")
            static let disconnected = String(localized: "settings.mobile-gateway.disconnected", defaultValue: "Disconnected")
            static let stopped = String(localized: "settings.mobile-gateway.stopped", defaultValue: "Stopped")
            static let starting = String(localized: "settings.mobile-gateway.starting", defaultValue: "Starting...")
            static let running = String(localized: "settings.mobile-gateway.running", defaultValue: "Running")
            static let noPairingPayload = String(localized: "settings.mobile-gateway.no-pairing-payload", defaultValue: "Pairing is unavailable. Refresh pairing after enabling new device pairing.")
            static let startToPair = String(localized: "settings.mobile-gateway.start-to-pair", defaultValue: "Start the gateway to show a QR pairing code.")
            static let noDevices = String(localized: "settings.mobile-gateway.no-devices", defaultValue: "No Android devices are paired yet.")
            static let revoked = String(localized: "settings.mobile-gateway.revoked", defaultValue: "Revoked")
            static let qrAccessibilityLabel = String(localized: "settings.mobile-gateway.qr-accessibility-label", defaultValue: "Mobile Gateway pairing QR code")
            static let qrUnavailable = String(localized: "settings.mobile-gateway.qr-unavailable", defaultValue: "QR code unavailable")
            static let listenDescription = String(localized: "settings.mobile-gateway.listen-description", defaultValue: "The gateway listens only after you enable it. Android connects over the local network; Agent execution, tools, patches, and file access still run through the Mac app.")
            static func resolvedExecutable(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.resolved-executable", defaultValue: "Using %@")
                return String(format: template, a1)
            }
            static func failed(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.failed", defaultValue: "Failed: %@")
                return String(format: template, a1)
            }
            static func lastConnected(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.last-connected", defaultValue: "Last connected %@")
                return String(format: template, a1)
            }
            static func createdAt(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.created-at", defaultValue: "Paired %@")
                return String(format: template, a1)
            }
        }

        enum RemoteRuntimes {
            static let listSection = String(localized: "settings.remote-runtimes.list-section", defaultValue: "Remote Runtimes")
            static let empty = String(localized: "settings.remote-runtimes.empty", defaultValue: "No remote runtimes configured.")
            static let addButton = String(localized: "settings.remote-runtimes.add", defaultValue: "Add SSH Runtime")
            static let addDaemonButton = String(localized: "settings.remote-runtimes.add-daemon", defaultValue: "Add Daemon Runtime")
            static let newRuntimeDefaultName = String(localized: "settings.remote-runtimes.new-default-name", defaultValue: "New SSH Runtime")
            static let newDaemonRuntimeDefaultName = String(localized: "settings.remote-runtimes.new-daemon-default-name", defaultValue: "New Daemon Runtime")
            static let connectionSection = String(localized: "settings.remote-runtimes.connection-section", defaultValue: "SSH Connection")
            static let displayNameLabel = String(localized: "settings.remote-runtimes.display-name", defaultValue: "Display name")
            static let displayNamePrompt = String(localized: "settings.remote-runtimes.display-name.prompt", defaultValue: "Name shown in the runtime list")
            static let transportLabel = String(localized: "settings.remote-runtimes.transport", defaultValue: "Transport")
            static let sshTransportLabel = String(localized: "settings.remote-runtimes.transport.ssh", defaultValue: "SSH")
            static let daemonTransportLabel = String(localized: "settings.remote-runtimes.transport.daemon", defaultValue: "Daemon")
            static let hostLabel = String(localized: "settings.remote-runtimes.host", defaultValue: "Host")
            static let hostPrompt = String(localized: "settings.remote-runtimes.host.prompt", defaultValue: "example.com or SSH config host")
            static let usernameLabel = String(localized: "settings.remote-runtimes.username", defaultValue: "Username")
            static let usernamePrompt = String(localized: "settings.remote-runtimes.username.prompt", defaultValue: "Remote login user")
            static let portInputLabel = String(localized: "settings.remote-runtimes.port-input", defaultValue: "Port")
            static let portPrompt = String(localized: "settings.remote-runtimes.port.prompt", defaultValue: "22")
            static func portLabel(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.port", defaultValue: "Port %@")
                return String(format: template, a1)
            }
            static let identityFileLabel = String(localized: "settings.remote-runtimes.identity-file", defaultValue: "SSH identity file path (optional)")
            static let identityFilePrompt = String(localized: "settings.remote-runtimes.identity-file.prompt", defaultValue: "~/.ssh/id_rsa")
            static let daemonURLLabel = String(localized: "settings.remote-runtimes.daemon-url", defaultValue: "Daemon URL")
            static let daemonURLPrompt = String(localized: "settings.remote-runtimes.daemon-url.prompt", defaultValue: "http://127.0.0.1:8765")
            static let daemonTokenLabel = String(localized: "settings.remote-runtimes.daemon-token", defaultValue: "Daemon token (stored in Keychain)")
            static let daemonTokenPrompt = String(localized: "settings.remote-runtimes.daemon-token.prompt", defaultValue: "Paste daemon token")
            static let workspacePathLabel = String(localized: "settings.remote-runtimes.workspace-path", defaultValue: "Remote workspace path")
            static let workspacePathPrompt = String(localized: "settings.remote-runtimes.workspace-path.prompt", defaultValue: "/path/to/workspace")
            static let sshDescription = String(localized: "settings.remote-runtimes.ssh-description", defaultValue: "Uses the system ssh client with BatchMode authentication. Configure hosts in your normal SSH config or provide an optional identity-file path; WillDeep stores only the path, never private key contents.")
            static let probeSection = String(localized: "settings.remote-runtimes.probe-section", defaultValue: "Probe")
            static let platformLabel = String(localized: "settings.remote-runtimes.platform", defaultValue: "Platform")
            static let capabilitiesLabel = String(localized: "settings.remote-runtimes.capabilities", defaultValue: "Capabilities")
            static let toolchainLabel = String(localized: "settings.remote-runtimes.toolchain", defaultValue: "Toolchain")
            static let collaborationLabel = String(localized: "settings.remote-runtimes.collaboration", defaultValue: "Collaboration")
            static let githubCLIMissing = String(localized: "settings.remote-runtimes.github-cli-missing", defaultValue: "GitHub CLI (gh) not found. Install it on the remote host and run gh auth login for GitHub workflows.")
            static let githubCLIAuthSuggested = String(localized: "settings.remote-runtimes.github-cli-auth-suggested", defaultValue: "Run gh auth login on the remote host to enable GitHub workflows.")
            static let mirrorLabel = String(localized: "settings.remote-runtimes.mirrors", defaultValue: "Registries / mirrors")
            static let proxyLabel = String(localized: "settings.remote-runtimes.proxies", defaultValue: "Proxy settings")
            static let lastProbeLabel = String(localized: "settings.remote-runtimes.last-probe", defaultValue: "Last probe")
            static let probeButton = String(localized: "settings.remote-runtimes.probe", defaultValue: "Test & Probe")
            static let probingButton = String(localized: "settings.remote-runtimes.probing", defaultValue: "Probing...")
            static let saveButton = String(localized: "settings.remote-runtimes.save", defaultValue: "Save")
            static let deleteButton = String(localized: "settings.remote-runtimes.delete", defaultValue: "Delete")
            static let savedStatus = String(localized: "settings.remote-runtimes.saved", defaultValue: "Runtime saved.")
            static let deletedStatus = String(localized: "settings.remote-runtimes.deleted", defaultValue: "Runtime deleted.")
            static func probingStatus(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probing-status", defaultValue: "Probing %@...")
                return String(format: template, a1)
            }
            static func probeSucceeded(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probe-succeeded", defaultValue: "Probe succeeded: %1$@ / %2$@.")
                return String(format: template, a1, a2)
            }
            static func probeFailed(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probe-failed", defaultValue: "Probe failed: %@")
                return String(format: template, a1)
            }
            static let daemonSection = String(localized: "settings.remote-runtimes.daemon-section", defaultValue: "Daemon Runtime")
            static let daemonDescription = String(localized: "settings.remote-runtimes.daemon-description", defaultValue: "Connects to willdeep-agent over HTTP/WebSocket. Keep the daemon bound to 127.0.0.1 and reach it through an SSH tunnel; WillDeep stores the token in Keychain.")
        }

        enum Provider {
            static let editsAutoSave = String(localized: "settings.provider.edits-auto-save", defaultValue: "Edits save automatically. The active provider (★) drives the next chat turn — click any star to switch.")
            static let addTooltip = String(localized: "settings.provider.add-tooltip", defaultValue: "Add provider")
            static let removeTooltip = String(localized: "settings.provider.remove-tooltip", defaultValue: "Remove selected provider")
            static let activeTooltip = String(localized: "settings.provider.active-tooltip", defaultValue: "Active provider")
            static let makeActiveTooltip = String(localized: "settings.provider.make-active-tooltip", defaultValue: "Make active")
            static let emptySelection = String(localized: "settings.provider.empty-selection", defaultValue: "Pick a provider on the left, or add one with +")
            static let connectionSection = String(localized: "settings.provider.connection", defaultValue: "Connection")
            static let displayNameLabel = String(localized: "settings.provider.display-name", defaultValue: "Display name")
            static let displayNamePlaceholder = String(localized: "settings.provider.display-name-placeholder", defaultValue: "e.g. Work OpenAI")
            static let presetLabel = String(localized: "settings.provider.preset", defaultValue: "Preset")
            static let protocolLabel = String(localized: "settings.provider.protocol", defaultValue: "Protocol")
            static let openAIChatDefault = String(localized: "settings.provider.openai-chat-default", defaultValue: "OpenAI Chat (default)")
            static let baseURLLabel = String(localized: "settings.provider.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.provider.api-key", defaultValue: "API key")
            static let baseURLDefault = String(localized: "settings.provider.base-url-default", defaultValue: "Using preset URL")
            static let baseURLCustom = String(localized: "settings.provider.base-url-custom", defaultValue: "Customized")
            static func protocolLine(_ a1: String) -> String {
                let template = String(localized: "settings.provider.protocol-line", defaultValue: "Protocol: %@")
                return String(format: template, a1)
            }
            static let modelsSection = String(localized: "settings.provider.models", defaultValue: "Models")
            static let routingSection = String(localized: "settings.provider.routing", defaultValue: "Routing")
            static let defaultTierLabel = String(localized: "settings.provider.default-tier", defaultValue: "Default tier")
            static let fetchModels = String(localized: "settings.provider.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.provider.fetching-models", defaultValue: "Fetching…")
            static let alternatesHint = String(localized: "settings.provider.alternates-hint", defaultValue: "One model id per line — surfaces in the chat picker as one-click switches.")
            static let pickFromFetched = String(localized: "settings.provider.pick-from-fetched", defaultValue: "Pick from fetched models")
            static let hideKey = String(localized: "settings.provider.hide-key", defaultValue: "Hide key")
            static let showKey = String(localized: "settings.provider.show-key", defaultValue: "Show key")
            static let modelIDPlaceholder = String(localized: "settings.provider.model-id-placeholder", defaultValue: "model-id")
            static func primarySuffix(_ a1: String) -> String {
                let template = String(localized: "settings.provider.primary-suffix", defaultValue: "%@ primary")
                return String(format: template, a1)
            }
            static func alternatesSuffix(_ a1: String) -> String {
                let template = String(localized: "settings.provider.alternates-suffix", defaultValue: "%@ alternates")
                return String(format: template, a1)
            }
        }

        enum MCP {
            static let serversDescription = String(localized: "settings.mcp.servers-description", defaultValue: "Servers available in this workspace.")
            static func serversEnabled(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.mcp.servers-enabled", defaultValue: "%1$@ of %2$@ MCP servers enabled")
                return String(format: template, a1, a2)
            }
            static let refresh = String(localized: "settings.mcp.refresh", defaultValue: "Refresh")
            static let cursorConfig = String(localized: "settings.mcp.cursor-config", defaultValue: "Cursor mcp.json")
            static let newServer = String(localized: "settings.mcp.new-server", defaultValue: "New MCP Server")
            static let userServers = String(localized: "settings.mcp.user-servers", defaultValue: "User MCP Servers")
            static let cursorServers = String(localized: "settings.mcp.cursor-servers", defaultValue: "Cursor MCP Servers")
            static let codexServers = String(localized: "settings.mcp.codex-servers", defaultValue: "Codex MCP Servers")
            static let noServers = String(localized: "settings.mcp.no-servers", defaultValue: "No servers in this group.")
            static let logout = String(localized: "settings.mcp.logout", defaultValue: "Logout")
            static func toolsEnabled(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.tools-enabled", defaultValue: "%@ tools enabled")
                return String(format: template, a1)
            }
            static let toolListNotRefreshed = String(localized: "settings.mcp.tool-list-not-refreshed", defaultValue: "Tool list not refreshed")
            static let disabled = String(localized: "settings.mcp.disabled", defaultValue: "Disabled")
            static let trustedHelp = String(localized: "settings.mcp.trusted-help", defaultValue: "Trusted. Pinned tools auto-run.")
            static let untrustedHelp = String(localized: "settings.mcp.untrusted-help", defaultValue: "Untrusted. Always-Allow rules ignored — every call gates.")
            static func markedTrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-trusted", defaultValue: "Marked %@ as trusted.")
                return String(format: template, a1)
            }
            static func markedUntrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-untrusted", defaultValue: "Marked %@ as untrusted. Always-Allow rules will be ignored for it.")
                return String(format: template, a1)
            }
            static let trustLevelFull = String(localized: "settings.mcp.trust-level-full", defaultValue: "Fully trusted — all calls auto-run")
            static let trustLevelStandard = String(localized: "settings.mcp.trust-level-standard", defaultValue: "Default — read-style calls auto-run, writes ask")
            static let trustLevelUntrusted = String(localized: "settings.mcp.trust-level-untrusted", defaultValue: "Untrusted — every call asks")
            static let trustLevelHelp = String(localized: "settings.mcp.trust-level-help", defaultValue: "Trust level for this server's tool calls")
            static func markedFullyTrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-fully-trusted", defaultValue: "Marked %@ as fully trusted. All its calls now auto-run — writes included.")
                return String(format: template, a1)
            }
            static let refreshTools = String(localized: "settings.mcp.refresh-tools", defaultValue: "Refresh Tools")
            static let delete = String(localized: "settings.mcp.delete", defaultValue: "Delete")
            static func headersPrefix(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.headers-prefix", defaultValue: "headers: %@")
                return String(format: template, a1)
            }
            static func lastChecked(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.last-checked", defaultValue: "Last checked: %@")
                return String(format: template, a1)
            }
            static func failedPrefix(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.failed-prefix", defaultValue: "Failed: %@")
                return String(format: template, a1)
            }
            static let openedCursorConfig = String(localized: "settings.mcp.opened-cursor-config", defaultValue: "Opened Cursor mcp.json.")
            static let cursorConfigMissing = String(localized: "settings.mcp.cursor-config-missing", defaultValue: "Cursor mcp.json does not exist yet.")
            static func createdServer(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.created-server", defaultValue: "Created %@.")
                return String(format: template, a1)
            }
            static func deletedServer(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.deleted-server", defaultValue: "Deleted %@.")
                return String(format: template, a1)
            }
            static func authCleared(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.auth-cleared", defaultValue: "Authorization header cleared for %@.")
                return String(format: template, a1)
            }
            static let newServerTitle = String(localized: "settings.mcp.new-server-title", defaultValue: "New MCP Server")
            static let serverNamePlaceholder = String(localized: "settings.mcp.server-name-placeholder", defaultValue: "Server name")
            static let transportLabel = String(localized: "settings.mcp.transport", defaultValue: "Transport")
            static let urlPlaceholder = String(localized: "settings.mcp.url-placeholder", defaultValue: "https://example.com/mcp")
            static let headersLabel = String(localized: "settings.mcp.headers", defaultValue: "Headers")
            static let headersHint = String(localized: "settings.mcp.headers-hint", defaultValue: "One header per line, for example: Authorization=Bearer ...")
            static let commandPathPlaceholder = String(localized: "settings.mcp.command-path-placeholder", defaultValue: "/absolute/path/to/server")
            static let argsPlaceholder = String(localized: "settings.mcp.args-placeholder", defaultValue: "Arguments separated by spaces")
            static let environmentLabel = String(localized: "settings.mcp.environment", defaultValue: "Environment")
            static let environmentHint = String(localized: "settings.mcp.environment-hint", defaultValue: "One variable per line, for example: HTTPS_PROXY=http://127.0.0.1:7890")
            static let timeoutLabel = String(localized: "settings.mcp.timeout", defaultValue: "Timeout")
            static let cancelButton = String(localized: "settings.mcp.cancel", defaultValue: "Cancel")
            static let createButton = String(localized: "settings.mcp.create", defaultValue: "Create")
            static let errorServerNameRequired = String(localized: "settings.mcp.error-server-name", defaultValue: "Server name is required.")
            static let errorValidURLRequired = String(localized: "settings.mcp.error-valid-url", defaultValue: "A valid server URL is required.")
            static let errorCommandRequired = String(localized: "settings.mcp.error-command-required", defaultValue: "Command is required.")
        }

        enum Skill {
            static let autoExtractSection = String(localized: "settings.skill.auto-extract-section", defaultValue: "Automatic Skill Extraction")
            static let autoExtractTitle = String(localized: "settings.skill.auto-extract-title", defaultValue: "Auto-extract reusable skills from conversations")
            static let autoExtractDescription = String(localized: "settings.skill.auto-extract-description", defaultValue: "When enabled, WillDeep can surface reusable workflows as skill candidates.")
            static let minimumToolCallsLabel = String(localized: "settings.skill.minimum-tool-calls", defaultValue: "Minimum tool calls")
            static let minimumToolCallsHint = String(localized: "settings.skill.minimum-tool-calls-hint", defaultValue: "Conversations with fewer tool calls are skipped.")
            static let marketplaceSection = String(localized: "settings.skill.marketplace-section", defaultValue: "Skill Marketplace")
            static let marketplaceDescription = String(localized: "settings.skill.marketplace-description", defaultValue: "Install first-party skills from the bundled static catalog. A server-backed marketplace can replace this catalog later.")
            static let marketplaceInstall = String(localized: "settings.skill.marketplace-install", defaultValue: "Install")
            static let marketplaceInstalled = String(localized: "settings.skill.marketplace-installed", defaultValue: "Installed")
            static let marketplaceUpdate = String(localized: "settings.skill.marketplace-update", defaultValue: "Update")
            static let marketplaceUninstall = String(localized: "settings.skill.marketplace-uninstall", defaultValue: "Uninstall")
            static let marketplaceConflictLabel = String(localized: "settings.skill.marketplace-conflict-label", defaultValue: "Name conflict")
            static let marketplaceNoResults = String(localized: "settings.skill.marketplace-no-results", defaultValue: "No marketplace skills match the current search.")
            static let marketplaceStaticSource = String(localized: "settings.skill.marketplace-static-source", defaultValue: "Static catalog")
            static let marketplaceCredentialConfigured = String(localized: "settings.skill.marketplace-credential-configured", defaultValue: "Configured")
            static let marketplaceCredentialRequired = String(localized: "settings.skill.marketplace-credential-required", defaultValue: "Required")
            static let marketplaceCredentialClear = String(localized: "settings.skill.marketplace-credential-clear", defaultValue: "Clear")
            static let marketplaceInvalidSkill = String(localized: "settings.skill.marketplace-invalid-skill", defaultValue: "Marketplace skill name is invalid.")
            static func marketplaceCount(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-count", defaultValue: "%@ marketplace skills")
                return String(format: template, a1)
            }
            static func marketplaceCredentialCleared(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-credential-cleared", defaultValue: "Cleared %@.")
                return String(format: template, a1)
            }
            static func marketplaceVersion(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-version", defaultValue: "v%@")
                return String(format: template, a1)
            }
            static func marketplaceMinimumVersion(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-minimum-version", defaultValue: "Requires WillDeep %@+")
                return String(format: template, a1)
            }
            static func marketplaceInstalledStatus(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-installed-status", defaultValue: "Installed %@")
                return String(format: template, a1)
            }
            static func marketplaceUpdateStatus(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.skill.marketplace-update-status", defaultValue: "Installed %@ · Latest %@")
                return String(format: template, a1, a2)
            }
            static func marketplaceInstalledMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-installed-message", defaultValue: "Installed %@.")
                return String(format: template, a1)
            }
            static func marketplaceUpdatedMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-updated-message", defaultValue: "Updated %@.")
                return String(format: template, a1)
            }
            static func marketplaceUninstalledMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-uninstalled-message", defaultValue: "Uninstalled %@.")
                return String(format: template, a1)
            }
            static func marketplaceConflict(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-conflict", defaultValue: "A user skill named %@ already exists. Rename or remove it before installing this marketplace skill.")
                return String(format: template, a1)
            }
            static func marketplaceMissing(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-missing", defaultValue: "Marketplace skill %@ is not installed.")
                return String(format: template, a1)
            }
            static func availableCount(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.skill.available-count", defaultValue: "%1$@ of %2$@ skills available")
                return String(format: template, a1, a2)
            }
            static let refresh = String(localized: "settings.skill.refresh", defaultValue: "Refresh")
            static let openFolder = String(localized: "settings.skill.open-folder", defaultValue: "Open Folder")
            static let newSkill = String(localized: "settings.skill.new-skill", defaultValue: "New Skill")
            static let searchPlaceholder = String(localized: "settings.skill.search-placeholder", defaultValue: "Search by skill name, description, or path...")
            static let builtInSkills = String(localized: "settings.skill.built-in", defaultValue: "Built-in Skills")
            static let userSkills = String(localized: "settings.skill.user", defaultValue: "User Skills")
            static let pluginSkills = String(localized: "settings.skill.plugin", defaultValue: "Plugin Skills")
            static let noSkills = String(localized: "settings.skill.no-skills", defaultValue: "No skills in this group.")
            static let viewContent = String(localized: "settings.skill.view-content", defaultValue: "View content")
            static let unableToRead = String(localized: "settings.skill.unable-to-read", defaultValue: "Unable to read skill content.")
            static let newUserSkillTitle = String(localized: "settings.skill.new-user-skill", defaultValue: "New User Skill")
            static let skillNamePlaceholder = String(localized: "settings.skill.name-placeholder", defaultValue: "Skill name")
            static let descriptionPlaceholder = String(localized: "settings.skill.description-placeholder", defaultValue: "Description")
            static let cancelButton = String(localized: "settings.skill.cancel", defaultValue: "Cancel")
            static let createButton = String(localized: "settings.skill.create", defaultValue: "Create")
            static let defaultBody = String(localized: "settings.skill.default-body", defaultValue: "Describe when and how the Agent should use this skill.")
            static let openedFolder = String(localized: "settings.skill.opened-folder", defaultValue: "Opened user skills folder.")
            static func createdSkill(_ a1: String) -> String {
                let template = String(localized: "settings.skill.created", defaultValue: "Created %@.")
                return String(format: template, a1)
            }
        }

        enum Memory {
            static let featuresSection = String(localized: "settings.memory.features-section", defaultValue: "Memory Features")
            static let enableToggle = String(localized: "settings.memory.enable", defaultValue: "Enable memory")
            static let enableDescription = String(localized: "settings.memory.enable-description", defaultValue: "When enabled, the Agent can use saved preferences, recurring facts, and project notes as personalization context.")
            static let retrievalSection = String(localized: "settings.memory.retrieval-section", defaultValue: "Memory Retrieval")
            static let autoRetrievalToggle = String(localized: "settings.memory.auto-retrieval", defaultValue: "Auto-retrieve memories")
            static let autoRetrievalDescription = String(localized: "settings.memory.auto-retrieval-description", defaultValue: "Automatically search related memories before each Agent turn and inject the best matches as compact context.")
            static let queryRewriteToggle = String(localized: "settings.memory.query-rewrite", defaultValue: "Rewrite retrieval query")
            static let queryRewriteDescription = String(localized: "settings.memory.query-rewrite-description", defaultValue: "Use the tool model to turn conversational wording into a focused semantic search query.")
            static let maxRetrievedLabel = String(localized: "settings.memory.max-retrieved", defaultValue: "Max retrieved memories")
            static let similarityThresholdLabel = String(localized: "settings.memory.similarity-threshold", defaultValue: "Similarity threshold")
            static let similarityBroad = String(localized: "settings.memory.similarity-broad", defaultValue: "Broad (0%)")
            static let similarityStrict = String(localized: "settings.memory.similarity-strict", defaultValue: "Strict (100%)")
            static let summariesSection = String(localized: "settings.memory.summaries-section", defaultValue: "Memory Summaries")
            static let autoSummaryToggle = String(localized: "settings.memory.auto-summary", defaultValue: "Auto-summarize conversations")
            static let autoSummaryDescription = String(localized: "settings.memory.auto-summary-description", defaultValue: "Extract durable facts from conversations and save them as candidate memories.")
            static let maintenanceSection = String(localized: "settings.memory.maintenance-section", defaultValue: "Memory Maintenance")
            static let dailyMaintenanceToggle = String(localized: "settings.memory.daily-maintenance", defaultValue: "Run daily memory maintenance")
            static let maintenanceDescription = String(localized: "settings.memory.maintenance-description", defaultValue: "Archives duplicate or stale transient entries, removes expired archived entries, and records the last maintenance result.")
            static let runMaintenanceButton = String(localized: "settings.memory.run-maintenance", defaultValue: "Run maintenance cycle")
            static let previewMaintenanceButton = String(localized: "settings.memory.preview-maintenance", defaultValue: "Preview next cycle")
            static let triggerTimeLabel = String(localized: "settings.memory.trigger-time", defaultValue: "Trigger time")
            static let transientTTLLabel = String(localized: "settings.memory.transient-ttl", defaultValue: "Transient memory TTL")
            static let archiveRetentionLabel = String(localized: "settings.memory.archive-retention", defaultValue: "Archive retention")
            static func daysFormat(_ a1: String) -> String {
                let template = String(localized: "settings.memory.days-format", defaultValue: "%@ days")
                return String(format: template, a1)
            }
            static let mergeParametersLabel = String(localized: "settings.memory.merge-parameters", defaultValue: "Similarity and merge parameters")
            static let mergeParametersDescription = String(localized: "settings.memory.merge-parameters-description", defaultValue: "The current local maintenance pass handles retention and archiving. LLM-assisted duplicate merging can be wired into this section once the Agent memory retrieval pipeline starts consuming embeddings.")
            static func archivedMemoriesLabel(_ a1: String) -> String {
                let template = String(localized: "settings.memory.archived-label", defaultValue: "Archived memories (%@)")
                return String(format: template, a1)
            }
            static let noArchivedMemories = String(localized: "settings.memory.no-archived", defaultValue: "No archived memories.")
            static let exportSnapshotButton = String(localized: "settings.memory.export-snapshot", defaultValue: "Export memory snapshot")
            static let toolModelSection = String(localized: "settings.memory.tool-model-section", defaultValue: "Memory Tool Model")
            static let toolModelLabel = String(localized: "settings.memory.tool-model", defaultValue: "Tool model")
            static let useActiveAgentModel = String(localized: "settings.memory.use-active-agent-model", defaultValue: "Use active Agent model")
            static let toolModelDescription = String(localized: "settings.memory.tool-model-description", defaultValue: "Used for query rewriting and future LLM-assisted memory maintenance. Leave blank to follow the active Agent model.")
            static let embeddingSection = String(localized: "settings.memory.embedding-section", defaultValue: "Embedding Model")
            static let embeddingPlaceholder = String(localized: "settings.memory.embedding-placeholder", defaultValue: "Embedding model")
            static let embeddingDescription = String(localized: "settings.memory.embedding-description", defaultValue: "Used for semantic retrieval. Leave the default unless your provider exposes a compatible embedding model.")
            static let statisticsSection = String(localized: "settings.memory.statistics-section", defaultValue: "Statistics")
            static let totalMemoriesLabel = String(localized: "settings.memory.total-memories", defaultValue: "Total memories")
            static let autoGeneratedLabel = String(localized: "settings.memory.auto-generated", defaultValue: "Auto-generated")
            static let manualLabel = String(localized: "settings.memory.manual", defaultValue: "Manual")
            static let addMemorySection = String(localized: "settings.memory.add-memory-section", defaultValue: "Add Memory")
            static let lifetimeLabel = String(localized: "settings.memory.lifetime", defaultValue: "Lifetime")
            static let scopeLabel = String(localized: "settings.memory.scope", defaultValue: "Scope")
            static let projectScopeRequiresWorkspace = String(localized: "settings.memory.project-scope-requires-workspace", defaultValue: "Open a workspace before saving a project-scoped memory.")
            static let addMemoryButton = String(localized: "settings.memory.add-memory", defaultValue: "Add memory")
            static let searchSection = String(localized: "settings.memory.search-section", defaultValue: "Search Memories")
            static let searchPlaceholder = String(localized: "settings.memory.search-placeholder", defaultValue: "Search by text...")
            static let includeArchivedToggle = String(localized: "settings.memory.include-archived", defaultValue: "Include archived")
            static func shownCount(_ a1: String) -> String {
                let template = String(localized: "settings.memory.shown-count", defaultValue: "%@ shown")
                return String(format: template, a1)
            }
            static let resetSearchButton = String(localized: "settings.memory.reset-search", defaultValue: "Reset search")
            static let clearAllButton = String(localized: "settings.memory.clear-all", defaultValue: "Clear all")
            static let noMemoriesMatching = String(localized: "settings.memory.no-matching", defaultValue: "No memories match the current filters.")
            static let memoryListSection = String(localized: "settings.memory.memory-list-section", defaultValue: "Memory List")
            static let dailySleepCycleTitle = String(localized: "settings.memory.daily-sleep-cycle", defaultValue: "Daily sleep cycle")
            static func headerSummary(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.memory.header-summary", defaultValue: "Archived %1$@ · Next: %2$@")
                return String(format: template, a1, a2)
            }
            static let notScheduled = String(localized: "settings.memory.not-scheduled", defaultValue: "Not scheduled")
            static func lastStatus(_ a1: String) -> String {
                let template = String(localized: "settings.memory.last-status", defaultValue: "Last: %@")
                return String(format: template, a1)
            }
            static func maintenanceCounts(_ a1: String, _ a2: String, _ a3: String, _ a4: String) -> String {
                let template = String(localized: "settings.memory.maintenance-counts", defaultValue: "Inspected %1$@, archived %2$@, removed %3$@, merged %4$@.")
                return String(format: template, a1, a2, a3, a4)
            }
            static func tokensLine(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.memory.tokens-line", defaultValue: "LLM tokens: %1$@ input / %2$@ output")
                return String(format: template, a1, a2)
            }
            static func usedXTimes(_ a1: String) -> String {
                let template = String(localized: "settings.memory.used-x-times", defaultValue: "Used %@x")
                return String(format: template, a1)
            }
            static func confidenceTag(_ a1: String) -> String {
                let template = String(localized: "settings.memory.confidence-tag", defaultValue: "%@%% confidence")
                return String(format: template, a1)
            }
            static let sensitiveTag = String(localized: "settings.memory.sensitive-tag", defaultValue: "Sensitive redacted")
            static func topicsLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.topics-line", defaultValue: "Topics: %@")
                return String(format: template, a1)
            }
            static func provenanceLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.provenance-line", defaultValue: "Provenance: %@")
                return String(format: template, a1)
            }
            static func projectFingerprintLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-fingerprint-line", defaultValue: "Project fingerprint: %@")
                return String(format: template, a1)
            }
            static func lastAccessedLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.last-accessed-line", defaultValue: "Last retrieved: %@")
                return String(format: template, a1)
            }
            static let archivedTag = String(localized: "settings.memory.archived-tag", defaultValue: "Archived")
            static let editTooltip = String(localized: "settings.memory.edit-tooltip", defaultValue: "Edit memory")
            static let restoreTooltip = String(localized: "settings.memory.restore-tooltip", defaultValue: "Restore memory")
            static let archiveTooltip = String(localized: "settings.memory.archive-tooltip", defaultValue: "Archive memory")
            static let deleteTooltip = String(localized: "settings.memory.delete-tooltip", defaultValue: "Delete memory")
            static let cancelButton = String(localized: "settings.memory.cancel", defaultValue: "Cancel")
            static let saveButton = String(localized: "settings.memory.save", defaultValue: "Save")
            static let exportPanelTitle = String(localized: "settings.memory.export-panel-title", defaultValue: "Export Memory Snapshot")
            static func exportedTo(_ a1: String) -> String {
                let template = String(localized: "settings.memory.exported-to", defaultValue: "Exported to %@.")
                return String(format: template, a1)
            }
        }

        enum GlobalRules {
            static let fileSection = String(localized: "settings.global-rules.file-section", defaultValue: "Global Rules File")
            static let enableToggle = String(localized: "settings.global-rules.enable", defaultValue: "Enable global rules")
            static let filePathLabel = String(localized: "settings.global-rules.file-path", defaultValue: "File")
            static let reloadButton = String(localized: "settings.global-rules.reload", defaultValue: "Reload")
            static let description = String(localized: "settings.global-rules.description", defaultValue: "WillDeep reads this Markdown file before every Agent turn. The default is ~/.willdeep/CLAUDE.md, but you can point it at any personal rules file.")
            static let editorSection = String(localized: "settings.global-rules.editor-section", defaultValue: "Rules Content")
            static let precedenceNote = String(localized: "settings.global-rules.precedence-note", defaultValue: "Global rules apply across workspaces. Repository AGENTS.md or CLAUDE.md files are still included as project-specific instructions.")
            static let choosePanelTitle = String(localized: "settings.global-rules.choose-title", defaultValue: "Choose Global Rules File")
            static func loadedStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.loaded-status", defaultValue: "Loaded %@.")
                return String(format: template, a1)
            }
            static func noFileStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.no-file-status", defaultValue: "No rules file yet at %@. Save to create it.")
                return String(format: template, a1)
            }
            static func savedStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.saved-status", defaultValue: "Saved %@.")
                return String(format: template, a1)
            }
            static func saveFailed(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.save-failed", defaultValue: "Save failed: %@")
                return String(format: template, a1)
            }
        }
    }

    enum Transcript {
        static let messageTruncatedHelp = String(localized: "transcript.message-truncated.help", defaultValue: "Open in standalone window to view full message content")
        static func messageTruncatedText(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "transcript.message-truncated.text", defaultValue: "Message shows first N characters only")
            return String(format: template, a1, a2)
        }
        static let olderHistoryHelp = String(localized: "transcript.older-history.help", defaultValue: "Open in standalone window to view full conversation history")
        static func olderHistoryText(_ a1: String) -> String {
            let template = String(localized: "transcript.older-history.text", defaultValue: "More messages earlier in conversation")
            return String(format: template, a1)
        }
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

}
