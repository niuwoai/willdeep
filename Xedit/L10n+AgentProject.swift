//
//  L10n+AgentProject.swift
//  WillDeep
//
//  Strings for named multi-folder projects.
//

import Foundation

extension L10n {
    enum AgentProjectStrings {
        // MARK: Menu

        static let editProject = String(
            localized: "agent-project.edit",
            defaultValue: "Edit Project…"
        )
        static let pinProject = String(
            localized: "agent-project.pin",
            defaultValue: "Pin Project"
        )
        static let unpinProject = String(
            localized: "agent-project.unpin",
            defaultValue: "Unpin Project"
        )
        static let createProject = String(
            localized: "agent-project.create",
            defaultValue: "Make This a Project…"
        )

        // MARK: Sheet

        static let sheetTitle = String(
            localized: "agent-project.sheet-title",
            defaultValue: "Edit Project"
        )
        static let nameLabel = String(
            localized: "agent-project.name-label",
            defaultValue: "Project name"
        )
        static let namePlaceholder = String(
            localized: "agent-project.name-placeholder",
            defaultValue: "e.g. TokenHub"
        )
        static let foldersLabel = String(
            localized: "agent-project.folders-label",
            defaultValue: "Source folders"
        )
        static let addFolder = String(
            localized: "agent-project.add-folder",
            defaultValue: "Add folder"
        )
        static let removeFolder = String(
            localized: "agent-project.remove-folder",
            defaultValue: "Remove this folder"
        )
        static let save = String(localized: "agent-project.save", defaultValue: "Save")
        static let cancel = String(localized: "agent-project.cancel", defaultValue: "Cancel")
        static let removeProject = String(
            localized: "agent-project.remove-project",
            defaultValue: "Remove Project"
        )
        static let missingFolder = String(
            localized: "agent-project.missing-folder",
            defaultValue: "Folder not found"
        )
        static let lastFolderHint = String(
            localized: "agent-project.last-folder-hint",
            defaultValue: "A project keeps at least one folder. Removing the last one removes the project."
        )

        // MARK: Removal confirmation

        static func removeTitle(_ a1: String) -> String {
            let template = String(
                localized: "agent-project.remove-title",
                defaultValue: "Remove project “%@”?"
            )
            return String(format: template, a1)
        }
        static func removeDeletesMessage(_ a1: String) -> String {
            let template = String(
                localized: "agent-project.remove-deletes",
                defaultValue: "This permanently deletes %@ conversation(s) and all their contents. This cannot be undone."
            )
            return String(format: template, a1)
        }
        /// Shown when some conversations survive because another project also
        /// owns their folder — the number the user would not otherwise expect.
        static func removeKeepsMessage(_ a1: String, _ a2: String) -> String {
            let template = String(
                localized: "agent-project.remove-keeps",
                defaultValue: "%@ conversation(s) whose folder also belongs to “%@” will be kept and moved there."
            )
            return String(format: template, a1, a2)
        }
        static let removeNothingToDelete = String(
            localized: "agent-project.remove-nothing",
            defaultValue: "No conversations will be deleted. The folders and their chats stay where they are."
        )
        static let removeConfirm = String(
            localized: "agent-project.remove-confirm",
            defaultValue: "Remove"
        )
        static let removeCancel = String(
            localized: "agent-project.remove-cancel",
            defaultValue: "Cancel"
        )
    }
}
