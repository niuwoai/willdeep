import Foundation

// Split out of L10n.swift to keep that generated façade under the 3000-line
// complexity-guard hard limit. Same `nonisolated` isolation as the parent
// `enum L10n` so these lookups stay callable from nonisolated model code.
extension L10n {
    nonisolated enum ExecutionAgent {
        static let willDeepName = String(localized: "execution-agent.willdeep.name", defaultValue: "WillDeep")
        static let claudeCodeName = String(localized: "execution-agent.claude-code.name", defaultValue: "Claude Code")
        static let codexName = String(localized: "execution-agent.codex.name", defaultValue: "Codex")
        static let cursorName = String(localized: "execution-agent.cursor.name", defaultValue: "Cursor Agent")
        static let clineName = String(localized: "execution-agent.cline.name", defaultValue: "Cline")
        static let willDeepSummary = String(localized: "execution-agent.willdeep.summary", defaultValue: "Let WillDeep run this task with its built-in model and tools.")
        static let claudeCodeSummary = String(localized: "execution-agent.claude-code.summary", defaultValue: "Run this task with the local Claude Code CLI.")
        static let codexSummary = String(localized: "execution-agent.codex.summary", defaultValue: "Run this task with the local Codex CLI.")
        static let cursorSummary = String(localized: "execution-agent.cursor.summary", defaultValue: "Run this task with the local Cursor Agent CLI.")
        static let clineSummary = String(localized: "execution-agent.cline.summary", defaultValue: "Run this task with the local Cline CLI.")
        static let pickerHelp = String(localized: "execution-agent.picker.help", defaultValue: "Choose whether WillDeep runs this turn or delegates it to a local external coding CLI.")
    }

    nonisolated enum AgentTerminal {
        static let clear = String(localized: "agent-terminal.clear", defaultValue: "Clear")
        static let connect = String(localized: "agent-terminal.connect", defaultValue: "Connect")
        static let disconnect = String(localized: "agent-terminal.disconnect", defaultValue: "Disconnect")
        static let disconnected = String(localized: "agent-terminal.disconnected", defaultValue: "Disconnected")
        static let disconnectedRuntime = String(localized: "agent-terminal.disconnected-runtime", defaultValue: "No terminal")
        static let noRuntime = String(localized: "agent-terminal.no-runtime", defaultValue: "No SSH runtime configured.")
        static let noRuntimeShort = String(localized: "agent-terminal.no-runtime-short", defaultValue: "No runtime")
        static let emptyOutput = String(localized: "agent-terminal.empty-output", defaultValue: "Connect an SSH runtime to start an interactive terminal.")
        static let copyOutput = String(localized: "agent-terminal.copy-output", defaultValue: "Copy Output")
        static let services = String(localized: "agent-terminal.services", defaultValue: "Service Commands")
        static let noServices = String(localized: "agent-terminal.no-services", defaultValue: "No services configured.")
        static let pendingAutoCommands = String(localized: "agent-terminal.pending-auto-commands", defaultValue: "Pending auto commands")
        static let serviceStatus = String(localized: "agent-terminal.service.status", defaultValue: "Status")
        static let serviceRestart = String(localized: "agent-terminal.service.restart", defaultValue: "Restart")
        static let serviceLogs = String(localized: "agent-terminal.service.logs", defaultValue: "Logs")
        static let serviceLogsFollow = String(localized: "agent-terminal.service.logs-follow", defaultValue: "Follow Logs")
        static let dockerPs = String(localized: "agent-terminal.docker.ps", defaultValue: "Docker ps")
        static let dockerLogs = String(localized: "agent-terminal.docker.logs", defaultValue: "Docker logs")
        static let newTab = String(localized: "agent-terminal.new-tab", defaultValue: "New Terminal Tab")
        static let newLocalTab = String(localized: "agent-terminal.new-local-tab", defaultValue: "New Local Shell")
        static let delegatedShellTitle = String(localized: "agent-terminal.delegated-shell-title", defaultValue: "Delegated · sh")
        static let delegatedShellTooltip = String(localized: "agent-terminal.delegated-shell-tooltip", defaultValue: "Reusable /bin/sh tab managed for external coding tasks")
        static let delegatedTask = String(localized: "agent-terminal.delegated-task", defaultValue: "Delegated task")
        static let sessionDelegated = String(localized: "agent-terminal.session.delegated", defaultValue: "Delegated Shell")
        static let sshHostsSection = String(localized: "agent-terminal.ssh-hosts-section", defaultValue: "Configured SSH Hosts")
        static let noSSHHostsConfigured = String(localized: "agent-terminal.no-ssh-hosts-configured", defaultValue: "No SSH hosts configured")
        static let manageSSHHosts = String(localized: "agent-terminal.manage-ssh-hosts", defaultValue: "Manage SSH Hosts...")
        static let localShellTooltip = String(localized: "agent-terminal.local-shell-tooltip", defaultValue: "Local shell")
        static let openedByThisSession = String(localized: "agent-terminal.opened-by-this-session", defaultValue: "Opened by this chat session")
        static let recording = String(localized: "agent-terminal.recording", defaultValue: "Recording")
        static let startRecording = String(localized: "agent-terminal.start-recording", defaultValue: "Start recording")
        static let stopRecording = String(localized: "agent-terminal.stop-recording", defaultValue: "Stop recording")
        static let recordingHelp = String(localized: "agent-terminal.recording-help", defaultValue: "Record common commands for quick execution later")
        static let recentRecordings = String(localized: "agent-terminal.recent-recordings", defaultValue: "Recent shortcuts")
        static let noShortcuts = String(localized: "agent-terminal.no-shortcuts", defaultValue: "No shortcuts yet")
        static let sessionLocal = String(localized: "agent-terminal.session.local", defaultValue: "Local Shell")
        static let sessionSSH = String(localized: "agent-terminal.session.ssh", defaultValue: "SSH")
        static let sessionRunning = String(localized: "agent-terminal.session.running", defaultValue: "Running")
        static let sessionExited = String(localized: "agent-terminal.session.exited", defaultValue: "Exited")
        static let localSessionCaution = String(localized: "agent-terminal.session.local-caution", defaultValue: "A local tab can contain a manual SSH session. Check the prompt or run hostname before remote actions.")
        static let sessionVerifyHostTitle = String(localized: "agent-terminal.session.verify-host-title", defaultValue: "Host identity")
        static let sessionExtractHostIdentity = String(localized: "agent-terminal.session.extract-host-identity", defaultValue: "Extract host identity")
        static let sessionExtractingHostIdentity = String(localized: "agent-terminal.session.extracting-host-identity", defaultValue: "Extracting…")
        static let sessionHostIdentityHint = String(localized: "agent-terminal.session.host-identity-hint", defaultValue: "Sends a hostname/IP/OS probe into this tab's live shell (including a manual SSH session) and renames the tab to the hostname.")
        static let sessionHostIdentityHostname = String(localized: "agent-terminal.session.host-identity-hostname", defaultValue: "Hostname")
        static let sessionHostIdentityIP = String(localized: "agent-terminal.session.host-identity-ip", defaultValue: "IP")
        static let sessionHostIdentityOS = String(localized: "agent-terminal.session.host-identity-os", defaultValue: "System")
        static let shortcutRunning = String(localized: "agent-terminal.shortcut.running", defaultValue: "Running")
        static let shortcutFinished = String(localized: "agent-terminal.shortcut.finished", defaultValue: "Finished")
        static let shortcutCancelled = String(localized: "agent-terminal.shortcut.cancelled", defaultValue: "Interrupted")
        static let shortcutDefaultTitle = String(localized: "agent-terminal.shortcut.default-title", defaultValue: "Terminal Shortcut")
        static let shortcutProtected = String(localized: "agent-terminal.shortcut.protected", defaultValue: "Contains protected input; executes only while terminal echo is off")
        static let shortcutReplay = String(localized: "agent-terminal.shortcut.replay", defaultValue: "Run")
        static let shortcutStopReplay = String(localized: "agent-terminal.shortcut.stop-replay", defaultValue: "Stop")
        static let shortcutActions = String(localized: "agent-terminal.shortcut.actions", defaultValue: "Shortcut actions")
        static let shortcutEdit = String(localized: "agent-terminal.shortcut.edit", defaultValue: "Edit")
        static let shortcutRename = String(localized: "agent-terminal.shortcut.rename", defaultValue: "Rename...")
        static let shortcutClone = String(localized: "agent-terminal.shortcut.clone", defaultValue: "Clone")
        static let shortcutDelete = String(localized: "agent-terminal.shortcut.delete", defaultValue: "Delete")
        static let shortcutPasswordCardDescription = String(localized: "agent-terminal.shortcut.password-card.description", defaultValue: "Saved only to this Mac's encrypted terminal vault. The AI never receives these values.")
        static let shortcutPasswordSave = String(localized: "agent-terminal.shortcut.password-card.save", defaultValue: "Save to Recording")
        static let shortcutRenameTitle = String(localized: "agent-terminal.shortcut.rename-title", defaultValue: "Rename Terminal Shortcut")
        static let shortcutNamePlaceholder = String(localized: "agent-terminal.shortcut.name-placeholder", defaultValue: "Shortcut name")
        static let shortcutRenameCancel = String(localized: "agent-terminal.shortcut.rename-cancel", defaultValue: "Cancel")
        static let shortcutRenameSave = String(localized: "agent-terminal.shortcut.rename-save", defaultValue: "Save")
        static func shortcutPendingProtected(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.pending-protected", defaultValue: "%@ password placeholder(s) still need local values")
            return String(format: template, a1)
        }
        static func shortcutPasswordCardTitle(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.password-card.title", defaultValue: "Fill Passwords for %@")
            return String(format: template, a1)
        }
        static func shortcutPasswordDefaultLabel(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.password-card.default-label", defaultValue: "Password %@")
            return String(format: template, a1)
        }
        static func shortcutMeta(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.meta", defaultValue: "%1$@ · %2$@ events")
            return String(format: template, a1, a2)
        }
        static func shortcutCopyTitle(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.copy-title", defaultValue: "%@-Copy")
            return String(format: template, a1)
        }
        static func shortcutDurationFallback(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.duration-fallback", defaultValue: "%@s")
            return String(format: template, a1)
        }
        static func shortcutReplayWait(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.replay-wait", defaultValue: "Execution wait: %@")
            return String(format: template, a1)
        }
        static func shortcutRemaining(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.remaining", defaultValue: "Remaining %@")
            return String(format: template, a1)
        }
        static func shortcutProgress(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.progress", defaultValue: "%1$@/%2$@")
            return String(format: template, a1, a2)
        }
        static func shortcutEstimatedFinish(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.estimated-finish", defaultValue: "Estimated finish: %@")
            return String(format: template, a1)
        }
        static func shortcutBadgeTooltip(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.shortcut.badge-tooltip", defaultValue: "Shortcut: %@")
            return String(format: template, a1)
        }
        static func newSSHTab(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.new-ssh-tab", defaultValue: "SSH: %@")
            return String(format: template, a1)
        }

        static func connecting(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "agent-terminal.connecting", defaultValue: "Connecting %@ (%@)")
            return String(format: template, a1, a2)
        }
        static func connected(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "agent-terminal.connected", defaultValue: "Connected to %@ (%@)")
            return String(format: template, a1, a2)
        }
        static func exited(_ a1: Int32) -> String {
            let template = String(localized: "agent-terminal.exited", defaultValue: "terminal exited %@")
            return String(format: template, "\(a1)")
        }
        static func ptyFailed(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.pty-failed", defaultValue: "failed to allocate pseudo terminal: %@")
            return String(format: template, a1)
        }
        static func spawnFailed(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.spawn-failed", defaultValue: "failed to spawn SSH terminal: %@")
            return String(format: template, a1)
        }
        static func writeFailed(_ a1: String) -> String {
            let template = String(localized: "agent-terminal.write-failed", defaultValue: "terminal write failed: %@")
            return String(format: template, a1)
        }
    }
}
