//
//  L10n+Plugins.swift
//  WillDeep
//

import Foundation

extension L10n {
    nonisolated enum Plugins {
        static let sidebarHeader = String(localized: "plugins.sidebar.header", defaultValue: "Plugins")
        static let addPlugin = String(localized: "plugins.sidebar.add", defaultValue: "Add Plugin…")
        static let morePlugins = String(localized: "plugins.sidebar.more", defaultValue: "More Plugins")
        static let centerTitle = String(localized: "plugins.center.title", defaultValue: "Plugins")
        static let centerDescription = String(localized: "plugins.center.description", defaultValue: "Install and manage WillDeep destinations, skills, MCP servers, and permissions.")
        static let installLocal = String(localized: "plugins.install.local", defaultValue: "Install from Folder or ZIP…")
        static let installGit = String(localized: "plugins.install.git", defaultValue: "Install from Git…")
        static let refresh = String(localized: "plugins.refresh", defaultValue: "Refresh")
        static let enabled = String(localized: "plugins.enabled", defaultValue: "Enabled")
        static let disabled = String(localized: "plugins.disabled", defaultValue: "Disabled")
        static let approvalRequired = String(localized: "plugins.approval-required", defaultValue: "Approval required")
        static let approve = String(localized: "plugins.approve", defaultValue: "Approve and Enable")
        static let cancel = String(localized: "plugins.cancel", defaultValue: "Cancel")
        static let uninstall = String(localized: "plugins.uninstall", defaultValue: "Uninstall")
        static let rollback = String(localized: "plugins.rollback", defaultValue: "Roll Back")
        static let checkForUpdates = String(localized: "plugins.update", defaultValue: "Check Source for Updates")
        static let pin = String(localized: "plugins.pin", defaultValue: "Pin to Sidebar")
        static let unpin = String(localized: "plugins.unpin", defaultValue: "Unpin from Sidebar")
        static let permissions = String(localized: "plugins.permissions", defaultValue: "Permissions")
        static let noPermissions = String(localized: "plugins.permissions.none", defaultValue: "No additional permissions")
        static let source = String(localized: "plugins.source", defaultValue: "Source")
        static let version = String(localized: "plugins.version", defaultValue: "Version")
        static let openInFinder = String(localized: "plugins.finder", defaultValue: "Show in Finder")
        static let diagnostics = String(localized: "plugins.diagnostics", defaultValue: "Diagnostics")
        static let noPlugins = String(localized: "plugins.empty.title", defaultValue: "No plugins installed")
        static let noPluginsDetail = String(localized: "plugins.empty.detail", defaultValue: "Install a local package, ZIP archive, or Git repository to add new destinations.")
        static let pageLoading = String(localized: "plugins.page.loading", defaultValue: "Loading plugin…")
        static let pageUnavailable = String(localized: "plugins.page.unavailable", defaultValue: "Plugin page unavailable")
        static let pageCrashedRepeatedly = String(localized: "plugins.page.crashed-repeatedly", defaultValue: "The plugin page crashed three times. Reloading has stopped; disable the plugin or roll back to an earlier version.")
        static let retry = String(localized: "plugins.retry", defaultValue: "Retry")
        static let openMCPSettings = String(localized: "plugins.mcp-settings", defaultValue: "Open MCP Settings")
        static let executeCommandTitle = String(localized: "plugins.command.confirm-title", defaultValue: "Allow Plugin Command?")
        static let executeCommand = String(localized: "plugins.command.allow", defaultValue: "Allow")
        static let selectSource = String(localized: "plugins.install.select-source", defaultValue: "Select a plugin folder or ZIP archive")
        static let gitTitle = String(localized: "plugins.git.title", defaultValue: "Install Plugin from Git")
        static let gitRepository = String(localized: "plugins.git.repository", defaultValue: "Repository URL")
        static let gitReference = String(localized: "plugins.git.reference", defaultValue: "Branch or tag (optional)")
        static let inspect = String(localized: "plugins.inspect", defaultValue: "Inspect")
        static let install = String(localized: "plugins.install", defaultValue: "Install")
        static let addedPermissions = String(localized: "plugins.permissions.added", defaultValue: "New permissions requested")
        static let packageUnchanged = String(localized: "plugins.package.unchanged", defaultValue: "This version is already installed.")
        static let settings = String(localized: "plugins.settings", defaultValue: "Settings")
        static let loadingSidebar = String(localized: "plugins.sidebar.loading", defaultValue: "Loading plugin sidebar…")
        static let emptySidebar = String(localized: "plugins.sidebar.empty", defaultValue: "Nothing to show here yet.")
        static let errorSidebar = String(localized: "plugins.sidebar.error", defaultValue: "The plugin sidebar could not be loaded.")
        static let actions = String(localized: "plugins.actions", defaultValue: "Plugin Actions")

        static func commandPaletteSubtitle(_ plugin: String) -> String {
            let template = String(localized: "plugins.command-palette.subtitle", defaultValue: "Provided by %@")
            return String(format: template, plugin)
        }

        static func commandConfirmation(_ plugin: String, _ command: String) -> String {
            let template = String(
                localized: "plugins.command.confirm-message",
                defaultValue: "%1$@ wants to run “%2$@”. The MCP server may access files, processes, or the network."
            )
            return String(format: template, plugin, command)
        }

        static func installedVersion(_ version: String) -> String {
            let template = String(localized: "plugins.installed-version", defaultValue: "Installed %@")
            return String(format: template, version)
        }

        static func destinationCount(_ count: Int) -> String {
            let template = String(localized: "plugins.destination-count", defaultValue: "%d destinations")
            return String(format: template, count)
        }

        static func versionLabel(_ version: String) -> String {
            let template = String(localized: "plugins.version-label", defaultValue: "v%@")
            return String(format: template, version)
        }
    }
}
