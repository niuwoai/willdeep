import Foundation

// Generated façade over Localizable.xcstrings.
// Each `static let` reads from the String Catalog at runtime with a baked-in en defaultValue
// (so missing entries fall back gracefully). Interpolated entries are exposed as `static func`
// taking String args; the catalog template uses %@ placeholders.
//
// To regenerate: see scripts/i18n_regenerate.rb (TODO if we ever automate this).

enum L10n {
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

    enum GoalEditorSheet {
        static let cancel = String(localized: "goal-editor-sheet.cancel", defaultValue: "Cancel")
        static let checklistLabel = String(localized: "goal-editor-sheet.checklist-label", defaultValue: "Acceptance checklist one per line")
        static let save = String(localized: "goal-editor-sheet.save", defaultValue: "Save")
        static let statementLabel = String(localized: "goal-editor-sheet.statement-label", defaultValue: "Goal statement")
        static let statementPlaceholder = String(localized: "goal-editor-sheet.statement-placeholder", defaultValue: "What are we trying to accomplish")
        static let title = String(localized: "goal-editor-sheet.title", defaultValue: "Define Goal")
    }

    enum Header {
        static let copyTitle = String(localized: "header.copy-title", defaultValue: "Copy title")
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
        static let label = String(localized: "queued-message.label", defaultValue: "Queued")
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
    }

}
