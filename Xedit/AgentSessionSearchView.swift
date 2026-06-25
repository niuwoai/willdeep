//
//  AgentSessionSearchView.swift
//  WillDeep
//
//  Title-only session search overlay (rc24). Opened from the chat header
//  magnifier (⌘⇧P). Substring-matches `AgentSession.title` across every
//  workspace — archived sessions included — and jumps to the chosen one
//  via `selectAgentSession(id:)`.
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
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            placeholderState(text: L10n.SessionSearch.prompt, systemImage: "text.bubble")
        } else if results.isEmpty {
            placeholderState(text: L10n.SessionSearch.empty, systemImage: "magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { session in
                        Button {
                            open(session)
                        } label: {
                            SessionSearchRow(session: session)
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

    /// Case- and diacritic-insensitive substring match on the title, then
    /// most-recently-updated first so the row you probably want is on top.
    private var results: [AgentSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return appState.agentSessions
            .filter { $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func openTopResult() {
        guard let first = results.first else { return }
        open(first)
    }

    private func open(_ session: AgentSession) {
        // Restoring an archived session purely by selecting it would be
        // surprising; selection just focuses it — the sidebar still shows
        // it under "Archived". Dismiss first so the selection isn't fighting
        // the sheet's own state teardown.
        dismiss()
        appState.selectAgentSession(id: session.id)
    }
}

private struct SessionSearchRow: View {
    let session: AgentSession
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.archivedAt != nil ? "archivebox" : "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        let workspace = session.workspaceRootPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? L10n.Workspace.noWorkspace
        let when = Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date())
        return "\(workspace) · \(when)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
