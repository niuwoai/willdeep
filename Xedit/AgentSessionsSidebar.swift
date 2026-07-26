//
//  AgentSessionsSidebar.swift
//  WillDeep
//
//  Left sidebar for the Agent pane, split out of AgentModeView.swift in
//  rc42. Two pieces:
//   - `AgentSessionsSidebar`: the whole chats list — header band that
//     reserves room for traffic lights, provider-status pill (only when
//     more than one provider is configured), New Chat action, the
//     workspace-grouped session list with archived disclosure, and the
//     per-row hover-revealed pin/archive actions. Persists per-workspace
//     collapse / "see more" / archived disclosure state.
//   - `SidebarActionRow`: the small generic row used by the New Chat
//     entry (icon + title + optional ⌘N shortcut, hover-tints the row
//     background).
//
//  Previously `private struct` inside AgentModeView.swift; now internal
//  so the main view can mount them across file boundaries.
//

import AppKit
import SwiftUI

private struct SidebarWorkspaceGroup: Identifiable {
    let id: String
    let displayName: String
    let remoteRuntime: RuntimeDescriptor?
    let sessions: [AgentSession]
}

enum AgentSidebarSessionVisibility {
    /// `isMetadataOnly` / `metadataOnlyHasUserMessage` come from the
    /// caller's AppState instance — the classification is per-instance,
    /// so it cannot be looked up from a global here. Defaults treat every
    /// session as fully materialized, which is what in-memory-only
    /// callers (tests, previews) have.
    static func visibleSessions(
        from sessions: [AgentSession],
        activeID: AgentSession.ID?,
        isMetadataOnly: (AgentSession.ID) -> Bool = { _ in false },
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool = { _ in false }
    ) -> [AgentSession] {
        func hasUserMessage(_ session: AgentSession) -> Bool {
            Self.hasUserMessage(
                session,
                isMetadataOnly: isMetadataOnly,
                metadataOnlyHasUserMessage: metadataOnlyHasUserMessage
            )
        }

        var workspaceKeysWithHistory: Set<String> = []
        for session in sessions where hasUserMessage(session) {
            workspaceKeysWithHistory.insert(session.workspaceSidebarGroupKey)
        }

        var fallbackPlaceholderIDs: Set<AgentSession.ID> = []
        var placeholderWorkspaceKeys: Set<String> = []
        if let activeID,
           let activeSession = sessions.first(where: { $0.id == activeID }),
           !hasUserMessage(activeSession) {
            placeholderWorkspaceKeys.insert(activeSession.workspaceSidebarGroupKey)
        }
        for session in sessions {
            if session.id == activeID || hasUserMessage(session) { continue }
            let key = session.workspaceSidebarGroupKey
            if workspaceKeysWithHistory.contains(key) { continue }
            guard placeholderWorkspaceKeys.insert(key).inserted else { continue }
            fallbackPlaceholderIDs.insert(session.id)
        }

        return sessions.filter { session in
            session.isPinned
                || session.id == activeID
                || hasUserMessage(session)
                || fallbackPlaceholderIDs.contains(session.id)
        }
    }

    private static func hasUserMessage(
        _ session: AgentSession,
        isMetadataOnly: (AgentSession.ID) -> Bool,
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool
    ) -> Bool {
        if isMetadataOnly(session.id) {
            return metadataOnlyHasUserMessage(session.id)
        }
        return session.messages.contains { $0.role == .user }
    }
}

/// Splits the visible conversation list into Codex-style global pins and
/// workspace-owned rows. Pinning changes presentation only: the session keeps
/// its workspace binding, but appears once in the global section until it is
/// unpinned. Archived sessions stay behind their workspace disclosure even if
/// they were pinned before archiving.
enum AgentSidebarSessionPlacement {
    static func globalPinnedSessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions
            .filter { $0.isPinned && !$0.isArchived }
            .sorted { lhs, rhs in
                let lhsPinnedAt = lhs.pinnedAt ?? .distantPast
                let rhsPinnedAt = rhs.pinnedAt ?? .distantPast
                if lhsPinnedAt != rhsPinnedAt {
                    return lhsPinnedAt > rhsPinnedAt
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
    }

    static func workspaceSessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { !$0.isPinned || $0.isArchived }
    }

    static func workspaceOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        switch (lhs.isPinned, rhs.isPinned) {
        case (true, false): return true
        case (false, true): return false
        case (true, true):
            return (lhs.pinnedAt ?? .distantPast) > (rhs.pinnedAt ?? .distantPast)
        case (false, false):
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }
}

enum AgentSidebarSessionTrailingLayout {
    /// A pinned row only needs enough idle width for its compact pin glyph.
    /// The full action lane is restored when the pointer enters the row.
    private static let pinnedIndicatorWidth: CGFloat = 16

    static func reservedActionsWidth(isHovered: Bool, isPinned: Bool) -> CGFloat {
        if isHovered {
            return AgentDesign.sidebarSessionTrailingActionsWidth
        }
        return isPinned ? pinnedIndicatorWidth : 0
    }
}

struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var expandedWorkspaces = AgentSidebarWorkspaceStateStore.load(.expandedWorkspaces)
    /// Workspace keys the user has manually collapsed by clicking the
    /// folder icon — the whole group hides every session row and only
    /// the title line stays. Independent from `expandedWorkspaces` (that
    /// one controls the "more than 5 sessions → show all" toggle).
    @State private var collapsedWorkspaces = AgentSidebarWorkspaceStateStore.load(.collapsedWorkspaces)
    /// Workspace keys whose "已归档" sub-section is currently expanded.
    /// Archived sessions sit behind a disclosure row so they don't add
    /// noise to the main list but stay one click away.
    @State private var expandedArchivedGroups = AgentSidebarWorkspaceStateStore.load(.expandedArchivedGroups)
    /// The session row the mouse is hovering. Drives the on-row
    /// pin/archive button visibility — cursor-style "they only show up
    /// when you're aiming at them".
    @State private var hoveredSessionID: AgentSession.ID?
    /// The workspace group the mouse is hovering. Drives the trailing
    /// "+" (new chat in this workspace) button visibility, same
    /// show-on-aim pattern as the session rows.
    @State private var hoveredWorkspaceGroup: String?
    @State private var someIMAccount = SomeIMIntegrationStore.loadAuthenticatedAccount()
    @State private var isSomeIMAuthenticated = SomeIMIntegrationStore
        .loadAuthenticationSnapshot()
        .isAuthenticated
    @State private var isRefreshingSomeIMAccount = false
    @State private var someIMAccountStatus = ""

    private let initialRowCount = 5

    /// Vertical room left at the top of the sidebar for the macOS
    /// traffic-light buttons. The window uses `titlebarAppearsTransparent`,
    /// so close/minimize/zoom float over the first ~28pt of sidebar
    /// content — anything we draw inside this band gets hidden behind
    /// the buttons.
    private let trafficLightReserve: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            // Keep the traffic-light safe area, but let the real navigation
            // start immediately below it. The former "Chats" / provider
            // strip duplicated information available elsewhere and consumed
            // valuable vertical space in the sidebar.
            Color.clear.frame(height: trafficLightReserve)
            ScrollView {
                // Workspace groups are the expensive unit: each contains up
                // to five transcript rows plus badges/actions. Keeping them
                // as direct LazyVStack children prevents off-screen projects
                // from participating in every AttributeGraph layout pass.
                LazyVStack(alignment: .leading, spacing: 0) {
                    primaryActions
                    Spacer().frame(height: 18)
                    if appState.agentPrimaryDestination == .dispatchBoard {
                        AgentDispatchSidebarSections(
                            coordinator: appState.agentDispatchCoordinator
                        )
                    } else {
                        pinnedSessionsSection
                        workspacesHeader
                        ForEach(groupedSessions) { group in
                            workspaceGroup(group)
                        }
                        if appState.agentSessions.isEmpty {
                            Text(L10n.Sidebar.emptyState)
                                .font(AgentDesign.secondaryFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                        }
                    }
                }
                // 30pt 交通灯安全区继续保留；顶部只补 3pt 呼吸感，
                // 避免再叠加完整的 8pt，让“新聊天”显得离顶部过远。
                .padding(.top, 3)
                .padding(.bottom, 8)
                // 父 AgentModeView 给了 `.frame(width: sidebarWidth)`,
                // 但 SwiftUI ScrollView 里的内容若声明了更大的固有宽
                // 度(比如长 session title 跑出 truncation 边界),会向
                // 右溢出到 chat 区域。把内容显式钉到 maxWidth=.infinity
                // 让 ScrollView 知道它就只有那么宽,内部 Text 会按
                // truncationMode 收尾。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            someIMAccountFooter
        }
        // sidebar 整体再 clip 一次:即便 SwiftUI 在 narrow window 下
        // 没把某个子 view 完美约束,溢出的部分也不会糊到 chat / side
        // panel 上去。
        .clipped()
        .onAppear(perform: handleAppear)
        .onCompatibleChange(of: workspaceStatePruneKey) { _, _ in
            prunePersistedWorkspaceStateIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.accountDidChangeNotification)) { _ in
            reloadSomeIMAuthenticationState()
            if someIMAccount != nil {
                someIMAccountStatus = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
            reloadSomeIMAuthenticationState()
            if someIMAccount != nil {
                someIMAccountStatus = ""
            }
        }
        .task(id: isSomeIMAuthenticated) {
            await runAutomaticSomeIMAccountRefreshLoop()
        }
        .alert(
            L10n.Sidebar.sessionUnavailableAlertTitle,
            isPresented: sessionUnavailableAlertBinding
        ) {
            Button(L10n.Sidebar.sessionUnavailableConfirm, role: .cancel) {
                appState.dismissAgentSessionLoadFailure()
            }
        } message: {
            Text(L10n.Sidebar.sessionUnavailableAlertMessage(
                appState.agentSessionLoadFailure?.title ?? L10n.Sidebar.defaultSessionTitle
            ))
        }
    }

    private var sessionUnavailableAlertBinding: Binding<Bool> {
        Binding(
            get: { appState.agentSessionLoadFailure != nil },
            set: { isPresented in
                if !isPresented {
                    appState.dismissAgentSessionLoadFailure()
                }
            }
        )
    }

    @ViewBuilder
    private var someIMAccountFooter: some View {
        AgentSidebarAccountFooter(
            account: someIMAccount,
            isAuthenticated: isSomeIMAuthenticated,
            isRefreshingAccount: isRefreshingSomeIMAccount,
            accountStatus: someIMAccountStatus,
            onOpenAccount: { openSomeIMSettings() },
            onOpenLogin: { openSomeIMSettings(autogenerateBrowserLogin: true) },
            onRefreshAccount: refreshSomeIMAccount,
            onOpenSettings: {
                EditorSettingsNavigation.shared.open(.typography, appState: appState)
            },
            onLogOut: {
                SomeIMIntegrationStore.logout()
                appState.clearSomeIMProvider()
                someIMAccount = nil
                isSomeIMAuthenticated = false
                someIMAccountStatus = ""
            },
            onOpenHelp: {
                NSWorkspace.shared.open(AgentSidebarAccountLinks.helpURL())
            }
        )
        .environmentObject(appState)
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
            SidebarActionRow(
                icon: "clock",
                title: L10n.Automation.navigationTitle,
                shortcut: nil,
                isSelected: appState.agentPrimaryDestination == .scheduledTasks
            ) {
                appState.agentPrimaryDestination = .scheduledTasks
                appState.agentSidePanelKind = nil
                appState.agentSidePanelRequest = nil
            }
            SidebarActionRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: L10n.Dispatch.navigationTitle,
                shortcut: nil,
                isSelected: appState.agentPrimaryDestination == .dispatchBoard
            ) {
                appState.agentPrimaryDestination = .dispatchBoard
                appState.agentSidePanelKind = nil
                appState.agentSidePanelRequest = nil
                appState.agentDispatchCoordinator.synchronize(with: appState.agentSessions)
            }
            // 专家圆桌:切到嵌入的 .roundtable 目的地(和「已安排」同级,不切主
            // Agent 会话流);嵌入页内还提供「弹出到独立窗口」入口。
            SidebarActionRow(
                icon: "bubble.left.and.bubble.right",
                title: L10n.Roundtable.sidebarEntry,
                shortcut: nil,
                isSelected: appState.agentPrimaryDestination == .roundtable
            ) {
                appState.agentPrimaryDestination = .roundtable
                appState.agentSidePanelKind = nil
                appState.agentSidePanelRequest = nil
            }
        }
    }

    private var workspacesHeader: some View {
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
    }

    @ViewBuilder
    private var pinnedSessionsSection: some View {
        let sessions = globalPinnedSessions
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.Sidebar.pinnedHeader)
                    .font(AgentDesign.sidebarSectionFont)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)

                ForEach(sessions) { session in
                    sessionRow(
                        session,
                        contentHorizontalInset: AgentDesign.sidebarPinnedSessionContentHorizontalInset
                    )
                }
            }
            Spacer().frame(height: 12)
        }
    }

    @ViewBuilder
    private func workspaceGroup(_ group: SidebarWorkspaceGroup) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        let workspace = group.id
        let sessions = group.sessions
        let activeSessions = sessions.filter { !$0.isArchived }
        let archivedSessions = sessions.filter { $0.isArchived }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        let isExpanded = expandedWorkspaces.contains(workspace)
        let isCollapsed = collapsedWorkspaces.contains(workspace)
        let visible = isExpanded ? activeSessions : Array(activeSessions.prefix(initialRowCount))
        let archivedExpanded = expandedArchivedGroups.contains(workspace)
        let remoteWorkspace = remoteWorkspaceGroup(from: workspace)
        let remoteRuntime = group.remoteRuntime
        let isWorkspaceHovered = hoveredWorkspaceGroup == workspace

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AgentDesign.sidebarWorkspaceIconToTitleSpacing) {
                // Clicking the workspace identity collapses / expands the
                // whole group. Using `folder` vs `folder.fill` as the visual
                // affordance — filled means "closed, stuff hidden behind
                // it", outline means "open".
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        setWorkspaceCollapsed(workspace, collapsed: !isCollapsed)
                    }
                } label: {
                    HStack(spacing: AgentDesign.sidebarWorkspaceIconToTitleSpacing) {
                        Image(systemName: remoteWorkspace == nil
                            ? (isCollapsed ? "folder.fill" : "folder")
                            : WorkspacePresentation.remoteSymbolName(for: remoteRuntime))
                            .font(.system(size: AgentDesign.sidebarWorkspaceIconSize))
                            .foregroundStyle(remoteWorkspace == nil
                                ? palette.primaryText.opacity(AgentDesign.sidebarPrimaryTextOpacity)
                                : WorkspacePresentation.remoteTint(for: remoteRuntime))
                            .frame(
                                width: AgentDesign.sidebarWorkspaceIconSize,
                                height: AgentDesign.sidebarWorkspaceIconSize
                            )
                        Text(group.displayName)
                            .font(AgentDesign.sidebarWorkspaceFont)
                            .foregroundStyle(palette.primaryText.opacity(AgentDesign.sidebarPrimaryTextOpacity))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if remoteWorkspace != nil {
                            Text(WorkspacePresentation.remoteBadge(for: remoteRuntime))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(WorkspacePresentation.remoteTint(for: remoteRuntime))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(WorkspacePresentation.remoteTint(for: remoteRuntime).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? L10n.Sidebar.workspaceToggleExpandTooltip : L10n.Sidebar.workspaceToggleCollapseTooltip)
                Spacer(minLength: 0)
                Button {
                    startNewSession(inWorkspaceGroup: workspace)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isWorkspaceHovered ? 1 : 0)
                .allowsHitTesting(isWorkspaceHovered)
                .accessibilityHidden(!isWorkspaceHovered)
                .help(L10n.Sidebar.workspaceMenuNewChat)
            }
            .padding(.horizontal, AgentDesign.sidebarWorkspaceHorizontalInset)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .contextMenu {
                Button(L10n.Sidebar.workspaceMenuNewChat) {
                    startNewSession(inWorkspaceGroup: workspace)
                }
                if workspace != AgentSession.noWorkspaceSidebarGroupKey {
                    Divider()
                    // Removal only hides the group — sessions stay on disk
                    // and reappear if the same folder is re-added later.
                    Button(L10n.Sidebar.workspaceMenuRemove, role: .destructive) {
                        appState.hideWorkspace(key: workspace)
                    }
                }
            }

            if !isCollapsed {
                ForEach(visible) { session in
                    sessionRow(session)
                }

                if activeSessions.count > initialRowCount {
                    Button {
                        setWorkspaceExpanded(workspace, expanded: !isExpanded)
                    } label: {
                        Text(isExpanded ? L10n.Sidebar.sessionListShowLess : L10n.Sidebar.sessionListSeeMore)
                            .font(AgentDesign.sidebarRowFont)
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset + AgentDesign.sidebarSessionContentHorizontalInset)
                            .frame(height: AgentDesign.sidebarRowHeight)
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

            Spacer().frame(height: AgentDesign.sidebarWorkspaceGroupSpacing)
        }
        .onHover { hovering in
            if hovering {
                hoveredWorkspaceGroup = workspace
            } else if hoveredWorkspaceGroup == workspace {
                hoveredWorkspaceGroup = nil
            }
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
            setArchivedGroupExpanded(workspace, expanded: !isExpanded)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(L10n.Sidebar.archivedSessionsHeader(String(sessions.count)))
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AgentDesign.sidebarSessionContentHorizontalInset)
            .frame(height: AgentDesign.sidebarRowHeight)
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
    private func sessionRow(
        _ session: AgentSession,
        contentHorizontalInset: CGFloat = AgentDesign.sidebarSessionContentHorizontalInset
    ) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        let isActive = appState.activeAgentSessionID == session.id
        let isHovered = (hoveredSessionID == session.id)
        let observedRuntime = appState.agentRuntimes[session.id]
        let displaySession = observedRuntime?.session ?? session

        Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            HStack(spacing: 6) {
                if activeScheduledTaskCount(for: session) > 0 {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .help(L10n.Sidebar.hasActiveScheduledTasksTooltip)
                }
                // 被截断的标题在悬停时向左滚动整段可读(照 Claude 侧栏),
                // 松开指针回位;放得下的标题静止不动。hugWidth 用 NSFont
                // 同步测出自然宽度,保证短标题仍紧贴内容、徽章跟在标题后。
                MarqueeOnHoverText(
                    attributed: AttributedString(session.title),
                    font: AgentDesign.sidebarRowFont,
                    color: palette.primaryText.opacity(
                        isActive ? 1 : AgentDesign.sidebarPrimaryTextOpacity
                    ),
                    tooltip: L10n.Sidebar.sessionMenuRename,
                    hugWidth: Self.sessionTitleNaturalWidth(session.title)
                )
                // sidebar 收窄时:title 优先保留(给它 priority 1),
                // progress / trailing actions 走默认 0，SwiftUI 会先
                // 压缩 chrome，而不是把标题压到只剩一个字符。
                .layoutPriority(1)
                // Double-click the title to rename — same dialog as the
                // context-menu "Rename". Takes priority over the row
                // button's single-click select for two-tap sequences.
                .onTapGesture(count: 2) { presentRenameAlert(for: session) }
                AgentSessionApprovalBadge(
                    session: session,
                    runtime: observedRuntime,
                    baseFontSize: appState.agentChatBaseFontSize
                )
                Spacer(minLength: 0)
                AgentSessionModeBadges(
                    session: displaySession,
                    runtime: observedRuntime,
                    baseFontSize: appState.agentChatBaseFontSize
                )
                // Codex keeps ordinary rows visually quiet: no leading
                // bullet and no always-on timestamp. Runtime state moves
                // to the trailing edge, where it only becomes visible for
                // the active/running/waiting session.
                //
                // The active dot stays LAST — to the right of every other
                // row icon (mode badge, pin.fill, …) — so "this session is
                // live" always reads as the final marker on the row. It and
                // the hover-revealed pin/archive actions are mutually
                // exclusive (dot hides on hover, actions appear), so their
                // trailing slots don't fight for width.
                sessionRowTrailingActions(session: session, isHovered: isHovered)
                AgentSessionRowStatusDot(
                    runtime: observedRuntime,
                    isActive: isActive,
                    accentColor: palette.accent
                )
                .opacity(isHovered ? 0 : 1)
            }
            .padding(.horizontal, contentHorizontalInset)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(
                    cornerRadius: AgentDesign.sidebarSelectionCornerRadius,
                    style: .continuous
                )
                .fill(isActive ? palette.selectionFill : (isHovered ? palette.hoverFill : Color.clear))
            )
            .clipShape(RoundedRectangle(
                cornerRadius: AgentDesign.sidebarSelectionCornerRadius,
                style: .continuous
            ))
            .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
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
                requestArchiveToggle(for: session)
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
                presentDeleteAlert(for: session)
            }
        }
    }

    /// Deletion is the only unrecoverable action in this menu (rename
    /// already confirms via its own alert), so gate it behind an explicit
    /// NSAlert — a mis-click on the context menu used to wipe the whole
    /// conversation with no way back.
    private func presentDeleteAlert(for session: AgentSession) {
        let alert = NSAlert()
        alert.messageText = L10n.Sidebar.deleteSessionAlertTitle
        alert.informativeText = L10n.Sidebar.deleteSessionAlertMessage(session.title)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Sidebar.deleteSessionConfirm)
        alert.addButton(withTitle: L10n.Sidebar.deleteSessionCancel)
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        appState.deleteAgentSession(id: session.id)
    }

    /// Enabled scheduled tasks (routines) created from this session. Archiving
    /// a session stops these, so the row shows a clock badge and archiving
    /// confirms first.
    private func activeScheduledTaskCount(for session: AgentSession) -> Int {
        appState.agentRoutines.filter { $0.originSessionID == session.id && $0.isEnabled }.count
    }

    /// Archive / unarchive with a guard: archiving a session that still owns
    /// active scheduled tasks confirms first, then removes those tasks (they
    /// won't run once the session is archived).
    private func requestArchiveToggle(for session: AgentSession) {
        // Unarchiving, or no active tasks → just toggle.
        if session.isArchived || activeScheduledTaskCount(for: session) == 0 {
            appState.toggleAgentSessionArchived(id: session.id)
            return
        }
        let count = activeScheduledTaskCount(for: session)
        let alert = NSAlert()
        alert.messageText = L10n.Sidebar.archiveWithTasksTitle
        alert.informativeText = L10n.Sidebar.archiveWithTasksMessage("\(count)")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Sidebar.archiveWithTasksConfirm)
        alert.addButton(withTitle: L10n.Sidebar.archiveWithTasksCancel)
        if let confirmButton = alert.buttons.first {
            confirmButton.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for routine in appState.agentRoutines where routine.originSessionID == session.id {
            appState.deleteAgentRoutine(id: routine.id)
        }
        appState.toggleAgentSessionArchived(id: session.id)
    }

    /// Pop a tiny NSAlert with an accessory NSTextField for renaming.
    /// We use AppKit directly because SwiftUI's `.alert(...)` doesn't
    /// expose a text-input variant on macOS pre-14 and trying to roll
    /// one inline in the row View blows up the state machine. The
    /// alert is modal to the active window, so the user can't keep
    /// typing into the session list while it's open.
    /// 会话标题的自然排版宽度(单行、sidebarRowFont)。给
    /// MarqueeOnHoverText 的 hugWidth 用:同步测出结果,首帧就有正确
    /// 上限,不用等 PreferenceKey 回填(那会让徽章闪一下)。+2 的余量
    /// 抵消 NSString 测宽与 SwiftUI Text 渲染间的亚像素差,防止刚好
    /// 放得下的标题被削掉最后一个字符的边。
    private static func sessionTitleNaturalWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: AgentDesign.sidebarRowFontSize)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + 2
    }

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
    /// glance even without hovering. Idle unpinned rows release this lane
    /// back to the title; hovering restores the full controls, while a
    /// pinned row reserves only the compact pin glyph.
    @ViewBuilder
    private func sessionRowTrailingActions(session: AgentSession, isHovered: Bool) -> some View {
        HStack(spacing: 4) {
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

            Button {
                requestArchiveToggle(for: session)
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
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
        .overlay(alignment: .trailing) {
            if session.isPinned && !isHovered {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(
            width: AgentSidebarSessionTrailingLayout.reservedActionsWidth(
                isHovered: isHovered,
                isPinned: session.isPinned
            ),
            alignment: .trailing
        )
        .clipped()
    }

    private var groupedSessions: [SidebarWorkspaceGroup] {
        // Hide empty "New Chat" rows — sessions that never got a user
        // message just clutter the sidebar with a wall of identical
        // placeholders (see screenshot). The active session is always kept
        // visible even when empty, because it's the one the user is about
        // to type into; hiding it would make the highlight disappear. If a
        // workspace has no real chat yet, keep one empty placeholder so an
        // added project does not vanish the moment the next project is added.
        let visibleSessions = AgentSidebarSessionVisibility.visibleSessions(
            from: appState.agentSessions,
            activeID: appState.activeAgentSessionID,
            isMetadataOnly: appState.agentSessionIsMetadataOnly,
            metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
        )
        let groups = Dictionary(grouping: visibleSessions) { session in
            session.workspaceSidebarGroupKey
        }
        let remoteDescriptors = remoteRuntimeDescriptorsByID
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
            .filter { !appState.hiddenWorkspaceKeys.contains($0.key) }
            .map { entry in
                let remoteWorkspace = remoteWorkspaceGroup(from: entry.key)
                let remoteRuntime = remoteWorkspace.flatMap { remoteDescriptors[$0.runtimeID] }
                return SidebarWorkspaceGroup(
                    id: entry.key,
                    displayName: workspaceDisplayName(entry.key, remoteDescriptors: remoteDescriptors),
                    remoteRuntime: remoteRuntime,
                    sessions: AgentSidebarSessionPlacement
                        .workspaceSessions(from: entry.value)
                        .sorted(by: AgentSidebarSessionPlacement.workspaceOrder)
                )
            }
            .sorted { lhs, rhs in
                let lKey = lhs.id
                let rKey = rhs.id
                let lIsNoWorkspace = (lKey == AgentSession.noWorkspaceSidebarGroupKey)
                let rIsNoWorkspace = (rKey == AgentSession.noWorkspaceSidebarGroupKey)
                if lIsNoWorkspace != rIsNoWorkspace { return !lIsNoWorkspace }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var globalPinnedSessions: [AgentSession] {
        let visibleSessions = AgentSidebarSessionVisibility.visibleSessions(
            from: appState.agentSessions,
            activeID: appState.activeAgentSessionID,
            isMetadataOnly: appState.agentSessionIsMetadataOnly,
            metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
        )
        return AgentSidebarSessionPlacement.globalPinnedSessions(from: visibleSessions)
    }

    private var remoteRuntimeDescriptorsByID: [UUID: RuntimeDescriptor] {
        var descriptors: [UUID: RuntimeDescriptor] = [:]
        for descriptor in AgentRuntimeStore.loadDescriptors() {
            descriptors[descriptor.id] = descriptor
        }
        return descriptors
    }

    private var workspaceStatePruneKey: [String] {
        Array(Set(appState.agentSessions.map(\.workspaceSidebarGroupKey))).sorted()
    }

    private func setWorkspaceExpanded(_ workspace: String, expanded: Bool) {
        var updated = expandedWorkspaces
        guard updateWorkspaceState(&updated, workspace: workspace, enabled: expanded) else { return }
        expandedWorkspaces = updated
        AgentSidebarWorkspaceStateStore.save(updated, kind: .expandedWorkspaces)
    }

    private func setWorkspaceCollapsed(_ workspace: String, collapsed: Bool) {
        var updated = collapsedWorkspaces
        guard updateWorkspaceState(&updated, workspace: workspace, enabled: collapsed) else { return }
        collapsedWorkspaces = updated
        AgentSidebarWorkspaceStateStore.save(updated, kind: .collapsedWorkspaces)
    }

    private func setArchivedGroupExpanded(_ workspace: String, expanded: Bool) {
        var updated = expandedArchivedGroups
        guard updateWorkspaceState(&updated, workspace: workspace, enabled: expanded) else { return }
        expandedArchivedGroups = updated
        AgentSidebarWorkspaceStateStore.save(updated, kind: .expandedArchivedGroups)
    }

    private func updateWorkspaceState(_ values: inout Set<String>, workspace: String, enabled: Bool) -> Bool {
        if enabled {
            return values.insert(workspace).inserted
        }
        return values.remove(workspace) != nil
    }

    private func handleAppear() {
        prunePersistedWorkspaceStateIfNeeded()
        reloadSomeIMAuthenticationState()
    }

    private func reloadSomeIMAuthenticationState() {
        let authentication = SomeIMIntegrationStore.loadAuthenticationSnapshot()
        isSomeIMAuthenticated = authentication.isAuthenticated
        someIMAccount = authentication.account
    }

    private func prunePersistedWorkspaceStateIfNeeded() {
        let valid = Set(workspaceStatePruneKey)
        expandedWorkspaces = AgentSidebarWorkspaceStateStore.prune(expandedWorkspaces, to: valid, kind: .expandedWorkspaces)
        collapsedWorkspaces = AgentSidebarWorkspaceStateStore.prune(collapsedWorkspaces, to: valid, kind: .collapsedWorkspaces)
        expandedArchivedGroups = AgentSidebarWorkspaceStateStore.prune(expandedArchivedGroups, to: valid, kind: .expandedArchivedGroups)
    }

    private func refreshSomeIMAccount() {
        Task {
            await refreshSomeIMAccountNow()
        }
    }

    @MainActor
    private func refreshSomeIMAccountNow() async {
        guard !isRefreshingSomeIMAccount else { return }
        let authentication = SomeIMIntegrationStore.loadAuthenticationSnapshot()
        guard authentication.isAuthenticated else {
            isSomeIMAuthenticated = false
            someIMAccount = nil
            someIMAccountStatus = ""
            return
        }
        isSomeIMAuthenticated = true
        isRefreshingSomeIMAccount = true
        someIMAccountStatus = ""
        defer { isRefreshingSomeIMAccount = false }
        do {
            someIMAccount = try await SomeIMClient.fetchAccountBalance()
        } catch {
            someIMAccountStatus = error.localizedDescription
        }
    }

    @MainActor
    private func runAutomaticSomeIMAccountRefreshLoop() async {
        guard isSomeIMAuthenticated else { return }
        if someIMAccount == nil || SomeIMAccountRefreshPolicy.shouldRefresh(someIMAccount) {
            await refreshSomeIMAccountNow()
        }
        while !Task.isCancelled, isSomeIMAuthenticated {
            let delay = SomeIMAccountRefreshPolicy.nextDelay()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshSomeIMAccountNow()
        }
    }


    @MainActor
    private func openSomeIMSettings(autogenerateBrowserLogin: Bool = false) {
        EditorSettingsNavigation.shared.openSomeIM(
            autogenerateBrowserLogin: autogenerateBrowserLogin,
            appState: appState
        )
    }

    private func workspaceDisplayName(
        _ key: String,
        remoteDescriptors: [UUID: RuntimeDescriptor]
    ) -> String {
        if key == AgentSession.noWorkspaceSidebarGroupKey { return L10n.Workspace.noWorkspace }
        if let remote = remoteWorkspaceGroup(from: key) {
            let runtime = remoteDescriptors[remote.runtimeID]
            return WorkspacePresentation.remoteDisplayName(runtime: runtime, path: remote.path)
        }
        return localWorkspaceDisplayName(key)
    }

    private func localWorkspaceDisplayName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    private func localWorkspacePath(for key: String) -> String? {
        guard key != AgentSession.noWorkspaceSidebarGroupKey,
              remoteWorkspaceGroup(from: key) == nil else {
            return nil
        }
        return key
    }

    private func startNewSession(inWorkspaceGroup key: String) {
        if let remote = remoteWorkspaceGroup(from: key) {
            appState.moveActiveAgentSessionToRemoteWorkspace(runtimeID: remote.runtimeID, path: remote.path)
        } else {
            appState.startNewAgentSession(inWorkspaceAt: localWorkspacePath(for: key))
        }
    }

    private func remoteWorkspaceGroup(from key: String) -> (runtimeID: UUID, path: String)? {
        let prefix = "remote:"
        guard key.hasPrefix(prefix) else { return nil }
        let remainder = String(key.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let idPart = String(remainder[..<separator])
        guard let runtimeID = UUID(uuidString: idPart) else { return nil }
        let path = String(remainder[remainder.index(after: separator)...])
        return (runtimeID, path)
    }

}

enum AgentSidebarWorkspaceStateStore {
    enum Kind {
        case expandedWorkspaces
        case collapsedWorkspaces
        case expandedArchivedGroups

        var defaultsKey: String {
            switch self {
            case .expandedWorkspaces:
                return "com.willdeep.sidebar.expandedWorkspaceKeys.v1"
            case .collapsedWorkspaces:
                return "com.willdeep.sidebar.collapsedWorkspaceKeys.v1"
            case .expandedArchivedGroups:
                return "com.willdeep.sidebar.expandedArchivedWorkspaceKeys.v1"
            }
        }
    }

    static func load(_ kind: Kind, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: kind.defaultsKey) ?? [])
    }

    static func save(_ values: Set<String>, kind: Kind, defaults: UserDefaults = .standard) {
        let sorted = values.sorted()
        if sorted.isEmpty {
            defaults.removeObject(forKey: kind.defaultsKey)
        } else {
            defaults.set(sorted, forKey: kind.defaultsKey)
        }
    }

    @discardableResult
    static func prune(
        _ values: Set<String>,
        to validValues: Set<String>,
        kind: Kind,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        let pruned = values.intersection(validValues)
        guard pruned != values else { return values }
        save(pruned, kind: kind, defaults: defaults)
        return pruned
    }
}

enum AgentRelativeTimestamp {
    static func compactString(since date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        let minute = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        let month = 30 * day
        let year = 365 * day

        if elapsed < minute {
            return "0m"
        }
        if elapsed < hour {
            return "\(elapsed / minute)m"
        }
        if elapsed < day {
            return "\(elapsed / hour)h"
        }
        if elapsed < week {
            return "\(elapsed / day)d"
        }
        if elapsed < month {
            return "\(elapsed / week)w"
        }
        if elapsed < year {
            return "\(elapsed / month)mo"
        }
        return "\(elapsed / year)y"
    }
}

struct SidebarActionRow: View {
    @EnvironmentObject var appState: AppState

    let icon: String
    let title: String
    let shortcut: String?
    var isDimmed: Bool = false
    var isSelected: Bool = false
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Title 是主信息,sidebar 收窄时优先保留它,把 shortcut
                    // (e.g. "⌘N") 先挤掉而不是反过来。
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.sidebarSelectionCornerRadius)
                    .fill(rowBackground)
                    .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isDimmed)
    }

    private var rowBackground: Color {
        let palette = appState.editorSettings.interfaceSkin.palette
        if isSelected {
            return palette.selectionFill
        }
        if isHovered {
            return palette.hoverFill
        }
        return .clear
    }
}
