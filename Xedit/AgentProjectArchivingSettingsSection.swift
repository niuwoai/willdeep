import SwiftUI

struct AgentProjectArchivingSettingsSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Section(L10n.ProjectArchiving.section) {
            Toggle(L10n.ProjectArchiving.enabled, isOn: $appState.projectAutoArchiveEnabled)
            Text(L10n.ProjectArchiving.description)
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.ProjectArchiving.runNow) { appState.archiveInactiveAgentProjects() }
                .disabled(!appState.projectAutoArchiveEnabled || !appState.hasLoadedAgentSessionCatalog)
            if appState.projectArchivingSaveFailed {
                Text(L10n.ProjectArchiving.saveFailed).foregroundStyle(.red)
            }
            let projects = appState.archivedAgentProjects
            if projects.isEmpty {
                Text(L10n.ProjectArchiving.empty).foregroundStyle(.secondary)
            } else {
                Text(L10n.ProjectArchiving.archived).font(.headline)
                ForEach(projects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.resolvedDisplayName)
                            if let date = project.archivedAt {
                                Text(date, format: .dateTime.year().month().day())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(project.folderPaths.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(L10n.ProjectArchiving.unarchive) {
                            appState.setAgentProjectArchived(id: project.id, archived: false)
                        }
                    }
                }
            }
        }
    }
}

extension L10n {
    enum ProjectArchiving {
        static let section = String(localized: "section", table: "ProjectArchiving")
        static let enabled = String(localized: "enabled", table: "ProjectArchiving")
        static let description = String(localized: "description", table: "ProjectArchiving")
        static let runNow = String(localized: "run-now", table: "ProjectArchiving")
        static let archived = String(localized: "archived", table: "ProjectArchiving")
        static let empty = String(localized: "empty", table: "ProjectArchiving")
        static let archive = String(localized: "archive", table: "ProjectArchiving")
        static let unarchive = String(localized: "unarchive", table: "ProjectArchiving")
        static let saveFailed = String(localized: "save-failed", table: "ProjectArchiving")
    }
}
