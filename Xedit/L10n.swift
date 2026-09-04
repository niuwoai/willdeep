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
    enum AgentTools {
        static let readBundledRule = String(
            localized: "agent-tools.read-bundled-rule",
            defaultValue: "Read bundled rule"
        )
    }
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

    enum HelpMenu {
        static let menuItem = String(localized: "help-menu.menu-item", defaultValue: "WillDeep Help")
        static let windowTitle = String(localized: "help-menu.window-title", defaultValue: "WillDeep Help")
        static let unavailableTitle = String(localized: "help-menu.unavailable-title", defaultValue: "Help content is missing")
        static let unavailableDetail = String(
            localized: "help-menu.unavailable-detail",
            defaultValue: "This copy of WillDeep does not contain the help book. Reinstall a complete release to restore it."
        )
    }

    enum AppUpdate {
        static let checkForUpdates = String(localized: "app-update.check-for-updates", defaultValue: "Check for Updates…")
        static let diagnosticClose = String(localized: "app-update.diagnostic-close", defaultValue: "Close")
        static let diagnosticCopy = String(localized: "app-update.diagnostic-copy", defaultValue: "Copy Details")
        static let diagnosticInstallerLaunchHint = String(localized: "app-update.diagnostic-installer-launch-hint", defaultValue: "The installer could not obtain authorization or start. Reinstall a signed WillDeep release in Applications, then try again.")
        static func diagnosticMessage(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "app-update.diagnostic-message", defaultValue: "Error: %1$@\n%2$@\n\nDetails were saved to the update log.")
            return String(format: template, a1, a2)
        }
        static func diagnosticMessageWithoutLog(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "app-update.diagnostic-message-without-log", defaultValue: "Error: %1$@\n%2$@\n\nThe update log could not be written. Copy the details when reporting the problem.")
            return String(format: template, a1, a2)
        }
        static let diagnosticShowLog = String(localized: "app-update.diagnostic-show-log", defaultValue: "Show Log")
        static let diagnosticTitle = String(localized: "app-update.diagnostic-title", defaultValue: "Update Details")
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
        static let scrollToLatest = String(
            localized: "agent-transcript-reader.scroll-to-latest",
            defaultValue: "Scroll to latest message"
        )
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

    enum Approval {
        /// 裁判缺席时的一次性提示。用户看到的现象是「每条命令都要点」，
        /// 而这其实是可以消除的配置问题——不说出来，他只会以为产品就这样。
        static let safetyJudgeUnconfigured = String(
            localized: "approval.safety-judge-unconfigured",
            defaultValue: "No safety judge is available, so every command needs your confirmation. Add an API key for the current model provider in Settings, or sign in to some.im, to restore automatic review."
        )
    }

    enum ApprovalMode {
        static let pickerHelp = String(localized: "approval-mode.picker-help", defaultValue: "Choose how this session approves Agent tool calls.")
        static let requestEveryTime = String(localized: "approval-mode.request-every-time", defaultValue: "Strict mode")
        static let requestEveryTimeSummary = String(localized: "approval-mode.request-every-time.summary", defaultValue: "Ask before security-relevant writes or external actions.")
        static let fullAccess = String(localized: "approval-mode.silent", defaultValue: "Full access")
        static let fullAccessSummary = String(localized: "approval-mode.silent.summary", defaultValue: "Access the internet and any file on this Mac without asking.")
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
        static let deleteAlertTitle = String(
            localized: "automation.delete.alert-title",
            defaultValue: "Delete Automation"
        )
        static func deleteAlertMessage(_ name: String) -> String {
            let template = String(
                localized: "automation.delete.alert-message",
                defaultValue: "“%@” will stop running and its schedule, prompt, and settings will be removed. This cannot be undone."
            )
            return String(format: template, name)
        }
        static let deleteConfirm = String(localized: "automation.delete.confirm", defaultValue: "Delete")
        static let deleteCancel = String(localized: "automation.delete.cancel", defaultValue: "Cancel")
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
        static func notificationBodyFailed(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "automation.notification.body.failed", defaultValue: "%1$@ failed: %2$@")
            return String(format: template, a1, a2)
        }
        static let notificationFailedTitle = String(localized: "automation.notification.failed-title", defaultValue: "Automation failed")
        static let notificationTitle = String(localized: "automation.notification.title", defaultValue: "Automation started")
        static let runOutcomeRunning = String(localized: "automation.run-outcome.running", defaultValue: "Running")
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
        static let savedSecretCopyHelp = String(localized: "composer.secret.saved-copy-help", defaultValue: "Authenticate and copy this secret")
        static let savedSecretCopyReason = String(localized: "composer.secret.saved-copy-reason", defaultValue: "Authenticate to copy this saved secret from Keychain.")
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

    enum WorktreeRecovery {
        static let title = String(localized: "worktree.recovery.title", defaultValue: "Worktree cleaned up")
        static let restorableMessage = String(localized: "worktree.recovery.restorable-message", defaultValue: "This conversation's worktree was removed. Restore it to continue on the original branch.")
        static let unavailableMessage = String(localized: "worktree.recovery.unavailable-message", defaultValue: "This conversation's worktree is unavailable and cannot be safely restored. Choose another workspace to continue.")
        static let restore = String(localized: "worktree.recovery.restore", defaultValue: "Restore Worktree")
        static let restoring = String(localized: "worktree.recovery.restoring", defaultValue: "Restoring…")
        static let chooseWorkspace = String(localized: "worktree.recovery.choose-workspace", defaultValue: "Choose Workspace")
        static let sessionBadgeHelp = String(localized: "worktree.recovery.session-badge-help", defaultValue: "This conversation runs in a Git worktree")
        static func failedMessage(_ details: String) -> String {
            String(
                format: String(localized: "worktree.recovery.failed-message", defaultValue: "The worktree could not be restored: %@"),
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

    enum Dock {
        static let pendingApprovalHeader = String(localized: "dock.pending-approval.header", defaultValue: "Needs Attention")
        static let recentHeader = String(localized: "dock.recent.header", defaultValue: "Recent")
        static let more = String(localized: "dock.more", defaultValue: "More")
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
        static let pauseExecution = String(localized: "goal-status-bar.pause-execution", defaultValue: "Pause goal execution")
        static let pinnedPrefix = String(localized: "goal-status-bar.pinned-prefix", defaultValue: "Goal pinned")
        static func progressHelp(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "goal-status-bar.progress-help", defaultValue: "%@/%@ checklist items done")
            return String(format: template, a1, a2)
        }
        static let resumeExecution = String(localized: "goal-status-bar.resume-execution", defaultValue: "Resume goal execution")
        static let runningPrefix = String(localized: "goal-status-bar.running-prefix", defaultValue: "Goal in progress")
        static let untitled = String(localized: "goal-status-bar.untitled", defaultValue: "Untitled goal")
    }

    enum GoalRoadmap {
        static func phase(_ current: Int, _ total: Int) -> String {
            let template = String(
                localized: "goal-roadmap.phase-position",
                defaultValue: "Phase %1$@/%2$@"
            )
            return String(format: template, "\(current)", "\(total)")
        }
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
        /// %1 total used · %2 window · %3 conversation share · %4 system +
        /// tools baseline · %5 remaining. The leading pair matches the bare
        /// used/window fraction the ring, compression trigger, and runway
        /// handoff all report; %3/%4 are the tooltip-only breakdown.
        static func tooltip(_ a1: String, _ a2: String, _ a3: String, _ a4: String, _ a5: String) -> String {
            let template = String(
                localized: "context-ring.tooltip-breakdown",
                defaultValue: "~%1$@ of %2$@ used · conversation ~%3$@ · system + tools ~%4$@ · %5$@ remaining (estimate)."
            )
            return String(format: template, a1, a2, a3, a4, a5)
        }
    }

    enum SessionSearch {
        static let placeholder = String(localized: "session-search.placeholder", defaultValue: "Search chats and projects by title…")
        static let empty = String(localized: "session-search.empty", defaultValue: "No matching chats or projects")
        static let prompt = String(localized: "session-search.prompt", defaultValue: "Type to search chats and projects")
        static let sessionResultKind = String(localized: "session-search.result-kind-session", defaultValue: "Chat")
        static let projectResultKind = String(localized: "session-search.result-kind-project", defaultValue: "Project")
        static func projectResultSubtitle(_ a1: String) -> String {
            let template = String(localized: "session-search.project-result-subtitle", defaultValue: "%1$@ folders")
            return String(format: template, a1)
        }
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

    enum ChromeImport {
        static let title = String(localized: "chrome-import.title", defaultValue: "Import from Chrome")
        static let subtitle = String(localized: "chrome-import.subtitle", defaultValue: "Bring your Chrome logins into this browser")
        static let profile = String(localized: "chrome-import.profile", defaultValue: "Chrome profile")
        static let chooseFolder = String(localized: "chrome-import.choose-folder", defaultValue: "Choose Chrome data folder…")
        static let choosePrompt = String(localized: "chrome-import.choose-prompt", defaultValue: "Select the Chrome folder so this browser can read its cookies. This grants read access to just that folder.")
        static let notFound = String(localized: "chrome-import.not-found", defaultValue: "No Chrome profile with cookies was found in the folder you chose.")
        static let noticeKeychain = String(localized: "chrome-import.notice-keychain", defaultValue: "macOS will ask permission to read Chrome's stored cookies.")
        static let noticeLocal = String(localized: "chrome-import.notice-local", defaultValue: "Cookies stay in this browser on this Mac and are not sent anywhere.")
        static let noticeNoPasswords = String(localized: "chrome-import.notice-no-passwords", defaultValue: "Saved passwords are never touched—only cookies.")
        static let importing = String(localized: "chrome-import.importing", defaultValue: "Importing cookies…")
        static let action = String(localized: "chrome-import.action", defaultValue: "Import Cookies")
        static let close = String(localized: "chrome-import.close", defaultValue: "Close")
        static func done(_ count: Int) -> String {
            let template = String(localized: "chrome-import.done", defaultValue: "Imported %lld cookies. Reload a page to use your Chrome session.")
            return String(format: template, count)
        }
    }

    enum AgentEmbeddedBrowser {
        static let addressPlaceholder = String(localized: "agent-embedded-browser.address-placeholder", defaultValue: "URL or domain")
        static let back = String(localized: "agent-embedded-browser.back", defaultValue: "Back")
        static let capture = String(localized: "agent-embedded-browser.capture", defaultValue: "Capture Screenshot")
        static let forward = String(localized: "agent-embedded-browser.forward", defaultValue: "Forward")
        static let go = String(localized: "agent-embedded-browser.go", defaultValue: "Go")
        static let importChrome = String(localized: "agent-embedded-browser.import-chrome", defaultValue: "Import logins from Chrome")
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
        static func tooltip(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(localized: "heatmap-cell.tooltip", defaultValue: "%1$@ · Requests: %2$@ · Tokens: %3$@")
            return String(format: template, a1, a2, a3)
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
        static let viewSwitchToAgentMode = String(localized: "menu.view.switch-to-agent-mode", defaultValue: "Switch to Agent Mode")
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
        static let openDetails = String(localized: "plan-card.open-details", defaultValue: "View full plan")
        static let openDetailsHelp = String(localized: "plan-card.open-details-help", defaultValue: "Show the full plan in the sidebar")
    }

    enum PlanContinuation {
        static let missingProgressPaused = String(localized: "plan-continuation.missing-progress-paused", defaultValue: "Plan status sync paused: no valid step statuses arrived after reconciliation. This does not mean execution failed. Review the plan and mark it complete, or add guidance to continue.")
        // 不写具体轮数：普通模式 8 轮、Goal 模式 24 轮，写死任何一个都会
        // 在另一个模式下说谎。
        static let safetyLimitPaused = String(localized: "plan-continuation.safety-limit-paused", defaultValue: "Plan auto-continuation reached its safety limit for this turn. Review the current deliverables and step statuses before continuing.")
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
        static let interrupted = String(localized: "plan-status.interrupted", defaultValue: "Interrupted")
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
        static let adjustDirection = String(localized: "queued-message.adjust-direction", defaultValue: "Adjust direction")
        static let actionsButton = String(localized: "queued-message.actions-button", defaultValue: "Queued message actions")
        static let actionsButtonHelp = String(localized: "queued-message.actions-button.help", defaultValue: "Show queued message actions")
        static let deleteButton = String(localized: "queued-message.delete-button", defaultValue: "Delete")
        static let deleteButtonHelp = String(localized: "queued-message.delete-button.help", defaultValue: "Delete this queued message")
        static let dragHelp = String(localized: "queued-message.drag.help", defaultValue: "Drag to reorder queued messages")
        static let editButton = String(localized: "queued-message.edit-button", defaultValue: "Edit message")
        static let editButtonHelp = String(localized: "queued-message.edit-button.help", defaultValue: "Edit this queued message in the composer")
        static let emptyPreview = String(localized: "queued-message.empty-preview", defaultValue: "Queued message")
        static func imageCount(_ a1: String) -> String {
            let template = String(localized: "queued-message.image-count", defaultValue: "%@ images")
            return String(format: template, a1)
        }
        static let label = String(localized: "queued-message.label", defaultValue: "Queued")
        static let openInSideChat = String(localized: "queued-message.open-in-side-chat", defaultValue: "Open in side chat")
        static let closeQueue = String(localized: "queued-message.close-queue", defaultValue: "Close queue")
        static let sendNowButton = String(localized: "queued-message.send-now-button", defaultValue: "Send queued message now")
        static let sendNowButtonHelp = String(localized: "queued-message.send-now-button.help", defaultValue: "Send this queued message now")
        static let sendNowCompact = String(localized: "queued-message.send-now-compact", defaultValue: "Send now")
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
            let template = String(localized: "sidebar.archived-sessions.header", defaultValue: "Archived")
            return String(format: template, a1)
        }
        static let chatsHeader = String(localized: "sidebar.chats-header", defaultValue: "Chats")
        static let emptyState = String(localized: "sidebar.empty-state", defaultValue: "Sessions you start will appear here.")
        static let loadingState = String(localized: "sidebar.loading-state", defaultValue: "Loading sessions…")
        /// Navigates to the conversation surface. Distinct from
        /// `newChatAction`, which starts a fresh one.
        static let chatAction = String(localized: "sidebar.chat-action", defaultValue: "Chat")
        static let newChatAction = String(localized: "sidebar.new-chat-action", defaultValue: "New Chat")
        /// 首行在聊天页之外的说法：点它是「回到最近一次会话」。
        static let sessionAction = String(localized: "sidebar.session-action", defaultValue: "Session")
        /// 首行在聊天页里的说法：点它是「开一个新会话」。
        static let newSessionAction = String(
            localized: "sidebar.new-session-action",
            defaultValue: "New Session"
        )
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
        static let sessionMenuContinueInNewChat = String(localized: "sidebar.session-menu.continue-in-new-chat", defaultValue: "Continue in New Chat")
        static let sessionMenuContinueInNewWorktree = String(localized: "sidebar.session-menu.continue-in-new-worktree", defaultValue: "Continue in New Worktree")
        static let sessionMenuCopyDeepLink = String(localized: "sidebar.session-menu.copy-deep-link", defaultValue: "Copy Deep Link")
        static let sessionMenuCopySessionID = String(localized: "sidebar.session-menu.copy-session-id", defaultValue: "Copy Session ID")
        static let sessionMenuCopyWorkingDirectory = String(localized: "sidebar.session-menu.copy-working-directory", defaultValue: "Copy Working Directory")
        static let sessionMenuMarkRead = String(localized: "sidebar.session-menu.mark-read", defaultValue: "Mark as Read")
        static let sessionMenuMarkUnread = String(localized: "sidebar.session-menu.mark-unread", defaultValue: "Mark as Unread")
        static let sessionMenuOpenInNewWindow = String(localized: "sidebar.session-menu.open-in-new-window", defaultValue: "Open Transcript in New Window")
        static let sessionMenuShowInFinder = String(localized: "sidebar.session-menu.show-in-finder", defaultValue: "Show in Finder")
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
        static let pendingApprovalHeader = String(localized: "sidebar.pending-approval.header", defaultValue: "Waiting for you")
        static let pendingApprovalRowTooltip = String(localized: "sidebar.pending-approval.row-tooltip", defaultValue: "Jump to this session")
        static let sessionRowWaitingApproval = String(localized: "sidebar.session-row.waiting-approval", defaultValue: "Needs attention")
        static let sessionRowWaitingApprovalTooltip = String(localized: "sidebar.session-row.waiting-approval-tooltip", defaultValue: "This session is waiting for you to handle a request, approval, or answer.")
        static let sessionUnreadIndicator = String(localized: "sidebar.session-row.unread-indicator", defaultValue: "Unread chat")
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
        static let workspaceHeaderOpenTooltip = String(localized: "sidebar.workspace-header.open-tooltip", defaultValue: "Add a folder as a new project")
        static let workspaceHeaderCollapseAllTooltip = String(localized: "sidebar.workspace-header.collapse-all-tooltip", defaultValue: "Collapse all projects")
        static let workspaceHeaderExpandAllTooltip = String(localized: "sidebar.workspace-header.expand-all-tooltip", defaultValue: "Expand all projects")
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
        static let backgroundTaskAuthorizationTitle = String(localized: "tool-card.authorization.background-task.title", defaultValue: "Background Task")
        static let backgroundTaskAuthorizationGenericQuestion = String(localized: "tool-card.authorization.background-task.generic-question", defaultValue: "Stop this background task?")
        static func backgroundTaskAuthorizationQuestion(_ a1: String) -> String {
            let template = String(localized: "tool-card.authorization.background-task.question", defaultValue: "Stop background task %@?")
            return String(format: template, a1)
        }
        static let browserAuthorizationTitle = String(localized: "tool-card.authorization.browser.title", defaultValue: "Browser")
        static let browserChromeAuthorizationQuestion = String(localized: "tool-card.authorization.browser.chrome-question", defaultValue: "Allow WillDeep to control Chrome?")
        static let browserEmbeddedAuthorizationQuestion = String(localized: "tool-card.authorization.browser.embedded-question", defaultValue: "Allow WillDeep to control Browser?")
        static let computerUseAuthorizationTitle = String(localized: "tool-card.authorization.computer-use.title", defaultValue: "Computer Use")
        static let computerUseAuthorizationQuestion = String(localized: "tool-card.authorization.computer-use.question", defaultValue: "Allow WillDeep to control this Mac?")
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
        static let managerTitle = String(localized: "agent-jobs.manager-title", defaultValue: "Background Tasks")
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
        static let scope = String(localized: "agent-jobs.scope", defaultValue: "Task scope")
        static let currentSession = String(localized: "agent-jobs.scope.current-session", defaultValue: "Current session")
        static let allSessions = String(localized: "agent-jobs.scope.all-sessions", defaultValue: "All sessions")
        static let currentSessionBadge = String(localized: "agent-jobs.current-session-badge", defaultValue: "Current session")
        static let searchPlaceholder = String(localized: "agent-jobs.search-placeholder", defaultValue: "Search tasks")
        static let statusFilter = String(localized: "agent-jobs.status-filter", defaultValue: "Status filter")
        static let filterAll = String(localized: "agent-jobs.filter.all", defaultValue: "All statuses")
        static let filterRunning = String(localized: "agent-jobs.filter.running", defaultValue: "Running")
        static let filterFinished = String(localized: "agent-jobs.filter.finished", defaultValue: "Finished")
        static let emptyAllSessions = String(localized: "agent-jobs.empty-all-sessions", defaultValue: "No background tasks match these filters.")
        static let processName = String(localized: "agent-jobs.process-name", defaultValue: "Process")
        static let workingDirectory = String(localized: "agent-jobs.working-directory", defaultValue: "Working directory")
        static let noWorkingDirectory = String(localized: "agent-jobs.no-working-directory", defaultValue: "No working directory")
        static let command = String(localized: "agent-jobs.command", defaultValue: "Command")
        static let pid = String(localized: "agent-jobs.pid", defaultValue: "PID")
        static let startedAt = String(localized: "agent-jobs.started-at", defaultValue: "Started")
        static let duration = String(localized: "agent-jobs.duration", defaultValue: "Duration")
        static let stop = String(localized: "agent-jobs.stop", defaultValue: "Stop task")
        static let copyCommand = String(localized: "agent-jobs.copy-command", defaultValue: "Copy command")
        static let logLayout = String(localized: "agent-jobs.log-layout", defaultValue: "Log layout")
        static let tabbedLogs = String(localized: "agent-jobs.logs.tabbed", defaultValue: "Tabbed")
        static let splitLogs = String(localized: "agent-jobs.logs.split", defaultValue: "Split")
        static let autoFollow = String(localized: "agent-jobs.auto-follow", defaultValue: "Follow")
        static let outputStream = String(localized: "agent-jobs.output-stream", defaultValue: "Output stream")
        static let combined = String(localized: "agent-jobs.output.combined", defaultValue: "Combined")
        static let stdout = String(localized: "agent-jobs.output.stdout", defaultValue: "stdout")
        static let stderr = String(localized: "agent-jobs.output.stderr", defaultValue: "stderr")
        static let copyOutput = String(localized: "agent-jobs.copy-output", defaultValue: "Copy output")
        static let openManagerHelp = String(localized: "agent-jobs.open-manager-help", defaultValue: "Open the background task manager")

        static func runningSection(_ count: Int) -> String {
            let template = String(localized: "agent-jobs.section.running", defaultValue: "Running %d")
            return String(format: template, count)
        }

        static func recentSection(_ count: Int) -> String {
            let template = String(localized: "agent-jobs.section.recent", defaultValue: "Recently finished %d")
            return String(format: template, count)
        }

        static func lineCount(_ count: Int) -> String {
            let template = String(localized: "agent-jobs.line-count", defaultValue: "%d lines")
            return String(format: template, count)
        }

        /// Only the running count. The composer card is shown exclusively while
        /// something is running, so a total that also counted finished jobs was
        /// reporting on tasks the user had no pending stake in.
        static func composerRunningSummary(_ running: Int) -> String {
            let template = String(localized: "agent-jobs.composer-running-summary", defaultValue: "%d running")
            return String(format: template, running)
        }

        static func inspectOutputPrompt(_ jobID: String) -> String {
            let template = String(
                localized: "agent-jobs.inspect-output.prompt",
                defaultValue: "Check background job %@ status and output: get_job_output(job_id: \"%@\")"
            )
            return String(format: template, jobID, jobID)
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
        static let turnReportApprovalFullAccess = String(localized: "transcript.turn-report.approval.silent", defaultValue: "Full access")
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
        static let postTurnLearningTooltip = String(localized: "transcript.post-turn.learning-tooltip", defaultValue: "Memory / skill / MCP suggestions from this turn; saving needs your approval")
        static func postTurnLearningOneLiner(_ a1: String) -> String {
            let template = String(localized: "transcript.post-turn.learning-summary", defaultValue: "%@ learning suggestion(s) this turn")
            return String(format: template, a1)
        }
        static let learningRejectHelp = String(localized: "transcript.learning.reject-help", defaultValue: "Dismiss from review queue")
        // 1.85.0-rc16:popover 里 Approve 按钮的 tooltip。仅当事件有
        // pending memoryDrafts 时显示;点击会把 draft 真正写入 memory store。
        static let learningApproveHelp = String(localized: "transcript.learning.approve-help", defaultValue: "Save these memories to your memory store")
    }

}
