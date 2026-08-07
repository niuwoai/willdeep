//
//  AgentProjectEditorSheet.swift
//  WillDeep
//
//  The "Edit Project" sheet: rename a project and manage its folders.
//

import AppKit
import SwiftUI

struct AgentProjectEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Existing project to edit, or nil when promoting a plain folder group
    /// into a new project.
    let existingProject: AgentProject?
    /// Seed folder used when creating; ignored when editing.
    let seedFolderPath: String?

    @State private var name: String = ""
    @State private var folders: [String] = []

    private var isCreating: Bool { existingProject == nil }

    private var canSave: Bool {
        !folders.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCreating ? L10n.AgentProjectStrings.createProject : L10n.AgentProjectStrings.sheetTitle)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.AgentProjectStrings.nameLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.AgentProjectStrings.namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.AgentProjectStrings.foldersLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(folders, id: \.self) { folder in
                    folderRow(folder)
                }
                Button {
                    addFolder()
                } label: {
                    Label(L10n.AgentProjectStrings.addFolder, systemImage: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(L10n.AgentProjectStrings.lastFolderHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let existingProject {
                    Button(L10n.AgentProjectStrings.removeProject, role: .destructive) {
                        if appState.confirmAndRemoveAgentProject(id: existingProject.id) {
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button(L10n.AgentProjectStrings.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.AgentProjectStrings.save) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: folder).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(folder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            // A folder that has been moved or unmounted is flagged, never
            // auto-removed: an external drive being offline must not quietly
            // rewrite the user's configuration.
            if !FileManager.default.fileExists(atPath: folder) {
                Text(L10n.AgentProjectStrings.missingFolder)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button {
                folders.removeAll { $0 == folder }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.AgentProjectStrings.removeFolder)
        }
        .padding(.vertical, 3)
    }

    private func load() {
        if let existingProject {
            name = existingProject.displayName
            folders = existingProject.folderPaths
        } else {
            folders = [seedFolderPath].compactMap { $0.flatMap(AgentProject.normalizedPath) }
            name = folders.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let normalized = AgentProject.normalizedPath(url.path) else { continue }
            if !folders.contains(normalized) {
                folders.append(normalized)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        if let existingProject {
            appState.updateAgentProject(
                id: existingProject.id,
                displayName: name,
                folderPaths: folders
            )
        } else {
            appState.createAgentProject(displayName: name, folderPaths: folders)
        }
        dismiss()
    }
}
