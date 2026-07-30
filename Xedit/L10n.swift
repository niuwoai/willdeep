import Foundation

// Generated façade over Localizable.xcstrings.
// Each `static let` reads from the String Catalog at runtime with a baked-in en defaultValue
// (so missing entries fall back gracefully). Interpolated entries are exposed as `static func`
// taking String args; the catalog template uses %@ placeholders.
//
// To regenerate: see scripts/i18n_regenerate.rb (TODO if we ever automate this).

// `nonisolated`: pure `String(localized:)` lookups with no main-actor
// state. Under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor these statics
// would otherwise be unusable from nonisolated model code (e.g. the
// persisted session graph's displayName helpers).
nonisolated enum L10n {
    enum About {
        static let appName = String(localized: "about.app-name", defaultValue: "WillDeep")
        static let buildLabel = String(localized: "about.build-label", defaultValue: "Build")
        static let bundleIDLabel = String(localized: "about.bundle-id-label", defaultValue: "Bundle ID")
        static let copyVersionInfo = String(localized: "about.copy-version-info", defaultValue: "Copy Version Info")
        static let menuItem = String(localized: "about.menu-item", defaultValue: "About WillDeep")
        static let unknownValue = String(localized: "about.unknown-value", defaultValue: "Unknown")
        static func versionBadge(_ a1: String) -> String {
            let template = String(localized: "about.version-badge", defaultValue: "v%@")
            return String(format: template, a1)
        }
        static let versionDetails = String(localized: "about.version-details", defaultValue: "Version Details")
        static let versionLabel = String(localized: "about.version-label", defaultValue: "Version")
        static let website = String(localized: "about.website", defaultValue: "Website")
        static let windowTitle = String(localized: "about.window-title", defaultValue: "About WillDeep")
    }

    enum AppUpdate {
        static let checkForUpdates = String(localized: "app-update.check-for-updates", defaultValue: "Check for Updates…")
        static let download = String(localized: "app-update.download", defaultValue: "Download")
        static let downloadFailedTitle = String(localized: "app-update.download-failed-title", defaultValue: "Download Failed")
        static func downloadedMessage(_ a1: String) -> String {
            let template = String(localized: "app-update.downloaded-message", defaultValue: "%@ has been downloaded. Quit WillDeep and open the installer now?")
            return String(format: template, a1)
        }
        static func downloadedTitle(_ a1: String) -> String {
            let template = String(localized: "app-update.downloaded-title", defaultValue: "WillDeep %@ is ready")
            return String(format: template, a1)
        }
        static let later = String(localized: "app-update.later", defaultValue: "Later")
        static let quitAndInstall = String(localized: "app-update.quit-and-install", defaultValue: "Quit and Update")
        static let releaseNotes = String(localized: "app-update.release-notes", defaultValue: "Release Notes")
        static let sidebarAction = String(localized: "app-update.sidebar-action", defaultValue: "Update")
        static let sidebarActionHelp = String(localized: "app-update.sidebar-action-help", defaultValue: "Download the latest WillDeep release.")
        static let sidebarSubtitle = String(localized: "app-update.sidebar-subtitle", defaultValue: "A newer build is available.")
        static func sidebarTitle(_ a1: String) -> String {
            let template = String(localized: "app-update.sidebar-title", defaultValue: "Update %@")
            return String(format: template, a1)
        }
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

    /// some.im "省心托管" managed-routing composer entries.
    enum AgentManagedRouting {
        static let title = String(localized: "agent-managed-routing.title", defaultValue: "Managed")
        static let titleFlash = String(localized: "agent-managed-routing.title-flash", defaultValue: "Managed · Flash")
        static let titleHigh = String(localized: "agent-managed-routing.title-high", defaultValue: "Managed · Pro")
        static let titlePremium = String(localized: "agent-managed-routing.title-premium", defaultValue: "Managed · Premium")
        static let tierMenu = String(localized: "agent-managed-routing.tier-menu", defaultValue: "Managed tier")
        static let tierFlash = String(localized: "agent-managed-routing.tier-flash", defaultValue: "Flash")
        static let tierPro = String(localized: "agent-managed-routing.tier-pro", defaultValue: "Pro")
        static let tierPremium = String(localized: "agent-managed-routing.tier-premium", defaultValue: "Premium")
        static let footerPrefix = String(localized: "agent-managed-routing.footer-prefix", defaultValue: "Managed")
        static func generalFooter(_ level: String) -> String {
            let template = String(localized: "agent-managed-routing.footer-general", defaultValue: "Managed-General-%@")
            return String(format: template, level)
        }
        static func codingFooter(_ level: String) -> String {
            let template = String(localized: "agent-managed-routing.footer-coding", defaultValue: "Managed-Coding-%@")
            return String(format: template, level)
        }
    }

    enum AgentGeneratedImage {
        static let quoteAction = String(localized: "agent-generated-image.quote-action", defaultValue: "Quote Image")
        static let quoteHelp = String(localized: "agent-generated-image.quote-help", defaultValue: "Reference this generated image in your next reply without uploading it again.")
    }

    enum AgentTranscriptReader {
        static func loadEarlier(_ batch: Int, _ hidden: Int) -> String {
            let template = String(localized: "agent-transcript-reader.load-earlier", defaultValue: "Load %1$lld earlier messages (%2$lld not shown)")
            return String(format: template, batch, hidden)
        }
    }

    enum ComputerUsePreview {
        static let close = String(localized: "computer-use-preview.close", defaultValue: "Close Computer Use preview")
        static let open = String(localized: "computer-use-preview.open", defaultValue: "Open latest Computer Use screenshot")
        static let idle = String(localized: "computer-use-preview.state.idle", defaultValue: "Computer Use idle")
        static let observing = String(localized: "computer-use-preview.state.observing", defaultValue: "Observing")
        static let controlling = String(localized: "computer-use-preview.state.controlling", defaultValue: "Controlling")
        static let paused = String(localized: "computer-use-preview.state.paused", defaultValue: "Computer Use paused")
        static let userTakeover = String(localized: "computer-use-preview.state.user-takeover", defaultValue: "You are in control")
        static let stopping = String(localized: "computer-use-preview.state.stopping", defaultValue: "Stopping Computer Use")
        static let stoppingDetail = String(localized: "computer-use-preview.stopping-detail", defaultValue: "Finishing the current action and releasing control…")
        static let failed = String(localized: "computer-use-preview.state.failed", defaultValue: "Computer Use failed")
        static let unknownTarget = String(localized: "computer-use-preview.unknown-target", defaultValue: "Unknown application")
        static let pause = String(localized: "computer-use-preview.action.pause", defaultValue: "Pause")
        static let takeOver = String(localized: "computer-use-preview.action.take-over", defaultValue: "I'll take over")
        static let resume = String(localized: "computer-use-preview.action.resume", defaultValue: "Resume")
        static let stop = String(localized: "computer-use-preview.action.stop", defaultValue: "Stop")
        static let statusAccessibility = String(localized: "computer-use-preview.status-accessibility", defaultValue: "Computer Use control status")

        static func owningTask(_ title: String) -> String {
            let template = String(localized: "computer-use-preview.owning-task", defaultValue: "Task: %@")
            return String(format: template, title)
        }
    }

    enum AgentSelection {
        static let addToConversation = String(localized: "agent-selection.add-to-conversation", defaultValue: "Add to Conversation")
        static let addToTask = String(localized: "agent-selection.add-to-task", defaultValue: "Add to Task")
        static let askInSidebar = String(localized: "agent-selection.ask-in-sidebar", defaultValue: "Ask in Side Agent")
        static let askPrompt = String(localized: "agent-selection.ask-prompt", defaultValue: "Ask about the attached selection: ")
        static let chatExcerptFilename = String(localized: "agent-selection.chat-excerpt-filename", defaultValue: "Chat excerpt.txt")
        static let filenamePrefix = String(localized: "agent-selection.filename-prefix", defaultValue: "Selection")
        static let selectionAttachedHint = String(localized: "agent-selection.selection-attached-hint", defaultValue: "Selection attached · Tools available")
        static let untitledFile = String(localized: "agent-selection.untitled-file", defaultValue: "Untitled")
    }

    enum InteractionMode {
        // 顶层只区分普通对话和持续验收的 Goal；计划属于任务进度。
        static let normal = String(localized: "interaction-mode.normal", defaultValue: "Normal")
        static let goal = String(localized: "interaction-mode.goal", defaultValue: "Goal")
        static let help = String(
            localized: "interaction-mode.help",
            defaultValue: "Conversation mode — Ordinary plans and executes as needed; Goal repeatedly checks a persistent objective."
        )
    }

    enum ApprovalMode {
        static let pickerHelp = String(localized: "approval-mode.picker-help", defaultValue: "Choose how this session approves Agent tool calls.")
        static let requestEveryTime = String(localized: "approval-mode.request-every-time", defaultValue: "Strict mode")
        static let requestEveryTimeSummary = String(localized: "approval-mode.request-every-time.summary", defaultValue: "Ask before every write or external action.")
        static let smart = String(localized: "approval-mode.smart", defaultValue: "Smart review")
        static let smartSummary = String(localized: "approval-mode.smart.summary", defaultValue: "Auto-write in the workspace; intelligently review external actions.")
        static let workspaceAccess = String(localized: "approval-mode.workspace-access", defaultValue: "Workspace write")
        static let workspaceAccessSummary = String(localized: "approval-mode.workspace-access.summary", defaultValue: "Allow workspace writes; ask before external actions.")
    }

    enum Expert {
        static let pickerHelp = String(localized: "expert.picker-help", defaultValue: "Activate skill packs for this session.")
        static let pickerLabel = String(localized: "expert.picker-label", defaultValue: "Skill Packs")
        static func pickerLabelActive(_ a1: String) -> String {
            let template = String(localized: "expert.picker-label.active", defaultValue: "Skill Packs %@")
            return String(format: template, a1)
        }
        static let lockedNotice = String(localized: "expert.locked-notice", defaultValue: "After a skill pack joins the conversation, it cannot be turned off for this session.")
        static let shortDrama = String(localized: "expert.short-drama", defaultValue: "Short Drama")
        static let shortDramaSummary = String(localized: "expert.short-drama.summary", defaultValue: "Enable short-drama planning, storyboard, media task, and production-package tools.")
        static let browserOps = String(localized: "expert.browser-ops", defaultValue: "Browser Ops")
        static let browserOpsSummary = String(localized: "expert.browser-ops.summary", defaultValue: "Enable the side-panel browser plus screenshot, click, fill, and Chrome tab tools.")
        static let webCoding = String(localized: "expert.web-coding", defaultValue: "Web Programming")
        static let webCodingSummary = String(localized: "expert.web-coding.summary", defaultValue: "Enable screenshot-to-UI, local HTML/CSS/image previews, browser QA, and dev-server orchestration.")
    }

    enum Roundtable {
        static let windowTitle = String(localized: "roundtable.window-title", defaultValue: "Expert Roundtable")
        static let sidebarEntry = String(localized: "roundtable.sidebar-entry", defaultValue: "Expert Roundtable")
        static let homeTagline = String(localized: "roundtable.home-tagline", defaultValue: "Pose a question and let experts from different fields discuss it, then converge into a document.")
        static let topicPlaceholder = String(localized: "roundtable.topic-placeholder", defaultValue: "What do you want to discuss?")
        static let startAction = String(localized: "roundtable.start", defaultValue: "Start discussion")
        static let recommendHint = String(localized: "roundtable.recommend-hint", defaultValue: "Experts are recommended after you enter a topic")
        static let historyTitle = String(localized: "roundtable.history", defaultValue: "Past discussions")
        static let emptyHistory = String(localized: "roundtable.empty-history", defaultValue: "No discussions yet. Start your first one above.")
        static let statusConverged = String(localized: "roundtable.status.converged", defaultValue: "Converged")
        static let statusRunning = String(localized: "roundtable.status.running", defaultValue: "In progress")
        static let statusFailed = String(localized: "roundtable.status.failed", defaultValue: "Failed")
        static let hostPlaceholder = String(localized: "roundtable.host-placeholder", defaultValue: "Chime in as host, or ask a follow-up…")
        static let sendAction = String(localized: "roundtable.send", defaultValue: "Send")
        static let dashboardTitle = String(localized: "roundtable.dashboard", defaultValue: "Board")
        static let stanceSpectrum = String(localized: "roundtable.stance-spectrum", defaultValue: "Stance spectrum")
        static let exportAction = String(localized: "roundtable.export", defaultValue: "Export")
        static let documentSavedAction = String(localized: "roundtable.document-saved-action", defaultValue: "Saved")
        static let documentSaveRetry = String(localized: "roundtable.document-save-retry", defaultValue: "Retry")
        static func documentSaveFailed(_ a1: String) -> String {
            let template = String(localized: "roundtable.document-save-failed-format", defaultValue: "Couldn’t save the Markdown file automatically: %@")
            return String(format: template, a1)
        }
        static let backAction = String(localized: "roundtable.back", defaultValue: "Back")
        static let newDiscussion = String(localized: "roundtable.new", defaultValue: "New discussion")
        static let convergedHint = String(localized: "roundtable.converged-hint", defaultValue: "The discussion has converged")
        static let roundLabelFormat = String(localized: "roundtable.round-format", defaultValue: "Round %d")
        static let detachAction = String(localized: "roundtable.detach", defaultValue: "Open in new window")
        static let statusAwaiting = String(localized: "roundtable.status.awaiting", defaultValue: "Awaiting you")
        static let awaitingBanner = String(localized: "roundtable.awaiting-banner", defaultValue: "An expert is waiting for your input")
        static let answerPlaceholder = String(localized: "roundtable.answer-placeholder", defaultValue: "Type your answer, or pick an option above…")
        static let viewDocumentAction = String(localized: "roundtable.view-document", defaultValue: "View document")
        static let failedNote = String(localized: "roundtable.failed-note", defaultValue: "This discussion ended with an error.")
        static let cancelledNote = String(localized: "roundtable.cancelled-note", defaultValue: "This discussion was cancelled.")
        static let examplesTitle = String(localized: "roundtable.examples-title", defaultValue: "Try one of these")
        static let example1 = String(localized: "roundtable.example-1", defaultValue: "Should I quit my job to become an indie developer?")
        static let example2 = String(localized: "roundtable.example-2", defaultValue: "Should my product use freemium or one-time pricing?")
        static let example3 = String(localized: "roundtable.example-3", defaultValue: "Is switching to AI engineering at 35 realistic?")
        static let example4 = String(localized: "roundtable.example-4", defaultValue: "Should I keep renting or buy a home now?")
        static let submitShortcutHint = String(localized: "roundtable.submit-shortcut", defaultValue: "Return to send · Shift+Return for a new line")
        static let expertWillSpeakFormat = String(localized: "roundtable.expert-will-speak-format", defaultValue: "%@ is preparing to speak")
        static let expertThinkingDetail = String(localized: "roundtable.expert-thinking-detail", defaultValue: "Reviewing the discussion and organizing a point of view…")
        static let quoteMessage = String(localized: "roundtable.quote-message", defaultValue: "Quote this response")
        static let quoteSelection = String(localized: "roundtable.quote-selection", defaultValue: "Quote selected text")
        static let selectionQuoteHint = String(localized: "roundtable.selection-quote-hint", defaultValue: "Select text to quote it in your response")
        static let quotingFormat = String(localized: "roundtable.quoting-format", defaultValue: "Replying to %@")
        static let cancelQuote = String(localized: "roundtable.cancel-quote", defaultValue: "Remove quote")
        static let expertPanel = String(localized: "roundtable.expert-panel", defaultValue: "Expert panel")
        static let liveSignals = String(localized: "roundtable.live-signals", defaultValue: "Live signals")
        static let waitingForStances = String(localized: "roundtable.waiting-for-stances", defaultValue: "Stances will appear after the first expert speaks")
        static let thinking = String(localized: "roundtable.thinking", defaultValue: "Thinking")
        static let waiting = String(localized: "roundtable.waiting", defaultValue: "Waiting")
        static let phaseRecommending = String(localized: "roundtable.phase.recommending", defaultValue: "Assembling the panel")
        static let phaseOpening = String(localized: "roundtable.phase.opening", defaultValue: "Framing the question")
        static let phaseDiscussing = String(localized: "roundtable.phase.discussing", defaultValue: "Discussion in progress")
        static let phaseAwaiting = String(localized: "roundtable.phase.awaiting", defaultValue: "Waiting for your reply")
        static let phaseSynthesizing = String(localized: "roundtable.phase.synthesizing", defaultValue: "Synthesizing the conclusion")
        static let progressFormat = String(localized: "roundtable.progress-format", defaultValue: "%d / %d")

        /// 主页展示的示例议题(点一下填进输入框)。
        static let exampleTopics: [String] = [example1, example2, example3, example4]
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
        static let atPickerNoMatches = String(localized: "composer.at-picker.no-matches", defaultValue: "No matching files or workspace shortcuts")
        static let atPickerSearchPlaceholder = String(localized: "composer.at-picker.search-placeholder", defaultValue: "Search files or workspace...")
        static let addSecretAction = String(localized: "composer.add-secret.action", defaultValue: "Add another secret")
        static let addSecretHelp = String(localized: "composer.add-secret.help", defaultValue: "Add another protected secret, up to three total")
        static let attachFileHelp = String(localized: "composer.attach-file.help", defaultValue: "Attach images or documents")
        static let attachFilePanelTitle = String(localized: "composer.attach-file.panel-title", defaultValue: "Attach Files or Knowledge Folders")
        static let attachUnknownFile = String(localized: "composer.attach-file.unknown.confirm", defaultValue: "Attach as Text")
        static let cancelUnknownFile = String(localized: "composer.attach-file.unknown.cancel", defaultValue: "Cancel")
        static let dismissAttachmentNotice = String(localized: "composer.attach-file.notice.dismiss", defaultValue: "Dismiss attachment notice")
        static let attachmentInjectionWarning = String(localized: "composer.attachment.injection-warning", defaultValue: "Suspicious instructions detected")
        static let attachmentOCRUsed = String(localized: "composer.attachment.ocr-used", defaultValue: "Local OCR used")
        static let attachmentParseFailed = String(localized: "composer.attachment.parse-failed", defaultValue: "Could not parse this attachment")
        static let attachmentParsing = String(localized: "composer.attachment.parsing", defaultValue: "Parsing locally…")
        static let attachmentPreviewHelp = String(localized: "composer.attachment.preview-help", defaultValue: "Preview parsed attachment")
        static let disableSessionDocument = String(localized: "composer.attachment.session-disable", defaultValue: "Exclude from future turns")
        static let documentModeAutomatic = String(localized: "composer.document-mode.automatic", defaultValue: "Auto document task")
        static let documentModeCodeReview = String(localized: "composer.document-mode.code-review", defaultValue: "Code review")
        static let documentModeCompare = String(localized: "composer.document-mode.compare", defaultValue: "Compare documents")
        static let documentModeEvidence = String(localized: "composer.document-mode.evidence", defaultValue: "Extract evidence")
        static let documentModeSpreadsheet = String(localized: "composer.document-mode.spreadsheet", defaultValue: "Analyze spreadsheet")
        static let documentModeSummarize = String(localized: "composer.document-mode.summarize", defaultValue: "Summarize documents")
        static let documentRedactSensitive = String(localized: "composer.document.redact-sensitive", defaultValue: "Redact sensitive data")
        static let documentSendPreview = String(localized: "composer.document.send-preview", defaultValue: "Send preview")
        static let documentSendPreviewClose = String(localized: "composer.document.send-preview-close", defaultValue: "Close send preview")
        static let documentSendPreviewTitle = String(localized: "composer.document.send-preview-title", defaultValue: "Document context sent to the model")
        static let designToCodeAction = String(localized: "composer.design-to-code.action", defaultValue: "Generate UI code")
        static let designToCodeActionDetail = String(localized: "composer.design-to-code.action-detail", defaultValue: "Build · run · visual acceptance")
        static let designToCodeHelp = String(localized: "composer.design-to-code.help", defaultValue: "Implement the attached UI in this workspace, then verify it with Browser or Computer Use")
        static let designToCodePrompt = String(localized: "composer.design-to-code.prompt", defaultValue: "Implement the attached UI completely in the current workspace using the existing project stack. Write the production code directly, build and run it, then use Browser or Computer Use to capture the real result and compare it with the source. Make at most three focused correction passes; then report any remaining material differences instead of looping.")
        static let enableSessionDocument = String(localized: "composer.attachment.session-enable", defaultValue: "Include in future turns")
        static let removeSessionDocument = String(localized: "composer.attachment.session-remove", defaultValue: "Remove from this conversation")
        static let removeAttachmentHelp = String(localized: "composer.attachment.remove-help", defaultValue: "Remove attachment")
        static let selectAllAttachmentSections = String(localized: "composer.attachment.select-all", defaultValue: "Select all")
        static let selectNoAttachmentSections = String(localized: "composer.attachment.select-none", defaultValue: "Select none")
        static let waitForAttachmentParsing = String(localized: "composer.attachment.wait-for-parsing", defaultValue: "Wait for local attachment parsing to finish")
        static func attachmentChunk(_ a1: Int) -> String {
            let template = String(localized: "composer.attachment.chunk", defaultValue: "Chunk %lld")
            return String(format: template, a1)
        }
        static func attachmentPage(_ a1: Int) -> String {
            let template = String(localized: "composer.attachment.page", defaultValue: "Page %lld")
            return String(format: template, a1)
        }
        static func attachmentReady(_ a1: Int, _ a2: Int) -> String {
            let template = String(localized: "composer.attachment.ready", defaultValue: "%lld sources · %lld characters extracted")
            return String(format: template, a1, a2)
        }
        static func attachmentSheet(_ a1: String) -> String {
            let template = String(localized: "composer.attachment.sheet", defaultValue: "Sheet: %@")
            return String(format: template, a1)
        }
        static func sessionDocuments(_ a1: Int) -> String {
            let template = String(localized: "composer.attachment.session-documents", defaultValue: "Conversation documents · %lld")
            return String(format: template, a1)
        }
        static func documentSensitiveFindings(_ a1: Int) -> String {
            let template = String(localized: "composer.document.sensitive-findings", defaultValue: "%lld sensitive values detected locally")
            return String(format: template, a1)
        }
        static func attachmentTooLarge(_ a1: String) -> String {
            let template = String(localized: "composer.attach-file.too-large", defaultValue: "%@ is larger than the 50 MB attachment limit.")
            return String(format: template, a1)
        }
        static func unsupportedAttachment(_ a1: String) -> String {
            let template = String(localized: "composer.attach-file.unsupported", defaultValue: "%@ is not a supported attachment type.")
            return String(format: template, a1)
        }
        static func unknownAttachmentConfirmationTitle(_ a1: String) -> String {
            let template = String(localized: "composer.attach-file.unknown.title", defaultValue: "Attach %@ as text?")
            return String(format: template, a1)
        }
        static func unknownAttachmentConfirmationMessage(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "composer.attach-file.unknown.message", defaultValue: "%@ has an unknown file type but is only %@. If you continue, WillDeep will decode and send it as plain text.")
            return String(format: template, a1, a2)
        }
        static func unknownAttachmentTooLarge(_ a1: String) -> String {
            let template = String(localized: "composer.attach-file.unknown.too-large", defaultValue: "%@ has an unknown file type and is larger than 8 KB, so it was not attached.")
            return String(format: template, a1)
        }
        static func unknownAttachmentUnreadable(_ a1: String) -> String {
            let template = String(localized: "composer.attach-file.unknown.unreadable", defaultValue: "%@ has an unknown file type and its size could not be read, so it was not attached.")
            return String(format: template, a1)
        }
        static let insertSecretAction = String(localized: "composer.insert-secret.action", defaultValue: "Insert")
        static let knowledgeFolderApplyExclusions = String(localized: "composer.knowledge-folder.apply-exclusions", defaultValue: "Apply")
        static let knowledgeFolderExclusionsHelp = String(localized: "composer.knowledge-folder.exclusions-help", defaultValue: "Comma-separated .gitignore-style patterns")
        static let knowledgeFolderExclusionsPlaceholder = String(localized: "composer.knowledge-folder.exclusions-placeholder", defaultValue: "Extra exclusions, e.g. drafts/**, *.log")
        static let knowledgeFolderFailed = String(localized: "composer.knowledge-folder.failed", defaultValue: "Could not index this folder")
        static let knowledgeFolderIndexing = String(localized: "composer.knowledge-folder.indexing", defaultValue: "Indexing local documents…")
        static let knowledgeFolderPending = String(localized: "composer.knowledge-folder.pending", defaultValue: "Not indexed yet. Start indexing when you want to use this folder.")
        static let knowledgeFolderReindex = String(localized: "composer.knowledge-folder.reindex", defaultValue: "Reindex")
        static let knowledgeFolderRetryIndexing = String(localized: "composer.knowledge-folder.retry-indexing", defaultValue: "Retry indexing")
        static let knowledgeFolderStartIndexing = String(localized: "composer.knowledge-folder.start-indexing", defaultValue: "Start indexing")
        static func knowledgeFolderReady(_ a1: Int, _ a2: Int) -> String {
            let template = String(localized: "composer.knowledge-folder.ready", defaultValue: "%lld documents ready · %lld skipped")
            return String(format: template, a1, a2)
        }
        static func knowledgeFolders(_ a1: Int) -> String {
            let template = String(localized: "composer.knowledge-folder.title", defaultValue: "Knowledge folders · %lld")
            return String(format: template, a1)
        }
        static let insertSecretDescription = String(localized: "composer.insert-secret.description", defaultValue: "Add up to three secrets. Each secret is saved locally in Keychain; the model only sees placeholders, and WillDeep resolves them when a local tool runs.")
        static let insertSecretHelp = String(localized: "composer.insert-secret.help", defaultValue: "Insert protected secret")
        static let insertSecretTitle = String(localized: "composer.insert-secret.title", defaultValue: "Insert Protected Secret")
        static let insertSecretUsage = String(localized: "composer.insert-secret.usage", defaultValue: "Use one row per password or token. After inserting, place the generated placeholders exactly where the command, header, or form field needs them.")
        static func legacySecretLabel(_ a1: String) -> String {
            let template = String(localized: "composer.secret.legacy-label", defaultValue: "Legacy secret · %@")
            return String(format: template, a1)
        }
        static let newSecretsTitle = String(localized: "composer.secret.new-title", defaultValue: "Add or update a secret")
        static let savedSecretInsertHelp = String(localized: "composer.secret.saved-insert-help", defaultValue: "Insert this protected secret at the cursor")
        static let savedSecretsEmpty = String(localized: "composer.secret.saved-empty", defaultValue: "No reusable secrets have been saved yet.")
        static let savedSecretsTitle = String(localized: "composer.secret.saved-title", defaultValue: "Saved secrets")
        static let secretAliasRule = String(localized: "composer.secret.alias-rule", defaultValue: "Aliases become lowercase kebab-case placeholders. Saving the same alias updates its local value.")
        static let inputPlaceholder = String(localized: "composer.input.placeholder", defaultValue: "Ask anything... / commands, @ files/workspace, $ skills & plugins")
        static let queueSendHelp = String(localized: "composer.queue-send.help", defaultValue: "Queue this message after the current turn")
        static let removeSecretHelp = String(localized: "composer.remove-secret.help", defaultValue: "Remove this secret row")
        static let secretLabelPlaceholder = String(localized: "composer.secret-label.placeholder", defaultValue: "Label, e.g. Production SSH password")
        static let secretValuePlaceholder = String(localized: "composer.secret-value.placeholder", defaultValue: "Secret value")
        static let sendHelp = String(localized: "composer.send.help", defaultValue: "Send")
        static let skillPickerNoMatches = String(localized: "composer.skill-picker.no-matches", defaultValue: "No matching skills")
        static let skillPickerSearchPlaceholder = String(localized: "composer.skill-picker.search-placeholder", defaultValue: "Search skills...")
        static let stopHelp = String(localized: "composer.stop.help", defaultValue: "Stop the current Agent turn")
        static let stopped = String(
            localized: "composer.stop.stopped",
            defaultValue: "The user stopped generation."
        )
        static func stoppedCheckingProcesses(_ count: Int) -> String {
            let template = String(
                localized: "composer.stop.checking-processes",
                defaultValue: "Stopped generating. Checking %lld process(es) started by this turn…"
            )
            return String(format: template, count)
        }
        static func stoppedAndCleanedUp(_ count: Int) -> String {
            let template = String(
                localized: "composer.stop.cleaned-up",
                defaultValue: "Stopped generating and stopped %lld related task(s) or process(es) from this turn."
            )
            return String(format: template, count)
        }
        static let stoppedProcessesKept = String(
            localized: "composer.stop.processes-kept",
            defaultValue: "Stopped generating. Current-turn processes were left running because they still need to continue."
        )
        static let stoppedProcessesFinished = String(
            localized: "composer.stop.processes-finished",
            defaultValue: "Stopped generating. Related current-turn processes had already finished."
        )
        static let overflowHelp = String(localized: "composer.overflow.help", defaultValue: "More settings: plugins and experts")
        static let overflowTitle = String(localized: "composer.overflow.title", defaultValue: "More settings")
        static let overflowWorkspace = String(localized: "composer.overflow.workspace", defaultValue: "Workspace")
        static let overflowExecutor = String(localized: "composer.overflow.executor", defaultValue: "Executor")
        static let overflowApproval = String(localized: "composer.overflow.approval", defaultValue: "Approval")
        static let overflowPlugins = String(localized: "composer.overflow.plugins", defaultValue: "Plugins")
    }

    enum AttachmentCitation {
        static let exportAction = String(localized: "attachment-citation.export-action", defaultValue: "Export…")
        static let exportFailed = String(localized: "attachment-citation.export-failed", defaultValue: "Could not export document citation")
        static let exportTitle = String(localized: "attachment-citation.export-title", defaultValue: "Export Document Citation")
        static let highlightedSource = String(localized: "attachment-citation.highlighted-source", defaultValue: "Referenced source")
        static let openOriginal = String(localized: "attachment-citation.open-original", defaultValue: "Open Original")
        static let showInFinder = String(localized: "attachment-citation.show-in-finder", defaultValue: "Show in Finder")
        static let windowTitle = String(localized: "attachment-citation.window-title", defaultValue: "Document Citation")
    }

    enum ComposerWorkspace {
        static let chooseFolder = String(localized: "composer.workspace.choose-folder", defaultValue: "Choose folder…")
        static let chooseWorkspaceHelp = String(localized: "composer.workspace.choose-workspace.help", defaultValue: "Choose a workspace for this chat")
        static let copyBranchName = String(localized: "composer.workspace.copy-branch-name", defaultValue: "Copy branch name")
        static let copyPath = String(localized: "composer.workspace.copy-path", defaultValue: "Copy path")
        static let gitWorktrees = String(localized: "composer.workspace.git-worktrees", defaultValue: "Git worktrees")
        static let localRun = String(localized: "composer.workspace.local-run", defaultValue: "Local")
        static let localRunHelp = String(localized: "composer.workspace.local-run.help", defaultValue: "Run this conversation in the primary local workspace")
        static let runLocation = String(localized: "composer.workspace.run-location", defaultValue: "Run location")
        static let newWorktreeRun = String(localized: "composer.workspace.new-worktree-run", defaultValue: "New worktree")
        static let newWorktreeRunHelp = String(localized: "composer.workspace.new-worktree-run.help", defaultValue: "Create an isolated Git worktree and move this conversation there")
        static let currentBranch = String(localized: "composer.workspace.current-branch", defaultValue: "Current branch")
        static let noBranch = String(localized: "composer.workspace.no-branch", defaultValue: "No branch")
        static let newWorktree = String(localized: "composer.workspace.new-worktree", defaultValue: "New worktree…")
        static let pickFolder = String(localized: "composer.workspace.pick-folder", defaultValue: "Pick folder")
        static let pruneStaleWorktrees = String(localized: "composer.workspace.prune-stale-worktrees", defaultValue: "Prune stale worktrees")
        static let remoteRuntimes = String(localized: "composer.workspace.remote-runtimes", defaultValue: "Remote runtimes")
        static let removeCurrentWorktree = String(localized: "composer.workspace.remove-current-worktree", defaultValue: "Remove current worktree…")
        static let showInFinder = String(localized: "composer.workspace.show-in-finder", defaultValue: "Show in Finder")
        static let switchWorkspace = String(localized: "composer.workspace.switch-workspace", defaultValue: "Switch workspace")
    }

    enum GitWorktreeCreation {
        static let title = String(localized: "git-worktree.creation.title", defaultValue: "Creating worktree")
        static let cancel = String(localized: "git-worktree.creation.cancel", defaultValue: "Cancel")
        static let cancelling = String(localized: "git-worktree.creation.cancelling", defaultValue: "Cancelling…")
        static func starting(_ branchName: String) -> String {
            String(
                format: String(localized: "git-worktree.creation.starting", defaultValue: "[info] Creating branch %@"),
                branchName
            )
        }
        static func failed(_ details: String) -> String {
            String(
                format: String(localized: "git-worktree.creation.failed", defaultValue: "Could not create Git worktree: %@"),
                details
            )
        }
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
        static let diagnosticsHelp = String(localized: "editor-status-bar.diagnostics.help", defaultValue: "Jump to first language diagnostic")
        static let externalChanges = String(localized: "editor-status-bar.external-changes", defaultValue: "External changes")
        static func gitBranch(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.git-branch", defaultValue: "Git")
            return String(format: template, a1)
        }
        static let modified = String(localized: "editor-status-bar.modified", defaultValue: "Modified")
        static let plainText = String(localized: "editor-status-bar.plain-text", defaultValue: "Plain Text")
        static let reloadButton = String(localized: "editor-status-bar.reload-button", defaultValue: "Reload")
        static let saved = String(localized: "editor-status-bar.saved", defaultValue: "Saved")
        static let toggleTerminalHelp = String(localized: "editor-status-bar.toggle-terminal.help", defaultValue: "Show or hide the editor terminal")
        static func selection(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.selection", defaultValue: "chars")
            return String(format: template, a1)
        }
        static func selectionLines(_ a1: String) -> String {
            let template = String(localized: "editor-status-bar.selection.lines", defaultValue: "lines selected")
            return String(format: template, a1)
        }
    }

    enum EditorContextMenu {
        static let goToDefinition = String(localized: "editor-context-menu.go-to-definition", defaultValue: "Go to Definition")
        static let goToDeclaration = String(localized: "editor-context-menu.go-to-declaration", defaultValue: "Go to Declaration")
        static let goToTypeDefinition = String(localized: "editor-context-menu.go-to-type-definition", defaultValue: "Go to Type Definition")
        static let goToImplementation = String(localized: "editor-context-menu.go-to-implementation", defaultValue: "Go to Implementation")
        static let findReferences = String(localized: "editor-context-menu.find-references", defaultValue: "Find References")
        static let showCallHierarchy = String(localized: "editor-context-menu.show-call-hierarchy", defaultValue: "Show Call Hierarchy")
        static let renameSymbol = String(localized: "editor-context-menu.rename-symbol", defaultValue: "Rename Symbol…")
        static let formatDocument = String(localized: "editor-context-menu.format-document", defaultValue: "Format Document")
        static let formatSelection = String(localized: "editor-context-menu.format-selection", defaultValue: "Format Selection")
        static let showHoverInfo = String(localized: "editor-context-menu.show-hover-info", defaultValue: "Show Hover Info")
        static let showCompletions = String(localized: "editor-context-menu.show-completions", defaultValue: "Show Completions")
        static let showSignatureHelp = String(localized: "editor-context-menu.show-signature-help", defaultValue: "Show Signature Help")
        static let showCodeActions = String(localized: "editor-context-menu.show-code-actions", defaultValue: "Show Code Actions")
        static let expandSelection = String(localized: "editor-context-menu.expand-selection", defaultValue: "Expand Selection")
    }

    enum EditorSelectionRange {
        static let noRange = String(localized: "editor-selection-range.no-range", defaultValue: "The language server did not return a larger semantic selection.")
        static let unavailable = String(localized: "editor-selection-range.unavailable", defaultValue: "Language server selection range is unavailable.")
        static func failed(_ reason: String) -> String {
            let template = String(localized: "editor-selection-range.failed", defaultValue: "Could not expand selection: %@")
            return String(format: template, reason)
        }
    }

    enum EditorRename {
        static let title = String(localized: "editor-rename.title", defaultValue: "Rename Symbol")
        static func message(_ symbol: String) -> String {
            let template = String(localized: "editor-rename.message", defaultValue: "Enter a new name for “%@”.")
            return String(format: template, symbol)
        }
        static let confirm = String(localized: "editor-rename.confirm", defaultValue: "Rename")
        static let cancel = String(localized: "editor-rename.cancel", defaultValue: "Cancel")
        static let emptyName = String(localized: "editor-rename.empty-name", defaultValue: "Enter a non-empty symbol name.")
        static let noChanges = String(localized: "editor-rename.no-changes", defaultValue: "The language server did not return any rename edits.")
        static let notRenameable = String(localized: "editor-rename.not-renameable", defaultValue: "The language server says this symbol cannot be renamed.")
        static let unavailable = String(localized: "editor-rename.unavailable", defaultValue: "Language server rename is unavailable.")
        static func unsafeFile(_ path: String) -> String {
            let template = String(localized: "editor-rename.unsafe-file", defaultValue: "Rename returned edits outside the current workspace: %@")
            return String(format: template, path)
        }
        static func failed(_ reason: String) -> String {
            let template = String(localized: "editor-rename.failed", defaultValue: "Could not rename symbol: %@")
            return String(format: template, reason)
        }
        static func unsavedFile(_ path: String) -> String {
            let template = String(localized: "editor-rename.unsaved-file", defaultValue: "Save or close the unsaved tab before renaming: %@")
            return String(format: template, path)
        }
    }

    enum EditorHover {
        static let close = String(localized: "editor-hover.close", defaultValue: "Close hover info")
        static let loading = String(localized: "editor-hover.loading", defaultValue: "Loading...")
        static let noInformation = String(localized: "editor-hover.no-information", defaultValue: "No hover information available.")
        static let unavailable = String(localized: "editor-hover.unavailable", defaultValue: "Language server hover information is unavailable.")
    }

    enum EditorCompletion {
        static let title = String(localized: "editor-completion.title", defaultValue: "Completions")
        static let close = String(localized: "editor-completion.close", defaultValue: "Close completions")
        static let loading = String(localized: "editor-completion.loading", defaultValue: "Loading completions...")
        static let noItems = String(localized: "editor-completion.no-items", defaultValue: "No completions available.")
        static let unavailable = String(localized: "editor-completion.unavailable", defaultValue: "Language server completions are unavailable.")
    }

    enum EditorSignatureHelp {
        static let title = String(localized: "editor-signature-help.title", defaultValue: "Signature Help")
        static let close = String(localized: "editor-signature-help.close", defaultValue: "Close signature help")
        static let loading = String(localized: "editor-signature-help.loading", defaultValue: "Loading signature help...")
        static let noItems = String(localized: "editor-signature-help.no-items", defaultValue: "No signature help available.")
        static let unavailable = String(localized: "editor-signature-help.unavailable", defaultValue: "Language server signature help is unavailable.")
    }

    enum EditorCodeAction {
        static let title = String(localized: "editor-code-action.title", defaultValue: "Code Actions")
        static let close = String(localized: "editor-code-action.close", defaultValue: "Close code actions")
        static let loading = String(localized: "editor-code-action.loading", defaultValue: "Loading code actions...")
        static let noItems = String(localized: "editor-code-action.no-items", defaultValue: "No code actions available.")
        static let noChanges = String(localized: "editor-code-action.no-changes", defaultValue: "The language server did not return any code action edits.")
        static let preferred = String(localized: "editor-code-action.preferred", defaultValue: "Preferred")
        static let unavailable = String(localized: "editor-code-action.unavailable", defaultValue: "Language server code actions are unavailable.")
        static let unsupportedCommand = String(localized: "editor-code-action.unsupported-command", defaultValue: "This code action only returned a command, which is not supported yet.")
        static func unsafeFile(_ path: String) -> String {
            let template = String(localized: "editor-code-action.unsafe-file", defaultValue: "Code action returned edits outside the current workspace: %@")
            return String(format: template, path)
        }
        static func failed(_ reason: String) -> String {
            let template = String(localized: "editor-code-action.failed", defaultValue: "Could not apply code action: %@")
            return String(format: template, reason)
        }
        static func unsavedFile(_ path: String) -> String {
            let template = String(localized: "editor-code-action.unsaved-file", defaultValue: "Save or close the unsaved tab before applying this code action: %@")
            return String(format: template, path)
        }
    }

    enum EditorReferences {
        static let title = String(localized: "editor-references.title", defaultValue: "References")
        static let close = String(localized: "editor-references.close", defaultValue: "Close references")
        static let loading = String(localized: "editor-references.loading", defaultValue: "Loading references...")
        static let noItems = String(localized: "editor-references.no-items", defaultValue: "No references found.")
        static let unavailable = String(localized: "editor-references.unavailable", defaultValue: "Language server references are unavailable.")
    }

    enum EditorCallHierarchy {
        static let title = String(localized: "editor-call-hierarchy.title", defaultValue: "Call Hierarchy")
        static let close = String(localized: "editor-call-hierarchy.close", defaultValue: "Close call hierarchy")
        static let loading = String(localized: "editor-call-hierarchy.loading", defaultValue: "Loading call hierarchy...")
        static let noItems = String(localized: "editor-call-hierarchy.no-items", defaultValue: "No calls found.")
        static let unavailable = String(localized: "editor-call-hierarchy.unavailable", defaultValue: "Language server call hierarchy is unavailable.")
        static let incoming = String(localized: "editor-call-hierarchy.incoming", defaultValue: "Incoming")
        static let outgoing = String(localized: "editor-call-hierarchy.outgoing", defaultValue: "Outgoing")
        static let emptySection = String(localized: "editor-call-hierarchy.empty-section", defaultValue: "No items in this direction.")
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

    enum EditorTerminal {
        static let blinkCursor = String(localized: "editor-terminal.blink-cursor", defaultValue: "Blink cursor")
        static let clearHelp = String(localized: "editor-terminal.clear-help", defaultValue: "Clear")
        static let closeHelp = String(localized: "editor-terminal.close-help", defaultValue: "Close")
        static let colorScheme = String(localized: "editor-terminal.color-scheme", defaultValue: "Color scheme")
        static let colorSchemeFootnote = String(localized: "editor-terminal.color-scheme-footnote", defaultValue: "“Follow App Skin” uses the terminal palette matched to your interface skin; ANSI program colors stay standard so output stays readable. Line spacing isn't adjustable with the current terminal engine.")
        static let cursor = String(localized: "editor-terminal.cursor", defaultValue: "Cursor")
        static let customFont = String(localized: "editor-terminal.custom-font", defaultValue: "Custom font")
        static let customFontFootnote = String(localized: "editor-terminal.custom-font-footnote", defaultValue: "Type the exact name of any installed font to override the picker — use this to apply a Nerd Font that isn't auto-detected so powerline/icon glyphs stop showing as boxes. Leave empty to use the selection above.")
        static let customFontPlaceholder = String(localized: "editor-terminal.custom-font-placeholder", defaultValue: "e.g. JetBrainsMono Nerd Font")
        static let environmentFootnote = String(localized: "editor-terminal.environment-footnote", defaultValue: "One KEY=value per line. Values are shared by the editor terminal and local Agent commands; $VAR references expand in order.")
        static let environmentSection = String(localized: "editor-terminal.environment-section", defaultValue: "Environment")
        static let followAppSkin = String(localized: "editor-terminal.follow-app-skin", defaultValue: "Follow App Skin")
        static let font = String(localized: "editor-terminal.font", defaultValue: "Font")
        static func fontSizePoints(_ a1: String) -> String {
            let template = String(localized: "editor-terminal.font-size-points", defaultValue: "%@ pt")
            return String(format: template, a1)
        }
        static let noProjectCommands = String(localized: "editor-terminal.no-project-commands", defaultValue: "No project commands found")
        static let run = String(localized: "editor-terminal.run", defaultValue: "Run")
        static let settingsHelp = String(localized: "editor-terminal.settings-help", defaultValue: "Terminal Settings")
        static let settingsSection = String(localized: "editor-terminal.settings-section", defaultValue: "Terminal")
        static let shell = String(localized: "editor-terminal.shell", defaultValue: "Shell")
        static let size = String(localized: "editor-terminal.size", defaultValue: "Size")
        static let startShellHelp = String(localized: "editor-terminal.start-shell-help", defaultValue: "Start Shell")
        static let title = String(localized: "editor-terminal.title", defaultValue: "Terminal")
        static let workingDirectoryPlaceholder = String(localized: "editor-terminal.working-directory-placeholder", defaultValue: "working directory")
    }

    enum EmptyState {
        static func hero(_ a1: String) -> String {
            let template = String(localized: "empty-state.hero", defaultValue: "What's up next")
            return String(format: template, a1)
        }
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
        static let pinnedPrefix = String(localized: "goal-status-bar.pinned-prefix", defaultValue: "Goal pinned")
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

    enum ContextRing {
        /// %1 conversation tokens used · %2 usable window · %3 reserved for
        /// system+tools · %4 total remaining.
        static func tooltip(_ a1: String, _ a2: String, _ a3: String, _ a4: String) -> String {
            let template = String(
                localized: "context-ring.tooltip",
                defaultValue: "Conversation: ~%1$@ / %2$@ usable · %3$@ reserved for system + tools · %4$@ total remaining (estimate)."
            )
            return String(format: template, a1, a2, a3, a4)
        }
    }

    enum SessionSearch {
        static let placeholder = String(localized: "session-search.placeholder", defaultValue: "Search chats by title…")
        static let empty = String(localized: "session-search.empty", defaultValue: "No matching chats")
        static let prompt = String(localized: "session-search.prompt", defaultValue: "Type to search your chats")
        static func resultCount(_ a1: String) -> String {
            let template = String(localized: "session-search.result-count", defaultValue: "%@ results")
            return String(format: template, a1)
        }
        static let close = String(localized: "session-search.close", defaultValue: "Close")
    }

    enum Workspace {
        static let noWorkspace = String(localized: "workspace.no-workspace", defaultValue: "No workspace")
    }

    enum AgentPatch {
        static let apply = String(localized: "agent-patch.apply", defaultValue: "Apply")
        static let reject = String(localized: "agent-patch.reject", defaultValue: "Reject")
        static let showDiff = String(localized: "agent-patch.show-diff", defaultValue: "Show Diff")
        static let hideDiff = String(localized: "agent-patch.hide-diff", defaultValue: "Hide Diff")
        static let applyAll = String(localized: "agent-patch.apply-all", defaultValue: "Apply All")
        static let rejectAll = String(localized: "agent-patch.reject-all", defaultValue: "Reject All")
        static let showAll = String(localized: "agent-patch.show-all", defaultValue: "Show All")
        static let hideAll = String(localized: "agent-patch.hide-all", defaultValue: "Collapse")

        /// Title of the transcript-level bar that batches every still-pending
        /// proposal across multiple independent cards — e.g. "5 changes
        /// awaiting review".
        static func allPendingTitle(_ count: Int) -> String {
            String(format: String(localized: "agent-patch.all-pending-title",
                                   defaultValue: "%d changes awaiting review"), count)
        }

        /// Title of a collapsed group bundling several patch proposals from
        /// the same turn — e.g. "3 patch proposals this turn".
        static func groupTitle(_ count: Int) -> String {
            let template = String(localized: "agent-patch.group-title",
                                  defaultValue: "%d patch proposals this turn")
            return String(format: template, count)
        }

        static func countApplied(_ n: Int) -> String {
            String(format: String(localized: "agent-patch.count-applied", defaultValue: "%d applied"), n)
        }
        static func countPending(_ n: Int) -> String {
            String(format: String(localized: "agent-patch.count-pending", defaultValue: "%d pending"), n)
        }
        static func countRejected(_ n: Int) -> String {
            String(format: String(localized: "agent-patch.count-rejected", defaultValue: "%d rejected"), n)
        }
        static func countFailed(_ n: Int) -> String {
            String(format: String(localized: "agent-patch.count-failed", defaultValue: "%d failed"), n)
        }

        /// Status shown when applying a card is a no-op because the file is
        /// already in the patch's target state (the change landed earlier).
        static let alreadyApplied = String(
            localized: "agent-patch.already-applied",
            defaultValue: "Change already present — nothing to apply"
        )
    }

    enum AgentPatchError {
        static let emptyDiff = String(localized: "agent-patch-error.empty-diff", defaultValue: "The diff is empty.")
        static let unsupportedDiff = String(localized: "agent-patch-error.unsupported-diff", defaultValue: "The diff format is not supported yet. Use a unified diff for existing files.")
        static let noWorkspace = String(localized: "agent-patch-error.no-workspace", defaultValue: "Open a project folder before applying an agent patch.")
        static func pathOutsideWorkspace(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.path-outside-workspace", defaultValue: "The patch path is outside the workspace: %@")
            return String(format: template, a1)
        }
        static func missingFile(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.missing-file", defaultValue: "The patch target file does not exist: %@")
            return String(format: template, a1)
        }
        static func hunkDidNotMatch(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.hunk-did-not-match", defaultValue: "A patch hunk did not match the current file content: %@")
            return String(format: template, a1)
        }
        static func targetAlreadyExists(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.target-already-exists", defaultValue: "Cannot create %@ — it already exists. Use a modify diff instead.")
            return String(format: template, a1)
        }
        static func duplicateTarget(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.duplicate-target", defaultValue: "The same file appears more than once in this patch batch: %@")
            return String(format: template, a1)
        }
        static func writeVerificationFailed(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.write-verification-failed", defaultValue: "The patch reported a write for %@, but the file could not be verified on disk.")
            return String(format: template, a1)
        }
        static func rollbackFailed(_ a1: String) -> String {
            let template = String(localized: "agent-patch-error.rollback-failed", defaultValue: "Applying the patch failed, and WillDeep could not fully restore: %@")
            return String(format: template, a1)
        }
    }

    enum AgentSidePanel {
        static let preview = String(localized: "agent-side-panel.preview", defaultValue: "Preview")
        static let diff = String(localized: "agent-side-panel.diff", defaultValue: "Review")
        static let files = String(localized: "agent-side-panel.files", defaultValue: "Files")
        static let terminal = String(localized: "agent-side-panel.terminal", defaultValue: "Terminal")
        static let backgroundTasks = String(localized: "agent-side-panel.background-tasks", defaultValue: "Background tasks")
        static let embeddedBrowser = String(localized: "agent-side-panel.embedded-browser", defaultValue: "Browser")
        static let plan = String(localized: "agent-side-panel.plan", defaultValue: "Plan")
        static let close = String(localized: "agent-side-panel.close", defaultValue: "Close Panel")
        static let detach = String(localized: "agent-side-panel.detach", defaultValue: "Open as Separate Window")
        static let reattach = String(localized: "agent-side-panel.reattach", defaultValue: "Move Back to Sidebar")
        static let comingSoon = String(localized: "agent-side-panel.coming-soon", defaultValue: "Coming soon")
        static let refresh = String(localized: "agent-side-panel.refresh", defaultValue: "Refresh")
        static let noWorkspace = String(localized: "agent-side-panel.no-workspace", defaultValue: "No workspace selected for this session.")
        static let noWorkspaceDetail = String(localized: "agent-side-panel.no-workspace-detail", defaultValue: "Choose a folder to browse files and review changes. Chat, Terminal, Browser, and Preview work without one.")
        static let chooseWorkspace = String(localized: "agent-side-panel.choose-workspace", defaultValue: "Choose Workspace")
        static let diffLoading = String(localized: "agent-side-panel.diff-loading", defaultValue: "Computing diff…")
        static let diffEmpty = String(localized: "agent-side-panel.diff-empty", defaultValue: "No uncommitted changes.")
        static let diffNotRepo = String(localized: "agent-side-panel.diff-not-repo", defaultValue: "Not a git repository.")
        static let diffBackToFiles = String(localized: "agent-side-panel.diff-back-to-files", defaultValue: "Back to changed files")
        static let diffFileUnavailable = String(localized: "agent-side-panel.diff-file-unavailable", defaultValue: "No diff preview is available for this file.")
        static func diffSourceFileTooLarge(_ a1: String, _ a2: String) -> String {
            let template = String(
                localized: "agent-side-panel.diff-source-file-too-large",
                defaultValue: "This file is %@ bytes, above the side-panel file limit of %@ bytes, so its diff is not generated here. Open it in an editor or use an external Git tool to review it."
            )
            return String(format: template, a1, a2)
        }
        static func diffFilesSummary(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "agent-side-panel.diff-files-summary", defaultValue: "%@ files · +%@ -%@")
            return String(format: template, a1, a2, a3)
        }
        static func diffSummary(_ a1: String) -> String {
            let template = String(localized: "agent-side-panel.diff-summary", defaultValue: "Diff against HEAD · %@")
            return String(format: template, a1)
        }
        static func diffTooLarge(
            _ a1: String,
            _ a2: String,
            _ a3: String,
            _ a4: String
        ) -> String {
            let template = String(
                localized: "agent-side-panel.diff-too-large",
                defaultValue: "Diff is %@ UTF-8 bytes / %@ lines, above the side-panel budget of %@ bytes / %@ lines, so it is not displayed here. Open the file in an editor or use git diff --no-ext-diff HEAD -- <path> to review it."
            )
            return String(format: template, a1, a2, a3, a4)
        }
        static let planMissing = String(localized: "agent-side-panel.plan-missing", defaultValue: "No active plan.")
        static let previewEmpty = String(localized: "agent-side-panel.preview-empty", defaultValue: "Pick a markdown or HTML file to preview.")
        static let previewChoose = String(localized: "agent-side-panel.preview-choose", defaultValue: "Choose File…")
        static let previewUnsupported = String(localized: "agent-side-panel.preview-unsupported", defaultValue: "Only Markdown and HTML can be previewed here.")
    }

    enum AgentEmbeddedBrowser {
        static let addressPlaceholder = String(localized: "agent-embedded-browser.address-placeholder", defaultValue: "URL or domain")
        static let back = String(localized: "agent-embedded-browser.back", defaultValue: "Back")
        static let capture = String(localized: "agent-embedded-browser.capture", defaultValue: "Capture Screenshot")
        static let forward = String(localized: "agent-embedded-browser.forward", defaultValue: "Forward")
        static let go = String(localized: "agent-embedded-browser.go", defaultValue: "Go")
        static func lastScreenshot(_ a1: String) -> String {
            let template = String(localized: "agent-embedded-browser.last-screenshot", defaultValue: "Last screenshot: %@")
            return String(format: template, a1)
        }
        static let ready = String(localized: "agent-embedded-browser.ready", defaultValue: "Ready")
        static let reload = String(localized: "agent-embedded-browser.reload", defaultValue: "Reload")
        static let untitled = String(localized: "agent-embedded-browser.untitled", defaultValue: "Untitled page")
    }

    enum AgentPanel {
        static let activeFileIncludedHint = String(localized: "agent-panel.active-file-included-hint", defaultValue: "Active file included · Tools available")
        static let contextCompressing = String(localized: "agent-panel.context-compressing", defaultValue: "Compressing context")
        static let openFolderHint = String(localized: "agent-panel.open-folder-hint", defaultValue: "Open a folder to enable tools")
        static let queueWaiting = String(localized: "agent-panel.queue-waiting", defaultValue: "Queued, waiting for an available concurrency slot…")
        static let selectionIncludedHint = String(localized: "agent-panel.selection-included-hint", defaultValue: "Selection included · Tools available")
        static let sessionSaveFailed = String(localized: "agent-panel.session-save-failed", defaultValue: "Failed to save this conversation to disk — recent messages may be lost after quitting. Check free disk space and folder permissions.")
        static let thinking = String(localized: "agent-panel.thinking", defaultValue: "Thinking")
        static let thinkingPreviewAccessibility = String(localized: "agent-panel.thinking-preview-accessibility", defaultValue: "Live thinking preview")
    }

    enum HeatmapCell {
        static func tooltip(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "heatmap-cell.tooltip", defaultValue: "%1$@ used %2$@ tokens")
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
        static let fitButton = String(localized: "image-preview.fit-button", defaultValue: "Fit")
        static let openButton = String(localized: "image-preview.open-button", defaultValue: "Open Image Preview")
        static let windowTitle = String(localized: "image-preview.window-title", defaultValue: "Image Preview")
        static let zoomIn = String(localized: "image-preview.zoom-in", defaultValue: "Zoom In")
        static let zoomOut = String(localized: "image-preview.zoom-out", defaultValue: "Zoom Out")
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
        static let viewShowEditor = String(localized: "menu.view.show-editor", defaultValue: "Show Editor")
        static let viewSwitchToAgentMode = String(localized: "menu.view.switch-to-agent-mode", defaultValue: "Switch to Agent Mode")
        static let viewSwitchToEditorMode = String(localized: "menu.view.switch-to-editor-mode", defaultValue: "Switch to Editor Mode")
        static let viewToggleAgent = String(localized: "menu.view.toggle-agent", defaultValue: "Toggle Agent")
        static let viewToggleFocusMode = String(localized: "menu.view.toggle-focus-mode", defaultValue: "Toggle Focus Mode")
        static let viewToggleInspector = String(localized: "menu.view.toggle-inspector", defaultValue: "Toggle Inspector")
        static let viewTogglePreview = String(localized: "menu.view.toggle-preview", defaultValue: "Toggle Preview")
        static let viewToggleTerminal = String(localized: "menu.view.toggle-terminal", defaultValue: "Toggle Terminal")
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
        static func cacheRate(_ percentage: String) -> String {
            let template = String(localized: "message-footer.cache-rate", defaultValue: "cache %@")
            return String(format: template, percentage)
        }
        static let copied = String(localized: "message-footer.copied", defaultValue: "Copied")
        static let copy = String(localized: "message-footer.copy", defaultValue: "Copy message")
        static let copyAccessibility = String(localized: "message-footer.copy-accessibility", defaultValue: "Copy message")
        static let processing = String(localized: "message-footer.processing", defaultValue: "Processing")
        static let processed = String(localized: "message-footer.processed", defaultValue: "Processed")
        static func processedDuration(_ duration: String) -> String {
            let template = String(localized: "message-footer.processed-duration", defaultValue: "Processed %@")
            return String(format: template, duration)
        }
    }

    enum ModelUsage {
        static let cached = { (a1: String) -> String in
            let template = String(localized: "model-usage.cached", defaultValue: "%@ cached")
            return String(format: template, a1)
        }
        static let costUnknown = String(localized: "model-usage.cost-unknown", defaultValue: "n/a")
        static let empty = String(localized: "model-usage.empty", defaultValue: "No model usage in this range yet.")
        static let footnoteEstimatedUsage = String(localized: "model-usage.footnote.estimated-usage", defaultValue: "≈ means token split was estimated from older session data.")
        static let footnoteExternalDelegated = String(localized: "model-usage.footnote.external-delegated", defaultValue: "Delegated CLI calls are tracked separately because their real token usage and provider cache hits are not reported to WillDeep.")
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
        static let prefix = { (a1: String) -> String in
            let template = String(localized: "model-usage.prefix", defaultValue: "%@ stable prefix")
            return String(format: template, a1)
        }
        static let reasoning = { (a1: String) -> String in
            let template = String(localized: "model-usage.reasoning", defaultValue: "%@ reasoning")
            return String(format: template, a1)
        }
        static let sourceExternal = String(localized: "model-usage.source.external", defaultValue: "external")
        static let sessions = { (a1: String) -> String in
            let template = String(localized: "model-usage.sessions", defaultValue: "%@ sessions")
            return String(format: template, a1)
        }
        static let tokensHelp = { (a1: String, a2: String) -> String in
            let template = String(localized: "model-usage.tokens-help", defaultValue: "%@ input tokens, %@ output tokens")
            return String(format: template, a1, a2)
        }
        static let warAndPeaceMoreTokens = { (a1: String) -> String in
            let template = String(localized: "model-usage.war-and-peace.more-tokens", defaultValue: "You've used ~%@× more tokens than War and Peace.")
            return String(format: template, a1)
        }
        static let warAndPeacePercent = { (a1: String) -> String in
            let template = String(localized: "model-usage.war-and-peace.percent", defaultValue: "You've used about %@%% of War and Peace in tokens so far.")
            return String(format: template, a1)
        }
    }

    enum PlanCard {
        static let collapseHelp = String(localized: "plan-card.collapse-help", defaultValue: "Collapse plan")
        static let collapsed = String(localized: "plan-card.collapsed", defaultValue: "Collapsed")
        static let expandHelp = String(localized: "plan-card.expand-help", defaultValue: "Expand plan")
        static let expanded = String(localized: "plan-card.expanded", defaultValue: "Expanded")
        static let header = String(localized: "plan-card.header", defaultValue: "Plan")
        static let markCompleteButton = String(localized: "plan-card.mark-complete-button", defaultValue: "Mark plan complete")
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
        static let approved = String(localized: "plan-status.approved", defaultValue: "Ready")
        static let done = String(localized: "plan-status.done", defaultValue: "Done")
        static let executing = String(localized: "plan-status.executing", defaultValue: "Executing")
        static let proposed = String(localized: "plan-status.proposed", defaultValue: "Planned")
        static let rejected = String(localized: "plan-status.rejected", defaultValue: "Rejected")
    }

    enum PlanStep {
        static let cycleStatusHelp = String(localized: "plan-step.cycle-status.help", defaultValue: "This legacy plan is no longer active")
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
        static let dragHelp = String(localized: "queued-message.drag.help", defaultValue: "Drag to reorder queued messages")
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

    enum FileTree {
        static let openInEditor = String(localized: "file-tree.open-in-editor", defaultValue: "Open in Editor")
    }

    enum Sidebar {
        static func archivedSessionsHeader(_ a1: String) -> String {
            let template = String(localized: "sidebar.archived-sessions.header", defaultValue: "Archived count")
            return String(format: template, a1)
        }
        static let chatsHeader = String(localized: "sidebar.chats-header", defaultValue: "Chats")
        static let emptyState = String(localized: "sidebar.empty-state", defaultValue: "Sessions you start will appear here.")
        static let newChatAction = String(localized: "sidebar.new-chat-action", defaultValue: "New Chat")
        static let pinnedHeader = String(localized: "sidebar.pinned-header", defaultValue: "Pinned")
        static let defaultSessionTitle = String(localized: "sidebar.default-session-title", defaultValue: "New Chat")
        static let recentSessionsRailTitle = String(localized: "sidebar.recent-sessions-rail.title", defaultValue: "Recent chats")
        static let recentSessionsRailEmpty = String(localized: "sidebar.recent-sessions-rail.empty", defaultValue: "Recent chats will appear here.")
        static func recentSessionsRailRowTooltip(_ a1: String) -> String {
            let template = String(localized: "sidebar.recent-sessions-rail.row-tooltip", defaultValue: "Recent chat from %@")
            return String(format: template, a1)
        }
        static let sessionListSeeMore = String(localized: "sidebar.session-list.see-more", defaultValue: "See more")
        static let sessionListShowLess = String(localized: "sidebar.session-list.show-less", defaultValue: "Show less")
        static let sessionMenuArchive = String(localized: "sidebar.session-menu.archive", defaultValue: "Archive")
        static let sessionMenuDelete = String(localized: "sidebar.session-menu.delete", defaultValue: "Delete session")
        static let sessionMenuPin = String(localized: "sidebar.session-menu.pin", defaultValue: "Pin")
        static let sessionMenuRename = String(localized: "sidebar.session-menu.rename", defaultValue: "Rename…")
        static let sessionMenuSummarizeTitle = String(localized: "sidebar.session-menu.summarize-title", defaultValue: "Summarize with AI")
        static let sessionMenuUnarchive = String(localized: "sidebar.session-menu.unarchive", defaultValue: "Unarchive")
        static let sessionMenuUnpin = String(localized: "sidebar.session-menu.unpin", defaultValue: "Unpin")
        static let deleteSessionAlertTitle = String(localized: "sidebar.delete-session.alert-title", defaultValue: "Delete Session")
        static func deleteSessionAlertMessage(_ title: String) -> String {
            let template = String(localized: "sidebar.delete-session.alert-message", defaultValue: "“%@” and all its messages will be permanently deleted. This cannot be undone.")
            return String(format: template, title)
        }
        static let deleteSessionConfirm = String(localized: "sidebar.delete-session.confirm", defaultValue: "Delete")
        static let deleteSessionCancel = String(localized: "sidebar.delete-session.cancel", defaultValue: "Cancel")
        static let archiveWithTasksTitle = String(localized: "sidebar.archive-with-tasks.title", defaultValue: "Archive this session?")
        static func archiveWithTasksMessage(_ count: String) -> String {
            let template = String(localized: "sidebar.archive-with-tasks.message", defaultValue: "This session has %@ active scheduled task(s). Archiving stops and removes them — they won't run anymore.")
            return String(format: template, count)
        }
        static let archiveWithTasksConfirm = String(localized: "sidebar.archive-with-tasks.confirm", defaultValue: "Archive & Stop Tasks")
        static let archiveWithTasksCancel = String(localized: "sidebar.archive-with-tasks.cancel", defaultValue: "Cancel")
        static let hasActiveScheduledTasksTooltip = String(localized: "sidebar.has-active-scheduled-tasks.tooltip", defaultValue: "Has active scheduled tasks")
        static let renameSessionAlertTitle = String(localized: "sidebar.rename-session.alert-title", defaultValue: "Rename Session")
        static let renameSessionAlertMessage = String(localized: "sidebar.rename-session.alert-message", defaultValue: "Give this conversation a new name.")
        static let renameSessionConfirm = String(localized: "sidebar.rename-session.confirm", defaultValue: "Save")
        static let renameSessionCancel = String(localized: "sidebar.rename-session.cancel", defaultValue: "Cancel")
        static let sessionUnavailableAlertTitle = String(localized: "sidebar.session-unavailable.alert-title", defaultValue: "Conversation Unavailable")
        static func sessionUnavailableAlertMessage(_ title: String) -> String {
            let template = String(localized: "sidebar.session-unavailable.alert-message", defaultValue: "“%@” could not be opened because its local history file is missing. WillDeep kept the sidebar entry so you can restore the file from backup. No new data was written over it.")
            return String(format: template, title)
        }
        static let sessionUnavailableConfirm = String(localized: "sidebar.session-unavailable.confirm", defaultValue: "OK")
        static let sessionRowArchiveTooltip = String(localized: "sidebar.session-row.archive-tooltip", defaultValue: "Archive")
        static let sessionRowPinTooltip = String(localized: "sidebar.session-row.pin-tooltip", defaultValue: "Pin")
        static let sessionRowUnarchiveTooltip = String(localized: "sidebar.session-row.unarchive-tooltip", defaultValue: "Unarchive")
        static let sessionRowUnpinTooltip = String(localized: "sidebar.session-row.unpin-tooltip", defaultValue: "Unpin")
        static let sessionRowWaitingApproval = String(localized: "sidebar.session-row.waiting-approval", defaultValue: "Waiting approval")
        static let sessionRowWaitingApprovalTooltip = String(localized: "sidebar.session-row.waiting-approval-tooltip", defaultValue: "This session is waiting for your approval or answer.")
        static func sessionTodoPlanTooltip(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "sidebar.session-todo.plan-tooltip", defaultValue: "Plan progress: %@ of %@ done. Current: %@")
            return String(format: template, a1, a2, a3)
        }
        static func sessionTodoGoalTooltip(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "sidebar.session-todo.goal-tooltip", defaultValue: "Goal progress: %@ of %@ done. Current: %@")
            return String(format: template, a1, a2, a3)
        }
        static func sessionUpdatedTooltip(_ a1: String) -> String {
            let template = String(localized: "sidebar.session-row.updated-tooltip", defaultValue: "Updated %@ ago")
            return String(format: template, a1)
        }
        static let someIMAccountTitle = String(localized: "sidebar.some-im.account-title", defaultValue: "some.im")
        static func someIMCredits(_ a1: String) -> String {
            let template = String(localized: "sidebar.some-im.credits", defaultValue: "%@ credits")
            return String(format: template, a1)
        }
        static let someIMOpenTooltip = String(localized: "sidebar.some-im.open-tooltip", defaultValue: "Open some.im with this account")
        static let someIMSettingsTooltip = String(localized: "sidebar.some-im.settings-tooltip", defaultValue: "Open some.im settings")
        static let someIMRefreshTooltip = String(localized: "sidebar.some-im.refresh-tooltip", defaultValue: "Refresh some.im credits")
        static let someIMNotLoggedIn = String(localized: "sidebar.some-im.not-logged-in", defaultValue: "Not signed in")
        static let someIMNotLoggedInTooltip = String(localized: "sidebar.some-im.not-logged-in-tooltip", defaultValue: "Open some.im integration settings")
        static let workspaceHeader = String(localized: "sidebar.workspace-header", defaultValue: "Workspaces")
        static let workspaceHeaderOpenTooltip = String(localized: "sidebar.workspace-header.open-tooltip", defaultValue: "Open another folder as a new workspace")
        static let workspaceMenuNewChat = String(localized: "sidebar.workspace-menu.new-chat", defaultValue: "New Chat in this Workspace")
        static let workspaceMenuRemove = String(localized: "sidebar.workspace-menu.remove", defaultValue: "Remove from List")
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

    enum SymbolJump {
        static let noSymbols = String(localized: "symbol-jump.no-symbols", defaultValue: "No Symbols")
        static let placeholder = String(localized: "symbol-jump.placeholder", defaultValue: "Go to Symbol")
        static let searchingWorkspace = String(localized: "symbol-jump.searching-workspace", defaultValue: "Searching workspace…")
        static func symbolKindLine(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "symbol-jump.symbol-kind.line", defaultValue: "line")
            return String(format: template, a1, a2)
        }
        static func workspaceSymbolLocation(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "symbol-jump.workspace-symbol.location", defaultValue: "%@ · line %@")
            return String(format: template, a1, a2)
        }
        static func workspaceSymbolContainerLocation(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "symbol-jump.workspace-symbol.container-location", defaultValue: "%@ · %@")
            return String(format: template, a1, a2)
        }
    }

    enum ToolCard {
        static let allow = String(localized: "tool-card.allow", defaultValue: "Allow")
        static let allowConversation = String(localized: "tool-card.allow-conversation", defaultValue: "Allow for This Conversation")
        static let allowComputerUseSession = String(localized: "tool-card.allow-computer-use-session", defaultValue: "Allow This Control Session")
        static let approvalControlLeaseBadge = String(localized: "tool-card.approval.control-lease.badge", defaultValue: "CONTROL")
        static let approvalControlLeaseTooltip = String(localized: "tool-card.approval.control-lease.tooltip", defaultValue: "Auto-approved by the current runtime-, turn-, and target-bound Computer Use controlling lease.")
        static let alwaysAllow = String(localized: "tool-card.always-allow", defaultValue: "Always Allow")
        static let browserAuthorizationTitle = String(localized: "tool-card.authorization.browser.title", defaultValue: "Browser")
        static let browserChromeAuthorizationQuestion = String(localized: "tool-card.authorization.browser.chrome-question", defaultValue: "Allow WillDeep to control Chrome?")
        static let browserEmbeddedAuthorizationQuestion = String(localized: "tool-card.authorization.browser.embedded-question", defaultValue: "Allow WillDeep to control Browser?")
        static let computerUseAuthorizationTitle = String(localized: "tool-card.authorization.computer-use.title", defaultValue: "Computer Use")
        static let computerUseAuthorizationQuestion = String(localized: "tool-card.authorization.computer-use.question", defaultValue: "Allow WillDeep to use Computer Use?")
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
        static let localPreviewExplanation = String(localized: "tool-card.local-preview.explanation", defaultValue: "This is a local confirmation-panel preview. No command or network request will run, and nothing from this preview is sent to AI.")
        static let localPreviewModel = String(localized: "tool-card.local-preview.model", defaultValue: "Local preview")
        static let collapse = String(localized: "tool-card.collapse", defaultValue: "Collapse")
        static let expand = String(localized: "tool-card.expand", defaultValue: "Expand")
        static let statusAwaitingApproval = String(localized: "tool-card.status.awaiting-approval", defaultValue: "Awaiting approval")
        static let statusConfirmRequired = String(localized: "tool-card.status.confirm-required", defaultValue: "Confirm required")
        static let statusAskingYou = String(localized: "tool-card.status.asking-you", defaultValue: "Asking you")
        static let statusRunning = String(localized: "tool-card.status.running", defaultValue: "Running…")
        static let statusDone = String(localized: "tool-card.status.done", defaultValue: "Done")
        static let statusFailed = String(localized: "tool-card.status.failed", defaultValue: "Failed")
        static let statusDenied = String(localized: "tool-card.status.denied", defaultValue: "Denied")
        static let askUserAnswerPlaceholder = String(localized: "tool-card.ask-user.answer-placeholder", defaultValue: "Your answer")
        static let askUserOtherAnswerPlaceholder = String(localized: "tool-card.ask-user.other-answer-placeholder", defaultValue: "Other answer (optional)")
        static let askUserSkip = String(localized: "tool-card.ask-user.skip", defaultValue: "Skip")
        static let askUserSend = String(localized: "tool-card.ask-user.send", defaultValue: "Send")
        static let askUserAnswered = String(localized: "tool-card.ask-user.answered", defaultValue: "You answered")
        static let askUserSkipped = String(localized: "tool-card.ask-user.skipped", defaultValue: "You skipped this question")
        static let terminalPasswordWaiting = String(localized: "tool-card.terminal-password.waiting", defaultValue: "Waiting for password")
        static let terminalPasswordEntered = String(localized: "tool-card.terminal-password.entered", defaultValue: "User entered password")
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
        static let inspectOutputHelp = String(localized: "agent-jobs.inspect-output.help", defaultValue: "Fill the composer with a request to inspect this job")
        static let notificationTitle = String(localized: "agent-jobs.notification.title", defaultValue: "Background job finished")
        static let notificationTitleCompleted = String(localized: "agent-jobs.notification.title.completed", defaultValue: "Background job finished")
        static let notificationTitleFailed = String(localized: "agent-jobs.notification.title.failed", defaultValue: "Background job failed")
        static let notificationTitleStopped = String(localized: "agent-jobs.notification.title.stopped", defaultValue: "Background job stopped")

        static func inspectOutputPrompt(_ jobID: String) -> String {
            let template = String(
                localized: "agent-jobs.inspect-output.prompt",
                defaultValue: "Check background job %@ status and output: get_job_output(job_id: \"%@\")"
            )
            return String(format: template, jobID, jobID)
        }
    }

    enum Settings {
        static let windowTitle = String(localized: "settings.window.title", defaultValue: "Settings")
        static let tabUpdates = String(localized: "settings.tab.updates", defaultValue: "Updates")
        static let tabTypography = String(localized: "settings.tab.typography", defaultValue: "Font")
        static let tabEditing = String(localized: "settings.tab.editing", defaultValue: "Editing")
        static let tabAppearance = String(localized: "settings.tab.appearance", defaultValue: "Format")
        static let tabBackground = String(localized: "settings.tab.background", defaultValue: "Background")
        static let tabWorkspace = String(localized: "settings.tab.workspace", defaultValue: "Workspace")
        static let tabAgent = String(localized: "settings.tab.agent", defaultValue: "AI Providers")
        static let tabSomeIM = String(localized: "settings.tab.some-im", defaultValue: "some.im")
        static let tabReplicate = String(localized: "settings.tab.replicate", defaultValue: "Replicate")
        static let tabMemory = String(localized: "settings.tab.memory", defaultValue: "Memory")
        static let tabRules = String(localized: "settings.tab.rules", defaultValue: "Rules")
        static let tabSkills = String(localized: "settings.tab.skills", defaultValue: "Skills")
        static let tabConnectors = String(localized: "settings.tab.connectors", defaultValue: "Connectors")
        static let tabMcp = String(localized: "settings.tab.mcp", defaultValue: "MCP")
        static let tabTools = String(localized: "settings.tab.tools", defaultValue: "Tools")
        static let tabTerminal = String(localized: "settings.tab.terminal", defaultValue: "Terminal")
        static let tabLocalAgents = String(localized: "settings.tab.local-agents", defaultValue: "Local Agents")
        static let tabRemoteRuntimes = String(localized: "settings.tab.remote-runtimes", defaultValue: "Runtimes")
        static let tabMobileGateway = String(localized: "settings.tab.mobile-gateway", defaultValue: "Mobile Gateway")
        static let tabVoice = String(localized: "settings.tab.voice", defaultValue: "Voice")
        static let agentBarSettings = String(localized: "agent.statusbar.settings", defaultValue: "Settings")
        static let agentBarMobileGateway = String(localized: "agent.statusbar.mobile-gateway", defaultValue: "Mobile Gateway")

        static let groupGeneral = String(localized: "settings.group.general", defaultValue: "General")
        static let groupFormatAndAppearance = String(localized: "settings.group.format-and-appearance", defaultValue: "Format & Appearance")
        static let groupAI = String(localized: "settings.group.ai", defaultValue: "AI Agents")
        static let groupAgentTools = String(localized: "settings.group.agent-tools", defaultValue: "Agent Tools")
        static let groupAccountAndDevices = String(localized: "settings.group.account-and-devices", defaultValue: "Account & Devices")
        static let groupRuntimes = String(localized: "settings.group.runtimes", defaultValue: "Runtimes")
        static let groupIntegrations = String(localized: "settings.group.integrations", defaultValue: "Integrations")
        static let groupTerminal = String(localized: "settings.group.terminal", defaultValue: "Terminal")
        static let groupVoice = String(localized: "settings.group.voice", defaultValue: "Voice")

        static let sectionTypography = String(localized: "settings.section.typography", defaultValue: "Typography")
        static let sectionEditorText = String(localized: "settings.section.editor-text", defaultValue: "Editor Text")
        static let sectionWorkspaceText = String(localized: "settings.section.workspace-text", defaultValue: "Workspace List")
        static let sectionInterfaceSkin = String(localized: "settings.section.interface-skin", defaultValue: "Interface Skin")
        static let interfaceSkinHelp = String(localized: "settings.interface-skin.help", defaultValue: "Choose a full-window skin. Skin changes apply to window chrome, sidebars, panels, selection color, and the recommended editor theme.")
        static let sectionColorStyle = String(localized: "settings.section.color-style", defaultValue: "Color Style")
        static let sectionEditorBackground = String(localized: "settings.section.editor-background", defaultValue: "Editor Background")
        static let sectionWorkspaceWallpaper = String(localized: "settings.section.workspace-wallpaper", defaultValue: "Workspace Wallpaper")
        static let sectionAgentWallpaper = String(localized: "settings.section.agent-wallpaper", defaultValue: "Agent Global Wallpaper")
        static let builtInWallpapers = String(localized: "settings.workspace-wallpaper.built-in", defaultValue: "Built-in Wallpapers")
        static let backgroundChoices = String(localized: "settings.workspace-wallpaper.choices", defaultValue: "Background Choices")
        static let workspaceWallpaperHelp = String(localized: "settings.workspace-wallpaper.help", defaultValue: "Choose the shared wallpaper and image layout here. Agent workspace effects are controlled separately below. WillDeep keeps a private managed copy of custom images.")
        static let workspaceWallpaperInstallFailed = String(localized: "settings.workspace-wallpaper.install-failed", defaultValue: "WillDeep couldn't use that image. Choose a valid image smaller than 64 MB and 80 megapixels.")
        static let sectionEditor = String(localized: "settings.section.editor", defaultValue: "Editor")
        static let sectionSidebar = String(localized: "settings.section.sidebar", defaultValue: "Sidebar")
        static let sectionInspector = String(localized: "settings.section.inspector", defaultValue: "Inspector")
        static let sectionSave = String(localized: "settings.section.save", defaultValue: "Save")
        static let sectionAgentProviders = String(localized: "settings.section.agent-providers", defaultValue: "Agent Providers")
        static let sectionImageUnderstanding = String(localized: "settings.section.image-understanding", defaultValue: "Image Understanding")
        static let sectionLocalModelAcceleration = String(localized: "settings.section.local-model-acceleration", defaultValue: "本地模型加速")
        static let sectionConversationTitle = String(localized: "settings.section.conversation-title", defaultValue: "Conversation Title")
        static let sectionToolApproval = String(localized: "settings.section.tool-approval", defaultValue: "Tool approval")
        static let sectionConcurrency = String(localized: "settings.section.concurrency", defaultValue: "Concurrency")
        static let sectionAgentAppearance = String(localized: "settings.section.agent-appearance", defaultValue: "Appearance")
        static let sectionAgentChatText = String(localized: "settings.section.agent-chat-text", defaultValue: "Agent Chat Text")
        static let sectionSoftwareUpdate = String(localized: "settings.section.software-update", defaultValue: "Software Update")
        static let sectionAgentAlwaysAllow = String(localized: "settings.section.agent-always-allow", defaultValue: "Agent Always Allow")
        static let sectionWebTools = String(localized: "settings.section.web-tools", defaultValue: "Web tools")

        static let toggleShowLineNumbers = String(localized: "settings.toggle.show-line-numbers", defaultValue: "Show Line Numbers")
        static let toggleHighlightCurrentLine = String(localized: "settings.toggle.highlight-current-line", defaultValue: "Highlight Current Line")
        static let toggleGlassEditorBackground = String(localized: "settings.toggle.glass-editor-background", defaultValue: "Glass Editor Background")
        static let toggleAgentWallpaper = String(localized: "settings.toggle.agent-wallpaper", defaultValue: "Use as Agent Global Background")
        static let toggleAgentWallpaperGlass = String(localized: "settings.toggle.agent-wallpaper-glass", defaultValue: "Frosted Glass")
        static let toggleTrimTrailingWhitespace = String(localized: "settings.toggle.trim-trailing-whitespace", defaultValue: "Trim Trailing Whitespace")
        static let toggleEnsureFinalNewline = String(localized: "settings.toggle.ensure-final-newline", defaultValue: "Ensure Final Newline")
        static let toggleAutoApproveSafe = String(localized: "settings.toggle.auto-approve-safe", defaultValue: "AI-approve normal commands")

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
        static let labelAgentWallpaperSurfaceOpacity = String(localized: "settings.label.agent-wallpaper-surface-opacity", defaultValue: "Agent Surface Opacity")
        static let labelGlassMaterial = String(localized: "settings.label.glass-material", defaultValue: "Glass Material")
        static let labelGlassStrength = String(localized: "settings.label.glass-strength", defaultValue: "Glass Strength")
        static let labelEditorSurface = String(localized: "settings.label.editor-surface", defaultValue: "Editor Surface")
        static let labelTextSize = String(localized: "settings.label.text-size", defaultValue: "Text Size")
        static let labelLineHeight = String(localized: "settings.label.line-height", defaultValue: "Line Height")
        static let labelInstalledVersion = String(localized: "settings.label.installed-version", defaultValue: "Installed Version")
        static let labelDefaultView = String(localized: "settings.label.default-view", defaultValue: "Default View")
        static let labelViewOrder = String(localized: "settings.label.view-order", defaultValue: "View Order")
        static let noImageSelected = String(localized: "settings.no-image-selected", defaultValue: "No image selected")
        static let noBackground = String(localized: "settings.no-background", defaultValue: "No Background")
        static let chooseBackgroundImageTitle = String(localized: "settings.choose-background-image.title", defaultValue: "Choose Editor Background Image")
        static let chooseWorkspaceWallpaperTitle = String(localized: "settings.choose-workspace-wallpaper.title", defaultValue: "Choose Workspace Wallpaper")
        static let backgroundImageModeFill = String(localized: "settings.background-image-mode.fill", defaultValue: "Fill & Crop")
        static let backgroundImageModeFit = String(localized: "settings.background-image-mode.fit", defaultValue: "Fit")
        static let backgroundImageModeStretch = String(localized: "settings.background-image-mode.stretch", defaultValue: "Stretch")
        static let backgroundImageModeCenter = String(localized: "settings.background-image-mode.center", defaultValue: "Center")
        static let backgroundImageModeTile = String(localized: "settings.background-image-mode.tile", defaultValue: "Tile")
        static let agentWallpaperHelp = String(localized: "settings.agent-wallpaper.help", defaultValue: "Uses the workspace wallpaper selected above throughout the Agent workspace. Adjust the interface surface opacity and optional frosted glass for readability.")
        static let savedStatus = String(localized: "settings.saved-status", defaultValue: "Saved.")
        static let allChangesSaved = String(localized: "settings.all-changes-saved", defaultValue: "All changes saved")
        static let softwareUpdateHelp = String(localized: "settings.software-update.help", defaultValue: "WillDeep checks for signed updates automatically. You can also check now; Sparkle verifies the download before installing it.")
        static func versionAndBuild(_ version: String, _ build: String) -> String {
            let template = String(localized: "settings.software-update.version-and-build", defaultValue: "%@ (Build %@)")
            return String(format: template, version, build)
        }

        enum BuiltInWallpaper {
            static func name(_ id: String) -> String {
                switch id {
                case BuiltInWorkspaceWallpaper.pastelDrift.id:
                    return String(localized: "settings.workspace-wallpaper.name.pastel-drift", defaultValue: "Pastel Drift")
                case BuiltInWorkspaceWallpaper.ringedWorld.id:
                    return String(localized: "settings.workspace-wallpaper.name.ringed-world", defaultValue: "Ringed World")
                case BuiltInWorkspaceWallpaper.skyGarden.id:
                    return String(localized: "settings.workspace-wallpaper.name.sky-garden", defaultValue: "Sky Garden")
                case BuiltInWorkspaceWallpaper.springQipao.id:
                    return String(localized: "settings.workspace-wallpaper.name.spring-qipao", defaultValue: "Spring Qipao")
                case BuiltInWorkspaceWallpaper.glacierMirror.id:
                    return String(localized: "settings.workspace-wallpaper.name.glacier-mirror", defaultValue: "Glacier Mirror")
                case BuiltInWorkspaceWallpaper.emeraldSteppe.id:
                    return String(localized: "settings.workspace-wallpaper.name.emerald-steppe", defaultValue: "Emerald Steppe")
                case BuiltInWorkspaceWallpaper.coralRealm.id:
                    return String(localized: "settings.workspace-wallpaper.name.coral-realm", defaultValue: "Coral Realm")
                case BuiltInWorkspaceWallpaper.auroraSanctuary.id:
                    return String(localized: "settings.workspace-wallpaper.name.aurora-sanctuary", defaultValue: "Aurora Sanctuary")
                default:
                    return id
                }
            }
        }

        enum InterfaceSkin {
            static func name(_ skin: EditorInterfaceSkin) -> String {
                switch skin.id {
                case EditorInterfaceSkin.system.id:
                    return String(localized: "settings.interface-skin.system.name", defaultValue: "System Default")
                case EditorInterfaceSkin.mistForest.id:
                    return String(localized: "settings.interface-skin.mist-forest.name", defaultValue: "Mist Forest")
                case EditorInterfaceSkin.ricePaper.id:
                    return String(localized: "settings.interface-skin.rice-paper.name", defaultValue: "Rice Paper")
                case EditorInterfaceSkin.sciFiRaster.id:
                    return String(localized: "settings.interface-skin.sci-fi-raster.name", defaultValue: "Sci-Fi Raster")
                case EditorInterfaceSkin.midnightSlate.id:
                    return String(localized: "settings.interface-skin.midnight-slate.name", defaultValue: "Midnight Slate")
                case EditorInterfaceSkin.auroraNight.id:
                    return String(localized: "settings.interface-skin.aurora-night.name", defaultValue: "Aurora Night")
                case EditorInterfaceSkin.emberGraphite.id:
                    return String(localized: "settings.interface-skin.ember-graphite.name", defaultValue: "Ember Graphite")
                default:
                    return skin.id
                }
            }

            static func summary(_ skin: EditorInterfaceSkin) -> String {
                switch skin.id {
                case EditorInterfaceSkin.system.id:
                    return String(localized: "settings.interface-skin.system.summary", defaultValue: "Follows macOS with stable native contrast.")
                case EditorInterfaceSkin.mistForest.id:
                    return String(localized: "settings.interface-skin.mist-forest.summary", defaultValue: "Soft green and warm mist for calm long sessions.")
                case EditorInterfaceSkin.ricePaper.id:
                    return String(localized: "settings.interface-skin.rice-paper.summary", defaultValue: "Low-saturation ink and paper tones with a quiet reading feel.")
                case EditorInterfaceSkin.sciFiRaster.id:
                    return String(localized: "settings.interface-skin.sci-fi-raster.summary", defaultValue: "Deep cyan neon with a compact terminal-like atmosphere.")
                case EditorInterfaceSkin.midnightSlate.id:
                    return String(localized: "settings.interface-skin.midnight-slate.summary", defaultValue: "Blue-black depth for longer night coding.")
                case EditorInterfaceSkin.auroraNight.id:
                    return String(localized: "settings.interface-skin.aurora-night.summary", defaultValue: "Dark green-blue with clear aurora accents.")
                case EditorInterfaceSkin.emberGraphite.id:
                    return String(localized: "settings.interface-skin.ember-graphite.summary", defaultValue: "Graphite warmth with ember highlights.")
                default:
                    return skin.id
                }
            }
        }

        enum LearningReview {
            static let section = String(localized: "settings.learning-review.section", defaultValue: "Learning Review")
            static let title = String(localized: "settings.learning-review.title", defaultValue: "Review automatic learning")
            static let description = String(localized: "settings.learning-review.description", defaultValue: "Memory saves, skill candidates, and MCP suggestions discovered at turn end stay here until reviewed.")
            static let empty = String(localized: "settings.learning-review.empty", defaultValue: "No pending learning items.")
            static let copy = String(localized: "settings.learning-review.copy", defaultValue: "Copy details")
            static let copied = String(localized: "settings.learning-review.copied", defaultValue: "Copied")
            static let editSkillDraft = String(localized: "settings.learning-review.edit-skill-draft", defaultValue: "Edit skill draft")
            static let editSkillDraftTitle = String(localized: "settings.learning-review.edit-skill-draft-title", defaultValue: "Edit Skill Draft")
            static let createSkillFromDraft = String(localized: "settings.learning-review.create-skill-from-draft", defaultValue: "Create skill from draft")
            static let configureMCPFromDraft = String(localized: "settings.learning-review.configure-mcp-from-draft", defaultValue: "Configure MCP suggestion")
            static let saveSkillDraft = String(localized: "settings.learning-review.save-skill-draft", defaultValue: "Save Draft")
            static let markReviewed = String(localized: "settings.learning-review.mark-reviewed", defaultValue: "Mark reviewed")
            static let dismiss = String(localized: "settings.learning-review.dismiss", defaultValue: "Dismiss")
            static let clearReviewed = String(localized: "settings.learning-review.clear-reviewed", defaultValue: "Clear reviewed")
            static let decisionPending = String(localized: "settings.learning-review.decision.pending", defaultValue: "Pending")
            static let decisionReviewed = String(localized: "settings.learning-review.decision.reviewed", defaultValue: "Reviewed")
            static let decisionDismissed = String(localized: "settings.learning-review.decision.dismissed", defaultValue: "Dismissed")
            static func pendingCount(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.pending-count", defaultValue: "%@ pending")
                return String(format: template, a1)
            }
            static func morePending(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.more-pending", defaultValue: "%@ more pending items hidden")
                return String(format: template, a1)
            }
            static func reviewedDisclosure(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.reviewed-disclosure", defaultValue: "Reviewed items (%@)")
                return String(format: template, a1)
            }
            static func moreReviewed(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.more-reviewed", defaultValue: "%@ more reviewed items hidden")
                return String(format: template, a1)
            }
        }

        enum WebTools {
            static let providerLabel = String(localized: "settings.web-tools.provider", defaultValue: "Search Provider")
            static let providerAuto = String(localized: "settings.web-tools.provider.auto", defaultValue: "Auto")
            static let providerExa = String(localized: "settings.web-tools.provider.exa", defaultValue: "Exa")
            static let providerBrave = String(localized: "settings.web-tools.provider.brave", defaultValue: "Brave")
            static let exaKeyLabel = String(localized: "settings.web-tools.exa-api-key", defaultValue: "Exa API Key")
            static let braveKeyLabel = String(localized: "settings.web-tools.brave-api-key", defaultValue: "Brave Search API Key")
            static let description = String(localized: "settings.web-tools.description", defaultValue: "Enables the built-in web_search tool. Auto tries local Exa first, then Brave; if both keys are empty and some.im is signed in, it uses some.im managed search. API keys are stored in the macOS Keychain. web_fetch needs no key and asks for approval per domain.")

            static func providerName(_ provider: AgentWebSearchProvider) -> String {
                switch provider {
                case .auto:
                    return providerAuto
                case .exa:
                    return providerExa
                case .brave:
                    return providerBrave
                }
            }
        }

        enum SomeIM {
            static let accountSection = String(localized: "settings.some-im.account-section", defaultValue: "some.im Account")
            static let emailLabel = String(localized: "settings.some-im.email", defaultValue: "Email")
            static let emailCodeLabel = String(localized: "settings.some-im.email-code", defaultValue: "Verification Code")
            static let sendCode = String(localized: "settings.some-im.send-code", defaultValue: "Send Code")
            static let sendingCode = String(localized: "settings.some-im.sending-code", defaultValue: "Sending...")
            static let verifyCode = String(localized: "settings.some-im.verify-code", defaultValue: "Verify & Connect")
            static let verifyingCode = String(localized: "settings.some-im.verifying-code", defaultValue: "Connecting...")
            static let refreshBalance = String(localized: "settings.some-im.refresh-balance", defaultValue: "Refresh Balance")
            static let openSomeIM = String(localized: "settings.some-im.open", defaultValue: "Open some.im")
            static let logout = String(localized: "settings.some-im.logout", defaultValue: "Sign Out")
            static let logoutConfirmTitle = String(localized: "settings.some-im.logout-confirm-title", defaultValue: "Sign out of some.im?")
            static let logoutConfirmMessage = String(localized: "settings.some-im.logout-confirm-message", defaultValue: "This signs out every app on this Mac that shares this some.im login.")
            static let loggedOut = String(localized: "settings.some-im.logged-out", defaultValue: "Signed out of some.im.")
            static let logoutCancel = String(localized: "settings.some-im.logout-cancel", defaultValue: "Cancel")
            static let accountNotConnected = String(localized: "settings.some-im.account-not-connected", defaultValue: "Not connected")
            static let accountConnected = String(localized: "settings.some-im.account-connected", defaultValue: "Connected")
            static let creditsLabel = String(localized: "settings.some-im.credits", defaultValue: "Credits")
            static let defaultModelLabel = String(localized: "settings.some-im.default-model", defaultValue: "Default Model")
            static let newTabDefaultSection = String(localized: "settings.some-im.new-tab-default-section", defaultValue: "New Tab Default")
            static let newTabDefaultLabel = String(localized: "settings.some-im.new-tab-default-label", defaultValue: "Default model mode")
            static let newTabDefaultManaged = String(localized: "settings.some-im.new-tab-default-managed", defaultValue: "Managed Routing")
            static let newTabDefaultModel = String(localized: "settings.some-im.new-tab-default-model", defaultValue: "someim-auto-flash")
            static let newTabDefaultManagedHelp = String(localized: "settings.some-im.new-tab-default-managed-help", defaultValue: "New tabs use Managed Routing. You can still choose a concrete model in the composer for the current conversation.")
            static let newTabDefaultModelHelp = String(localized: "settings.some-im.new-tab-default-model-help", defaultValue: "New tabs use someim-auto-flash and let you choose another concrete model in the composer.")
            static let newTabDefaultLoginRequired = String(localized: "settings.some-im.new-tab-default-login-required", defaultValue: "Sign in to some.im to configure the default model mode for new tabs.")
            static let codeSent = String(localized: "settings.some-im.code-sent", defaultValue: "Verification code sent.")
            static let connected = String(localized: "settings.some-im.connected", defaultValue: "some.im connected.")
            static let browserLoginSection = String(localized: "settings.some-im.browser-login-section", defaultValue: "Browser Login")
            static let browserLoginDescription = String(localized: "settings.some-im.browser-login-description", defaultValue: "WillDeep prepares a secure some.im sign-in request automatically. Open it in your browser, sign in, then return to WillDeep when some.im says you can continue.")
            static let browserLoginPlaceholderTitle = String(localized: "settings.some-im.browser-login-placeholder-title", defaultValue: "Ready for browser sign-in")
            static let browserLoginPlaceholderDescription = String(localized: "settings.some-im.browser-login-placeholder-description", defaultValue: "Open some.im in your browser to finish signing in. WillDeep will keep waiting here for the account connection.")
            static let browserLoginQRCodeAccessibilityLabel = String(localized: "settings.some-im.browser-login-qr.accessibility-label", defaultValue: "some.im browser login QR code")
            static let browserLoginQRCodeUnavailable = String(localized: "settings.some-im.browser-login-qr.unavailable", defaultValue: "QR code unavailable")
            static let browserLoginCodeLabel = String(localized: "settings.some-im.browser-login-code", defaultValue: "Random Code")
            static let generateBrowserLoginLink = String(localized: "settings.some-im.generate-browser-login-link", defaultValue: "Generate Link")
            static let openBrowserLoginLink = String(localized: "settings.some-im.open-browser-login-link", defaultValue: "Open in Browser")
            static let copyBrowserLoginLink = String(localized: "settings.some-im.copy-browser-login-link", defaultValue: "Copy Link")
            static let copyBrowserLoginCode = String(localized: "settings.some-im.copy-browser-login-code", defaultValue: "Copy Code")
            static let browserLoginReady = String(localized: "settings.some-im.browser-login-ready", defaultValue: "Browser sign-in is ready.")
            static let browserLoginWaiting = String(localized: "settings.some-im.browser-login-waiting", defaultValue: "Waiting for browser sign-in...")
            static let browserLoginConnected = String(localized: "settings.some-im.browser-login-connected", defaultValue: "some.im account connected.")
            static let browserLoginExpired = String(localized: "settings.some-im.browser-login-expired", defaultValue: "Browser sign-in expired. Open some.im again to restart.")
            static let browserLoginClientSecretMissing = String(localized: "settings.some-im.browser-login-client-secret-missing", defaultValue: "This build is missing the some.im client-login secret. Set WILLDEEP_CLIENT_LOGIN_SECRET and rebuild WillDeep.")
            static let browserLoginMissingCredentials = String(localized: "settings.some-im.browser-login-missing-credentials", defaultValue: "Browser sign-in completed, but some.im did not return WillDeep credentials. Open some.im again and try signing in.")
            static let browserLoginCredentialSaveFailed = String(localized: "settings.some-im.browser-login-credential-save-failed", defaultValue: "some.im returned credentials, but WillDeep could not save them locally. Check Keychain access and try signing in again.")
            static let browserLoginConnectedTitle = String(localized: "settings.some-im.browser-login-connected-title", defaultValue: "Browser sign-in complete")
            static func browserLoginConnectedDescription(_ a1: String) -> String {
                String(localized: "settings.some-im.browser-login-connected-description", defaultValue: "Connected as \(a1). You can close the browser tab and continue in WillDeep.")
            }
            static let browserLoginOpened = String(localized: "settings.some-im.browser-login-opened", defaultValue: "some.im opened in your browser. Finish signing in there, then return to WillDeep.")
            static let browserLoginCopied = String(localized: "settings.some-im.browser-login-copied", defaultValue: "Browser login link copied.")
            static let browserLoginCodeCopied = String(localized: "settings.some-im.browser-login-code-copied", defaultValue: "Browser login code copied.")
            static let connectionSection = String(localized: "settings.some-im.connection-section", defaultValue: "some.im Integration")
            static let enabledToggle = String(localized: "settings.some-im.enabled-toggle", defaultValue: "Use some.im for multimodal generation")
            static let regionLabel = String(localized: "settings.some-im.region", defaultValue: "Region")
            static let baseURLLabel = String(localized: "settings.some-im.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.some-im.api-key", defaultValue: "API Key")
            static let fetchModels = String(localized: "settings.some-im.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.some-im.fetching-models", defaultValue: "Fetching...")
            static let description = String(localized: "settings.some-im.description", defaultValue: "Stores your some.im key in Keychain and lets WillDeep route image/video generation to the relay instead of guessing whether the active chat model supports generation.")
            static let imageSection = String(localized: "settings.some-im.image-section", defaultValue: "Image generation")
            static let videoSection = String(localized: "settings.some-im.video-section", defaultValue: "Video generation")
            static let imageModelLabel = String(localized: "settings.some-im.image-model", defaultValue: "Image Model")
            static let videoModelLabel = String(localized: "settings.some-im.video-model", defaultValue: "Video Model")
            static let priorityPlaceholder = String(localized: "settings.some-im.priority-placeholder", defaultValue: "Priority models, comma-separated")
            static let imageHelp = String(localized: "settings.some-im.image-help", defaultValue: "Image generation tools prefer this list. Default is gpt-image-2 when some.im is configured.")
            static let videoHelp = String(localized: "settings.some-im.video-help", defaultValue: "Choose the preferred some.im video model for async video-generation tasks.")
            static func accountSummary(_ email: String, _ credits: String) -> String {
                let template = String(localized: "settings.some-im.account-summary", defaultValue: "%1$@ · %2$@ credits")
                return String(format: template, email, credits)
            }
            static func fetchedModels(_ a1: String) -> String {
                let template = String(localized: "settings.some-im.fetched-models", defaultValue: "Fetched %@ models.")
                return String(format: template, a1)
            }
            static func regionName(_ region: SomeIMRelayRegion) -> String {
                switch region {
                case .china:
                    return String(localized: "settings.some-im.region.china", defaultValue: "China (api.niuwoai.com)")
                case .international:
                    return String(localized: "settings.some-im.region.international", defaultValue: "International (some.im)")
                case .custom:
                    return String(localized: "settings.some-im.region.custom", defaultValue: "Custom")
                }
            }
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

        enum LocalModel {
            static let enabled = String(localized: "settings.local-model.enabled", defaultValue: "启用本地辅助模型")
            static let baseURL = String(localized: "settings.local-model.base-url", defaultValue: "本地 Endpoint")
            static let visionModel = String(localized: "settings.local-model.vision-model", defaultValue: "图片理解模型")
            static let summaryModel = String(localized: "settings.local-model.summary-model", defaultValue: "Summary 模型")
            static let preferVision = String(localized: "settings.local-model.prefer-vision", defaultValue: "图片识别先用本地")
            static let preferTitle = String(localized: "settings.local-model.prefer-title", defaultValue: "会话标题先用本地")
            static let preferContextSummary = String(localized: "settings.local-model.prefer-context-summary", defaultValue: "上下文压缩先用本地")
            static let exposeComposerModel = String(localized: "settings.local-model.expose-composer-model", defaultValue: "加入 composer 模型备选")
            static let composerModelName = String(localized: "settings.local-model.composer-model-name", defaultValue: "composer 显示名称")
            static let composerModelNamePlaceholder = String(localized: "settings.local-model.composer-model-name-placeholder", defaultValue: "Local Chat (Ollama)")
            static let description = String(localized: "settings.local-model.description", defaultValue: "启用后，图片理解、会话标题可先请求本机 OpenAI-compatible 服务；上下文压缩默认不走本地，避免小模型误压缩长上下文。失败时自动回退到你配置的远端 provider。")
            static let downloadSection = String(localized: "settings.local-model.download-section", defaultValue: "模型下载")
            static let packageLabel = String(localized: "settings.local-model.package", defaultValue: "推荐包")
            static let filesLabel = String(localized: "settings.local-model.files", defaultValue: "必要文件")
            static let locationLabel = String(localized: "settings.local-model.location", defaultValue: "保存位置")
            static let download = String(localized: "settings.local-model.download", defaultValue: "后台下载")
            static let downloading = String(localized: "settings.local-model.downloading", defaultValue: "下载中")
            static let cancel = String(localized: "settings.local-model.cancel", defaultValue: "取消")
            static let openFolder = String(localized: "settings.local-model.open-folder", defaultValue: "打开目录")
            static let findLocalFiles = String(localized: "settings.local-model.find-local-files", defaultValue: "查找本地文件")
            static let findingLocalFiles = String(localized: "settings.local-model.finding-local-files", defaultValue: "查找中")
            static let findResults = String(localized: "settings.local-model.find-results", defaultValue: "本地候选文件")
            static let findNoResults = String(localized: "settings.local-model.find-no-results", defaultValue: "没有在常见目录找到同名必要文件。")
            static let findMatched = String(localized: "settings.local-model.find-matched", defaultValue: "大小匹配")
            static let findClose = String(localized: "settings.local-model.find-close", defaultValue: "大小接近")
            static let findMismatch = String(localized: "settings.local-model.find-mismatch", defaultValue: "大小不像")
            static let installed = String(localized: "settings.local-model.installed", defaultValue: "必要文件已就绪。")
            static let notInstalled = String(localized: "settings.local-model.not-installed", defaultValue: "尚未下载完整模型包。")
            static let canceled = String(localized: "settings.local-model.canceled", defaultValue: "下载已取消。")
            static let downloadHelp = String(localized: "settings.local-model.download-help", defaultValue: "只下载主模型 GGUF 和 mmproj 视觉 projector，不会下载同仓库里的所有量化版本。下载完成后仍需要 Ollama、LM Studio 或 llama.cpp server 加载这些文件并提供 OpenAI-compatible endpoint。")
            static let localProviderListed = String(localized: "settings.local-model.provider-listed", defaultValue: "勾选“加入 composer 模型备选”后，本地模型会以你设置的名称进入模型菜单；断网时可手动切过去聊天。")

            static func progress(_ fileIndex: String, _ fileCount: String, _ fileName: String) -> String {
                let template = String(localized: "settings.local-model.progress", defaultValue: "文件 %1$@/%2$@：%3$@")
                return String(format: template, fileIndex, fileCount, fileName)
            }

            static func downloaded(_ done: String, _ total: String) -> String {
                let template = String(localized: "settings.local-model.downloaded", defaultValue: "已下载 %1$@ / %2$@")
                return String(format: template, done, total)
            }

            static func failed(_ message: String) -> String {
                let template = String(localized: "settings.local-model.failed", defaultValue: "下载失败：%@")
                return String(format: template, message)
            }

            static func findSize(_ actual: String, _ expected: String) -> String {
                let template = String(localized: "settings.local-model.find-size", defaultValue: "%1$@ / 约 %2$@")
                return String(format: template, actual, expected)
            }

            static func findFailed(_ message: String) -> String {
                let template = String(localized: "settings.local-model.find-failed", defaultValue: "查找失败：%@")
                return String(format: template, message)
            }
        }

        enum AgentBehavior {
            static let saveBehaviorNote = String(localized: "settings.agent-behavior.save-note", defaultValue: "Keystrokes stay local until you press Save (⌘↩). API keys are stored separately in Keychain.")
            static let titleModelLabel = String(localized: "settings.agent-behavior.title-model", defaultValue: "Title Model")
            static let titleModelPlaceholder = String(localized: "settings.agent-behavior.title-model-placeholder", defaultValue: "(leave empty → use Flash model)")
            static let titleModelDescription = String(localized: "settings.agent-behavior.title-model-description", defaultValue: "A short one-shot completion summarizes each new chat into a ≤12-char title after the first assistant reply. Set a cheap/fast model here (e.g. `deepseek-chat`, `gpt-4o-mini`, `qwen-turbo`) to avoid burning Pro tokens on titling. Empty → falls back to the active provider's Flash model.")
            static let toolApprovalDescription = String(localized: "settings.agent-behavior.tool-approval-description", defaultValue: "Read-only shell commands in the built-in allowlist (cat, head, tail, ls, find without -delete/-exec, git diff/log/status/show, rg, grep, wc, file, stat, which, pwd, echo, …) run without asking. Commands outside the allowlist are passed to a one-shot LLM judge running on the active provider's **Flash** model (cheap & fast — never Pro), and only YES verdicts auto-run. Destructive patterns (rm, sudo, git push --force, git reset --hard, …) still require typing \"confirm\".")
            static let concurrencyDescription = String(localized: "settings.agent-behavior.concurrency-description", defaultValue: "Cap on simultaneous Agent turns per provider. Each provider has its own quota — running 3 DashScope sessions doesn't block OpenAI sessions. When the cap is hit, new dispatches queue (FIFO) and drain as turns finish. Raising the cap immediately promotes queued work; lowering it just stops promoting new ones (running turns are never aborted). Default 3 is conservative — bump up if your provider's rate limit comfortably allows.")
            static let anthropicMaxOutputTokens = String(localized: "settings.agent-behavior.anthropic-max-output-tokens", defaultValue: "Anthropic reply limit")
            static let anthropicMaxOutputTokensDescription = String(localized: "settings.agent-behavior.anthropic-max-output-tokens-description", defaultValue: "Maximum tokens a single Anthropic reply may produce (max_tokens). Default 32K keeps long documents and large refactor replies from truncating; legacy Claude 3.x models are automatically clamped to their lower API caps.")
            static func agentAppearanceDescription(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.agent-behavior.appearance-description", defaultValue: "Base size (pt) for Agent chat message body and rendered Markdown blocks (paragraphs, lists, quotes, fenced code, tables). Tool-call summaries, footers, message headers, and composer chrome keep their fixed sizes — this knob is about reading the conversation, not resizing the whole UI. Default is 14 pt; range %1$@ – %2$@ pt.")
                return String(format: template, a1, a2)
            }
        }

        enum Voice {
            static let overlaySection = String(localized: "settings.voice.overlay.section", defaultValue: "Floating Transcription Bar")
            static let overlayPositionLabel = String(localized: "settings.voice.overlay.position", defaultValue: "Position")
            static let overlaySizeLabel = String(localized: "settings.voice.overlay.size", defaultValue: "Size")
            static let overlayColorLabel = String(localized: "settings.voice.overlay.color", defaultValue: "Color")
            static let overlayWaveLabel = String(localized: "settings.voice.overlay.wave", defaultValue: "Waveform")
            static let overlayCornerLabel = String(localized: "settings.voice.overlay.corner", defaultValue: "Corner radius")
            static let overlayPreviewTitle = String(localized: "settings.voice.overlay.preview.title", defaultValue: "Preview")
            static let overlayPreviewDescription = String(localized: "settings.voice.overlay.preview.description", defaultValue: "Uses the same style presets as fastv's floating transcription toolbar.")
            static let overlayPreviewButton = String(localized: "settings.voice.overlay.preview.button", defaultValue: "Show bar")
            static let overlayDescription = String(localized: "settings.voice.overlay.description", defaultValue: "These settings apply to both the Fn push-to-talk shortcut and the composer mic button.")

            static let overlayPositionTopLeft = String(localized: "settings.voice.overlay.position.top-left", defaultValue: "Top left")
            static let overlayPositionTopRight = String(localized: "settings.voice.overlay.position.top-right", defaultValue: "Top right")
            static let overlayPositionBottomLeft = String(localized: "settings.voice.overlay.position.bottom-left", defaultValue: "Bottom left")
            static let overlayPositionBottomRight = String(localized: "settings.voice.overlay.position.bottom-right", defaultValue: "Bottom right")
            static let overlayPositionBottomCenter = String(localized: "settings.voice.overlay.position.bottom-center", defaultValue: "Bottom center")

            static let overlayStyleMinimal = String(localized: "settings.voice.overlay.style.minimal", defaultValue: "Minimal")
            static let overlayStyleCompact = String(localized: "settings.voice.overlay.style.compact", defaultValue: "Compact")
            static let overlayStyleNormal = String(localized: "settings.voice.overlay.style.normal", defaultValue: "Normal")
            static let overlayStyleLarge = String(localized: "settings.voice.overlay.style.large", defaultValue: "Large")

            static let overlayWaveClassic = String(localized: "settings.voice.overlay.wave.classic", defaultValue: "Classic bars")
            static let overlayWaveEqualizer = String(localized: "settings.voice.overlay.wave.equalizer", defaultValue: "Equalizer")
            static let overlayWaveSpectrum = String(localized: "settings.voice.overlay.wave.spectrum", defaultValue: "Spectrum")
            static let overlayWavePulse = String(localized: "settings.voice.overlay.wave.pulse", defaultValue: "Pulse")
            static let overlayWaveDigital = String(localized: "settings.voice.overlay.wave.digital", defaultValue: "Digital matrix")
            static let overlayWaveSkyline = String(localized: "settings.voice.overlay.wave.skyline", defaultValue: "Neon skyline")
            static let overlayWaveSine = String(localized: "settings.voice.overlay.wave.sine", defaultValue: "Sine wave")
            static let overlayWaveCosine = String(localized: "settings.voice.overlay.wave.cosine", defaultValue: "Cosine wave")
            static let overlayWaveECG = String(localized: "settings.voice.overlay.wave.ecg", defaultValue: "ECG")

            static let overlayCornerSubtle = String(localized: "settings.voice.overlay.corner.subtle", defaultValue: "Subtle")
            static let overlayCornerRounded = String(localized: "settings.voice.overlay.corner.rounded", defaultValue: "Rounded")
            static let overlayCornerSoft = String(localized: "settings.voice.overlay.corner.soft", defaultValue: "Soft")
            static let overlayCornerCapsule = String(localized: "settings.voice.overlay.corner.capsule", defaultValue: "Capsule")

            static let overlayColorBlue = String(localized: "settings.voice.overlay.color.blue", defaultValue: "Blue")
            static let overlayColorPurple = String(localized: "settings.voice.overlay.color.purple", defaultValue: "Purple")
            static let overlayColorPink = String(localized: "settings.voice.overlay.color.pink", defaultValue: "Pink")
            static let overlayColorGreen = String(localized: "settings.voice.overlay.color.green", defaultValue: "Green")
            static let overlayColorOrange = String(localized: "settings.voice.overlay.color.orange", defaultValue: "Orange")
            static let overlayColorRed = String(localized: "settings.voice.overlay.color.red", defaultValue: "Red")
            static let overlayColorBlackWhite = String(localized: "settings.voice.overlay.color.black-white", defaultValue: "Black + white")
            static let overlayColorWhiteBlack = String(localized: "settings.voice.overlay.color.white-black", defaultValue: "White + black")
            static let overlayColorSkyGlass = String(localized: "settings.voice.overlay.color.sky-glass", defaultValue: "Sky glass")
            static let overlayColorMintCream = String(localized: "settings.voice.overlay.color.mint-cream", defaultValue: "Mint cream")
            static let overlayColorLavenderMist = String(localized: "settings.voice.overlay.color.lavender-mist", defaultValue: "Lavender mist")
            static let overlayColorPeachSorbet = String(localized: "settings.voice.overlay.color.peach-sorbet", defaultValue: "Peach sorbet")
            static let overlayColorRoseQuartz = String(localized: "settings.voice.overlay.color.rose-quartz", defaultValue: "Rose quartz")
            static let overlayColorLemonCream = String(localized: "settings.voice.overlay.color.lemon-cream", defaultValue: "Lemon cream")
            static let overlayColorAquaGlass = String(localized: "settings.voice.overlay.color.aqua-glass", defaultValue: "Aqua glass")
            static let overlayColorWarmSand = String(localized: "settings.voice.overlay.color.warm-sand", defaultValue: "Warm sand")
            static let overlayColorDarkGrayWhite = String(localized: "settings.voice.overlay.color.dark-gray-white", defaultValue: "Dark gray + white")
            static let overlayColorDarkBlueCyan = String(localized: "settings.voice.overlay.color.dark-blue-cyan", defaultValue: "Dark blue + cyan")
            static let overlayColorDarkPurplePink = String(localized: "settings.voice.overlay.color.dark-purple-pink", defaultValue: "Dark purple + pink")
            static let overlayColorQuantumCyan = String(localized: "settings.voice.overlay.color.quantum-cyan", defaultValue: "Quantum cyan")
            static let overlayColorNeonTokyo = String(localized: "settings.voice.overlay.color.neon-tokyo", defaultValue: "Neon Tokyo")
            static let overlayColorAuroraMint = String(localized: "settings.voice.overlay.color.aurora-mint", defaultValue: "Aurora mint")
            static let overlayColorIonStorm = String(localized: "settings.voice.overlay.color.ion-storm", defaultValue: "Ion storm")
            static let overlayColorPlasmaCore = String(localized: "settings.voice.overlay.color.plasma-core", defaultValue: "Plasma core")
            static let overlayColorSolarFlare = String(localized: "settings.voice.overlay.color.solar-flare", defaultValue: "Solar flare")
            static let overlayColorHologram = String(localized: "settings.voice.overlay.color.hologram", defaultValue: "Hologram")
            static let overlayColorLaserGrid = String(localized: "settings.voice.overlay.color.laser-grid", defaultValue: "Laser grid")
            static let overlayColorDeepSpace = String(localized: "settings.voice.overlay.color.deep-space", defaultValue: "Deep space")
            static let overlayColorCyberSunset = String(localized: "settings.voice.overlay.color.cyber-sunset", defaultValue: "Cyber sunset")
            static let overlayColorLunarSignal = String(localized: "settings.voice.overlay.color.lunar-signal", defaultValue: "Lunar signal")
            static let overlayColorCosmicGrape = String(localized: "settings.voice.overlay.color.cosmic-grape", defaultValue: "Cosmic grape")
            static let overlayColorDarkGreenLime = String(localized: "settings.voice.overlay.color.dark-green-lime", defaultValue: "Dark green + lime")
            static let overlayColorDarkRedCoral = String(localized: "settings.voice.overlay.color.dark-red-coral", defaultValue: "Dark red + coral")
            static let overlayColorDarkGrayBlue = String(localized: "settings.voice.overlay.color.dark-gray-blue", defaultValue: "Dark gray + blue")
            static let overlayColorDarkGrayGreen = String(localized: "settings.voice.overlay.color.dark-gray-green", defaultValue: "Dark gray + green")
            static let overlayColorDarkGrayOrange = String(localized: "settings.voice.overlay.color.dark-gray-orange", defaultValue: "Dark gray + orange")
            static let overlayColorDarkGrayPink = String(localized: "settings.voice.overlay.color.dark-gray-pink", defaultValue: "Dark gray + pink")
            static let overlayColorDarkGrayPurple = String(localized: "settings.voice.overlay.color.dark-gray-purple", defaultValue: "Dark gray + purple")
            static let overlayColorDarkGrayRed = String(localized: "settings.voice.overlay.color.dark-gray-red", defaultValue: "Dark gray + red")
            static let overlayColorDarkGrayYellow = String(localized: "settings.voice.overlay.color.dark-gray-yellow", defaultValue: "Dark gray + yellow")
            static let overlayColorDarkGrayCyan = String(localized: "settings.voice.overlay.color.dark-gray-cyan", defaultValue: "Dark gray + cyan")

            static let headerTitle = String(localized: "settings.voice.header-title", defaultValue: "On-device Voice (SenseVoice)")
            static let headerDescription = String(localized: "settings.voice.header-description", defaultValue: "Push-to-talk in the composer transcribes on-device. Optional AI cleanup can polish the result after transcription.")
            static let cleanupSection = String(localized: "settings.voice.cleanup.section", defaultValue: "AI Cleanup")
            static let cleanupModeLabel = String(localized: "settings.voice.cleanup.mode", defaultValue: "After transcription")
            static let cleanupOff = String(localized: "settings.voice.cleanup.off", defaultValue: "Off")
            static let cleanupPunctuation = String(localized: "settings.voice.cleanup.punctuation", defaultValue: "Punctuation + paragraphs")
            static let cleanupBulletPoints = String(localized: "settings.voice.cleanup.bullet-points", defaultValue: "Structure into points")
            static let cleanupOffDescription = String(localized: "settings.voice.cleanup.off-description", defaultValue: "Append the local transcript exactly as produced by SenseVoice.")
            static let cleanupPunctuationDescription = String(localized: "settings.voice.cleanup.punctuation-description", defaultValue: "Use the configured AI model to add punctuation, paragraphs, and light wording cleanup without summarizing.")
            static let cleanupBulletPointsDescription = String(localized: "settings.voice.cleanup.bullet-points-description", defaultValue: "Use the configured AI model to lightly organize longer dictation into a few clear points.")
            static let cleanupPrivacyNote = String(localized: "settings.voice.cleanup.privacy-note", defaultValue: "When AI cleanup is enabled, the transcribed text is sent to your configured AI provider. Voice audio still stays on this Mac.")
            static let languageSection = String(localized: "settings.voice.language.section", defaultValue: "Transcription Language")
            static let languageLabel = String(localized: "settings.voice.language.label", defaultValue: "Language")
            static let languageDescription = String(localized: "settings.voice.language.description", defaultValue: "Follow system is the default. Choose Japanese or another fixed language when you need deterministic voice-input testing.")
            static let languageFollowSystem = String(localized: "settings.voice.language.follow-system", defaultValue: "Follow system")
            static let languageAuto = String(localized: "settings.voice.language.auto", defaultValue: "Auto detect")
            static let languageChinese = String(localized: "settings.voice.language.chinese", defaultValue: "Chinese")
            static let languageEnglish = String(localized: "settings.voice.language.english", defaultValue: "English")
            static let languageCantonese = String(localized: "settings.voice.language.cantonese", defaultValue: "Cantonese")
            static let languageJapanese = String(localized: "settings.voice.language.japanese", defaultValue: "Japanese")
            static let languageKorean = String(localized: "settings.voice.language.korean", defaultValue: "Korean")
            static let statusInstalledTitle = String(localized: "settings.voice.status-installed-title", defaultValue: "SenseVoice model installed")
            static let statusNotInstalledTitle = String(localized: "settings.voice.status-not-installed-title", defaultValue: "Model not installed yet")
            static let statusInstalledDetail = String(localized: "settings.voice.status-installed-detail", defaultValue: "Mic button in composer is enabled. Press and hold to record, release to transcribe. Tip: hold the Fn key anywhere in the app for the same push-to-talk.")
            static let statusNotInstalledDetail = String(localized: "settings.voice.status-not-installed-detail", defaultValue: "Click Download below (~937 MB). After install the mic button in composer goes live and the Fn-key push-to-talk shortcut starts working.")
            static let downloadButton = String(localized: "settings.voice.download-button", defaultValue: "Download model (~937 MB)")
            static let importButton = String(localized: "settings.voice.import-button", defaultValue: "Import from fastv (0 MB)")
            static let importHelp = String(localized: "settings.voice.import-help", defaultValue: "Symlink an existing fastv model copy — no download.")
            static let revealInFinder = String(localized: "settings.voice.reveal-in-finder", defaultValue: "Reveal in Finder")
            static let importing = String(localized: "settings.voice.importing", defaultValue: "Importing from fastv…")
            static let cancel = String(localized: "settings.voice.cancel", defaultValue: "Cancel")
            static let memorySection = String(localized: "settings.voice.memory-section", defaultValue: "Memory")
            static let preloadToggle = String(localized: "settings.voice.preload-toggle", defaultValue: "Preload on launch")
            static let preloadDescription = String(localized: "settings.voice.preload-description", defaultValue: "Keep the ~937 MB voice model out of memory at launch by default. Enable this after your first transcription if you prefer instant push-to-talk over lower idle memory.")
            static let loadedInMemory = String(localized: "settings.voice.loaded-in-memory", defaultValue: "Loaded in memory")
            static let notInMemory = String(localized: "settings.voice.not-in-memory", defaultValue: "Not in memory")
            static let unloadNow = String(localized: "settings.voice.unload-now", defaultValue: "Unload now")
            static let refreshStatusHelp = String(localized: "settings.voice.refresh-status-help", defaultValue: "Refresh status")
            static let autoUnloadNote = String(localized: "settings.voice.auto-unload-note", defaultValue: "The model also auto-unloads after 5 minutes of foreground idle, 10 minutes of background, or when the app's resident memory exceeds 4 GB.")
            static let modelLocation = String(localized: "settings.voice.model-location", defaultValue: "Model location")
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
            static let allowPairingToggle = String(localized: "settings.mobile-gateway.allow-pairing-toggle", defaultValue: "Allow new device pairing")
            static let statusLabel = String(localized: "settings.mobile-gateway.status", defaultValue: "Status")
            static let addressLabel = String(localized: "settings.mobile-gateway.address", defaultValue: "LAN address")
            static let protocolLabel = String(localized: "settings.mobile-gateway.protocol", defaultValue: "Protocol")
            static let desktopPeerLabel = String(localized: "settings.mobile-gateway.desktop-peer", defaultValue: "Desktop peer")
            static let pairingBaseURLLabel = String(localized: "settings.mobile-gateway.pairing-base-url", defaultValue: "Pairing URL")
            static let fallbackBaseURLsLabel = String(localized: "settings.mobile-gateway.fallback-base-urls", defaultValue: "Fallback URLs")
            static let expiresLabel = String(localized: "settings.mobile-gateway.expires", defaultValue: "Expires")
            static let hostPrompt = String(localized: "settings.mobile-gateway.host-prompt", defaultValue: "0.0.0.0")
            static let portInputLabel = String(localized: "settings.mobile-gateway.port-input", defaultValue: "Port")
            static let portPrompt = String(localized: "settings.mobile-gateway.port-prompt", defaultValue: "8877")
            static let desktopNamePrompt = String(localized: "settings.mobile-gateway.desktop-name-prompt", defaultValue: "Desktop name shown on Android")
            static let executablePathPrompt = String(localized: "settings.mobile-gateway.executable-path-prompt", defaultValue: "Optional willdeep-agent executable path")
            static let relayBaseURLPrompt = String(localized: "settings.mobile-gateway.relay-base-url-prompt", defaultValue: "Optional public relay URL")
            static let relayRoomPrompt = String(localized: "settings.mobile-gateway.relay-room-prompt", defaultValue: "Relay room")
            static let customRelayToggle = String(localized: "settings.mobile-gateway.custom-relay-toggle", defaultValue: "Custom relay service")
            static let customRelayDescription = String(localized: "settings.mobile-gateway.custom-relay-description", defaultValue: "Only change these if you run your own compatible WebSocket relay. The default public relay is already configured.")
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
            static let runningRelay = String(localized: "settings.mobile-gateway.running-relay", defaultValue: "Running (internet relay)")
            static let transportModeLabel = String(localized: "settings.mobile-gateway.transport-mode", defaultValue: "Connection")
            static let transportModeRelay = String(localized: "settings.mobile-gateway.transport-mode-relay", defaultValue: "Internet relay")
            static let transportModeLanGateway = String(localized: "settings.mobile-gateway.transport-mode-lan", defaultValue: "Local network")
            static let transportModeRelayCaption = String(localized: "settings.mobile-gateway.transport-mode-relay-caption", defaultValue: "Default. Connects through the public relay, so your phone works from anywhere with no local gateway to run. Session content is routed through the relay server (transport-encrypted, not yet end-to-end).")
            static let transportModeLanGatewayCaption = String(localized: "settings.mobile-gateway.transport-mode-lan-caption", defaultValue: "Fallback. Runs a local gateway process for same-network pairing with per-device tokens — useful offline or on isolated networks.")
            static let rotateRelayButton = String(localized: "settings.mobile-gateway.rotate-relay", defaultValue: "Rotate relay room")
            static let scanHintRelay = String(localized: "settings.mobile-gateway.scan-hint-relay", defaultValue: "Scan this QR code with the WillDeep Android app to pair over the internet relay. Works off your local network.")
            static let devicesRelayNote = String(localized: "settings.mobile-gateway.devices-relay-note", defaultValue: "Relay mode shares one room token instead of per-device tokens. To de-authorize a phone, rotate the relay room — every paired device must re-scan.")
            static let noPairingPayload = String(localized: "settings.mobile-gateway.no-pairing-payload", defaultValue: "Pairing is unavailable. Refresh pairing after enabling new device pairing.")
            static let startToPair = String(localized: "settings.mobile-gateway.start-to-pair", defaultValue: "Start the gateway to show a QR pairing code.")
            static let noDevices = String(localized: "settings.mobile-gateway.no-devices", defaultValue: "No Android devices are paired yet.")
            static let revoked = String(localized: "settings.mobile-gateway.revoked", defaultValue: "Revoked")
            static let qrAccessibilityLabel = String(localized: "settings.mobile-gateway.qr-accessibility-label", defaultValue: "Mobile Gateway pairing QR code")
            static let qrUnavailable = String(localized: "settings.mobile-gateway.qr-unavailable", defaultValue: "QR code unavailable")
            static let listenDescription = String(localized: "settings.mobile-gateway.listen-description", defaultValue: "The gateway listens only after you enable it. Android connects over the local network; Agent execution, tools, patches, and file access still run through the Mac app.")
            static let advancedToggle = String(localized: "settings.mobile-gateway.advanced-toggle", defaultValue: "Show advanced info (IP / port / executable)")
            static let logSection = String(localized: "settings.mobile-gateway.log-section", defaultValue: "Gateway log")
            static let scanHint = String(localized: "settings.mobile-gateway.scan-hint", defaultValue: "Scan this QR code with the WillDeep Android app to pair over your local network.")
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
            static let terminalSection = String(localized: "settings.remote-runtimes.terminal-section", defaultValue: "Interactive Terminal")
            static let terminalAutoRunLabel = String(localized: "settings.remote-runtimes.terminal-auto-run", defaultValue: "Run terminal startup queue after connect")
            static let terminalStartupDirectoryLabel = String(localized: "settings.remote-runtimes.terminal-startup-directory", defaultValue: "Startup directory")
            static let terminalStartupDirectoryPrompt = String(localized: "settings.remote-runtimes.terminal-startup-directory.prompt", defaultValue: "/var/www/app")
            static let terminalStartupCommandsLabel = String(localized: "settings.remote-runtimes.terminal-startup-commands", defaultValue: "Auto commands")
            static let terminalStartupCommandsHelp = String(localized: "settings.remote-runtimes.terminal-startup-commands.help", defaultValue: "One command per line. These run before jump commands.")
            static let terminalJumpCommandsLabel = String(localized: "settings.remote-runtimes.terminal-jump-commands", defaultValue: "Jump commands")
            static let terminalJumpCommandsHelp = String(localized: "settings.remote-runtimes.terminal-jump-commands.help", defaultValue: "One command per line. These run after auto commands, for bastion or second-hop shells.")
            static let terminalDelayLabel = String(localized: "settings.remote-runtimes.terminal-delay", defaultValue: "Command delay (ms)")
            static let terminalDelayPrompt = String(localized: "settings.remote-runtimes.terminal-delay.prompt", defaultValue: "450")
            static let terminalIdleTimeoutLabel = String(localized: "settings.remote-runtimes.terminal-idle-timeout", defaultValue: "Idle timeout (s)")
            static let terminalIdleTimeoutPrompt = String(localized: "settings.remote-runtimes.terminal-idle-timeout.prompt", defaultValue: "5")
            static let terminalServicesLabel = String(localized: "settings.remote-runtimes.terminal-services", defaultValue: "Common services")
            static let terminalServicesHelp = String(localized: "settings.remote-runtimes.terminal-services.help", defaultValue: "One service name per line for the Agent Terminal service menu.")
            static let terminalDescription = String(localized: "settings.remote-runtimes.terminal-description", defaultValue: "The Agent Terminal uses an interactive SSH PTY. User typing goes straight to the terminal; AI command input still requires approval.")
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
            static let protocolOpenAIChat = String(localized: "settings.provider.protocol-openai-chat", defaultValue: "OpenAI Chat")
            static let protocolAnthropicMessages = String(localized: "settings.provider.protocol-anthropic-messages", defaultValue: "Anthropic Messages")
            static let protocolGoogleGemini = String(localized: "settings.provider.protocol-google-gemini", defaultValue: "Google Gemini")
            static let protocolOpenAIResponses = String(localized: "settings.provider.protocol-openai-responses", defaultValue: "OpenAI Responses")
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
            static let showAlternatesToggle = String(localized: "settings.provider.show-alternates-toggle", defaultValue: "Show alternate models")
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
            static let recommendedServers = String(localized: "settings.mcp.recommended-servers", defaultValue: "Recommended MCP Servers")
            static let recommendedDescription = String(localized: "settings.mcp.recommended-description", defaultValue: "Add common MCP servers with safe defaults. Playwright uses npx -y so first launch does not stop at an interactive install prompt.")
            static let addPreset = String(localized: "settings.mcp.add-preset", defaultValue: "Add")
            static let playwrightPresetTitle = String(localized: "settings.mcp.playwright-preset-title", defaultValue: "Playwright MCP")
            static let playwrightChinaPresetTitle = String(localized: "settings.mcp.playwright-china-preset-title", defaultValue: "Playwright MCP (China mirror)")
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

        enum Connectors {
            static let description = String(localized: "settings.connectors.description", defaultValue: "Manage team collaboration platforms that WillDeep can use for notifications, commands, and document publishing.")
            static let platformsSection = String(localized: "settings.connectors.platforms-section", defaultValue: "Platforms")
            static let capabilitiesSection = String(localized: "settings.connectors.capabilities-section", defaultValue: "Capabilities")
            static let safetySection = String(localized: "settings.connectors.safety-section", defaultValue: "Safety")
            static let experimentalBadge = String(localized: "settings.connectors.experimental", defaultValue: "Experimental")
            static let enabledToggle = String(localized: "settings.connectors.enabled-toggle", defaultValue: "Enable connector")
            static let authModeLabel = String(localized: "settings.connectors.auth-mode", defaultValue: "Authorization")
            static let connectionStateLabel = String(localized: "settings.connectors.connection-state", defaultValue: "State")
            static let appIDLabel = String(localized: "settings.connectors.app-id", defaultValue: "App ID")
            static let appIDPrompt = String(localized: "settings.connectors.app-id-prompt", defaultValue: "Platform app_id / client_id")
            static let tenantIDLabel = String(localized: "settings.connectors.tenant-id", defaultValue: "Tenant / Corp ID")
            static let tenantIDPrompt = String(localized: "settings.connectors.tenant-id-prompt", defaultValue: "Optional enterprise identifier")
            static let redirectURILabel = String(localized: "settings.connectors.redirect-uri", defaultValue: "Redirect URI")
            static let redirectURIPrompt = String(localized: "settings.connectors.redirect-uri-prompt", defaultValue: "https://fly.niuwoai.com/oauth/<platform>/callback")
            static let authorizationURLLabel = String(localized: "settings.connectors.authorization-url", defaultValue: "Authorization URL")
            static let authorizationURLPrompt = String(localized: "settings.connectors.authorization-url-prompt", defaultValue: "https://... or URL with {client_id}, {redirect_uri}, {state}")
            static let credentialReferenceLabel = String(localized: "settings.connectors.credential-reference", defaultValue: "Credential reference")
            static let credentialReferencePrompt = String(localized: "settings.connectors.credential-reference-prompt", defaultValue: "Keychain item or env name, not the secret itself")
            static let defaultSpaceLabel = String(localized: "settings.connectors.default-space", defaultValue: "Default doc space")
            static let defaultSpacePrompt = String(localized: "settings.connectors.default-space-prompt", defaultValue: "Folder, wiki, or drive token")
            static let defaultChatLabel = String(localized: "settings.connectors.default-chat", defaultValue: "Default chat")
            static let defaultChatPrompt = String(localized: "settings.connectors.default-chat-prompt", defaultValue: "Group, robot, or conversation ID")
            static let writePolicyLabel = String(localized: "settings.connectors.write-policy", defaultValue: "Write policy")
            static let cloudRelayToggle = String(localized: "settings.connectors.cloud-relay", defaultValue: "Use WillDeep Cloud Relay for incoming events")
            static let cloudRelayDescription = String(localized: "settings.connectors.cloud-relay-description", defaultValue: "Incoming @mentions need a public callback. Cloud Relay can receive platform events and forward them to this Mac when it is online.")
            static let secretStorageNote = String(localized: "settings.connectors.secret-storage-note", defaultValue: "Secrets and OAuth tokens should live in macOS Keychain. This panel stores only non-sensitive routing metadata.")
            static let authorizationURLHelp = String(localized: "settings.connectors.authorization-url-help", defaultValue: "Leave empty to only prepare the callback and Keychain reference. When filled, WillDeep appends standard OAuth query parameters unless placeholders are present.")
            static let prepareAuthorization = String(localized: "settings.connectors.prepare-authorization", defaultValue: "Prepare authorization")
            static let generateQRCode = String(localized: "settings.connectors.generate-qr-code", defaultValue: "Generate QR code")
            static let openAuthorization = String(localized: "settings.connectors.open-authorization", defaultValue: "Open authorization")
            static let copyAuthorizationURL = String(localized: "settings.connectors.copy-authorization-url", defaultValue: "Copy authorization URL")
            static let copyRedirectURI = String(localized: "settings.connectors.copy-redirect-uri", defaultValue: "Copy redirect URI")
            static let clearCredentials = String(localized: "settings.connectors.clear-credentials", defaultValue: "Clear credentials")
            static let openDocs = String(localized: "settings.connectors.open-docs", defaultValue: "Open docs")
            static let advancedConfiguration = String(localized: "settings.connectors.advanced-configuration", defaultValue: "Advanced configuration")
            static let larkCLIConfigureApp = String(localized: "settings.connectors.lark-cli.configure-app", defaultValue: "Configure app")
            static let larkCLILogin = String(localized: "settings.connectors.lark-cli.login", defaultValue: "Login")
            static let larkCLIInstall = String(localized: "settings.connectors.lark-cli.install", defaultValue: "Install lark-cli")
            static let larkCLIVerify = String(localized: "settings.connectors.lark-cli.verify", defaultValue: "Verify status")
            static let larkCLIHelp = String(localized: "settings.connectors.lark-cli.help", defaultValue: "Official lark-cli is the recommended local bridge for active Feishu operations. It stores credentials in the OS keychain and lets WillDeep call Feishu with structured commands instead of raw shell.")
            static let larkCLINotInstalled = String(localized: "settings.connectors.lark-cli.not-installed", defaultValue: "lark-cli not found")
            static let larkCLIInstalling = String(localized: "settings.connectors.lark-cli.installing", defaultValue: "Installing official lark-cli...")
            static let larkCLIInstallSucceeded = String(localized: "settings.connectors.lark-cli.install-succeeded", defaultValue: "Official lark-cli installed.")
            static let larkCLIConfigStarted = String(localized: "settings.connectors.lark-cli.config-started", defaultValue: "Starting lark-cli app configuration...")
            static let larkCLIConfigFinished = String(localized: "settings.connectors.lark-cli.config-finished", defaultValue: "lark-cli app configuration finished.")
            static let larkCLILoginStarted = String(localized: "settings.connectors.lark-cli.login-started", defaultValue: "Starting lark-cli login...")
            static let larkCLILoginFinished = String(localized: "settings.connectors.lark-cli.login-finished", defaultValue: "lark-cli login command finished.")
            static let larkCLIVerifying = String(localized: "settings.connectors.lark-cli.verifying", defaultValue: "Checking lark-cli authorization...")
            static let larkCLIVerified = String(localized: "settings.connectors.lark-cli.verified", defaultValue: "lark-cli authorization verified.")
            static let larkCLIQRCodeReady = String(localized: "settings.connectors.lark-cli.qr-ready", defaultValue: "lark-cli authorization QR code is ready.")
            static let dingtalkMCPConfigure = String(localized: "settings.connectors.dingtalk-mcp.configure", defaultValue: "Configure official MCP")
            static let dingtalkMCPHelp = String(localized: "settings.connectors.dingtalk-mcp.help", defaultValue: "DingTalk does not currently expose a lark-cli-style official CLI. Use the official DingTalk MCP server as the preferred local tool bridge; event intake can still use Stream SDK or relay callbacks.")
            static let dingtalkMCPCapability = String(localized: "settings.connectors.dingtalk-mcp.capability", defaultValue: "DingTalk official MCP tools")
            static let dingtalkMCPInstallHint = String(localized: "settings.connectors.dingtalk-mcp.install-hint", defaultValue: "Uses stdio: npx -y dingtalk-mcp@latest. Fill DINGTALK_Client_ID and DINGTALK_Client_Secret from the DingTalk developer console; keep secrets out of git.")
            static let dingtalkMCPReason = String(localized: "settings.connectors.dingtalk-mcp.reason", defaultValue: "DingTalk's practical official integration path is MCP for active tool calls, plus Stream SDK or relay callbacks for incoming events.")
            static let dingtalkMCPDraftOpened = String(localized: "settings.connectors.dingtalk-mcp.draft-opened", defaultValue: "Opened DingTalk MCP setup draft.")
            static let feishuDocsNote = String(localized: "settings.connectors.feishu-docs-note", defaultValue: "Feishu document writing is feasible through OpenAPI after OAuth scopes are granted. WillDeep should preview generated docs before publishing.")
            static let feishuQRCodeHelp = String(localized: "settings.connectors.feishu-qr-help", defaultValue: "Scan this QR code with Feishu to configure WillDeep. Custom App ID setup is available under Advanced configuration.")
            static let feishuQRCodeReady = String(localized: "settings.connectors.feishu-qr-ready", defaultValue: "Ready to scan with Feishu")
            static let feishuQRCodeAccessibilityLabel = String(localized: "settings.connectors.feishu-qr-accessibility-label", defaultValue: "Feishu authorization QR code")
            static let feishuQRCodeUnavailable = String(localized: "settings.connectors.feishu-qr-unavailable", defaultValue: "Authorization QR code unavailable")
            static let feishuQRCodePlaceholderTitle = String(localized: "settings.connectors.feishu-qr-placeholder-title", defaultValue: "No authorization QR yet")
            static let feishuQRCodePlaceholderDescription = String(localized: "settings.connectors.feishu-qr-placeholder-description", defaultValue: "WillDeep prepares a short-lived setup link when this panel opens.")

            static let platformFeishu = String(localized: "settings.connectors.platform.feishu", defaultValue: "Feishu")
            static let platformDingTalk = String(localized: "settings.connectors.platform.dingtalk", defaultValue: "DingTalk")
            static let platformWeCom = String(localized: "settings.connectors.platform.wecom", defaultValue: "WeCom")
            static let platformWechatClaw = String(localized: "settings.connectors.platform.wechat-claw", defaultValue: "WeChat / Claw")
            static let summaryFeishu = String(localized: "settings.connectors.summary.feishu", defaultValue: "Best first target for OAuth, bots, and AI-generated docs.")
            static let summaryDingTalk = String(localized: "settings.connectors.summary.dingtalk", defaultValue: "Good for enterprise bots, approvals, and operational notifications.")
            static let summaryWeCom = String(localized: "settings.connectors.summary.wecom", defaultValue: "Official bridge for WeChat-style enterprise messaging.")
            static let summaryWechatClaw = String(localized: "settings.connectors.summary.wechat-claw", defaultValue: "Desktop automation bridge for personal workflows; keep it out of production defaults.")

            static let authWebhook = String(localized: "settings.connectors.auth.webhook", defaultValue: "Webhook")
            static let authOfficialLarkCLI = String(localized: "settings.connectors.auth.official-lark-cli", defaultValue: "Official lark-cli")
            static let authOfficialMCP = String(localized: "settings.connectors.auth.official-mcp", defaultValue: "Official MCP")
            static let authOAuth = String(localized: "settings.connectors.auth.oauth", defaultValue: "OAuth")
            static let authCloudRelay = String(localized: "settings.connectors.auth.cloud-relay", defaultValue: "Cloud Relay")
            static let authDesktopAutomation = String(localized: "settings.connectors.auth.desktop-automation", defaultValue: "Desktop automation")
            static let authWebhookHelp = String(localized: "settings.connectors.auth.webhook-help", defaultValue: "One-way robot messages and simple slash-like workflows. Fast to set up, limited user context.")
            static let authOfficialLarkCLIHelp = String(localized: "settings.connectors.auth.official-lark-cli-help", defaultValue: "Use Feishu/Lark's official CLI for local app setup, OAuth login, and active docs/messages/calendar operations.")
            static let authOfficialMCPHelp = String(localized: "settings.connectors.auth.official-mcp-help", defaultValue: "Use the platform's official MCP server as the active tool bridge. Credentials still need explicit user configuration.")
            static let authOAuthHelp = String(localized: "settings.connectors.auth.oauth-help", defaultValue: "User-authorized access for docs, drive, chat, and future write actions. Tokens belong in Keychain.")
            static let authCloudRelayHelp = String(localized: "settings.connectors.auth.cloud-relay-help", defaultValue: "Public event callbacks land in WillDeep Cloud Relay, then forward to the Mac app.")
            static let authDesktopAutomationHelp = String(localized: "settings.connectors.auth.desktop-automation-help", defaultValue: "Local GUI automation for personal workflows. Useful as a fallback, fragile for teams.")

            static let stateNotConfigured = String(localized: "settings.connectors.state.not-configured", defaultValue: "Not configured")
            static let stateReady = String(localized: "settings.connectors.state.ready", defaultValue: "Ready to authorize")
            static let stateConnected = String(localized: "settings.connectors.state.connected", defaultValue: "Connected")
            static let stateNeedsReview = String(localized: "settings.connectors.state.needs-review", defaultValue: "Needs review")

            static let capabilitySendMessages = String(localized: "settings.connectors.capability.send-messages", defaultValue: "Send messages")
            static let capabilityReceiveCommands = String(localized: "settings.connectors.capability.receive-commands", defaultValue: "Receive @mentions and commands")
            static let capabilityCreateDocs = String(localized: "settings.connectors.capability.create-docs", defaultValue: "Create documents")
            static let capabilityEditDocs = String(localized: "settings.connectors.capability.edit-docs", defaultValue: "Edit existing documents")
            static let capabilityImportDocs = String(localized: "settings.connectors.capability.import-docs", defaultValue: "Import documents as context")
            static let capabilityCalendar = String(localized: "settings.connectors.capability.calendar", defaultValue: "Calendar context")
            static let capabilityTasks = String(localized: "settings.connectors.capability.tasks", defaultValue: "Tasks")
            static let capabilityApprovals = String(localized: "settings.connectors.capability.approvals", defaultValue: "Approvals")
            static let capabilityDesktopAutomation = String(localized: "settings.connectors.capability.desktop-automation", defaultValue: "Desktop automation")

            static let policyPreviewThenPublish = String(localized: "settings.connectors.policy.preview-then-publish", defaultValue: "Preview before publish")
            static let policyAskEveryTime = String(localized: "settings.connectors.policy.ask-every-time", defaultValue: "Ask every time")
            static let policyAllowNewDocs = String(localized: "settings.connectors.policy.allow-new-docs", defaultValue: "Allow new docs only")

            static func enabledCount(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.connectors.enabled-count", defaultValue: "%1$@ of %2$@ connectors enabled")
                return String(format: template, a1, a2)
            }
            static func configurationSection(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.configuration-section", defaultValue: "%@ Configuration")
                return String(format: template, a1)
            }
            static func statusLine(_ a1: String, _ a2: String, _ a3: String) -> String {
                let template = String(localized: "settings.connectors.status-line", defaultValue: "%1$@ · %2$@ · %3$@ capabilities")
                return String(format: template, a1, a2, a3)
            }
            static func authorizationPrepared(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-prepared", defaultValue: "%@ is ready for OAuth wiring.")
                return String(format: template, a1)
            }
            static func authorizationOpened(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-opened", defaultValue: "%@ authorization page opened.")
                return String(format: template, a1)
            }
            static func authorizationQRCodeReady(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-qr-ready", defaultValue: "%@ authorization QR code is ready.")
                return String(format: template, a1)
            }
            static func authorizationURLCopied(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-url-copied", defaultValue: "%@ authorization URL copied.")
                return String(format: template, a1)
            }
            static func authorizationNeedsAppID(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-needs-app-id", defaultValue: "Add an App ID before preparing %@ authorization.")
                return String(format: template, a1)
            }
            static func redirectURICopied(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.redirect-uri-copied", defaultValue: "%@ redirect URI copied.")
                return String(format: template, a1)
            }
            static func credentialsCleared(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.credentials-cleared", defaultValue: "%@ local credentials cleared.")
                return String(format: template, a1)
            }
            static func larkCLIInstalled(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.lark-cli.installed", defaultValue: "Installed: %@")
                return String(format: template, a1)
            }
            static func larkCLICommandFailed(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.lark-cli.command-failed", defaultValue: "lark-cli failed: %@")
                return String(format: template, a1)
            }
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
            static let deleteUserSkill = String(localized: "settings.skill.delete-user-skill", defaultValue: "Delete")
            static let deleteUserSkillHelp = String(localized: "settings.skill.delete-user-skill-help", defaultValue: "Delete this user skill")
            static let deleteUserSkillMessage = String(localized: "settings.skill.delete-user-skill-message", defaultValue: "This removes the user skill folder from disk. Built-in and plugin skills are not affected.")
            static let deleteUserSkillConfirm = String(localized: "settings.skill.delete-user-skill-confirm", defaultValue: "Delete")
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
            static func deleteUserSkillTitle(_ a1: String) -> String {
                let template = String(localized: "settings.skill.delete-user-skill-title", defaultValue: "Delete %@?")
                return String(format: template, a1)
            }
            static func deletedUserSkill(_ a1: String) -> String {
                let template = String(localized: "settings.skill.deleted-user-skill", defaultValue: "Deleted %@.")
                return String(format: template, a1)
            }
            static func deleteUserSkillFailed(_ a1: String) -> String {
                let template = String(localized: "settings.skill.delete-user-skill-failed", defaultValue: "Could not delete skill: %@")
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
            static func projectPathLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-path-line", defaultValue: "Project: %@")
                return String(format: template, a1)
            }
            static func projectUnknownLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-unknown-line", defaultValue: "Unknown project (fingerprint %@) — edit and re-save as Project while the workspace is open to rebind")
                return String(format: template, a1)
            }
            static let scopeFilterLabel = String(localized: "settings.memory.scope-filter", defaultValue: "Show")
            static let scopeFilterAll = String(localized: "settings.memory.scope-filter-all", defaultValue: "All")
            static let scopeFilterGlobal = String(localized: "settings.memory.scope-filter-global", defaultValue: "Global only")
            static let scopeFilterCurrentProject = String(localized: "settings.memory.scope-filter-current-project", defaultValue: "This workspace")
            static let currentProjectTag = String(localized: "settings.memory.current-project-tag", defaultValue: "Current workspace")
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
        static let turnReportTitle = String(localized: "transcript.turn-report.title", defaultValue: "Agent turn report")
        static func turnReportSubtitle(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "transcript.turn-report.subtitle", defaultValue: "%1$@ · %2$@")
            return String(format: template, a1, a2)
        }
        static let turnReportCopyHelp = String(localized: "transcript.turn-report.copy-help", defaultValue: "Copy turn report")
        static let turnReportCopied = String(localized: "transcript.turn-report.copied", defaultValue: "Copied")
        static let turnReportModel = String(localized: "transcript.turn-report.model", defaultValue: "Model")
        static let turnReportProvider = String(localized: "transcript.turn-report.provider", defaultValue: "Provider")
        static let turnReportMode = String(localized: "transcript.turn-report.mode", defaultValue: "Mode")
        static let turnReportApprovalMode = String(localized: "transcript.turn-report.approval-mode", defaultValue: "Approval mode")
        static let turnReportTools = String(localized: "transcript.turn-report.tools", defaultValue: "Tools")
        static func turnReportToolsInline(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.tools-inline", defaultValue: "%@ tools")
            return String(format: template, a1)
        }
        static func turnReportShowRemaining(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.show-remaining", defaultValue: "Show remaining %@")
            return String(format: template, a1)
        }
        static let turnReportShowLess = String(localized: "transcript.turn-report.show-less", defaultValue: "Show less")
        static let turnReportApprovals = String(localized: "transcript.turn-report.approvals", defaultValue: "Approvals")
        static let turnReportLearning = String(localized: "transcript.turn-report.learning", defaultValue: "Learning")
        static let turnReportElapsed = String(localized: "transcript.turn-report.elapsed", defaultValue: "Elapsed")
        static let turnReportTokens = String(localized: "transcript.turn-report.tokens", defaultValue: "Tokens")
        static let turnReportRecall = String(localized: "transcript.turn-report.recall", defaultValue: "Recall")
        static let turnReportRecallSection = String(localized: "transcript.turn-report.recall-section", defaultValue: "Recalled context")
        static func turnReportRecallSummary(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "transcript.turn-report.recall-summary", defaultValue: "%1$@ memories · %2$@ skills")
            return String(format: template, a1, a2)
        }
        static let turnReportRecallMemory = String(localized: "transcript.turn-report.recall.memory", defaultValue: "Memory")
        static let turnReportRecallSkill = String(localized: "transcript.turn-report.recall.skill", defaultValue: "Skill")
        static func turnReportRecallScore(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.recall.score", defaultValue: "Score %@")
            return String(format: template, a1)
        }
        static let turnReportLearningSection = String(localized: "transcript.turn-report.learning-section", defaultValue: "Learning actions")
        static func turnReportApprovalSummary(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "transcript.turn-report.approval-summary", defaultValue: "%1$@ auto-approved / %2$@ user-approved")
            return String(format: template, a1, a2)
        }
        static func turnReportSucceeded(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.succeeded", defaultValue: "%@ succeeded")
            return String(format: template, a1)
        }
        static func turnReportFailed(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.failed", defaultValue: "%@ failed")
            return String(format: template, a1)
        }
        static func turnReportDenied(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.denied", defaultValue: "%@ denied")
            return String(format: template, a1)
        }
        static func turnReportEscalated(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.escalated", defaultValue: "%@ escalated")
            return String(format: template, a1)
        }
        static func turnReportSandbox(_ a1: String) -> String {
            let template = String(localized: "transcript.turn-report.sandbox", defaultValue: "Sandbox: %@")
            return String(format: template, a1)
        }
        static let turnReportStatusPendingApproval = String(localized: "transcript.turn-report.status.pending-approval", defaultValue: "Pending approval")
        static let turnReportStatusAwaitingConfirm = String(localized: "transcript.turn-report.status.awaiting-confirm", defaultValue: "Awaiting confirm")
        static let turnReportStatusAwaitingAnswer = String(localized: "transcript.turn-report.status.awaiting-answer", defaultValue: "Awaiting answer")
        static let turnReportStatusRunning = String(localized: "transcript.turn-report.status.running", defaultValue: "Running")
        static let turnReportStatusSucceeded = String(localized: "transcript.turn-report.status.succeeded", defaultValue: "Succeeded")
        static let turnReportStatusFailed = String(localized: "transcript.turn-report.status.failed", defaultValue: "Failed")
        static let turnReportStatusDenied = String(localized: "transcript.turn-report.status.denied", defaultValue: "Denied")
        static let turnReportApprovalUser = String(localized: "transcript.turn-report.approval.user", defaultValue: "User approved")
        static let turnReportApprovalAlwaysAllow = String(localized: "transcript.turn-report.approval.always-allow", defaultValue: "Always allow")
        static let turnReportApprovalControlLease = String(localized: "transcript.turn-report.approval.control-lease", defaultValue: "Control lease")
        static let turnReportApprovalStatic = String(localized: "transcript.turn-report.approval.static", defaultValue: "Static allow")
        static let turnReportApprovalJudge = String(localized: "transcript.turn-report.approval.judge", defaultValue: "Judge allow")
        static let turnReportApprovalGoal = String(localized: "transcript.turn-report.approval.goal", defaultValue: "Goal mode")
        static let turnReportApprovalWorkspace = String(localized: "transcript.turn-report.approval.workspace", defaultValue: "Workspace access")
        static let turnReportApprovalEscalated = String(localized: "transcript.turn-report.approval.escalated", defaultValue: "Escalated")
        static let turnReportApprovalTrustedServer = String(localized: "transcript.turn-report.approval.trusted-server", defaultValue: "Trusted server")

        static let learningCardTitle = String(localized: "transcript.learning.title", defaultValue: "Agent learned from this turn")
        static func learningCardSubtitle(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.subtitle", defaultValue: "%@ recent learning events")
            return String(format: template, a1)
        }
        static func learningMore(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.more", defaultValue: "%@ more learning events hidden")
            return String(format: template, a1)
        }
        static let learningKindMemory = String(localized: "transcript.learning.kind.memory", defaultValue: "Memory")
        static let learningKindSkill = String(localized: "transcript.learning.kind.skill", defaultValue: "Skill")
        static let learningKindMCP = String(localized: "transcript.learning.kind.mcp", defaultValue: "MCP")
        static let learningStatusSaved = String(localized: "transcript.learning.status.saved", defaultValue: "Saved")
        static let learningStatusCreated = String(localized: "transcript.learning.status.created", defaultValue: "Created")
        static let learningStatusSuggested = String(localized: "transcript.learning.status.suggested", defaultValue: "Suggested")
        static let learningStatusSkipped = String(localized: "transcript.learning.status.skipped", defaultValue: "Skipped")
        static let learningStatusFailed = String(localized: "transcript.learning.status.failed", defaultValue: "Failed")
        static let learningActionSaveMemory = String(localized: "transcript.learning.action.save-memory", defaultValue: "Saved memory")
        static let learningActionCreateSkill = String(localized: "transcript.learning.action.create-skill", defaultValue: "Created skill")
        static let learningActionProposeSkill = String(localized: "transcript.learning.action.propose-skill", defaultValue: "Skill candidate")
        static let learningActionSearchMCP = String(localized: "transcript.learning.action.search-mcp", defaultValue: "Search MCP")
        static let learningActionSuggestMCPInstall = String(localized: "transcript.learning.action.suggest-mcp-install", defaultValue: "Suggest MCP install")
        static let learningActionNeedsConfirmation = String(localized: "transcript.learning.action.needs-confirmation", defaultValue: "Needs user confirmation")
        static let learningConfidenceLow = String(localized: "transcript.learning.confidence.low", defaultValue: "Low confidence")
        static let learningConfidenceMedium = String(localized: "transcript.learning.confidence.medium", defaultValue: "Medium confidence")
        static let learningConfidenceHigh = String(localized: "transcript.learning.confidence.high", defaultValue: "High confidence")
        static let learningConfidenceLowShort = String(localized: "transcript.learning.confidence.low.short", defaultValue: "L")
        static let learningConfidenceMediumShort = String(localized: "transcript.learning.confidence.medium.short", defaultValue: "M")
        static let learningConfidenceHighShort = String(localized: "transcript.learning.confidence.high.short", defaultValue: "H")
        static let learningExplanationCompleted = String(localized: "transcript.learning.explanation.completed", defaultValue: "This learning event was completed automatically and persisted successfully.")
        static let learningExplanationNeedsReview = String(localized: "transcript.learning.explanation.needs-review", defaultValue: "The turn produced a visible suggestion, but it still expects user review before anything changes.")
        static let learningExplanationCouldNotFinish = String(localized: "transcript.learning.explanation.could-not-finish", defaultValue: "The system recorded the signal, but it could not safely finish the intended learning step.")
        static let learningExplanationAutomaticStepFailed = String(localized: "transcript.learning.explanation.automatic-step-failed", defaultValue: "A reusable candidate was detected, but the automatic write or configuration step failed.")
        static let learningExplanationNotEnoughEvidence = String(localized: "transcript.learning.explanation.not-enough-evidence", defaultValue: "The turn mentioned a reusable workflow, but there was not enough executed tool evidence to safely act on it.")
        static let learningExplanationCompletedFromDirectEvidence = String(localized: "transcript.learning.explanation.completed-from-direct-evidence", defaultValue: "The turn had direct evidence and the learning action already completed automatically.")
        static let learningExplanationDraftNeedsReview = String(localized: "transcript.learning.explanation.draft-needs-review", defaultValue: "A reusable workflow was detected strongly enough to draft a skill, but the final wording is left for review.")
        static let learningExplanationSignalTooThin = String(localized: "transcript.learning.explanation.signal-too-thin", defaultValue: "A possible skill signal was noticed, but the evidence was too thin to produce a structured draft.")
        static let learningExplanationMCPNeedsConfirmation = String(localized: "transcript.learning.explanation.mcp-needs-confirmation", defaultValue: "An external capability gap matched MCP discovery rules, but installation and credentials still require user confirmation.")
        static func learningActionCommand(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.command", defaultValue: "Tool: %@")
            return String(format: template, a1)
        }
        static func learningActionTarget(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.target", defaultValue: "Target: %@")
            return String(format: template, a1)
        }
        static func learningActionSearchQuery(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.search-query", defaultValue: "Search: %@")
            return String(format: template, a1)
        }
        static func learningActionNextStep(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.next-step", defaultValue: "Next: %@")
            return String(format: template, a1)
        }
        static func learningActionReason(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.reason", defaultValue: "Reason: %@")
            return String(format: template, a1)
        }
        static func learningActionConfidence(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.confidence", defaultValue: "Confidence: %@")
            return String(format: template, a1)
        }
        static func learningActionWhy(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.action.why", defaultValue: "Why: %@")
            return String(format: template, a1)
        }
        static func learningRelatedRecall(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.related-recall", defaultValue: "Related recall: %@")
            return String(format: template, a1)
        }
        static func learningRecallReasonTitle(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.recall-reason.title", defaultValue: "matched “%@” by name")
            return String(format: template, a1)
        }
        static func learningRecallReasonKeywords(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.recall-reason.keywords", defaultValue: "shared keywords: %@")
            return String(format: template, a1)
        }
        static func learningRecallReasonWithRecall(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "transcript.learning.recall-reason.with-recall", defaultValue: "%@ · recalled at %@")
            return String(format: template, a1, a2)
        }
        static func learningRecallNearMiss(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.recall-near-miss", defaultValue: "not linked — only shared “%@” (needs ≥2 keywords)")
            return String(format: template, a1)
        }
        static let learningRecallLinkedTag = String(localized: "transcript.learning.recall-linked-tag", defaultValue: "linked to a learning suggestion")
        static func learningRecallUtilization(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "transcript.learning.recall-utilization", defaultValue: "%@ linked · %@ near-miss · %@ unused")
            return String(format: template, a1, a2, a3)
        }
        static let learningRecallNoLearning = String(localized: "transcript.learning.recall-no-learning", defaultValue: "no learning suggestions this turn — nothing to link")
        static let learningRecallStrengthStrong = String(localized: "transcript.learning.recall-strength.strong", defaultValue: "strong")
        static let learningRecallStrengthRelated = String(localized: "transcript.learning.recall-strength.related", defaultValue: "related")
        static let learningRecallStrengthWeak = String(localized: "transcript.learning.recall-strength.weak", defaultValue: "weak")
        static let learningCopyHelp = String(localized: "transcript.learning.copy-help", defaultValue: "Copy learning event details")
        static let learningCopied = String(localized: "transcript.learning.copied", defaultValue: "Copied")
        static let learningApproved = String(localized: "transcript.learning.approved", defaultValue: "Saved")
        // 1.96.0-rc2:event title / 字段内容也走 i18n,简体中文用户
        // 看不懂英文模板;这些 key 在 Localizable.xcstrings 同步加了 zh-Hans。
        static func learningEventTitleConversationMemories(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.conversation-memories", defaultValue: "Suggested %@ conversation memory item(s) (pending your Approve)")
            return String(format: template, a1)
        }
        static func learningEventTitleSelfLearningMemories(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.self-learning-memories", defaultValue: "Suggested %@ self-learning memory item(s) (pending your Approve)")
            return String(format: template, a1)
        }
        static func learningEventTitleSuggestedMemories(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.suggested-memories", defaultValue: "Suggest saving %@ memory item(s)")
            return String(format: template, a1)
        }
        static func learningEventTitleMCPDiscovery(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.mcp-discovery", defaultValue: "Suggested MCP discovery for %@")
            return String(format: template, a1)
        }
        static func learningEventTitleSkippedExistingSkill(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.skipped-existing-skill", defaultValue: "Skipped existing user skill %@")
            return String(format: template, a1)
        }
        static let learningEventTitleSkippedAutoSkill = String(localized: "transcript.learning.event-title.skipped-auto-skill", defaultValue: "Skipped automatic skill creation")
        static func learningEventTitleCreatedSkill(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.event-title.created-skill", defaultValue: "Created user skill %@")
            return String(format: template, a1)
        }
        static let learningEventTitleAutoSkillFailed = String(localized: "transcript.learning.event-title.auto-skill-failed", defaultValue: "Automatic skill creation failed")
        static let learningTargetGlobalMemory = String(localized: "transcript.learning.target.global-memory", defaultValue: "global memory")
        static let learningTargetProjectMemory = String(localized: "transcript.learning.target.project-memory", defaultValue: "project memory")
        static let learningReasonConversationContext = String(localized: "transcript.learning.reason.conversation-context", defaultValue: "The latest turn exposed durable conversation context.")
        static let learningReasonSelfLearningPolicy = String(localized: "transcript.learning.reason.self-learning-policy", defaultValue: "The turn contained durable self-learning policy or integration guidance.")
        static let learningReasonSkillEvidenceTooThin = String(localized: "transcript.learning.reason.skill-evidence-too-thin", defaultValue: "The turn mentioned reusable skills, but there was not enough executed tool evidence to safely create one.")
        static let learningReasonSkillAlreadyExists = String(localized: "transcript.learning.reason.skill-already-exists", defaultValue: "A reusable workflow was detected, but the matching skill already exists.")
        static let learningReasonSkillWriteFailed = String(localized: "transcript.learning.reason.skill-write-failed", defaultValue: "A reusable workflow was detected, but writing the user skill failed.")
        static let learningMemorySuggestionUse = String(localized: "transcript.learning.memory-suggestion.use", defaultValue: "Use: Refer to this in future related turns.")
        static let learningMemorySuggestionAction = String(localized: "transcript.learning.memory-suggestion.action", defaultValue: "Action: Save to memory after confirmation.")
        static func learningMemorySuggestionMore(_ a1: String) -> String {
            let template = String(localized: "transcript.learning.memory-suggestion.more", defaultValue: "+%@ more")
            return String(format: template, a1)
        }
        static let learningNextStepApprovePopover = String(localized: "transcript.learning.next-step.approve-popover", defaultValue: "Click Approve in the learning popover to save these into your memory store.")
        static let learningNextStepRunSearchMCP = String(localized: "transcript.learning.next-step.run-search-mcp", defaultValue: "Run search_mcp_servers, review candidates, then ask the user before installing or adding credentials.")
        static let learningNextStepWaitForWorkflow = String(localized: "transcript.learning.next-step.wait-for-workflow", defaultValue: "Wait for a completed multi-tool workflow, or explicitly ask to create a skill from this lighter evidence.")
        static let learningNextStepFutureTurnDiscover = String(localized: "transcript.learning.next-step.future-turn-discover", defaultValue: "Future turns can discover this skill through list_skills or attach it from the skill picker.")
        static let learningNextStepReuseExisting = String(localized: "transcript.learning.next-step.reuse-existing", defaultValue: "Reuse or manually edit the existing skill instead of overwriting it.")
        static let learningNextStepRetryAfterFix = String(localized: "transcript.learning.next-step.retry-after-fix", defaultValue: "Review the error, fix local skill storage access, then retry if the workflow is still useful.")
        // 1.85.0-rc13:popover 策略下的 footer 图标 / 单行摘要 / reject 按钮文案
        static let postTurnReportTooltip = String(localized: "transcript.post-turn.report-tooltip", defaultValue: "Turn audit report")
        static let postTurnLearningTooltip = String(localized: "transcript.post-turn.learning-tooltip", defaultValue: "Memory / skill / MCP suggestions saved this turn")
        static func postTurnLearningOneLiner(_ a1: String) -> String {
            let template = String(localized: "transcript.post-turn.learning-summary", defaultValue: "Agent saved %@ item(s) this turn")
            return String(format: template, a1)
        }
        static let learningRejectHelp = String(localized: "transcript.learning.reject-help", defaultValue: "Dismiss from review queue")
        // 1.85.0-rc16:popover 里 Approve 按钮的 tooltip。仅当事件有
        // pending memoryDrafts 时显示;点击会把 draft 真正写入 memory store。
        static let learningApproveHelp = String(localized: "transcript.learning.approve-help", defaultValue: "Save these memories to your memory store")
    }

}
