//
//  AgentRecentSessionEdgeRail.swift
//  WillDeep
//
//  Hover rail for collapsed Agent sessions sidebar. When the full
//  sidebar is hidden, a narrow strip at the left edge reveals the most
//  recently active conversations without moving the chat layout.
//

import SwiftUI

struct AgentRecentSessionEdgeRail: View {
    @EnvironmentObject var appState: AppState
    @State private var isPresented = false
    @State private var showTask: DispatchWorkItem?
    @State private var hideTask: DispatchWorkItem?

    private let triggerWidth: CGFloat = 14
    private let panelWidth: CGFloat = 314
    private let maxRows = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: triggerWidth)
                .contentShape(Rectangle())

            if isPresented {
                recentPanel
                    .frame(width: panelWidth)
                    .padding(.leading, 6)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: isPresented ? panelWidth + 6 : triggerWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .onHover { hovering in
            if hovering {
                scheduleShow()
            } else {
                scheduleHide()
            }
        }
        .animation(.easeOut(duration: 0.16), value: isPresented)
        .accessibilityHidden(!isPresented)
    }

    private var recentItems: [AgentRecentSessionEdgeRailLogic.Item] {
        AgentRecentSessionEdgeRailLogic.recentItems(
            from: appState.agentSessions,
            hiddenWorkspaceKeys: appState.hiddenWorkspaceKeys,
            limit: maxRows,
            // In-memory list, not the `AgentProject.load()` default: this is a
            // computed property SwiftUI re-evaluates on every body pass, and
            // the default would read the projects file each time.
            projects: appState.agentProjects,
            isMetadataOnly: appState.agentSessionIsMetadataOnly,
            metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
        )
    }

    private var recentPanel: some View {
        let skin = appState.editorSettings.interfaceSkin
        let palette = skin.palette
        // One filter+sort per body — this was evaluated twice (isEmpty and
        // ForEach) over the full session list.
        let items = recentItems

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(L10n.Sidebar.recentSessionsRailTitle)
                    .font(AgentDesign.sidebarSectionFont)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 7)

            if items.isEmpty {
                Text(L10n.Sidebar.recentSessionsRailEmpty)
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    VStack(spacing: 1) {
                        ForEach(items) { item in
                            recentRow(item, now: timeline.date)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(skin.sidebarBackground)
                .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.hairline.opacity(0.72), lineWidth: 1)
        )
        .padding(.top, 36)
        .padding(.bottom, 10)
    }

    private func recentRow(_ item: AgentRecentSessionEdgeRailLogic.Item, now: Date) -> some View {
        let isActive = appState.activeAgentSessionID == item.session.id
        let observedRuntime = appState.agentRuntimes[item.session.id]
        let displaySession = observedRuntime?.session ?? item.session
        let timestamp = AgentRelativeTimestamp.compactString(since: displaySession.lastActivityAt, now: now)

        return Button {
            appState.selectAgentSession(id: item.session.id)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                AgentRecentWorkspaceBadge(
                    initials: item.workspaceInitials,
                    color: AgentRecentSessionEdgeRailLogic.badgeColor(for: item.workspaceDisplayName)
                )

                HStack(spacing: 6) {
                    Text(displaySession.title)
                        .font(AgentDesign.sidebarRowFont)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    AgentSessionModeBadges(
                        session: displaySession,
                        runtime: observedRuntime
                    )
                }

                Spacer(minLength: 0)
                Text(timestamp)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(L10n.Sidebar.recentSessionsRailRowTooltip(item.workspaceDisplayName))
    }

    private func scheduleShow() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            isPresented = true
        }
        showTask?.cancel()
        showTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func scheduleHide() {
        showTask?.cancel()
        let task = DispatchWorkItem {
            isPresented = false
        }
        hideTask?.cancel()
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: task)
    }
}

private struct AgentRecentWorkspaceBadge: View {
    let initials: String
    let color: Color

    var body: some View {
        Text(initials)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 26, height: 22)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.26), lineWidth: 1)
            )
            .accessibilityLabel(initials)
    }
}

enum AgentRecentSessionEdgeRailLogic {
    struct Item: Identifiable, Equatable {
        var id: AgentSession.ID { session.id }
        let session: AgentSession
        let workspaceDisplayName: String
        let workspaceInitials: String
    }

    /// `isMetadataOnly` / `metadataOnlyHasUserMessage` come from the
    /// caller's AppState instance — the classification is per-instance,
    /// so it cannot be looked up from a global here. Defaults treat every
    /// session as fully materialized, which is what in-memory-only
    /// callers (tests, previews) have.
    ///
    /// `projects` is passed in rather than loaded per row: resolving a
    /// `project:` group key needs the project list, and reading it inside the
    /// row mapping would hit the disk once per visible session. The
    /// `AgentProjectStore.load()` default is for tests and previews; the real
    /// caller hands over AppState's in-memory list.
    static func recentItems(
        from sessions: [AgentSession],
        hiddenWorkspaceKeys: Set<String>,
        limit: Int,
        projects: [AgentProject] = AgentProjectStore.load(),
        isMetadataOnly: (AgentSession.ID) -> Bool = { _ in false },
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool = { _ in false }
    ) -> [Item] {
        sessions
            .filter { session in
                !session.isArchived
                    && !hiddenWorkspaceKeys.contains(session.workspaceSidebarGroupKey)
                    && hasUserMessage(
                        session,
                        isMetadataOnly: isMetadataOnly,
                        metadataOnlyHasUserMessage: metadataOnlyHasUserMessage
                    )
            }
            .sorted { lhs, rhs in
                lhs.lastActivityAt > rhs.lastActivityAt
            }
            .prefix(max(0, limit))
            .map { session in
                let workspaceName = workspaceDisplayName(
                    for: session.workspaceSidebarGroupKey,
                    projects: projects
                )
                return Item(
                    session: session,
                    workspaceDisplayName: workspaceName,
                    workspaceInitials: workspaceInitials(from: workspaceName)
                )
            }
    }

    static func workspaceInitials(from displayName: String) -> String {
        let letters = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber }
        let prefix = String(letters.prefix(2)).uppercased()
        if prefix.isEmpty { return "??" }
        if prefix.count == 1 { return "\(prefix)\(prefix)" }
        return prefix
    }

    static func badgeColor(for seed: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for scalar in seed.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16_777_619
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.68, brightness: 0.68)
    }

    private static func hasUserMessage(
        _ session: AgentSession,
        isMetadataOnly: (AgentSession.ID) -> Bool,
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool
    ) -> Bool {
        if session.messages.contains(where: { $0.role == .user }) {
            return true
        }
        if isMetadataOnly(session.id) {
            return metadataOnlyHasUserMessage(session.id)
        }
        return false
    }

    private static func workspaceDisplayName(
        for key: String,
        projects: [AgentProject]
    ) -> String {
        WorkspacePresentation.groupDisplayName(
            for: key,
            projects: projects,
            remoteRuntime: { AgentRuntimeStore.descriptor(id: $0) }
        )
    }
}
