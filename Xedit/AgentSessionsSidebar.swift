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

enum AgentSessionDeepLink {
    static func url(for sessionID: AgentSession.ID) -> URL {
        var components = URLComponents()
        components.scheme = "willdeep"
        components.host = "chat"
        components.queryItems = [URLQueryItem(name: "session_id", value: sessionID.uuidString)]
        return components.url!
    }

    static func sessionID(from url: URL) -> AgentSession.ID? {
        guard url.scheme?.lowercased() == "willdeep", url.host?.lowercased() == "chat" else { return nil }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "session_id" })?.value
        return raw.flatMap(UUID.init(uuidString:))
    }
}

enum AgentSessionUnreadStore {
    private static let key = "com.willdeep.sidebar.unreadSessionIDs.v1"
    static let didChangeNotification = Notification.Name("willdeep.sessionUnreadStore.didChange")

    static func load() -> Set<AgentSession.ID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func save(_ ids: Set<AgentSession.ID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func setUnread(_ id: AgentSession.ID, unread: Bool) {
        var ids = load()
        if unread {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        save(ids)
    }
}

/// Identifies what the project sheet is editing: an existing project, or a
/// plain folder group about to become one.
struct AgentProjectEditorTarget: Identifiable {
    let id = UUID()
    let project: AgentProject?
    let seedFolderPath: String?
}

/// One-shot request from title search to reveal an item in the left chat
/// sidebar. A fresh id is deliberate: selecting the same result twice still
/// recentres the row after the user has scrolled somewhere else.
struct AgentSidebarRevealRequest: Equatable, Identifiable {
    enum Target: Equatable {
        case session(AgentSession.ID)
        case project(AgentProject.ID)
    }

    let id: UUID
    let target: Target

    init(target: Target, id: UUID = UUID()) {
        self.target = target
        self.id = id
    }
}

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
        let workspaceSessions = sessions.filter(\.belongsInWorkspaceSidebar)

        func hasUserMessage(_ session: AgentSession) -> Bool {
            Self.hasUserMessage(
                session,
                isMetadataOnly: isMetadataOnly,
                metadataOnlyHasUserMessage: metadataOnlyHasUserMessage
            )
        }

        var workspaceKeysWithHistory: Set<String> = []
        for session in workspaceSessions where hasUserMessage(session) {
            workspaceKeysWithHistory.insert(session.workspaceSidebarGroupKey)
        }

        var fallbackPlaceholderIDs: Set<AgentSession.ID> = []
        var placeholderWorkspaceKeys: Set<String> = []
        if let activeID,
           let activeSession = workspaceSessions.first(where: { $0.id == activeID }),
           !hasUserMessage(activeSession) {
            placeholderWorkspaceKeys.insert(activeSession.workspaceSidebarGroupKey)
        }
        for session in workspaceSessions {
            if session.id == activeID || hasUserMessage(session) { continue }
            let key = session.workspaceSidebarGroupKey
            if workspaceKeysWithHistory.contains(key) { continue }
            guard placeholderWorkspaceKeys.insert(key).inserted else { continue }
            fallbackPlaceholderIDs.insert(session.id)
        }

        return workspaceSessions.filter { session in
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
            .filter { $0.belongsInWorkspaceSidebar && $0.isPinned && !$0.isArchived }
            .sorted { lhs, rhs in
                let lhsPinnedAt = lhs.pinnedAt ?? .distantPast
                let rhsPinnedAt = rhs.pinnedAt ?? .distantPast
                if lhsPinnedAt != rhsPinnedAt {
                    return lhsPinnedAt > rhsPinnedAt
                }
                // Immutable tie-breakers only. The old lastActivityAt tie
                // shifted whenever a background reply landed, and Swift's
                // sort is unstable — any comparator that can return
                // "equal" or reads a mutable date lets rows swap on every
                // re-sort (which typing in the editor triggers via the
                // shared AppState).
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    static func workspaceSessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter {
            $0.belongsInWorkspaceSidebar && (!$0.isPinned || $0.isArchived)
        }
    }

    /// The moment a sidebar group came into existence, driving the frozen
    /// group ordering: a project group is born when its project was
    /// created; a bare folder group when its earliest session was. Both
    /// dates are immutable, so the group order can never reshuffle as
    /// sessions come and go.
    static func groupBirthDate(
        groupKey: String,
        sessions: [AgentSession],
        projects: [AgentProject]
    ) -> Date {
        if let projectID = AgentSession.projectID(fromSidebarGroupKey: groupKey),
           let project = projects.first(where: { $0.id == projectID }) {
            return project.createdAt
        }
        return sessions.map(\.createdAt).min() ?? .distantPast
    }

    /// Group comparator: "no workspace" stays last; pinned projects come
    /// first; each priority tier uses birth date (newest first), then name and
    /// key only as deterministic tie-breakers.
    static func groupOrder(
        lhs: (key: String, isPinned: Bool, birthDate: Date, displayName: String),
        rhs: (key: String, isPinned: Bool, birthDate: Date, displayName: String)
    ) -> Bool {
        let lhsIsNoWorkspace = lhs.key == AgentSession.noWorkspaceSidebarGroupKey
        let rhsIsNoWorkspace = rhs.key == AgentSession.noWorkspaceSidebarGroupKey
        if lhsIsNoWorkspace != rhsIsNoWorkspace { return !lhsIsNoWorkspace }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.birthDate != rhs.birthDate { return lhs.birthDate > rhs.birthDate }
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.key < rhs.key
    }

    static func workspaceOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        switch (lhs.isPinned, rhs.isPinned) {
        case (true, false): return true
        case (false, true): return false
        case (true, true):
            let lhsPinnedAt = lhs.pinnedAt ?? .distantPast
            let rhsPinnedAt = rhs.pinnedAt ?? .distantPast
            if lhsPinnedAt != rhsPinnedAt { return lhsPinnedAt > rhsPinnedAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        case (false, false):
            // createdAt, deliberately not lastActivityAt: activity-based
            // ordering reshuffled the group every time any background
            // session (scheduled task, dispatch node, still-streaming old
            // chat) received a reply — the user asked for the list to stop
            // moving around. Creation order is immutable, so a session's
            // row position is stable for its whole life; active sessions
            // are surfaced by the status dot and the recent-session edge
            // rail instead of by jumping to the top.
            //
            // The id tie-breaker matters because Swift's sort is unstable:
            // without a total order, rows with equal dates may swap places
            // on every re-sort — and the sidebar re-sorts whenever the
            // shared AppState publishes, including editor keystrokes.
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// Which placeholder the sidebar renders below the workspace groups when
/// there are no session rows. Pure branch selection, kept out of the view
/// body so the three-way split (loading / truly empty / has rows) stays
/// unit-testable.
enum AgentSidebarCatalogPlaceholder: Equatable {
    /// The on-disk session catalog is still loading. The list being empty
    /// says nothing yet — show a quiet loading row instead of claiming
    /// "no sessions" during the first few hundred milliseconds.
    case loading
    /// The catalog finished loading and there really are no sessions.
    case empty
    /// The list has rows; no placeholder is needed.
    case none

    static func state(
        hasLoadedCatalog: Bool,
        isSessionListEmpty: Bool
    ) -> AgentSidebarCatalogPlaceholder {
        guard isSessionListEmpty else { return .none }
        return hasLoadedCatalog ? .empty : .loading
    }
}

enum AgentSidebarSessionTrailingLayout {
    /// Idle rows reserve no trailing action width. The pinned section already
    /// communicates pin state, so a persistent row icon would add noise and
    /// shorten every title. Hovering restores the complete action lane.
    static func reservedActionsWidth(isHovered: Bool) -> CGFloat {
        isHovered ? AgentDesign.sidebarSessionTrailingActionsWidth : 0
    }
}

/// Keeps hover invalidation inside the one workspace or conversation row
/// currently under the pointer. Storing the hovered id on the parent sidebar
/// made a scroll gesture rebuild every group whenever a new row passed under
/// a stationary cursor.
private struct AgentSidebarHoverScope<Content: View>: View {
    @State private var isHovered = false
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(isHovered)
            .onHover { hovering in
                guard hovering != isHovered else { return }
                isHovered = hovering
            }
    }
}

struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var pluginRegistry = AgentPluginRegistry.shared
    @State private var editingProject: AgentProjectEditorTarget?
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
    @State private var someIMAccount = SomeIMIntegrationStore.loadAuthenticatedAccount()
    @State private var isSomeIMAuthenticated = SomeIMIntegrationStore
        .loadAuthenticationSnapshot()
        .isAuthenticated
    @State private var isRefreshingSomeIMAccount = false
    @State private var someIMAccountStatus = ""
    /// Project-name search results focus the group header itself. Session
    /// selection clears this and continues to use the existing active-row
    /// highlight.
    @State private var focusedWorkspaceGroupKey: String?
    @State private var unreadSessionIDs = AgentSessionUnreadStore.load()

    private let initialRowCount = 5

    /// Vertical room left at the top of the sidebar for the macOS
    /// traffic-light buttons. The window uses `titlebarAppearsTransparent`,
    /// so close/minimize/zoom float over the first ~28pt of sidebar
    /// content — anything we draw inside this band gets hidden behind
    /// the buttons.
    private let trafficLightReserve: CGFloat = 30

    var body: some View {
        // Materialize one stable snapshot per body evaluation. Passing the
        // computed grouping directly into ForEach made every sidebar
        // invalidation rebuild its filter/group/sort pipeline while SwiftUI
        // was also reconciling the list.
        //
        // The visibility filter runs exactly once here — the grouped list
        // and the pinned section used to each run their own full
        // `visibleSessions` pass per body evaluation.
        let visibleSessions = AgentSidebarSessionVisibility.visibleSessions(
            from: appState.agentSessions,
            activeID: appState.activeAgentSessionID,
            isMetadataOnly: appState.agentSessionIsMetadataOnly,
            metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
        )
        let workspaceGroups = groupedSessions(from: visibleSessions)

        VStack(spacing: 0) {
            // Keep the traffic-light safe area, but let the real navigation
            // start immediately below it. The former "Chats" / provider
            // strip duplicated information available elsewhere and consumed
            // valuable vertical space in the sidebar.
            Color.clear.frame(height: trafficLightReserve)
            ScrollViewReader { scrollProxy in
                ScrollView {
                // Keep the workspace stack eager. On macOS 26 the lazy-stack
                // item-phase cache can continuously invalidate when these
                // dynamic workspace groups contain nested ForEach rows. That
                // traps the main thread in AttributeGraph transactions and
                // consumes a full CPU core even while the sidebar is idle.
                // Each collapsed group renders at most five active rows, so
                // the bounded eager layout is the safer trade-off here.
                VStack(alignment: .leading, spacing: 0) {
                    primaryActions
                    AgentPluginPrimaryNavigationSection()
                    Spacer().frame(height: 18)
                    if appState.agentPrimaryDestination == .dispatchBoard {
                        AgentDispatchSidebarSections(
                            coordinator: appState.agentDispatchCoordinator
                        )
                    } else if let destinationID = appState.agentPrimaryDestination.pluginDestinationID {
                        if let destination = pluginRegistry.destination(id: destinationID) {
                            switch destination.companionSidebar.mode {
                            case .sessionList:
                                sessionSidebarContent(
                                    visibleSessions: visibleSessions,
                                    workspaceGroups: workspaceGroups
                                )
                            case .declarative:
                                AgentPluginDeclarativeSidebarHost(destination: destination)
                            case .none:
                                EmptyView()
                            }
                        } else {
                            EmptyView()
                        }
                    } else if appState.agentPrimaryDestination == .pluginCenter {
                        EmptyView()
                    } else {
                        sessionSidebarContent(
                            visibleSessions: visibleSessions,
                            workspaceGroups: workspaceGroups
                        )
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
                .onCompatibleChange(of: appState.agentSidebarRevealRequest) { _, request in
                    guard let request else { return }
                    reveal(request, using: scrollProxy)
                }
                .onAppear {
                    // When title search was opened with the sidebar hidden,
                    // AgentModeView mounts this reader only after receiving
                    // the same request. Consume the already-published value
                    // here as well so the first reveal is not missed.
                    if let request = appState.agentSidebarRevealRequest {
                        reveal(request, using: scrollProxy)
                    }
                }
            }
            someIMAccountFooter
        }
        .sheet(item: $editingProject) { target in
            AgentProjectEditorSheet(
                existingProject: target.project,
                seedFolderPath: target.seedFolderPath
            )
            .environmentObject(appState)
        }
        // sidebar 整体再 clip 一次:即便 SwiftUI 在 narrow window 下
        // 没把某个子 view 完美约束,溢出的部分也不会糊到 chat / side
        // panel 上去。
        .clipped()
        .onAppear(perform: handleAppear)
        .onCompatibleChange(of: workspaceStatePruneKey) { _, _ in
            prunePersistedWorkspaceStateIfNeeded()
        }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            focusedWorkspaceGroupKey = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentSessionUnreadStore.didChangeNotification)) { _ in
            unreadSessionIDs = AgentSessionUnreadStore.load()
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

    @ViewBuilder
    private func sessionSidebarContent(
        visibleSessions: [AgentSession],
        workspaceGroups: [SidebarWorkspaceGroup]
    ) -> some View {
        pinnedSessionsSection(visibleSessions: visibleSessions)
        workspacesHeader(groups: workspaceGroups)
        ForEach(workspaceGroups) { group in
            workspaceGroup(group)
                .id(group.id)
        }
        switch AgentSidebarCatalogPlaceholder.state(
            hasLoadedCatalog: appState.hasLoadedAgentSessionCatalog,
            isSessionListEmpty: appState.agentSessions.isEmpty && appState.agentProjects.isEmpty
        ) {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.Sidebar.loadingState)
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
            }
            .frame(height: AgentDesign.sidebarRowHeight)
            .padding(.horizontal, 14)
            .padding(.top, 16)
        case .empty:
            Text(L10n.Sidebar.emptyState)
                .font(AgentDesign.secondaryFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 16)
        case .none:
            EmptyView()
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
            // Context-dependent: elsewhere it navigates back to the open
            // conversation, on the conversation it starts a new one (see
            // `activateAgentConversationEntry`). It used to be "New Chat",
            // which made it the only way back from a plugin or the dispatch
            // board — and taking it abandoned whatever chat was open. The
            // trailing button is the unconditional "new chat", so that intent
            // is still one click away from anywhere (as is ⌘N, which the menu
            // owns; the "⌘N" label this row used to show never actually fired).
            SidebarActionRow(
                icon: "bubble.left",
                // 标题跟着语义走：在聊天页它就是「新会话」，在别处它是
                // 「会话」＝回到最近那一次。行为本来就是这样分叉的
                // （见 activateAgentConversationEntry），此前只有标题没跟上。
                title: appState.agentConversationEntryTitle,
                shortcut: nil,
                isSelected: appState.agentPrimaryDestination == .conversation,
                trailingIcon: "square.and.pencil",
                trailingHelp: L10n.Sidebar.newChatAction,
                trailingAction: {
                    appState.startNewAgentSession()
                    appState.agentComposerFocusRevision += 1
                }
            ) {
                appState.activateAgentConversationEntry()
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
                appState.synchronizeDispatchBoardInBackground()
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

    private func workspacesHeader(groups: [SidebarWorkspaceGroup]) -> some View {
        let workspaceIDs = groups.map(\.id)
        let everythingCollapsed = AgentSidebarCollapseAll.isEverythingCollapsed(
            workspaceIDs: workspaceIDs,
            collapsed: collapsedWorkspaces
        )
        return HStack {
            Text(L10n.Sidebar.workspaceHeader)
                .font(AgentDesign.sidebarSectionFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            // Fold every project down to its title line, so a long list of
            // folders can be taken in at a glance. Flips to Expand All once
            // everything is folded — otherwise the button would sit there
            // doing nothing on the second click.
            if AgentSidebarCollapseAll.isAvailable(workspaceCount: groups.count) {
                Button {
                    setCollapsedWorkspaces(
                        AgentSidebarCollapseAll.toggled(
                            workspaceIDs: workspaceIDs,
                            collapsed: collapsedWorkspaces
                        )
                    )
                } label: {
                    Image(
                        systemName: everythingCollapsed
                            ? "rectangle.expand.vertical"
                            : "rectangle.compress.vertical"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    everythingCollapsed
                        ? L10n.Sidebar.workspaceHeaderExpandAllTooltip
                        : L10n.Sidebar.workspaceHeaderCollapseAllTooltip
                )
            }
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
    private func pinnedSessionsSection(visibleSessions: [AgentSession]) -> some View {
        let sessions = AgentSidebarSessionPlacement.globalPinnedSessions(from: visibleSessions)
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
                        contentLeadingInset: AgentDesign.sidebarPinnedSessionContentHorizontalInset
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
        let isFocused = focusedWorkspaceGroupKey == workspace

        AgentSidebarHoverScope { isWorkspaceHovered in
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
                            .font(AgentDesign.scaledSidebarWorkspaceFont(
                                baseFontSize: appState.agentChatBaseFontSize
                            ))
                            .foregroundStyle(palette.primaryText.opacity(AgentDesign.sidebarPrimaryTextOpacity))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if appState.agentProject(forSidebarGroupKey: workspace)?.isPinned == true {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(45))
                        }
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
                .accessibilityAction(named: L10n.Sidebar.workspaceMenuNewChat) {
                    startNewSession(inWorkspaceGroup: workspace)
                }
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
                // VoiceOver gets the same operation as a stable custom
                // action on the workspace button above. Keeping this visual
                // hover affordance out of the accessibility tree avoids
                // rebuilding that tree as rows move beneath the pointer.
                .accessibilityHidden(true)
                .help(L10n.Sidebar.workspaceMenuNewChat)
            }
            .padding(.horizontal, AgentDesign.sidebarWorkspaceHorizontalInset)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(
                    cornerRadius: AgentDesign.sidebarSelectionCornerRadius,
                    style: .continuous
                )
                .fill(isFocused ? palette.selectionFill : Color.clear)
            )
            .clipShape(RoundedRectangle(
                cornerRadius: AgentDesign.sidebarSelectionCornerRadius,
                style: .continuous
            ))
            .padding(.horizontal, AgentDesign.sidebarSelectionHorizontalInset)
            .contextMenu {
                Button(L10n.Sidebar.workspaceMenuNewChat) {
                    startNewSession(inWorkspaceGroup: workspace)
                }
                if workspace != AgentSession.noWorkspaceSidebarGroupKey {
                    Divider()
                    // Already a project → edit it. A plain folder group can be
                    // promoted into one, which is how projects get created.
                    if let project = appState.agentProject(forSidebarGroupKey: workspace) {
                        Button(project.isPinned
                            ? L10n.AgentProjectStrings.unpinProject
                            : L10n.AgentProjectStrings.pinProject) {
                            appState.toggleAgentProjectPinned(id: project.id)
                        }
                        Button(L10n.AgentProjectStrings.editProject) {
                            editingProject = AgentProjectEditorTarget(project: project, seedFolderPath: nil)
                        }
                    } else if let path = localWorkspacePath(for: workspace) {
                        Button(L10n.AgentProjectStrings.createProject) {
                            editingProject = AgentProjectEditorTarget(project: nil, seedFolderPath: path)
                        }
                    }
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
                            .font(AgentDesign.scaledSidebarRowFont(
                                baseFontSize: appState.agentChatBaseFontSize
                            ))
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
                    .font(AgentDesign.scaledSidebarRowFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
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
        contentLeadingInset: CGFloat = AgentDesign.sidebarSessionContentHorizontalInset,
        contentTrailingInset: CGFloat = AgentDesign.sidebarSessionTrailingContentInset
    ) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        let isActive = appState.activeAgentSessionID == session.id
        let observedRuntime = appState.agentRuntimes[session.id]
        let displaySession = observedRuntime?.session ?? session

        AgentSidebarHoverScope { isHovered in
            Button {
                focusedWorkspaceGroupKey = nil
                setSessionUnread(session.id, unread: false)
                appState.selectAgentSession(id: session.id)
            } label: {
                HStack(spacing: 6) {
                if activeScheduledTaskCount(for: session) > 0 {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .help(L10n.Sidebar.hasActiveScheduledTasksTooltip)
                }
                // 标题保持单行并以省略号截断，完整内容通过系统 tooltip
                // 提供。hugWidth 用 NSFont 同步测出自然宽度，保证短标题
                // 仍紧贴内容、徽章跟在标题后。
                TruncatedTooltipText(
                    attributed: AttributedString(session.title),
                    font: AgentDesign.scaledSidebarRowFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ),
                    color: palette.primaryText.opacity(
                        isActive ? 1 : AgentDesign.sidebarPrimaryTextOpacity
                    ),
                    tooltip: session.title,
                    hugWidth: Self.sessionTitleNaturalWidth(
                        session.title,
                        baseFontSize: appState.agentChatBaseFontSize
                    )
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
                // row icon (for example a mode badge) — so "this session is
                // live" always reads as the final marker on the row. It and
                // the hover-revealed pin/archive actions are mutually
                // exclusive (dot hides on hover, actions appear), so their
                // trailing slots don't fight for width.
                sessionRowTrailingActions(session: session, isHovered: isHovered)
                if displaySession.isRunningInGitWorktree {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .help(L10n.WorktreeRecovery.sessionBadgeHelp)
                        .accessibilityLabel(L10n.WorktreeRecovery.sessionBadgeHelp)
                }
                if unreadSessionIDs.contains(session.id) && !isActive {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(L10n.Sidebar.sessionUnreadIndicator)
                }
                AgentSessionRowStatusDot(
                    runtime: observedRuntime,
                    isActive: isActive,
                    accentColor: palette.accent
                )
                .opacity(isHovered ? 0 : 1)
                }
                .padding(.leading, contentLeadingInset)
                .padding(.trailing, contentTrailingInset)
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
            .accessibilityAction(
                named: session.isPinned
                    ? L10n.Sidebar.sessionRowUnpinTooltip
                    : L10n.Sidebar.sessionRowPinTooltip
            ) {
                appState.toggleAgentSessionPinned(id: session.id)
            }
            .accessibilityAction(
                named: session.isArchived
                    ? L10n.Sidebar.sessionRowUnarchiveTooltip
                    : L10n.Sidebar.sessionRowArchiveTooltip
            ) {
                requestArchiveToggle(for: session)
            }
        }
        .id(session.id)
        .contextMenu {
            Button(session.isPinned ? L10n.Sidebar.sessionMenuUnpin : L10n.Sidebar.sessionMenuPin) {
                appState.toggleAgentSessionPinned(id: session.id)
            }
            Button(L10n.Sidebar.sessionMenuRename) {
                presentRenameAlert(for: session)
            }
            Button(session.isArchived ? L10n.Sidebar.sessionMenuUnarchive : L10n.Sidebar.sessionMenuArchive) {
                requestArchiveToggle(for: session)
            }
            Button(unreadSessionIDs.contains(session.id)
                   ? L10n.Sidebar.sessionMenuMarkRead
                   : L10n.Sidebar.sessionMenuMarkUnread) {
                setSessionUnread(session.id, unread: !unreadSessionIDs.contains(session.id))
            }
            Divider()
            Button(L10n.Sidebar.sessionMenuShowInFinder) {
                _ = appState.materializeAgentSessionIfNeeded(id: session.id)
                NSWorkspace.shared.activateFileViewerSelecting([AgentSessionStore.fileURL(for: session.id)])
            }
            Button(L10n.Sidebar.sessionMenuCopyWorkingDirectory) {
                copyToPasteboard(session.workspaceLocation?.localPath ?? session.workspaceRootPath ?? "")
            }
            .disabled((session.workspaceLocation?.localPath ?? session.workspaceRootPath) == nil)
            Button(L10n.Sidebar.sessionMenuCopySessionID) {
                copyToPasteboard(session.id.uuidString)
            }
            Button(L10n.Sidebar.sessionMenuCopyDeepLink) {
                copyToPasteboard(AgentSessionDeepLink.url(for: session.id).absoluteString)
            }
            Divider()
            Button(L10n.Sidebar.sessionMenuContinueInNewChat) {
                _ = appState.continueAgentSession(id: session.id)
                appState.agentComposerFocusRevision += 1
            }
            Button(L10n.Sidebar.sessionMenuContinueInNewWorktree) {
                guard appState.continueAgentSession(id: session.id) != nil else { return }
                appState.createAgentGitWorktreeFromActiveWorkspace()
            }
            .disabled((session.workspaceLocation?.localPath ?? session.workspaceRootPath) == nil)
            Divider()
            Button(L10n.Sidebar.sessionMenuOpenInNewWindow) {
                _ = appState.materializeAgentSessionIfNeeded(id: session.id)
                let current = appState.agentSessions.first(where: { $0.id == session.id }) ?? session
                AgentTranscriptReader.open(session: current)
            }
            Divider()
            Button(L10n.Sidebar.sessionMenuSummarizeTitle) {
                appState.manuallySummarizeAgentSessionTitle(id: session.id)
            }
            .disabled(appState.agentRuntimes[session.id] == nil)
            let pluginCommands = pluginRegistry.menuCommands(at: "session.context")
            if !pluginCommands.isEmpty {
                Divider()
                Menu(L10n.Plugins.actions) {
                    ForEach(pluginCommands) { resolved in
                        Button(pluginRegistry.localizedString(
                            resolved.command.titleKey,
                            pluginID: resolved.pluginID
                        )) {
                            runPluginSessionCommand(resolved, session: session)
                        }
                    }
                }
            }
            Divider()
            Button(L10n.Sidebar.sessionMenuDelete, role: .destructive) {
                presentDeleteAlert(for: session)
            }
        }
    }

    private func runPluginSessionCommand(_ resolved: AgentPluginResolvedCommand, session: AgentSession) {
        var arguments = ["sessionID": session.id.uuidString]
        if let workspace = session.workspaceLocation?.localPath ?? session.workspaceRootPath {
            arguments["workspace"] = workspace
        }
        Task {
            _ = try? await AgentPluginCommandExecutor.execute(
                pluginID: resolved.pluginID,
                commandID: resolved.command.id,
                arguments: arguments,
                destinationID: pluginRegistry.defaultDestinationID(for: resolved.pluginID),
                appState: appState
            )
        }
    }

    private func setSessionUnread(_ id: AgentSession.ID, unread: Bool) {
        if unread { unreadSessionIDs.insert(id) } else { unreadSessionIDs.remove(id) }
        AgentSessionUnreadStore.save(unreadSessionIDs)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
    /// TruncatedTooltipText 的 hugWidth 用：同步测出结果，首帧就有正确
    /// 上限。+2 的余量抵消 NSString 测宽与 SwiftUI Text 渲染间的
    /// 亚像素差，防止刚好放得下的标题被削掉最后一个字符的边。
    ///
    /// 结果按标题缓存：`sessionRow` 每行调用一次，而侧栏 body 每帧都重跑，于是
    /// 同一批标题被反复量给同一个字号。采样(1.228.0-rc10,5 秒)里这个函数独占
    /// 主线程 37 个样本,量的全是上一帧刚量过的东西。
    ///
    /// 行字号自 1.253.0-rc1 起跟随聊天正文字号,不再是编译期常量,标题本身已不足以
    /// 做缓存键。这里不给每个字号各留一份,而是在字号变化时整体作废:改字号是罕见
    /// 操作,代价只是接下来一帧重测一遍;若只按标题缓存,调字号后宽度会停留在旧值,
    /// 出现"字变了、截断位置没变"的错位。
    private static func sessionTitleNaturalWidth(
        _ title: String,
        baseFontSize: CGFloat
    ) -> CGFloat {
        let fontSize = AgentDesign.scaledChromeFontSize(
            AgentDesign.sidebarRowFontSize,
            baseFontSize: baseFontSize
        )
        if fontSize != titleNaturalWidthCacheFontSize {
            titleNaturalWidthCache.removeAll(keepingCapacity: true)
            titleNaturalWidthCacheFontSize = fontSize
        }
        if let cached = titleNaturalWidthCache[title] { return cached }
        let font = NSFont.systemFont(ofSize: fontSize)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2
        // 标题数随历史无限增长,缓存不能无界。到顶整体清空而不是做 LRU:代价只是
        // 接下来一帧重新测量一遍,换掉一整套淘汰逻辑。
        if titleNaturalWidthCache.count >= titleNaturalWidthCacheLimit {
            titleNaturalWidthCache.removeAll(keepingCapacity: true)
        }
        titleNaturalWidthCache[title] = width
        return width
    }

    private static var titleNaturalWidthCache: [String: CGFloat] = [:]
    /// 上面那批测量结果对应的行字号。与当前字号不符即整体作废。
    private static var titleNaturalWidthCacheFontSize: CGFloat = 0
    private static let titleNaturalWidthCacheLimit = 1024

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

    /// Trailing pin and archive controls appear only on hover. The pinned
    /// section already communicates state, so idle rows stay visually quiet
    /// and return the entire trailing lane to the title.
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
        // These two visual buttons duplicate the stable custom actions on
        // the row button. Never add/remove them from the accessibility tree
        // while scrolling; that previously made SwiftUI walk the complete
        // responder hierarchy for every crossed row.
        .accessibilityHidden(true)
        .frame(
            width: AgentSidebarSessionTrailingLayout.reservedActionsWidth(
                isHovered: isHovered
            ),
            alignment: .trailing
        )
        .clipped()
    }

    // `visibleSessions` comes pre-filtered from `body` (one visibility pass
    // shared with the pinned section). The filter hides empty "New Chat"
    // rows — sessions that never got a user message just clutter the
    // sidebar with a wall of identical placeholders. The active session is
    // always kept visible even when empty, because it's the one the user is
    // about to type into; hiding it would make the highlight disappear. If a
    // workspace has no real chat yet, one empty placeholder is kept so an
    // added project does not vanish the moment the next project is added.
    private func groupedSessions(from visibleSessions: [AgentSession]) -> [SidebarWorkspaceGroup] {
        var groups = Dictionary(grouping: visibleSessions) { session in
            session.workspaceSidebarGroupKey
        }
        let remoteDescriptors = remoteRuntimeDescriptorsByID
        let projects = appState.agentProjects
        // A named project remains a searchable sidebar destination even when
        // its final conversation was archived or removed. Otherwise title
        // search could truthfully find a project yet have nowhere to reveal.
        for project in projects {
            let key = AgentSession.projectSidebarGroupKeyPrefix + project.id.uuidString
            if groups[key] == nil {
                groups[key] = []
            }
        }
        // Group order rules — fully static, never depends on session
        // updatedAt or on which folder is currently open. The user
        // explicitly asked for the workspace list to stop moving around,
        // then for creation order instead of the interim alphabetical one:
        //   1. Groups sort by their birth date, newest first — a project
        //      group by the project's createdAt, a bare folder group by
        //      its earliest session. Both immutable, so the order is
        //      frozen for a group's whole life.
        //   2. "No workspace" is pinned to the bottom — it's a catch-all,
        //      not a real project.
        // Sessions *inside* a group sort by createdAt (newest first) —
        // fixed at birth, so rows never reshuffle while sessions stream
        // in the background. See AgentSidebarSessionPlacement.workspaceOrder.
        return groups
            .filter { !appState.hiddenWorkspaceKeys.contains($0.key) }
            .map { entry -> (group: SidebarWorkspaceGroup, isPinned: Bool, birthDate: Date) in
                let remoteWorkspace = remoteWorkspaceGroup(from: entry.key)
                let remoteRuntime = remoteWorkspace.flatMap { remoteDescriptors[$0.runtimeID] }
                let group = SidebarWorkspaceGroup(
                    id: entry.key,
                    displayName: workspaceDisplayName(entry.key, remoteDescriptors: remoteDescriptors),
                    remoteRuntime: remoteRuntime,
                    sessions: AgentSidebarSessionPlacement
                        .workspaceSessions(from: entry.value)
                        .sorted(by: AgentSidebarSessionPlacement.workspaceOrder)
                )
                let birthDate = AgentSidebarSessionPlacement.groupBirthDate(
                    groupKey: entry.key,
                    sessions: entry.value,
                    projects: projects
                )
                let isPinned = AgentSession.projectID(fromSidebarGroupKey: entry.key)
                    .flatMap { projectID in projects.first(where: { $0.id == projectID }) }?
                    .isPinned ?? false
                return (group, isPinned, birthDate)
            }
            .sorted { lhs, rhs in
                AgentSidebarSessionPlacement.groupOrder(
                    lhs: (lhs.group.id, lhs.isPinned, lhs.birthDate, lhs.group.displayName),
                    rhs: (rhs.group.id, rhs.isPinned, rhs.birthDate, rhs.group.displayName)
                )
            }
            .map(\.group)
    }

    private var remoteRuntimeDescriptorsByID: [UUID: RuntimeDescriptor] {
        var descriptors: [UUID: RuntimeDescriptor] = [:]
        for descriptor in AgentRuntimeStore.loadDescriptors() {
            descriptors[descriptor.id] = descriptor
        }
        return descriptors
    }

    private var workspaceStatePruneKey: [String] {
        let sessionKeys = appState.agentSessions.map(\.workspaceSidebarGroupKey)
        let projectKeys = appState.agentProjects.map {
            AgentSession.projectSidebarGroupKeyPrefix + $0.id.uuidString
        }
        return Array(Set(sessionKeys + projectKeys)).sorted()
    }

    private func setWorkspaceExpanded(_ workspace: String, expanded: Bool) {
        var updated = expandedWorkspaces
        guard updateWorkspaceState(&updated, workspace: workspace, enabled: expanded) else { return }
        expandedWorkspaces = updated
        AgentSidebarWorkspaceStateStore.save(updated, kind: .expandedWorkspaces)
    }

    private func reveal(_ request: AgentSidebarRevealRequest, using proxy: ScrollViewProxy) {
        switch request.target {
        case .session(let sessionID):
            guard let session = appState.agentSessions.first(where: { $0.id == sessionID }) else { return }
            let workspace = session.workspaceSidebarGroupKey
            focusedWorkspaceGroupKey = nil
            prepareWorkspaceForReveal(workspace, archived: session.isArchived)
            recenter(sessionID, using: proxy)
        case .project(let projectID):
            guard appState.agentProjects.contains(where: { $0.id == projectID }) else { return }
            let workspace = AgentSession.projectSidebarGroupKeyPrefix + projectID.uuidString
            focusedWorkspaceGroupKey = workspace
            prepareWorkspaceForReveal(workspace, archived: false)
            recenter(workspace, using: proxy)
        }
    }

    private func prepareWorkspaceForReveal(_ workspace: String, archived: Bool) {
        appState.unhideWorkspace(key: workspace)
        setWorkspaceCollapsed(workspace, collapsed: false)
        setWorkspaceExpanded(workspace, expanded: true)
        if archived {
            setArchivedGroupExpanded(workspace, expanded: true)
        }
    }

    private func recenter<ID: Hashable>(_ id: ID, using proxy: ScrollViewProxy) {
        // State changes above can insert previously hidden rows. Deferring two
        // turns gives SwiftUI time to materialize them before scrollTo asks for
        // the anchor, including archived and "see more" cases.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func setWorkspaceCollapsed(_ workspace: String, collapsed: Bool) {
        var updated = collapsedWorkspaces
        guard updateWorkspaceState(&updated, workspace: workspace, enabled: collapsed) else { return }
        collapsedWorkspaces = updated
        AgentSidebarWorkspaceStateStore.save(updated, kind: .collapsedWorkspaces)
    }

    /// Bulk counterpart to `setWorkspaceCollapsed`, for the header's
    /// collapse-all control. Persisted the same way, so the folded state
    /// survives a relaunch exactly like a per-folder click does.
    private func setCollapsedWorkspaces(_ updated: Set<String>) {
        guard updated != collapsedWorkspaces else { return }
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
        WorkspacePresentation.groupDisplayName(
            for: key,
            projects: appState.agentProjects,
            remoteRuntime: { remoteDescriptors[$0] }
        )
    }

    private func localWorkspacePath(for key: String) -> String? {
        // A project group's key is `project:<uuid>`, not a path. Returning it
        // verbatim anchored new sessions to that literal string as their
        // workspace root — it surfaced in the composer pill, and every
        // file/terminal/git operation would have resolved against a directory
        // that does not exist. Only a bare folder group's key doubles as its
        // own path, which is why this was safe before workspaces became
        // projects.
        if let project = appState.agentProject(forSidebarGroupKey: key) {
            return project.primaryFolderPath
        }
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

/// The workspace header's collapse-all control.
///
/// Pure so the "what does the button do next" question is answerable without
/// a running sidebar — the answer depends on state that is otherwise only
/// reachable through `@State`.
nonisolated enum AgentSidebarCollapseAll {
    /// Whether every currently listed workspace is already collapsed, in
    /// which case the control flips to Expand All. A button that stays
    /// "collapse all" after everything is collapsed is a dead control.
    static func isEverythingCollapsed(
        workspaceIDs: [String],
        collapsed: Set<String>
    ) -> Bool {
        !workspaceIDs.isEmpty && workspaceIDs.allSatisfy { collapsed.contains($0) }
    }

    /// The collapsed set after the control is used.
    ///
    /// Only the listed workspaces are touched. The stored set can still hold
    /// keys for folders that are not on screen right now (a project whose
    /// sessions are all archived, a workspace on another machine); expanding
    /// "all" must not silently un-collapse those — the user never saw them.
    static func toggled(
        workspaceIDs: [String],
        collapsed: Set<String>
    ) -> Set<String> {
        isEverythingCollapsed(workspaceIDs: workspaceIDs, collapsed: collapsed)
            ? collapsed.subtracting(workspaceIDs)
            : collapsed.union(workspaceIDs)
    }

    /// The control only earns its place once there is more than one project
    /// to fold away; with a single group it would collapse the very thing the
    /// user is looking at and save nothing.
    static func isAvailable(workspaceCount: Int) -> Bool {
        workspaceCount > 1
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
    /// Optional secondary action pinned to the row's trailing edge, for rows
    /// whose navigation and whose "make a new one" are different intents.
    var trailingIcon: String? = nil
    var trailingHelp: String? = nil
    var trailingAction: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isTrailingHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(AgentDesign.scaledSidebarRowFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
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
        // Overlay rather than a Button nested in the row's label: the row sets
        // `contentShape(Rectangle())` across its full width, which would
        // swallow the inner button's clicks. An overlay hit-tests first.
        .overlay(alignment: .trailing) {
            if let trailingIcon, let trailingAction {
                Button(action: trailingAction) {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isTrailingHovered ? .primary : .secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isTrailingHovered = $0 }
                .help(trailingHelp ?? "")
                .padding(.trailing, 10)
            }
        }
        // 侧边栏导航行只用 selectionFill 表达"当前在哪儿"。留着可聚焦时,
        // 首个 Button(「聊天」)会在窗口打开时拿到 first responder 并画出
        // 蓝色焦点环,和实际选中的「调度台」打架,看着像选了两行。
        .focusable(false)
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

    private var iconColor: Color {
        if isDimmed { return .secondary.opacity(0.45) }
        if isSelected { return .primary }
        return isHovered ? .primary.opacity(0.72) : .secondary
    }
}
