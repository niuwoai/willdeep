//
//  AgentModeView.swift
//  VeilWriter
//
//  Top-level Agent mode. Layout inspired by Cursor: a project-grouped
//  session sidebar on the left, a chat pane on the right, and a thin
//  status bar at the bottom of the chat pane.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentModeView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 230

    var body: some View {
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                .background(
                    AgentDesign.sidebarBackground
                        .overlay(AgentDesign.sidebarTint)
                )

            Divider()

            VStack(spacing: 0) {
                AgentChatHeader()
                Divider().opacity(0.5)
                AgentChatTranscript()
                AgentChatComposer()
                AgentChatStatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentDesign.chatBackground)
        }
        .background(AgentDesign.chatBackground)
    }
}

// MARK: - Design tokens
//
// Centralized so the next time we want to tweak spacing/colors, it's all
// in one place. Uses macOS semantic colors so the look follows system
// appearance (light / dark) automatically.

enum AgentDesign {
    // Backgrounds — semantic so light/dark adapt for free. Earlier
    // revisions used `underPageBackgroundColor` for the sidebar and the
    // status bar; on light appearance that paints a fairly dark grey
    // band that fights with the white chat area. Now everything sits on
    // a single `windowBackgroundColor` plane, separated by dividers and
    // very light overlays so the eye reads it as one calm canvas.
    static let chatBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let statusBarBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    /// Very faint tint to set the sidebar apart from the chat without
    /// the heavy grey of `underPageBackgroundColor`.
    static let sidebarTint = Color(nsColor: .labelColor).opacity(0.025)

    // Corner radii.
    static let cardCornerRadius: CGFloat = 8
    static let pillCornerRadius: CGFloat = 6
    static let inputCornerRadius: CGFloat = 10

    // Paddings & sizes.
    static let chatMaxContentWidth: CGFloat = 720
    static let messageVerticalSpacing: CGFloat = 18
    static let composerHeight: CGFloat = 124
    static let headerHeight: CGFloat = 42
    static let statusBarHeight: CGFloat = 26
    static let sidebarRowHeight: CGFloat = 26

    // Typography.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let secondaryFont = Font.system(size: 11)
    static let captionFont = Font.system(size: 10)
    static let sidebarSectionFont = Font.system(size: 11, weight: .semibold)
    static let sidebarRowFont = Font.system(size: 12)
}

// MARK: - Sessions sidebar

private struct AgentSessionsSidebar: View {
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
                        Text("Sessions you start will appear here.")
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
            Text("Chats")
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
            .help("Active provider — driving the next chat turn. Click to switch.")
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
            SidebarActionRow(icon: "square.and.pencil", title: "New Chat", shortcut: "⌘N") {
                appState.startNewAgentSession()
            }
        }
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(AgentDesign.sidebarSectionFont)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
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
                .help(isCollapsed ? "展开会话列表" : "收起会话列表")
                Text(workspaceDisplayName(workspace))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                Button("New Chat in this Workspace") {
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
                        Text(isExpanded ? "Show less" : "See more")
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
                Text("已归档 (\(sessions.count))")
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
            Button(session.isPinned ? "取消置顶" : "置顶") {
                appState.toggleAgentSessionPinned(id: session.id)
            }
            Button(session.isArchived ? "取消归档" : "归档") {
                appState.toggleAgentSessionArchived(id: session.id)
            }
            Divider()
            Button("删除会话", role: .destructive) {
                appState.deleteAgentSession(id: session.id)
            }
        }
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
                .help(session.isPinned ? "取消置顶" : "置顶")

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
                .help(session.isArchived ? "取消归档" : "归档")
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

private struct SidebarActionRow: View {
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

// MARK: - Header

private struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                copyTitle()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Copy title")

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    appState.startNewAgentSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("New Chat")

                Button {
                    appState.setAppMode(.editor)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Switch to Editor Mode")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.headerHeight)
    }

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return "New Chat"
        }
        return session.title
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }
}

// MARK: - Transcript

private struct AgentChatTranscript: View {
    @EnvironmentObject var appState: AppState
    private static let bottomScrollID = "agent-chat-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Keep this stack non-lazy. The visible transcript is
                // already capped and mostly rendered as one NSTextView;
                // LazyVStack's placement cache is the unstable part when
                // scrolling mixed SwiftUI/AppKit dynamic-height rows.
                VStack(alignment: .leading, spacing: AgentDesign.messageVerticalSpacing) {
                    // Plan + Goal banners — pinned above the transcript so
                    // the user always sees the current execution gate /
                    // long-term objective.
                    if appState.agentInteractionMode == .plan, let plan = appState.agentCurrentPlan {
                        AgentPlanCard(plan: plan)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }
                    if appState.agentInteractionMode == .goal, let goal = appState.agentCurrentGoal, !goal.isEmpty {
                        AgentGoalCard(goal: goal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    if appState.agentMessages.isEmpty {
                        AgentEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        // rc16: chat pane history rendered as ONE
                        // NSTextView (`AgentChatHistoryTextView`)
                        // instead of one SwiftUI bubble per message.
                        // 15 rcs of bisection showed SwiftUI's
                        // LazyVStack + per-message bubble chrome
                        // (HStack + VStack + padding + background +
                        // overlay + frame) freezes the main thread
                        // on medium-rich content (1.5 KB message
                        // with a few tables / fenced code / HTML
                        // details — all common in real assistant
                        // replies), and no amount of bubble-internal
                        // optimization stopped it. TextKit handles
                        // the same content incrementally with no
                        // freeze regardless of length. We pay for
                        // it in look-and-feel: no per-message
                        // bubbles, no markdown rendering on
                        // historical messages, no per-message copy
                        // button. Streaming assistant message is
                        // still rendered as a SwiftUI bubble so
                        // markdown formatting + token-by-token
                        // updates + streaming cursor still feel
                        // live; once the turn ends it folds into
                        // the NSTextView on the next refresh.
                        let allVisible = visibleMessages
                        let rendered = renderedMessages(from: allVisible)
                        let omitted = allVisible.count - rendered.count
                        if omitted > 0 {
                            transcriptOlderHistoryCard(omittedCount: omitted)
                        }

                        let streamingMessageID = currentStreamingMessageID
                        let history = historyMessages(rendered: rendered, streamingID: streamingMessageID)
                        if !history.isEmpty {
                            AgentChatHistoryTextView(messages: history)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }

                        // Render the active streaming message — and
                        // only it — through the SwiftUI bubble path
                        // so markdown formatting + the streaming
                        // cursor stay live during the turn.
                        if let streamingID = streamingMessageID,
                           let streamingMessage = rendered.first(where: { $0.id == streamingID }),
                           shouldShowMessageBubble(streamingMessage) {
                            AgentModeMessageView(
                                message: streamingMessage,
                                isStreamingThisMessage: true
                            )
                                .id(streamingMessage.id)
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                        }

                        // Tool call groups: rendered as their own
                        // SwiftUI cards (collapsible expand-on-tap).
                        // Each `AgentToolCallGroup` is one view —
                        // total stays small even on long sessions.
                        ForEach(toolCallGroupMessageIDs(in: rendered), id: \.self) { messageID in
                            let calls = toolCalls(for: messageID)
                            if !calls.isEmpty {
                                let segments = AgentToolCallGrouping.group(calls)
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(segments) { segment in
                                        AgentToolCallGroup(
                                            calls: segment.calls,
                                            headline: segment.kind.groupTitle(segment.count),
                                            headlineIcon: segment.kind.groupIcon
                                        )
                                    }
                                }
                                .id(toolGroupScrollID(for: messageID))
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                            }
                        }
                    }

                    if appState.shouldShowAgentThinkingIndicator {
                        AgentThinkingDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    ForEach(appState.agentQueuedMessages) { queued in
                        QueuedMessageRow(message: queued)
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    // Only show the worktree-change card once the Agent has
                    // actually applied a patch in this session — otherwise a
                    // brand-new chat opened inside a git repo with unrelated
                    // uncommitted changes would surface a misleading
                    // "正在编辑 / N 个文件已更改" banner.
                    if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomScrollID)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // CRITICAL: only react to count, not the whole array.
            // Pre-fix this watched `appState.agentMessages` (the full
            // [AgentMessage]) — every streaming-token delta mutates
            // `messages[i].content`, Equatable on the array sees a
            // diff, and we'd kick a fresh `withAnimation` scroll on
            // every single token. Combined with the deeply-nested
            // chat-bubble layout (padding/HStack/VStack/ZStack 6+
            // levels), that pinned the main thread inside SwiftUI
            // layout — the symptom was the app freezing while a long
            // turn streamed, with a backtrace deep inside
            // `_FrameLayout.commonPlacement` / `_PaddingLayout.sizeThatFits`.
            // Scrolling on `.count` only fires when a brand-new
            // message is appended. The target is a stable bottom
            // sentinel because historical messages are folded into
            // one NSTextView and no longer expose per-message ids.
            .onChange(of: appState.agentMessages.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { message in
            message.role != .tool && !isEmptyThinkingPlaceholder(message)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private func isEmptyThinkingPlaceholder(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty
    }

    private func shouldShowMessageBubble(_ message: AgentMessage) -> Bool {
        !(message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty)
    }

    private func toolGroupScrollID(for messageID: AgentMessage.ID) -> String {
        "agent-tools-\(messageID.uuidString)"
    }

    /// The id of the assistant message that is currently being
    /// streamed, or nil if nothing is streaming. Resolved once per
    /// parent body pass and passed into each child bubble so that
    /// AgentModeMessageView itself doesn't need an environment
    /// reference to AppState — see the comment on that view for the
    /// AttributeGraph cost story.
    private var currentStreamingMessageID: AgentMessage.ID? {
        guard appState.isAgentResponding else { return nil }
        return appState.agentMessages.last(where: { $0.role == .assistant })?.id
    }

    /// How many messages the in-pane transcript renders at once.
    /// Anything older falls behind the "older history" disclosure
    /// and is reachable via the standalone reader window. Tuned to
    /// give plenty of context for a back-and-forth without exposing
    /// SwiftUI's LazyVStack to the long-list freeze.
    private static let renderedMessageCap = 20

    /// Per-message content size cap (in characters). Any message with
    /// content longer than this gets truncated in the chat bubble and
    /// the user gets a "view full content" affordance that opens the
    /// message in a standalone NSTextView window. This is the real
    /// freeze culprit: 13 rcs of bisection ruled out structural and
    /// dependency-graph issues; the remaining hot spot was SwiftUI's
    /// per-bubble layout choking on a single very long message body
    /// (e.g. a 24 KB tool output or an assistant reply that
    /// streamed to 19 KB). Trimming to ~3 KB keeps the bubble small
    /// enough for SwiftUI to handle without main-thread freezes.
    private static let messageContentRenderCap = 3_000

    /// Returns the message unchanged when its content fits, or a
    /// truncated copy when it doesn't.
    /// `(rendered, wasTruncated, originalLength)`.
    private func truncatedForBubble(_ message: AgentMessage) -> (rendered: AgentMessage, truncated: Bool, originalLength: Int) {
        let originalLength = message.content.count
        guard originalLength > Self.messageContentRenderCap else {
            return (message, false, originalLength)
        }
        var copy = message
        copy.content = String(message.content.prefix(Self.messageContentRenderCap))
        return (copy, true, originalLength)
    }

    /// Subset of `rendered` that should land in the NSTextView
    /// history view — everything except the currently-streaming
    /// assistant message (that one is rendered as its own SwiftUI
    /// bubble so markdown + streaming cursor stay live).
    private func historyMessages(rendered: [AgentMessage], streamingID: AgentMessage.ID?) -> [AgentMessage] {
        guard let streamingID else { return rendered }
        return rendered.filter { $0.id != streamingID }
    }

    /// Preserve original tool-call order: returns the message ids in
    /// `rendered` that have non-empty tool calls, in the order they
    /// appear in the transcript. Used to drive the `ForEach` that
    /// renders tool-call group cards.
    private func toolCallGroupMessageIDs(in rendered: [AgentMessage]) -> [AgentMessage.ID] {
        rendered.compactMap { message in
            toolCalls(for: message.id).isEmpty ? nil : message.id
        }
    }

    /// Slice the bottom `renderedMessageCap` messages out of the
    /// full visible list. If the list already fits, returns it
    /// untouched.
    private func renderedMessages(from all: [AgentMessage]) -> [AgentMessage] {
        guard all.count > Self.renderedMessageCap else { return all }
        return Array(all.suffix(Self.renderedMessageCap))
    }

    /// Inline disclosure shown right under a message whose content
    /// was truncated for the chat-pane render (see
    /// `messageContentRenderCap`). One tap opens the full message
    /// content in a standalone NSTextView window — same idea as the
    /// session-wide reader, but for one bubble at a time.
    @ViewBuilder
    private func longMessageTruncationCard(original: AgentMessage, originalLength: Int) -> some View {
        let omitted = originalLength - AgentChatTranscript.messageContentRenderCap
        Button {
            let sessionTitle = appState.agentSessions
                .first(where: { $0.id == appState.activeAgentSessionID })?.title ?? ""
            AgentTranscriptReader.openSingleMessage(original, sessionTitle: sessionTitle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("此消息在窗口内只显示前 \(AgentChatTranscript.messageContentRenderCap) 字符 · 还有 \(omitted) 字符 · 点击查看完整内容")
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("打开独立窗口查看此消息的完整内容")
    }

    /// Banner shown at the top of the transcript when older messages
    /// have been hidden from the chat pane. One tap opens the full
    /// transcript in a standalone NSWindow.
    @ViewBuilder
    private func transcriptOlderHistoryCard(omittedCount: Int) -> some View {
        Button {
            guard let id = appState.activeAgentSessionID,
                  let session = appState.agentSessions.first(where: { $0.id == id }) else { return }
            AgentTranscriptReader.open(session: session)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("此对话前面还有 \(omittedCount) 条消息 · 点击在新窗口查看完整历史")
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("打开独立窗口查看完整对话历史")
    }

}

// MARK: - Message bubbles for Agent mode

/// CRITICAL: this view used to `@EnvironmentObject var appState: AppState`
/// to compute `isStreamingThisMessage`. That single dependency dragged
/// every bubble in the transcript into AppState's invalidation graph —
/// any AppState mutation (delegated `agent*` change, token streamed in,
/// sidebar status flip, whatever) caused AttributeGraph to re-run
/// `update` across every visible AgentModeMessageView. Instruments
/// profiling under the freeze showed `AG::Subgraph::update` at 77%
/// and `AG::Graph::UpdateStack::update` at 76% of total CPU — a
/// 15-second main-thread hang for a 19-second sample. By taking
/// `isStreamingThisMessage` as a Bool prop from the parent, the bubble
/// only invalidates when its own message or that streaming flag
/// actually changes; AppState's delegated `agent*` mutations no
/// longer touch the bubbles.
private struct AgentModeMessageView: View {
    let message: AgentMessage
    let isStreamingThisMessage: Bool

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantContent
        case .system: assistantContent
        case .tool: EmptyView()
        }
    }

    // User messages: right-aligned bubble with accent fill so the eye
    // immediately tells them apart from assistant prose. Capped at ~78%
    // of the chat column so long pastes still wrap nicely.
    private var userBubble: some View {
        // For text-only providers we splice the qwen-vl description right
        // into the user message content (so the next turn echoes it back
        // verbatim, and so providers without image support still get the
        // signal). That made the bubble grow into a wall of AI-generated
        // bullets — see screenshot. Split it back out at render time: the
        // user's own prose stays inline, the description collapses into a
        // disclosure chip.
        let split = AgentUserContentSplitter.split(message.content)
        // rc13: collapsed the previous HStack { Spacer; VStack { VStack
        // {...}.frame(maxWidth:); footer } }.frame(maxWidth:) chain.
        // Two nested .frame(maxWidth:) plus an HStack Spacer is a
        // SwiftUI layout pathology — the Spacer needs to know the
        // container width to size itself, the inner frame needs the
        // outer geometry to compute its 0.78 share, and the outer
        // frame in turn depends on what the inner one returns. Under
        // LazyVStack scrolling the resulting `StackPlacement.flushMinorGroup`
        // / `LazyHVStack.lengthAndSpacing` ping-pong froze the main
        // thread on long sessions. New shape: a single VStack with one
        // trailing alignment, right-aligned by the parent ForEach's
        // frame(alignment: .leading)? — no, kept right via .frame(...
        // alignment: .trailing) once at the end, and the inner card
        // is sized by its content (capped via .frame on the bubble
        // itself, not on its inner padding chrome).
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !split.visible.isEmpty {
                    // Inject zero-width break points into any
                    // unbreakable run >30 chars (see
                    // AgentLongTokenBreaker). Without this a
                    // user paste like a pnpm-store listing
                    // (150-char hash file names per line) sends
                    // SwiftUI's line-breaker into a freeze that
                    // takes the whole chat pane down on scroll.
                    // Real text restored.
                    Text(AgentLongTokenBreaker.inject(into: split.visible))
                        .font(AgentDesign.bodyFont)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = split.description {
                    AgentImageDescriptionDisclosure(description: description)
                }
                if !message.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.images) { image in
                                AgentImageThumbnail(image: image, size: 96, allowsRemoval: false, onRemove: nil)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                    .fill(Color.accentColor)
            )

            if !message.content.isEmpty {
                AgentMessageFooter(message: message, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // Assistant messages: left-aligned, wrapped in a soft card so the
    // boundary of one model turn is obvious. Body renders through the
    // existing MarkdownPreview pipeline (also used by the editor's
    // Markdown side preview) — headings, lists, quotes, dividers, inline
    // formatting, and fenced code blocks all render. The parser flushes
    // an unterminated ``` block at EOF, so streaming code blocks show up
    // correctly while still being typed.
    private var assistantContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 18, alignment: .center)
                .padding(.top, 10)
            if !message.content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    AgentAssistantMarkdownBody(content: message.content, isStreaming: isStreamingThisMessage)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    // Don't show the footer while the stream is still
                    // running — elapsedSeconds isn't stamped until
                    // `.finishedTurn`, so the row would briefly read
                    // "copy · — · —" and then update. Wait until the
                    // turn settles.
                    if !isStreamingThisMessage {
                        AgentMessageFooter(message: message, alignment: .leading)
                            .padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }

}

// MARK: - Assistant Markdown body

/// Renders an assistant message's Markdown content as a SINGLE
/// `Text(AttributedString)` view. Pre-rc9 this used a `VStack` +
/// `ForEach(blocks)` + `MarkdownPreviewBlockView` per block — which
/// turned every assistant message into N SwiftUI views (one per
/// markdown block). Combined with the outer `LazyVStack` + the
/// `ForEach` over messages, SwiftUI ended up with **3 nested
/// ForEach** in a LazyVStack: messages → blocks → (inside code
/// blocks: lines). LLDB backtraces under freeze showed
/// `LazyStack.measureEstimates` recursively walking
/// `ForEachState.item(at:offset:) + 1644`, which is the smoking-gun
/// signature of SwiftUI's lazy-layout estimator expanding the entire
/// nested ForEach tree on every measure pass.
///
/// One Text per message collapses the view tree by 1-2 orders of
/// magnitude: a 200-block message goes from ~200 SwiftUI views to 1.
/// The tradeoff is we lose the per-block chrome — code blocks no
/// longer have a copy button or language pill, tables degrade to
/// piped text — but the chat pane stays responsive on long replies.
/// MarkdownPreviewBlockView itself is unchanged and still used by
/// the editor's Markdown side preview where view-tree size isn't a
/// concern.
private struct AgentAssistantMarkdownBody: View {
    let content: String
    /// When true, appends a small blinking cursor at the end of the
    /// rendered body to signal that more tokens are still arriving.
    let isStreaming: Bool

    var body: some View {
        // The Text on the bottom is the single-view substitute for
        // the old `VStack + ForEach(blocks)`. The streaming cursor
        // is a tiny separate view (one AgentStreamingCursor) — that
        // is fine because it's always either 0 or 1 child, never N.
        VStack(alignment: .leading, spacing: 4) {
            Text(AgentAssistantMarkdownRenderer.render(content))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isStreaming {
                AgentStreamingCursor()
            }
        }
    }
}

/// Converts a streamed Markdown message into one `AttributedString`
/// that captures headings, paragraphs, lists, quotes, code blocks
/// (monospaced + soft background), and dividers. Reused inside the
/// chat pane to keep the view-tree-per-message at one node.
///
/// Trade-offs vs the old per-block SwiftUI renderer:
///  - Code blocks have no copy button, no language pill — just
///    monospace text with a subtle background and an inline language
///    hint on the line above.
///  - Tables degrade to `cell │ cell` piped rows.
///  - Inline links inherit AttributedString's link styling.
/// The point of the trade-off is keeping SwiftUI's LazyVStack from
/// having to walk a deeply-nested ForEach tree during scroll-time
/// measurement passes.
enum AgentAssistantMarkdownRenderer {
    /// Bounded LRU keyed by content. Streaming new tokens changes
    /// the content (hash differs), so we re-render once and cache
    /// the result; subsequent SwiftUI body evaluations during scroll
    /// just hand back the prior AttributedString.
    private static var cache: [Int: AttributedString] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLimit = 128

    static func render(_ content: String) -> AttributedString {
        let key = content.hashValue
        if let hit = cache[key] { return hit }
        let result = build(from: content)
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return result
    }

    private static func build(from content: String) -> AttributedString {
        // Pre-process: inject zero-width breakpoints into unbreakable
        // runs of >30 chars. Otherwise a message containing e.g. a
        // pnpm-store listing (150-char hash paths, no spaces) freezes
        // SwiftUI Text's line-breaker on the whole chat pane.
        let safe = AgentLongTokenBreaker.inject(into: content)
        let blocks = MarkdownPreviewParser.blocks(from: safe)
        var result = AttributedString()

        func appendSeparator() {
            if !result.characters.isEmpty {
                result += AttributedString("\n\n")
            }
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                appendSeparator()
                var heading = AttributedString(block.text)
                heading.font = headingFont(level: level)
                heading.foregroundColor = .primary
                result += heading

            case .paragraph:
                appendSeparator()
                var paragraph = inlineRendered(block.text)
                paragraph.foregroundColor = .primary
                result += paragraph

            case .quote:
                appendSeparator()
                var quote = AttributedString("❝ " + block.text)
                quote.font = .system(.body)
                quote.foregroundColor = .secondary
                result += quote

            case .unorderedList:
                appendSeparator()
                let bullet = block.indent == 0 ? "•" : (block.indent == 1 ? "◦" : "▪")
                let indent = String(repeating: "  ", count: block.indent)
                var prefix = AttributedString("\(indent)\(bullet) ")
                prefix.foregroundColor = .secondary
                var body = inlineRendered(block.text)
                body.foregroundColor = .primary
                result += prefix + body

            case .orderedList:
                appendSeparator()
                let indent = String(repeating: "  ", count: block.indent)
                var prefix = AttributedString("\(indent)1. ")
                prefix.foregroundColor = .secondary
                var body = inlineRendered(block.text)
                body.foregroundColor = .primary
                result += prefix + body

            case .code:
                appendSeparator()
                if let langHint = block.info?.trimmingCharacters(in: .whitespaces), !langHint.isEmpty {
                    var hint = AttributedString("\(langHint)\n")
                    hint.font = .system(size: 10, weight: .medium, design: .monospaced)
                    hint.foregroundColor = .secondary
                    result += hint
                }
                var code = AttributedString(block.text)
                code.font = .system(.body, design: .monospaced)
                code.foregroundColor = .primary
                code.backgroundColor = Color.primary.opacity(0.06)
                result += code

            case .divider:
                appendSeparator()
                var divider = AttributedString("─────")
                divider.foregroundColor = .secondary
                result += divider

            case .table:
                appendSeparator()
                if let headers = block.tableHeaders, let rows = block.tableRows {
                    let plain = ([headers] + rows)
                        .map { $0.joined(separator: " │ ") }
                        .joined(separator: "\n")
                    var table = AttributedString(plain)
                    table.font = .system(.body, design: .monospaced)
                    table.foregroundColor = .primary
                    result += table
                }
            }
        }

        return result
    }

    /// Run inline Markdown (bold/italic/`code`/links) through the
    /// same parser as the editor preview so styling stays consistent
    /// across the app.
    private static func inlineRendered(_ raw: String) -> AttributedString {
        MarkdownInline.attributedString(from: raw)
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .semibold)
        case 2: return .system(size: 18, weight: .semibold)
        case 3: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
}

/// Insert zero-width breakpoints into runs of unbreakable characters.
///
/// SwiftUI's Text has a hard time with very long tokens that contain
/// no whitespace or hyphens — it'll try to lay out the whole token on
/// one line, fail, and start probing every character position to find
/// a break opportunity. On macOS this manifests as the entire chat
/// pane freezing while scrolling past a message that contains, e.g.,
/// a pnpm-store path listing where each line is a 150-char hash.
///
/// We mitigate this at render time by walking the string and, for any
/// run of length > `threshold` that contains no natural break
/// character (space, newline, tab, hyphen, slash, etc.), inserting a
/// zero-width space (`\u{200B}`) every `threshold` characters. The
/// glyph is invisible and `textSelection(.enabled)` copy still gives
/// the original characters (some terminals strip ZWSPs on paste — we
/// can revisit if that's an issue, but the choice is between
/// "occasional invisible char on copy" and "app freezes on scroll").
enum AgentLongTokenBreaker {
    /// Threshold above which we start inserting breakpoints. Roughly
    /// the width of a chat-bubble column at the default font size, so
    /// anything wider than this would have to wrap anyway.
    private static let threshold = 30

    /// Characters SwiftUI already treats as wrap opportunities. We
    /// only inject breakpoints into runs that contain none of these.
    private static let naturalBreakers: Set<Character> = [
        " ", "\t", "\n", "-", "/", ".", ",", ";", ":", "|", "(", ")",
        "[", "]", "{", "}", "<", ">", "=", "+", "?", "&"
    ]

    /// LRU keyed by source hash. Same reasoning as for
    /// `AgentUserContentSplitter`: SwiftUI re-evaluates user/
    /// assistant body many times per layout pass, and walking a
    /// 6+ KB string char-by-char on every pass adds up to a freeze.
    /// The output also returns a new String instance every call —
    /// without a cache, SwiftUI sees the Text content "change"
    /// (new String identity) on every body pass and invalidates its
    /// layout cache, looping forever. Caching the same String
    /// identity for the same input cuts the loop.
    private static var cache: [Int: String] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLimit = 128

    static func inject(into source: String) -> String {
        // Fast path: source short enough that even the longest token
        // can't exceed the threshold.
        guard source.count > threshold else { return source }

        let key = source.hashValue
        if let hit = cache[key] { return hit }
        let result = compute(source)
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return result
    }

    private static func compute(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count + source.count / threshold)
        var runLength = 0

        for ch in source {
            if naturalBreakers.contains(ch) {
                result.append(ch)
                runLength = 0
                continue
            }
            if runLength >= threshold {
                result.append("\u{200B}")
                runLength = 0
            }
            result.append(ch)
            runLength += 1
        }
        return result
    }
}

/// A 2x14 blinking bar that follows the assistant's last token. Pure
/// decoration — disappears the moment `isAgentResponding` goes false.
private struct AgentStreamingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(visible ? 0.85 : 0.15))
            .frame(width: 7, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 1))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

// MARK: - User content splitter (hide qwen-vl description blocks)

/// Pulls the spliced-in image description block out of a user message so
/// the bubble can render the user's own prose at full size and tuck the
/// AI-generated wall of bullets behind a disclosure chip.
///
/// The block is recognised by the header line that
/// `contentByAppendingImageDescription(to:...)` emits — `[Image
/// description generated by <provider> / <model> for N attached
/// image(s)]` — and we strip that line plus everything after it. The
/// raw description (without the marker line) is what gets shown when
/// the user expands the chip; we don't bother showing the marker again.
enum AgentUserContentSplitter {
    struct Split {
        let visible: String
        let description: String?
        let imageCount: Int
        let provider: String?
    }

    /// Matches the header emitted by AppState.contentByAppendingImageDescription.
    /// Capture 1 = provider/model slug, capture 2 = image count.
    private static let headerPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[Image description generated by ([^\]]+?) for (\d+) attached image[s]?\]"#,
            options: []
        )
    }()

    /// Tiny LRU keyed by content hash. SwiftUI re-evaluates the user
    /// bubble's `body` many times per layout pass (measure / placement
    /// / cache invalidation cycles); without a cache, every pass
    /// re-runs the regex against the full message content. For a
    /// 6 KB pasted user message that's enough to pin the main thread
    /// on long sessions. Streaming user input changes content rarely
    /// (the composer holds it), so cache invalidation is naturally
    /// low-frequency.
    private static var cache: [Int: Split] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLimit = 64

    static func split(_ content: String) -> Split {
        let key = content.hashValue
        if let hit = cache[key] { return hit }
        let result = computeSplit(content)
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return result
    }

    private static func computeSplit(_ content: String) -> Split {
        guard let regex = headerPattern else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        guard let headerRange = Range(match.range, in: content),
              let providerRange = Range(match.range(at: 1), in: content),
              let countRange = Range(match.range(at: 2), in: content) else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        let visible = String(content[..<headerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(content[headerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = String(content[providerRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageCount = Int(content[countRange]) ?? 0
        return Split(
            visible: visible,
            description: description.isEmpty ? nil : description,
            imageCount: imageCount,
            provider: provider
        )
    }
}

/// Collapsed chip + on-demand body for the image description block. Lives
/// inside the user bubble (white-on-accent), so we tint everything against
/// the white text color and keep the chip itself tiny so it doesn't fight
/// the user's actual prose for attention.
private struct AgentImageDescriptionDisclosure: View {
    let description: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 10, weight: .medium))
                    Text(isExpanded ? "收起图片描述" : "图片 AI 描述")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("点击展开 / 收起视觉模型生成的图片描述")

            if isExpanded {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Message footer (copy button + timing + tokens)

/// Tiny caption row that sits directly under a chat bubble. Renders a
/// copy-to-clipboard button, plus — for assistant messages — the wall
/// clock elapsed seconds for the turn and the prompt/completion token
/// breakdown. User messages only show the copy button (timing and
/// tokens belong to the model side of the exchange).
private struct AgentMessageFooter: View {
    let message: AgentMessage
    /// `.leading` for assistant rows (left-aligned column), `.trailing`
    /// for the right-aligned user bubble so the footer hugs the same
    /// edge as the bubble.
    let alignment: HorizontalAlignment

    @State private var didJustCopy = false

    var body: some View {
        HStack(spacing: 10) {
            if alignment == .trailing { Spacer(minLength: 0) }

            Button(action: copyToClipboard) {
                Image(systemName: didJustCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(didJustCopy ? "Copied" : "Copy message")
            .accessibilityLabel("Copy message")

            if message.role == .assistant, let elapsed = message.elapsedSeconds, elapsed > 0 {
                Label(formatElapsed(elapsed), systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant, let tokenSummary = tokenSummary {
                Label(tokenSummary, systemImage: "number")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if alignment == .leading { Spacer(minLength: 0) }
        }
    }

    private var tokenSummary: String? {
        // Prefer the prompt/completion split when both are present —
        // gives the most information. Fall back to the bare total if
        // only that arrived. Nothing renders if we have neither (older
        // sessions, providers that don't emit usage at all).
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            return "in \(formatTokens(prompt)) · out \(formatTokens(completion))"
        }
        if let total = message.usageTokens, total > 0 {
            return "\(formatTokens(total)) tok"
        }
        return nil
    }

    private func formatElapsed(_ seconds: Double) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return String(count)
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(message.content, forType: .string)
        didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
        }
    }
}

// MARK: - Queued message

private struct QueuedMessageRow: View {
    let message: AgentQueuedMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Queued")
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.orange)
                    .textCase(.uppercase)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(AgentDesign.bodyFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !message.images.isEmpty {
                    Text("\(message.images.count) image\(message.images.count == 1 ? "" : "s")")
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Empty state

private struct AgentEmptyState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            heroLine
            // Only show the stats dashboard once the user has at least
            // one persisted session — for a fresh install the empty
            // grid would be more demotivating than helpful.
            if !appState.agentSessions.isEmpty {
                AgentStatsDashboard()
                    .frame(maxWidth: 560)
            } else {
                Text(subtitle)
                    .font(AgentDesign.secondaryFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var heroLine: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tertiary)
                Text("What's up next, \(NSUserName())?")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var subtitle: String {
        if appState.rootDirectory == nil {
            return "Open a folder from the menu to chat about a project."
        }
        return "Chatting about \(appState.rootDirectory?.lastPathComponent ?? ""). Paste images, switch models, queue follow-ups."
    }
}

// MARK: - Stats dashboard

private struct AgentStatsDashboard: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DashboardTab = .overview
    @State private var range: DashboardRange = .all

    enum DashboardTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case models = "Models"
        var id: String { rawValue }
    }

    enum DashboardRange: String, CaseIterable, Identifiable {
        case all = "All"
        case days30 = "30d"
        case days7 = "7d"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .all: return nil
            case .days30: return 30
            case .days7: return 7
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            statsGrid
            heatmap
            funFact
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AgentDesign.cardBackground.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var tabBar: some View {
        HStack {
            // Left-side Overview / Models selector.
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    Button { selectedTab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selectedTab == tab
                                    ? AnyShapeStyle(AgentDesign.cardBackground)
                                    : AnyShapeStyle(Color.clear)
                            )
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            // Right-side All / 30d / 7d range selector.
            HStack(spacing: 2) {
                ForEach(DashboardRange.allCases) { value in
                    Button { range = value } label: {
                        Text(value.rawValue)
                            .font(.system(size: 11, weight: range == value ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(range == value ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var overview: AgentUsageOverview {
        AgentUsageStats.overview(for: filteredSessions)
    }

    private var filteredSessions: [AgentSession] {
        guard let days = range.days else { return appState.agentSessions }
        let calendar = Calendar.current
        guard let threshold = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return appState.agentSessions
        }
        return appState.agentSessions.map { session in
            var copy = session
            copy.messages = session.messages.filter { $0.createdAt >= threshold }
            return copy
        }.filter { !$0.messages.isEmpty }
    }

    private var statsGrid: some View {
        let stats = overview
        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            StatCell(title: "Sessions", value: "\(stats.sessionCount)")
            StatCell(title: "Messages", value: formatCompact(stats.messageCount))
            StatCell(
                title: stats.hasAnyRealUsage ? "Tokens" : "Tokens (est.)",
                value: formatTokens(stats.totalTokens)
            )
            StatCell(title: "Active days", value: "\(stats.activeDays)")
            StatCell(title: "Current streak", value: "\(stats.currentStreak)d")
            StatCell(title: "Longest streak", value: "\(stats.longestStreak)d")
            StatCell(title: "Peak hour", value: peakHourLabel(stats.peakHour))
            StatCell(title: "Favorite model", value: stats.favoriteModel ?? "—")
        }
    }

    private var heatmap: some View {
        let cells = AgentUsageStats.heatmap(for: filteredSessions, weekCount: 12)
        let maxCount = cells.flatMap { $0 }.map(\.count).max() ?? 0
        return HStack(spacing: 3) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, column in
                VStack(spacing: 3) {
                    ForEach(column) { cell in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: cell.count, peak: maxCount))
                            .frame(width: 11, height: 11)
                            .help("\(cellDateLabel(cell.date)) · \(cell.count) message\(cell.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for count: Int, peak: Int) -> Color {
        guard count > 0, peak > 0 else { return Color.secondary.opacity(0.12) }
        let intensity = min(1.0, Double(count) / Double(peak))
        return Color.accentColor.opacity(0.25 + 0.6 * intensity)
    }

    private func cellDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var funFact: some View {
        let stats = overview
        let ratio = AgentUsageStats.warAndPeaceEquivalents(tokenTotal: stats.totalTokens)
        return Group {
            if ratio > 0.05 {
                Text(funFactString(ratio: ratio))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 0)
            }
        }
    }

    private func funFactString(ratio: Double) -> String {
        if ratio >= 1 {
            return String(format: "You've used ~%.1f× more tokens than War and Peace.", ratio)
        }
        let pct = Int(ratio * 100)
        return "You've used about \(pct)% of War and Peace in tokens so far."
    }

    private func formatCompact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }

    private func peakHourLabel(_ hour: Int?) -> String {
        guard let hour else { return "—" }
        let suffix = hour < 12 ? "AM" : "PM"
        let display = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(display) \(suffix)"
    }
}

private struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AgentDesign.cardBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Plan card

struct AgentPlanCard: View {
    @EnvironmentObject var appState: AppState
    let plan: AgentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.number")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Plan")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                PlanStatusPill(status: plan.status)
                Spacer(minLength: 0)
            }

            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    AgentPlanStepRow(
                        index: index + 1,
                        step: step,
                        interactive: plan.status != .proposed && plan.status != .rejected,
                        onCycle: { next in
                            appState.setAgentPlanStepStatus(id: step.id, status: next)
                        }
                    )
                }
            }

            if plan.status == .proposed {
                HStack(spacing: 8) {
                    Button("Approve") { appState.approveAgentPlan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Reject") { appState.rejectAgentPlan() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    Text("Plan mode blocks writes until you Approve.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if plan.status == .approved || plan.status == .executing {
                Button("Mark plan complete") { appState.completeAgentPlan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            // Always offer a way to revise mid-execution — useful when
            // the agent's plan diverged from what the user actually
            // wanted, or when a constraint emerges partway through.
            AgentPlanRevisionRow()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

/// "Replan" action collapsed by default; expands into a one-line note
/// field + Send button so the user can either re-ask cold ("revise the
/// plan") or pass guidance ("use sed instead of patches"). Sits at the
/// bottom of every plan card.
private struct AgentPlanRevisionRow: View {
    @EnvironmentObject var appState: AppState
    @State private var expanded = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .opacity(0.4)
            HStack(spacing: 6) {
                if expanded {
                    TextField("Revision note (optional, e.g. 'skip step 2', 'use sed instead')", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($noteFocused)
                        .onSubmit { send() }
                    Button("Send") { send() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isAgentResponding && appState.agentQueuedMessages.count > 8)
                    Button {
                        expanded = false
                        note = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
                } else {
                    Button {
                        expanded = true
                        // Defer focus so the TextField has mounted first.
                        DispatchQueue.main.async { noteFocused = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Replan")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.orange)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Ask the agent to revise the plan — optionally with a note")
                    Spacer(minLength: 0)
                    if appState.isAgentResponding {
                        Text("Note will queue until the current turn finishes.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func send() {
        appState.requestPlanRevision(note: note)
        expanded = false
        note = ""
    }
}

private struct PlanStatusPill: View {
    let status: AgentPlan.Status

    var body: some View {
        Text(labelText)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.white)
            .background(Capsule(style: .continuous).fill(pillColor))
    }

    private var labelText: String {
        switch status {
        case .proposed: return "Awaiting Approval"
        case .approved: return "Approved"
        case .executing: return "Executing"
        case .done: return "Done"
        case .rejected: return "Rejected"
        }
    }

    private var pillColor: Color {
        switch status {
        case .proposed: return .orange
        case .approved, .executing: return .green
        case .done: return .blue
        case .rejected: return .red
        }
    }
}

/// One row of the plan card. The status glyph doubles as a button that
/// cycles pending → in_progress → done → skipped → pending, so the
/// user can override whatever the agent reported. While the plan is
/// still .proposed (awaiting approval), the glyph is shown but not
/// interactive — checking off steps before approval doesn't make sense.
private struct AgentPlanStepRow: View {
    @EnvironmentObject var appState: AppState
    let index: Int
    let step: AgentPlan.Step
    let interactive: Bool
    let onCycle: (AgentPlan.StepStatus) -> Void

    @State private var sheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case edit
        case insertAbove
        case insertBelow
        case restart

        var id: String {
            switch self {
            case .edit: return "edit"
            case .insertAbove: return "above"
            case .insertBelow: return "below"
            case .restart: return "restart"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                guard interactive else { return }
                onCycle(nextStatus(after: step.status))
            } label: {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
            .help(interactive ? "Cycle status (was \(step.status.rawValue))" : "Approve the plan to track step progress")

            Text("\(index).")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(step.text)
                .font(.system(size: 12))
                .strikethrough(step.status == .done || step.status == .skipped, color: .secondary)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit step…") { sheet = .edit }
            Button("Insert step above…") { sheet = .insertAbove }
            Button("Insert step below…") { sheet = .insertBelow }
            if interactive {
                Divider()
                Button("Restart from this step…") { sheet = .restart }
                    .disabled(appState.agentInteractionMode != .plan)
            }
            Divider()
            Button("Remove step", role: .destructive) {
                appState.removeAgentPlanStep(id: step.id)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .edit:
                AgentPlanStepSimpleSheet(
                    title: "Edit step \(index)",
                    initialText: step.text,
                    placeholder: "Step description",
                    confirmTitle: "Save",
                    onConfirm: { text in
                        appState.editAgentPlanStepText(id: step.id, newText: text)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .insertAbove:
                AgentPlanStepSimpleSheet(
                    title: "Insert step above \(index)",
                    initialText: "",
                    placeholder: "New step description",
                    confirmTitle: "Insert",
                    onConfirm: { text in
                        appState.insertAgentPlanStep(text: text, relativeToID: step.id, before: true)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .insertBelow:
                AgentPlanStepSimpleSheet(
                    title: "Insert step below \(index)",
                    initialText: "",
                    placeholder: "New step description",
                    confirmTitle: "Insert",
                    onConfirm: { text in
                        appState.insertAgentPlanStep(text: text, relativeToID: step.id, before: false)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            case .restart:
                AgentPlanStepSimpleSheet(
                    title: "Restart from step \(index)",
                    initialText: "",
                    placeholder: "Optional note for the agent (e.g. 'use sed instead')",
                    confirmTitle: "Restart",
                    onConfirm: { note in
                        appState.restartAgentPlanFromStep(id: step.id, note: note)
                        sheet = nil
                    },
                    onCancel: { sheet = nil }
                )
            }
        }
    }

    private var glyph: String {
        switch step.status {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var glyphColor: Color {
        switch step.status {
        case .pending: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    private var textColor: Color {
        switch step.status {
        case .done, .skipped: return .secondary
        case .failed: return .red
        default: return .primary
        }
    }

    private func nextStatus(after current: AgentPlan.StepStatus) -> AgentPlan.StepStatus {
        switch current {
        case .pending: return .inProgress
        case .inProgress: return .done
        case .done: return .skipped
        case .skipped: return .pending
        case .failed: return .pending
        }
    }
}

/// Reused single-field sheet for all four plan-step actions
/// (edit / insert above / insert below / restart). One field, one
/// confirm button — keeps the modal weight low.
private struct AgentPlanStepSimpleSheet: View {
    let title: String
    @State private var text: String
    let placeholder: String
    let confirmTitle: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    init(title: String, initialText: String, placeholder: String, confirmTitle: String,
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        _text = State(initialValue: initialText)
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(text) }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Goal card

struct AgentGoalCard: View {
    @EnvironmentObject var appState: AppState
    let goal: AgentGoal
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Goal")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Edit goal")
            }

            if !goal.statement.isEmpty {
                Text(goal.statement)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !goal.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(goal.checklist) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                appState.toggleAgentGoalItem(item.id)
                            } label: {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(item.text)
                                .font(.system(size: 12))
                                .strikethrough(item.done, color: .secondary)
                                .foregroundStyle(item.done ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .sheet(isPresented: $showingEditor) {
            AgentGoalEditorSheet(
                initialStatement: goal.statement,
                initialItems: goal.checklist.map(\.text),
                onSave: { statement, items in
                    appState.setAgentGoal(statement: statement, items: items)
                    showingEditor = false
                },
                onCancel: { showingEditor = false }
            )
        }
    }
}

// MARK: - Goal editor sheet

struct AgentGoalEditorSheet: View {
    @State private var statement: String
    @State private var itemsText: String
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    init(initialStatement: String = "", initialItems: [String] = [], onSave: @escaping (String, [String]) -> Void, onCancel: @escaping () -> Void) {
        _statement = State(initialValue: initialStatement)
        _itemsText = State(initialValue: initialItems.joined(separator: "\n"))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Define Goal")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal statement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What are we trying to accomplish?", text: $statement, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Acceptance checklist (one per line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $itemsText)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let items = itemsText.components(separatedBy: .newlines)
                    onSave(statement, items)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
