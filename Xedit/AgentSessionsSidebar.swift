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

struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
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
    @State private var someIMAccount = SomeIMIntegrationStore.loadAccount()
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
            // Spacer reserves space for the traffic lights; the "CHATS"
            // header drops to the row below them so it stays visible.
            Color.clear.frame(height: trafficLightReserve)
            sidebarHeader
            providerStatusBar
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        primaryActions
                        Spacer().frame(height: 18)
                        AgentRoutinesSidebarSection()
                        Spacer().frame(height: 4)
                        workspacesSection(now: timeline.date)
                        if appState.agentSessions.isEmpty {
                            Text(L10n.Sidebar.emptyState)
                                .font(AgentDesign.secondaryFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.vertical, 8)
                    // 父 AgentModeView 给了 `.frame(width: sidebarWidth)`,
                    // 但 SwiftUI ScrollView 里的内容若声明了更大的固有宽
                    // 度(比如长 session title 跑出 truncation 边界),会向
                    // 右溢出到 chat 区域。把内容显式钉到 maxWidth=.infinity
                    // 让 ScrollView 知道它就只有那么宽,内部 Text 会按
                    // truncationMode 收尾。
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            someIMAccount = SomeIMIntegrationStore.loadAccount()
        }
    }

    @ViewBuilder
    private var someIMAccountFooter: some View {
        Divider()
        HStack(spacing: 8) {
            if let account = someIMAccount {
                Button {
                    // Logged in → open the some.im tab in Settings (not the browser).
                    openSomeIMSettings()
                } label: {
                    HStack(spacing: 8) {
                        someIMAvatar(title: account.email, isAnonymous: false)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.Sidebar.someIMAccountTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(L10n.Sidebar.someIMCredits(account.compactDisplayCredits))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "gearshape")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(someIMAccountStatus.isEmpty ? L10n.Sidebar.someIMSettingsTooltip : someIMAccountStatus)

                Button {
                    refreshSomeIMAccount()
                } label: {
                    if isRefreshingSomeIMAccount {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingSomeIMAccount)
                .help(L10n.Sidebar.someIMRefreshTooltip)
            } else {
                Button {
                    openSomeIMSettings(autogenerateBrowserLogin: true)
                } label: {
                    HStack(spacing: 8) {
                        someIMAvatar(title: "", isAnonymous: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.Sidebar.someIMAccountTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(L10n.Sidebar.someIMNotLoggedIn)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "gearshape")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .simultaneousGesture(TapGesture().onEnded {
                    openSomeIMSettings(autogenerateBrowserLogin: true)
                })
                .help(L10n.Sidebar.someIMNotLoggedInTooltip)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.48))
        .contentShape(Rectangle())
        .onTapGesture {
            if someIMAccount == nil {
                openSomeIMSettings(autogenerateBrowserLogin: true)
            }
        }
    }

    private func someIMAvatar(title: String, isAnonymous: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isAnonymous ? Color.secondary.opacity(0.16) : appState.editorSettings.interfaceSkin.palette.accent.opacity(0.22))
            if isAnonymous {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(someIMAvatarInitials(from: title))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
            }
        }
        .frame(width: 28, height: 28)
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
                let palette = appState.editorSettings.interfaceSkin.palette
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accent)
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
                .background(palette.controlFill.opacity(0.72))
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

    private func workspacesSection(now: Date) -> some View {
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
                workspaceGroup(workspace: workspace, sessions: sessions, now: now)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroup(workspace: String, sessions: [AgentSession], now: Date) -> some View {
        let activeSessions = sessions.filter { !$0.isArchived }
        let archivedSessions = sessions.filter { $0.isArchived }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        let isExpanded = expandedWorkspaces.contains(workspace)
        let isCollapsed = collapsedWorkspaces.contains(workspace)
        let visible = isExpanded ? activeSessions : Array(activeSessions.prefix(initialRowCount))
        let archivedExpanded = expandedArchivedGroups.contains(workspace)
        let remoteWorkspace = remoteWorkspaceGroup(from: workspace)
        let remoteRuntime = remoteWorkspace.flatMap { AgentRuntimeStore.descriptor(id: $0.runtimeID) }
        let isWorkspaceHovered = hoveredWorkspaceGroup == workspace

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Clicking the workspace identity collapses / expands the
                // whole group. Using `folder` vs `folder.fill` as the visual
                // affordance — filled means "closed, stuff hidden behind
                // it", outline means "open".
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        setWorkspaceCollapsed(workspace, collapsed: !isCollapsed)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: remoteWorkspace == nil
                            ? (isCollapsed ? "folder.fill" : "folder")
                            : WorkspacePresentation.remoteSymbolName(for: remoteRuntime))
                            .font(.system(size: 11))
                            .foregroundStyle(remoteWorkspace == nil ? Color.secondary : WorkspacePresentation.remoteTint(for: remoteRuntime))
                            .frame(width: 14, height: 14)
                        Text(workspaceDisplayName(workspace))
                            .font(.system(size: 12, weight: .semibold))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
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
                    sessionRow(session, now: now)
                }

                if activeSessions.count > initialRowCount {
                    Button {
                        setWorkspaceExpanded(workspace, expanded: !isExpanded)
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
                        isExpanded: archivedExpanded,
                        now: now
                    )
                }
            }

            Spacer().frame(height: 10)
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
        isExpanded: Bool,
        now: Date
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
                sessionRow(session, now: now)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession, now: Date) -> some View {
        let isActive = appState.activeAgentSessionID == session.id
        let isHovered = (hoveredSessionID == session.id)
        let observedRuntime = appState.agentRuntimes[session.id]
        let displaySession = observedRuntime?.session ?? session
        let todoSummary = AgentSessionTodoSummaryLogic.summary(for: displaySession)

        Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
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
                    if activeScheduledTaskCount(for: session) > 0 {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help(L10n.Sidebar.hasActiveScheduledTasksTooltip)
                    }
                    AgentSessionRowStatusDot(
                        runtime: observedRuntime,
                        isActive: isActive
                    )
                    Text(session.title)
                        .font(AgentDesign.sidebarRowFont)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // sidebar 收窄时:title 优先保留(给它 priority 1),
                        // badge / 时间 chip / trailing actions 走默认 0,
                        // SwiftUI 会先压缩低优先级元素,而不是把 title 压到
                        // 一个字符然后留一堆空白给 chrome。
                        .layoutPriority(1)
                        // Double-click the title to rename — same dialog as the
                        // context-menu "Rename". Takes priority over the row
                        // button's single-click select for two-tap sequences.
                        .onTapGesture(count: 2) { presentRenameAlert(for: session) }
                        .help(L10n.Sidebar.sessionMenuRename)
                    AgentSessionApprovalBadge(
                        session: session,
                        runtime: observedRuntime
                    )
                    Spacer(minLength: 0)
                    AgentSessionModeBadges(session: displaySession)
                    sessionUpdatedLabel(session, now: now)
                    sessionRowTrailingActions(session: session, isHovered: isHovered)
                }
                if let todoSummary {
                    AgentSessionTodoSummaryContainer(
                        session: displaySession,
                        runtime: observedRuntime,
                        fallbackSummary: todoSummary
                    )
                }
            }
            .padding(.horizontal, 28)
            .frame(height: todoSummary == nil ? AgentDesign.sidebarRowHeight : AgentDesign.sidebarTodoRowHeight)
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

    private func sessionUpdatedLabel(_ session: AgentSession, now: Date) -> some View {
        let label = AgentRelativeTimestamp.compactString(
            since: session.lastActivityAt,
            now: now
        )
        return Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 22, alignment: .trailing)
            .help(L10n.Sidebar.sessionUpdatedTooltip(label))
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
            if AgentSessionStore.isMetadataOnly(session.id) {
                return AgentSessionStore.metadataOnlySessionHasUserMessage(session.id)
            }
            return session.messages.contains(where: { $0.role == .user })
        }
        let groups = Dictionary(grouping: visibleSessions) { session in
            session.workspaceSidebarGroupKey
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
            .filter { !appState.hiddenWorkspaceKeys.contains($0.key) }
            .map { ($0.key, $0.value.sorted(by: sessionOrder)) }
            .sorted { lhs, rhs in
                let lKey = lhs.0
                let rKey = rhs.0
                let lIsNoWorkspace = (lKey == AgentSession.noWorkspaceSidebarGroupKey)
                let rIsNoWorkspace = (rKey == AgentSession.noWorkspaceSidebarGroupKey)
                if lIsNoWorkspace != rIsNoWorkspace { return !lIsNoWorkspace }
                let lName = workspaceDisplayName(lKey)
                let rName = workspaceDisplayName(rKey)
                return lName.localizedCaseInsensitiveCompare(rName) == .orderedAscending
            }
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
        someIMAccount = SomeIMIntegrationStore.loadAccount()
    }

    private func prunePersistedWorkspaceStateIfNeeded() {
        let valid = Set(workspaceStatePruneKey)
        expandedWorkspaces = AgentSidebarWorkspaceStateStore.prune(expandedWorkspaces, to: valid, kind: .expandedWorkspaces)
        collapsedWorkspaces = AgentSidebarWorkspaceStateStore.prune(collapsedWorkspaces, to: valid, kind: .collapsedWorkspaces)
        expandedArchivedGroups = AgentSidebarWorkspaceStateStore.prune(expandedArchivedGroups, to: valid, kind: .expandedArchivedGroups)
    }

    private func refreshSomeIMAccount() {
        guard !isRefreshingSomeIMAccount else { return }
        isRefreshingSomeIMAccount = true
        someIMAccountStatus = ""
        Task {
            let result: Result<SomeIMAccount, Error>
            do {
                result = .success(try await SomeIMClient.fetchAccountBalance())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isRefreshingSomeIMAccount = false
                switch result {
                case .success(let account):
                    someIMAccount = account
                case .failure(let error):
                    someIMAccountStatus = error.localizedDescription
                }
            }
        }
    }


    @MainActor
    private func openSomeIMSettings(autogenerateBrowserLogin: Bool = false) {
        EditorSettingsNavigation.shared.openSomeIM(
            autogenerateBrowserLogin: autogenerateBrowserLogin,
            appState: appState
        )
    }

    private func someIMAvatarInitials(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "S" }
        return String(first).uppercased()
    }

    private func workspaceDisplayName(_ key: String) -> String {
        if key == AgentSession.noWorkspaceSidebarGroupKey { return L10n.Workspace.noWorkspace }
        if let remote = remoteWorkspaceGroup(from: key) {
            let runtime = AgentRuntimeStore.descriptor(id: remote.runtimeID)
            return WorkspacePresentation.remoteDisplayName(runtime: runtime, path: remote.path)
        }
        return URL(fileURLWithPath: key).lastPathComponent
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

    /// Within-group ordering:
    ///   1. Pinned rows first, most-recently-pinned at the top of the
    ///      pinned block (`pinnedAt` desc) — re-pinning therefore
    ///      bubbles a chat back to the very top.
    ///   2. Non-pinned rows after, by recency (`lastActivityAt` desc) so the
    ///      displayed timestamp and the row order agree — a chat showing "5m"
    ///      never sits above one showing "0m".
    /// Archived rows still flow through this comparator; `workspaceGroup`
    /// splits them off into the disclosure section after sorting, so the
    /// archived disclosure stays in recency-desc order too.
    private func sessionOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
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
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(isHovered ? appState.editorSettings.interfaceSkin.palette.hoverFill : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isDimmed)
    }
}
