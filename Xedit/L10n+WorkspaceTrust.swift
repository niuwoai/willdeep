import Foundation

nonisolated extension L10n {
    /// The folder-trust prompt (AppStateWorkspaceTrust.swift). The wording has
    /// to make the stake concrete without turning into a security lecture: the
    /// user is deciding whether this folder's own scripts may run outside the
    /// sandbox, not whether the folder may be opened.
    enum WorkspaceTrust {
        static func title(_ folderName: String) -> String {
            let template = String(
                localized: "workspace-trust.title",
                defaultValue: "Do you trust the code in \"%@\"?"
            )
            return String(format: template, folderName)
        }

        static let message = String(
            localized: "workspace-trust.message",
            defaultValue: "Scripts kept in a trusted folder (.sh, .rb, .py, .js and the like) run outside the workspace sandbox, with your real home directory, your SSH keys and network access. Trust a folder only if you would run its scripts yourself."
        )

        static let untrustedMessage = String(
            localized: "workspace-trust.untrusted-message",
            defaultValue: "If you don't trust it, everything still works — the folder's scripts just stay confined to the sandbox."
        )

        static func folderList(_ folders: String) -> String {
            let template = String(
                localized: "workspace-trust.folder-list",
                defaultValue: "This covers every folder in the project:\n%@"
            )
            return String(format: template, folders)
        }

        static let trust = String(localized: "workspace-trust.trust", defaultValue: "Trust")
        static let doNotTrust = String(localized: "workspace-trust.do-not-trust", defaultValue: "Don't Trust")
    }
}
