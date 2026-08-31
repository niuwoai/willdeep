//
//  AgentSessionSearchView.swift
//  WillDeep
//
//  Conversation-and-project title search overlay. Opened from the native
//  titlebar magnifier or its ⌘⇧P shortcut.
//  Substring-matches conversation and project titles across every workspace
//  — archived sessions included — then reveals the selected sidebar target.
//
//  macOS 13.7 deployment target: `onKeyPress` (14+) is unavailable, so the
//  keyboard path is "type to filter → Enter opens the top match"; mouse
//  users click any row. Kept deliberately light per the agreed scope —
//  no message full-text indexing here.
//

import SwiftUI

struct AgentSessionSearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var queryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
        .onAppear { queryFieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.SessionSearch.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($queryFieldFocused)
                .onSubmit(openTopResult)
            if !query.isEmpty {
                Button {
                    query = ""
                    queryFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        // 一打开就有东西看：空查询时列最近会话（不分项目），真的一条会话都
        // 没有有效会话才退回空态提示。
        if results.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholderState(text: L10n.SessionSearch.prompt, systemImage: "text.bubble")
        } else if results.isEmpty {
            placeholderState(text: L10n.SessionSearch.empty, systemImage: "magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        Button {
                            open(result)
                        } label: {
                            SessionSearchRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func placeholderState(text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if !results.isEmpty {
                Text(L10n.SessionSearch.resultCount("\(results.count)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.SessionSearch.close) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Searches chat titles and named projects. The shared matcher keeps the
    /// literal, case/diacritic-insensitive rules consistent with model tools.
    private var results: [AgentSessionSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return AgentSessionSearch.recentSessions(
                appState.agentSessions,
                isMetadataOnly: appState.agentSessionIsMetadataOnly,
                metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
            )
        }
        return AgentSessionSearch.titleResults(
            sessions: appState.agentSessions,
            projects: appState.agentProjects,
            query: query,
            isMetadataOnly: appState.agentSessionIsMetadataOnly,
            metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
        )
    }

    private func openTopResult() {
        guard let first = results.first else { return }
        open(first)
    }

    private func open(_ result: AgentSessionSearchResult) {
        // Dismiss first so the sidebar animation isn't fighting the sheet's
        // teardown. A session result opens the transcript; a project result
        // only centres and highlights its group header.
        dismiss()
        switch result {
        case .session(let session):
            _ = appState.selectAndRevealAgentSessionInSidebar(id: session.id)
        case .project(let project):
            appState.revealAgentProjectInSidebar(id: project.id)
        }
    }
}

private struct SessionSearchRow: View {
    let result: AgentSessionSearchResult
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(resultKind)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        switch result {
        case .project(let project):
            return L10n.SessionSearch.projectResultSubtitle("\(project.folderPaths.count)")
        case .session(let session):
            let workspace = session.workspaceRootPath
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? L10n.Workspace.noWorkspace
            let when = Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date())
            return "\(workspace) · \(when)"
        }
    }

    private var iconName: String {
        switch result {
        case .project:
            return "folder"
        case .session(let session):
            return session.archivedAt != nil ? "archivebox" : "bubble.left.and.bubble.right"
        }
    }

    private var title: String {
        switch result {
        case .project(let project):
            return project.resolvedDisplayName
        case .session(let session):
            return session.title
        }
    }

    private var resultKind: String {
        switch result {
        case .project:
            return L10n.SessionSearch.projectResultKind
        case .session:
            return L10n.SessionSearch.sessionResultKind
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
