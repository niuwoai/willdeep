//
//  AgentSessionsSidebar.swift
//  VeilWriter
//
//  Left sidebar for the Agent pane, split out of AgentModeView.swift in
//  rc42. Two pieces:
//   - `AgentSessionsSidebar`: the whole chats list — header band that
//     reserves room for traffic lights, provider-status pill (only when
//     more than one provider is configured), New Chat action, the
//     workspace-grouped session list with archived disclosure, and the
//     per-row hover-revealed pin/archive actions. Owns its own collapse
//     and "see more" toggle state.
//   - `SidebarActionRow`: the small generic row used by the New Chat
//     entry (icon + title + optional ⌘N shortcut, hover-tints the row
//     background).
//
//  Previously `private struct` inside AgentModeView.swift; now internal
//  so the main view can mount them across file boundaries.
//

import AppKit
import SwiftUI

struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var expandedWorkspaces: Set<String> = []
    /// Workspace keys the user has manually collapsed by clicking the
    /// folder icon — the whole group hides every session row and only
    /// the title line stays. Independent from `expandedWorkspaces` (that
    /// one controls the "more than 5 sessions → show all" toggle).
    @State private var collapsedWorkspaces: Set<String> = []
    /// Workspace keys whose "已归档" sub-section is currently expanded.
    /// Archived sessions sit behind a disclosure row so they don't add
    /// noise to the main list but stay one click away.
    @State private var expandedArchivedGroups: Set<String> = []
    /// The session row the mouse is hovering. Drives the on-row
    /// pin/archive button visibility — cursor-style "they only show up
    /// when you're aiming at them".
    @State private var hoveredSessionID: AgentSession.ID?
    /// The workspace group header the mouse is hovering. Drives the
    /// trailing "+" (new chat in this workspace) button visibility,
    /// same show-on-aim pattern as the session rows.
    @State private var hoveredWorkspaceHeader: String?

    private let initialRowCount = 5

    /// Vertical room left at the top of the sidebar for the macOS
    /// traffic-light buttons. The window uses `titlebarAppearsTransparent`,
    /// so close/minimize/zoom float over the first ~28pt of sidebar
    /// content — anything we draw inside this band gets hidden behind
    /// the buttons.
    private let trafficLightReserve: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            // Spacer reserves space for the traffic lights; the "CHATS"
            // header drops to the row below them so it stays visible.
            Color.clear.frame(height: trafficLightReserve)
            sidebarHeader
            providerStatusBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    primaryActions
                    Spacer().frame(height: 18)
                    AgentRoutinesSidebarSection()
                    Spacer().frame(height: 4)
                    workspacesSection
                    if appState.agentSessions.isEmpty {
                        Text(L10n.Sidebar.emptyState)
                            .font(AgentDesign.secondaryFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Text(L10n.Sidebar.chatsHeader)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    /// One-line status pill showing which library entry is currently
    /// active, with a click-to-switch menu. Hidden when only one entry
    /// exists — no point in a picker that has nothing to pick.
    @ViewBuilder
    private var providerStatusBar: some View {
        if appState.agentProviderLibrary.entries.count > 1 {
            Menu {
                ForEach(appState.agentProviderLibrary.entries) { entry in
                    Button {
                        appState.setActiveProviderLibraryEntry(id: entry.id)
                    } label: {
                        HStack {
                            Text(entry.displayName)
                            if appState.agentProviderLibrary.activeID == entry.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    Text(activeProviderLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AgentDesign.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .help(L10n.ProviderStatus.help)
        }
    }

    private var activeProviderLabel: String {
        appState.agentProviderLibrary.active?.displayName ?? "No provider"
    }

    private var primaryActions: some View {
        // Automations / Customize used to live here as dimmed
        // placeholders — they had no behavior and just took up real
        // estate, so they've been removed. Add them back when there's
        // a real feature to attach.
        VStack(spacing: 0) {
            SidebarActionRow(icon: "square.and.pencil", title: L10n.Sidebar.newChatAction, shortcut: "⌘N") {
                appState.startNewAgentSession()
            }
        }
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.Sidebar.workspaceHeader)
                    .font(AgentDesign.sidebarSectionFont)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                // 标题行右侧"打开新工作区"入口。和 Composer 下方
                // WorkspacePickerPill 的 "Choose folder…" 走同一条路：
                // 选完目录后**立刻**新建一个 Agent 会话并锚到这个
                // workspace 路径，分组立刻出现在下面的列表里——而不是
                // 只切了根目录，让用户再手动 New Chat 一次才看到分组。
                Button {
                    appState.openFolderAndStartAgentSession()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.Sidebar.workspaceHeaderOpenTooltip)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            ForEach(groupedSessions, id: \.0) { workspace, sessions in
                workspaceGroup(workspace: workspace, sessions: sessions)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroup(workspace: String, sessions: [AgentSession]) -> some View {
        let activeSessions = sessions.filter { !$0.isArchived }
        let archivedSessions = sessions.filter { $0.isArchived }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        let isExpanded = expandedWorkspaces.contains(workspace)
        let isCollapsed = collapsedWorkspaces.contains(workspace)
        let visible = isExpanded ? activeSessions : Array(activeSessions.prefix(initialRowCount))
        let archivedExpanded = expandedArchivedGroups.contains(workspace)
        let hasRealWorkspace = workspace != "_no_workspace_"

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Clicking the folder glyph collapses / expands the whole
                // group. Using `folder` vs `folder.fill` as the visual
                // affordance — filled means "closed, stuff hidden behind
                // it", outline means "open". The hit target stays small
                // (just the icon) so dragging across the title line or
                // hitting the right-click menu still works as before.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isCollapsed {
                            collapsedWorkspaces.remove(workspace)
                        } else {
                            collapsedWorkspaces.insert(workspace)
                        }
                    }
                } label: {
                    Image(systemName: isCollapsed ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? L10n.Sidebar.workspaceToggleExpandTooltip : L10n.Sidebar.workspaceToggleCollapseTooltip)
                Text(workspaceDisplayName(workspace))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hoveredWorkspaceHeader == workspace {
                    Button {
                        appState.startNewAgentSession(inWorkspaceAt: hasRealWorkspace ? workspace : nil)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.Sidebar.workspaceMenuNewChat)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredWorkspaceHeader = workspace
                } else if hoveredWorkspaceHeader == workspace {
                    hoveredWorkspaceHeader = nil
                }
            }
            .contextMenu {
                Button(L10n.Sidebar.workspaceMenuNewChat) {
                    appState.startNewAgentSession(inWorkspaceAt: hasRealWorkspace ? workspace : nil)
                }
            }

            if !isCollapsed {
                ForEach(visible) { session in
                    sessionRow(session)
                }

                if activeSessions.count > initialRowCount {
                    Button {
                        if isExpanded {
                            expandedWorkspaces.remove(workspace)
                        } else {
                            expandedWorkspaces.insert(workspace)
                        }
                    } label: {
                        Text(isExpanded ? L10n.Sidebar.sessionListShowLess : L10n.Sidebar.sessionListSeeMore)
                            .font(AgentDesign.secondaryFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }

                if !archivedSessions.isEmpty {
                    archivedDisclosure(
                        workspace: workspace,
                        sessions: archivedSessions,
                        isExpanded: archivedExpanded
                    )
                }
            }

            Spacer().frame(height: 10)
        }
    }

    /// Collapsed disclosure row that sits at the bottom of each
    /// workspace group and reveals archived sessions when clicked.
    /// Kept dim and small so the eye treats it as secondary chrome —
    /// archived chats are out of sight by default, one click away.
    @ViewBuilder
    private func archivedDisclosure(
        workspace: String,
        sessions: [AgentSession],
        isExpanded: Bool
    ) -> some View {
        Button {
            if isExpanded {
                expandedArchivedGroups.remove(workspace)
            } else {
                expandedArchivedGroups.insert(workspace)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(L10n.Sidebar.archivedSessionsHeader(String(sessions.count)))
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isExpanded {
            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession) -> some View {
        let isActive = appState.activeAgentSessionID == session.id
        let isHovered = (hoveredSessionID == session.id)

        Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            HStack(spacing: 6) {
                // The status dot has three lives:
                //   • active session       → accent color (no animation)
                //   • runtime mid-turn     → green pulse (background runner)
                //   • runtime awaits user  → amber pulse (needs your eyes)
                //   • idle / cold          → default grey
                // Pulled out to its own view because we need to observe
                // the per-session runtime (if there is one); a static
                // expression here would only refresh when the row's
                // session changes, not when the runtime's `isResponding`
                // flips mid-stream.
                AgentSessionRowStatusDot(
                    runtime: appState.agentRuntimes[session.id],
                    isActive: isActive
                )
                Text(session.title)
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                AgentSessionModeBadges(session: session)
                sessionRowTrailingActions(session: session, isHovered: isHovered)
            }
            .padding(.horizontal, 28)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
                hoveredSessionID = nil
            }
        }
        .contextMenu {
            Button(session.isPinned ? L10n.Sidebar.sessionMenuUnpin : L10n.Sidebar.sessionMenuPin) {
                appState.toggleAgentSessionPinned(id: session.id)
            }
            Button(session.isArchived ? L10n.Sidebar.sessionMenuUnarchive : L10n.Sidebar.sessionMenuArchive) {
                appState.toggleAgentSessionArchived(id: session.id)
            }
            Divider()
            Button(L10n.Sidebar.sessionMenuRename) {
                presentRenameAlert(for: session)
            }
            Button(L10n.Sidebar.sessionMenuSummarizeTitle) {
                appState.manuallySummarizeAgentSessionTitle(id: session.id)
            }
            .disabled(appState.agentRuntimes[session.id] == nil)
            Divider()
            Button(L10n.Sidebar.sessionMenuDelete, role: .destructive) {
                appState.deleteAgentSession(id: session.id)
            }
        }
    }

    /// Pop a tiny NSAlert with an accessory NSTextField for renaming.
    /// We use AppKit directly because SwiftUI's `.alert(...)` doesn't
    /// expose a text-input variant on macOS pre-14 and trying to roll
    /// one inline in the row View blows up the state machine. The
    /// alert is modal to the active window, so the user can't keep
    /// typing into the session list while it's open.
    private func presentRenameAlert(for session: AgentSession) {
        let alert = NSAlert()
        alert.messageText = L10n.Sidebar.renameSessionAlertTitle
        alert.informativeText = L10n.Sidebar.renameSessionAlertMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Sidebar.renameSessionConfirm)
        alert.addButton(withTitle: L10n.Sidebar.renameSessionCancel)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = session.title
        input.placeholderString = session.title
        input.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        appState.renameAgentSession(id: session.id, to: input.stringValue)
    }

    /// Trailing icon cluster on each session row — pin & archive
    /// buttons that fade in on hover, plus a persistent `pin.fill`
    /// badge when the row is pinned so users can see the state at a
    /// glance even without hovering. Cursor-style: the actions stay
    /// out of the way until the user is aiming at the row.
    @ViewBuilder
    private func sessionRowTrailingActions(session: AgentSession, isHovered: Bool) -> some View {
        HStack(spacing: 4) {
            // Persistent pin badge when pinned & not hovered. While
            // hovered, the badge is replaced by the (also pinned-state-
            // aware) toggle button below, so we don't double up.
            if session.isPinned && !isHovered {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(45))
            }

            if isHovered {
                // Pin / Unpin
                Button {
                    appState.toggleAgentSessionPinned(id: session.id)
                } label: {
                    Image(systemName: session.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.isPinned ? L10n.Sidebar.sessionRowUnpinTooltip : L10n.Sidebar.sessionRowPinTooltip)

                // Archive / Unarchive
                Button {
                    appState.toggleAgentSessionArchived(id: session.id)
                } label: {
                    Image(systemName: session.isArchived ? "tray.and.arrow.up" : "archivebox")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.isArchived ? L10n.Sidebar.sessionRowUnarchiveTooltip : L10n.Sidebar.sessionRowArchiveTooltip)
            }
        }
        .frame(minWidth: isHovered ? 40 : 0, alignment: .trailing)
    }

    private var groupedSessions: [(String, [AgentSession])] {
        // Hide empty "New Chat" rows — sessions that never got a user
        // message just clutter the sidebar with a wall of identical
        // placeholders (see screenshot). The active session is always kept
        // visible even when empty, because it's the one the user is about
        // to type into; hiding it would make the highlight disappear.
        let activeID = appState.activeAgentSessionID
        let visibleSessions = appState.agentSessions.filter { session in
            if session.id == activeID { return true }
            return session.messages.contains(where: { $0.role == .user })
        }
        let groups = Dictionary(grouping: visibleSessions) { session in
            session.workspaceRootPath ?? "_no_workspace_"
        }
        // Group order rules — fully static, never depends on session
        // updatedAt or on which folder is currently open. The user
        // explicitly asked for the workspace list to stop moving around
        // (even "the active project floats to the top" was too dynamic).
        //   1. Every named workspace is sorted by its last path component
        //      via `localizedCaseInsensitiveCompare` — deterministic,
        //      Finder-like, doesn't depend on full path length.
        //   2. "No workspace" is pinned to the bottom — it's a catch-all,
        //      not a real project.
        // Sessions *inside* a group still sort by updatedAt (most recent
        // first), so within a folder the chat order still reflects
        // recency — only the folder ordering is frozen.
        return groups
            .map { ($0.key, $0.value.sorted(by: sessionOrder)) }
            .sorted { lhs, rhs in
                let lKey = lhs.0
                let rKey = rhs.0
                let lIsNoWorkspace = (lKey == "_no_workspace_")
                let rIsNoWorkspace = (rKey == "_no_workspace_")
                if lIsNoWorkspace != rIsNoWorkspace { return !lIsNoWorkspace }
                let lName = workspaceDisplayName(lKey)
                let rName = workspaceDisplayName(rKey)
                return lName.localizedCaseInsensitiveCompare(rName) == .orderedAscending
            }
    }

    private func workspaceDisplayName(_ key: String) -> String {
        if key == "_no_workspace_" { return "No workspace" }
        return URL(fileURLWithPath: key).lastPathComponent
    }

    /// Within-group ordering:
    ///   1. Pinned rows first, most-recently-pinned at the top of the
    ///      pinned block (`pinnedAt` desc) — re-pinning therefore
    ///      bubbles a chat back to the very top.
    ///   2. Non-pinned rows after, by recency (`updatedAt` desc).
    /// Archived rows still flow through this comparator; `workspaceGroup`
    /// splits them off into the disclosure section after sorting, so the
    /// archived disclosure stays in updatedAt-desc order too.
    private func sessionOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        switch (lhs.isPinned, rhs.isPinned) {
        case (true, false): return true
        case (false, true): return false
        case (true, true):
            return (lhs.pinnedAt ?? .distantPast) > (rhs.pinnedAt ?? .distantPast)
        case (false, false):
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

struct SidebarActionRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .foregroundStyle(isDimmed ? .tertiary : .secondary)
                Text(title)
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(isHovered ? AgentDesign.subtleBackground : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isDimmed)
    }
}
