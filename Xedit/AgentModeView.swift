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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    primaryActions
                    Spacer().frame(height: 18)
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
        let isExpanded = expandedWorkspaces.contains(workspace)
        let visible = isExpanded ? sessions : Array(sessions.prefix(initialRowCount))
        let hasRealWorkspace = workspace != "_no_workspace_"

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

            ForEach(visible) { session in
                sessionRow(session)
            }

            if sessions.count > initialRowCount {
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

            Spacer().frame(height: 10)
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let isActive = appState.activeAgentSessionID == session.id
        return Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(session.title)
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                AgentSessionModeBadges(session: session)
            }
            .padding(.horizontal, 28)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Chat", role: .destructive) {
                appState.deleteAgentSession(id: session.id)
            }
        }
    }

    private var groupedSessions: [(String, [AgentSession])] {
        let groups = Dictionary(grouping: appState.agentSessions) { session in
            session.workspaceRootPath ?? "_no_workspace_"
        }
        return groups
            .map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { lhs, rhs in
                let l = lhs.1.first?.updatedAt ?? .distantPast
                let r = rhs.1.first?.updatedAt ?? .distantPast
                return l > r
            }
    }

    private func workspaceDisplayName(_ key: String) -> String {
        if key == "_no_workspace_" { return "No workspace" }
        return URL(fileURLWithPath: key).lastPathComponent
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
            .help("Copy title")

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    appState.startNewAgentSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .help("New Chat")

                Button {
                    appState.setAppMode(.editor)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AgentDesign.messageVerticalSpacing) {
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
                            .padding(.top, 80)
                    } else {
                        ForEach(visibleMessages) { message in
                            if shouldShowMessageBubble(message) {
                                AgentModeMessageView(message: message)
                                    .id(message.id)
                            }
                            let calls = toolCalls(for: message.id)
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
                                .id(toolGroupScrollID(for: message.id))
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
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: appState.agentMessages) { _, messages in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                if let last = appState.agentToolCalls.last {
                    proxy.scrollTo(toolGroupScrollID(for: last.messageID), anchor: .bottom)
                }
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
}

// MARK: - Message bubbles for Agent mode

private struct AgentModeMessageView: View {
    @EnvironmentObject var appState: AppState
    let message: AgentMessage

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
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 8) {
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(AgentDesign.bodyFont)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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
            .frame(maxWidth: AgentDesign.chatMaxContentWidth * 0.78, alignment: .trailing)
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .trailing)
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
            }
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }

    private var isStreamingThisMessage: Bool {
        guard appState.isAgentResponding, message.role == .assistant else { return false }
        return appState.agentMessages.last(where: { $0.role == .assistant })?.id == message.id
    }
}

// MARK: - Assistant Markdown body

/// Renders an assistant message's Markdown content as a vertical stack of
/// parsed blocks. Reuses `MarkdownPreviewParser` + `MarkdownPreviewBlockView`
/// from the editor's Markdown side preview so we don't carry two parsers,
/// and so a partially-streamed ```code``` block still renders (the parser
/// flushes any open code buffer at EOF).
private struct AgentAssistantMarkdownBody: View {
    let content: String
    /// When true, appends a small blinking cursor at the end of the
    /// rendered body to signal that more tokens are still arriving.
    let isStreaming: Bool

    private var blocks: [MarkdownPreviewBlock] {
        MarkdownPreviewParser.blocks(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownPreviewBlockView(block: block)
            }
            if isStreaming {
                AgentStreamingCursor()
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Composer

private struct AgentChatComposer: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ComposerCard()
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }
}

private struct ComposerCard: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool
    @State private var slashMenuVisible: Bool = false
    @State private var slashMenuSelection: Int = 0
    @State private var atMenuVisible: Bool = false
    @State private var atMenuSelection: Int = 0
    @State private var atMenuQuery: String = ""
    /// Cached skill list — re-fetched whenever the @ popover opens so we
    /// pick up newly installed skills without recomputing on every
    /// keystroke.
    @State private var skillCatalog: [AgentSkillEntry] = []
    /// Strong ref to the coordinator so the @-token replacement helper
    /// can call back into it from SwiftUI callbacks.
    @State private var coordinatorRef = ComposerCoordinatorRef()

    private var filteredSlashCommands: [SlashCommand] {
        SlashCommand.filter(
            appState.agentInput,
            allCommands: SlashCommand.builtIn(state: appState)
        )
    }

    /// Unified entries for the `@` picker — skills + workspace shortcut
    /// + project files (from the already-cached Quick Open list, which
    /// honors the project file cache). All three are fuzzy-filtered by
    /// the same query and capped so a 10k-file repo doesn't carpet the
    /// popover.
    private var filteredAtEntries: [AtPickerEntry] {
        let q = atMenuQuery.lowercased()
        var entries: [AtPickerEntry] = []

        // Workspace shortcut — only shows when a folder is open, and
        // either the query is empty or matches "workspace".
        if appState.rootDirectory != nil,
           q.isEmpty || "workspace".contains(q) {
            entries.append(.workspace)
        }

        // Skills (cached once per popover open).
        let skills = q.isEmpty ? skillCatalog : skillCatalog.filter {
            $0.identifier.lowercased().contains(q)
                || $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
        entries.append(contentsOf: skills.map { .skill($0) })

        // Project files — limit to 30 matches so the popover stays
        // navigable. Match by last path component first, then full
        // relative path. Files already attached are filtered out so
        // the user can't double-add.
        let alreadyAttached = Set(appState.agentPendingFiles.map(\.url.standardizedFileURL.path))
        if let root = appState.rootDirectory?.standardizedFileURL.path {
            let files = appState.quickOpenFiles.lazy
                .filter { !alreadyAttached.contains($0.standardizedFileURL.path) }
                .filter { url in
                    if q.isEmpty { return true }
                    let name = url.lastPathComponent.lowercased()
                    if name.hasPrefix(q) || name.contains(q) { return true }
                    let rel = String(url.standardizedFileURL.path
                        .dropFirst(root.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .lowercased()
                    return rel.contains(q)
                }
                .prefix(30)
                .map { url -> AtPickerEntry in
                    let rel = String(url.standardizedFileURL.path
                        .dropFirst(root.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return .file(url: url, relativePath: rel.isEmpty ? url.lastPathComponent : rel)
                }
            entries.append(contentsOf: files)
        }

        return entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.agentPendingImages.isEmpty {
                AgentComposerImageStrip(images: appState.agentPendingImages) { id in
                    appState.removeAgentImage(id: id)
                }
            }

            if !appState.agentPendingSkills.isEmpty {
                AgentComposerSkillStrip(skills: appState.agentPendingSkills) { identifier in
                    appState.detachAgentSkill(identifier: identifier)
                }
            }

            if !appState.agentPendingFiles.isEmpty || appState.agentPendingIncludeWorkspaceOverview {
                AgentComposerAttachmentStrip(
                    includeWorkspace: appState.agentPendingIncludeWorkspaceOverview,
                    files: appState.agentPendingFiles,
                    onRemoveWorkspace: { appState.toggleAgentWorkspaceOverview() },
                    onRemoveFile: { appState.detachAgentFile(id: $0) }
                )
            }

            ZStack(alignment: .topLeading) {
                ComposerTextEditor(
                    text: $appState.agentInput,
                    onSubmit: { appState.sendAgentMessage() },
                    onPasteImage: handlePastedImage,
                    historyProvider: { appState.agentMessages
                        .filter { $0.role == .user }
                        .map(\.content)
                        .filter { !$0.isEmpty }
                    },
                    slashMenuVisible: $slashMenuVisible,
                    slashMenuSelection: $slashMenuSelection,
                    slashMenuItemCount: { filteredSlashCommands.count },
                    onSlashCommit: { runSelectedSlashCommand() },
                    atMenuVisible: $atMenuVisible,
                    atMenuSelection: $atMenuSelection,
                    atMenuItemCount: { filteredAtEntries.count },
                    onAtCommit: { commitSelectedAtEntry() },
                    onAtQueryChange: { handleAtQueryChange($0) },
                    coordinatorRef: coordinatorRef
                )
                .focused($inputFocused)
                .frame(minHeight: 40, maxHeight: 130)
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDroppedProviders(providers)
                    return true
                }

                if slashMenuVisible {
                    SlashCommandMenu(
                        commands: filteredSlashCommands,
                        selection: $slashMenuSelection,
                        onPick: { index in
                            slashMenuSelection = index
                            _ = runSelectedSlashCommand()
                        }
                    )
                    .offset(y: -8)
                    .transition(.opacity)
                }

                if atMenuVisible {
                    AtPickerMenu(
                        entries: filteredAtEntries,
                        selection: $atMenuSelection,
                        onPick: { index in
                            atMenuSelection = index
                            _ = commitSelectedAtEntry()
                        }
                    )
                    .offset(y: -8)
                    .transition(.opacity)
                }
            }

            HStack(spacing: 6) {
                AttachButton(action: attachImageFromPanel)
                ModelPickerPill()
                AgentModePickerPill()
                Spacer(minLength: 0)
                if !appState.agentQueuedMessages.isEmpty {
                    QueueBadge()
                }
                SendStopButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AgentDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear { inputFocused = true }
    }

    /// Runs the currently-highlighted slash command. Returns true when a
    /// command was executed so the text view swallows the key, false to
    /// let the keystroke fall through (no match → treat as a normal Enter).
    @discardableResult
    private func runSelectedSlashCommand() -> Bool {
        let commands = filteredSlashCommands
        guard !commands.isEmpty else { return false }
        let safeIndex = min(max(0, slashMenuSelection), commands.count - 1)
        let command = commands[safeIndex]
        slashMenuVisible = false
        appState.agentInput = ""
        command.action()
        return true
    }

    private func handleAtQueryChange(_ query: String?) {
        if let q = query {
            // Refresh the catalog on transition from closed → open so a
            // newly installed skill shows up the next time `@` is typed.
            if !atMenuVisible || skillCatalog.isEmpty {
                skillCatalog = AgentSkillDirectory.list()
            }
            atMenuQuery = q
        } else {
            atMenuQuery = ""
        }
    }

    @discardableResult
    private func commitSelectedAtEntry() -> Bool {
        let entries = filteredAtEntries
        guard !entries.isEmpty else { return false }
        let safeIndex = min(max(0, atMenuSelection), entries.count - 1)
        let entry = entries[safeIndex]
        // Drop the @-token from the buffer. AppState side-effects then
        // surface as chips above the composer; the actual context
        // (SKILL.md body, file contents, workspace overview) is
        // spliced into the prompt by composeAttachedPrompt at send time.
        _ = coordinatorRef.coordinator?.replaceCurrentAtToken(with: "")
        switch entry {
        case .workspace:
            if !appState.agentPendingIncludeWorkspaceOverview {
                appState.toggleAgentWorkspaceOverview()
            }
        case .skill(let skill):
            appState.attachAgentSkill(skill)
        case .file(let url, _):
            appState.attachAgentFile(url: url)
        }
        atMenuVisible = false
        atMenuQuery = ""
        return true
    }

    private func handlePastedImage() {
        for (data, mime) in AgentImagePasteboardHelper.readImages(from: NSPasteboard.general) {
            ingest(data: data, mimeType: mime)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let png = Self.pngData(for: image) else { return }
                    DispatchQueue.main.async { ingest(data: png, mimeType: "image/png") }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let raw = try? Data(contentsOf: url),
                          let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else { return }
                    DispatchQueue.main.async { ingest(data: raw, mimeType: mime) }
                }
            }
        }
    }

    private func attachImageFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url),
                      let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else { continue }
                ingest(data: data, mimeType: mime)
            }
        }

        // Prefer attaching the panel as a sheet on the current key
        // window. `panel.begin { }` without a parent has been observed
        // to freeze the app on macOS 26 + SwiftUI MainActor isolation
        // (it interacts badly with the run loop). The sheet form is
        // explicitly modeless on the rest of the app.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func ingest(data: Data, mimeType: String) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        appState.addAgentImage(data: data, mimeType: mimeType)
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct AttachButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach image")
    }
}

private struct SendStopButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            if appState.isAgentResponding {
                appState.stopAgentResponse()
            } else {
                appState.sendAgentMessage()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(appState.isAgentResponding ? Color.red : (canSend ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 26, height: 26)
                Image(systemName: appState.isAgentResponding ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!appState.isAgentResponding && !canSend)
        .help(appState.isAgentResponding ? "Stop" : "Send (↩)")
    }

    private var canSend: Bool {
        !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.agentPendingImages.isEmpty
    }
}

private struct QueueBadge: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Button("Clear Queue", role: .destructive) {
                appState.clearAgentQueue()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                Text("\(appState.agentQueuedMessages.count) queued")
                    .font(AgentDesign.captionFont)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Model picker pill

private struct ModelPickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            let configured = appState.agentConfiguration.normalized.model(for: .interactive)
            if !configured.isEmpty {
                Button {
                    appState.setAgentSessionModel(nil)
                } label: {
                    HStack {
                        Text("Use route default: \(configured)")
                        if appState.agentSessionModelOverride == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
            }
            ForEach(appState.agentKnownModelIDs, id: \.self) { model in
                Button {
                    appState.setAgentSessionModel(model)
                } label: {
                    HStack {
                        Text(model)
                        if appState.agentSessionModelOverride == model {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if appState.agentKnownModelIDs.isEmpty {
                Text("Fetch models in Settings > Agent")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModel.isEmpty ? "Select model" : currentModel)
                    .font(AgentDesign.secondaryFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AgentDesign.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentModel: String {
        appState.agentModelStatusText
    }
}

// MARK: - Status bar

private struct AgentChatStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let branch = appState.gitStatus.branchName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let root = appState.rootDirectory {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(root.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("No workspace")
            }

            if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                AgentWorktreeSummaryPill()
            }

            Spacer(minLength: 0)

            CompressButton()
            ContextRingIndicator()
        }
        .font(AgentDesign.captionFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.statusBarHeight)
        .background(AgentDesign.statusBarBackground)
        .overlay(Divider(), alignment: .top)
    }
}

/// Button to manually compress the conversation. Surfaces only when the
/// estimated context usage crosses 50% so light conversations don't see
/// it. Replaced with a spinner while a compression is in flight.
private struct CompressButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isCompressingAgentContext {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Compressing…")
                }
            } else if shouldOffer {
                Button {
                    appState.compressAgentContext()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9))
                        Text("Compress")
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Summarize older messages to free context budget")
                .disabled(appState.isAgentResponding)
            }
        }
    }

    private var usedFraction: Double {
        let window = max(1, appState.agentContextWindow)
        return min(1.0, Double(appState.estimatedAgentTokens) / Double(window))
    }

    private var shouldOffer: Bool {
        usedFraction > 0.5 && appState.agentMessages.count > 6
    }

    private var tint: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }
}

private struct ContextRingIndicator: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    .frame(width: 12, height: 12)
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: 12)
            }
            Text("\(percent)%")
                .monospacedDigit()
        }
        .help("Context: ~\(formatTokens(used)) / \(formatTokens(window)). \(formatTokens(remaining)) remaining (estimate).")
    }

    private var window: Int { max(1, appState.agentContextWindow) }
    private var used: Int { appState.estimatedAgentTokens }
    private var usedFraction: CGFloat { min(1, max(0, CGFloat(used) / CGFloat(window))) }
    private var remaining: Int { max(0, window - used) }
    private var percent: Int { Int(usedFraction * 100) }

    private var barColor: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}

// MARK: - NSTextView-backed composer (Cmd+V image intercept, Return submit)

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: () -> Void
    /// Returns the user's prior messages in chronological order. `↑` walks
    /// from the most recent backwards; `↓` walks forward and eventually
    /// restores the draft the user was typing before they started cycling.
    let historyProvider: () -> [String]
    /// Bound state for the "/" slash command palette. The composer card
    /// owns these so the menu can render in SwiftUI above the text view.
    @Binding var slashMenuVisible: Bool
    @Binding var slashMenuSelection: Int
    let slashMenuItemCount: () -> Int
    /// Called when the user presses Enter / Tab with the slash menu
    /// visible. Returning true tells the text view to swallow the key.
    let onSlashCommit: () -> Bool
    /// Same shape as the slash palette, used for the "@" skill picker.
    @Binding var atMenuVisible: Bool
    @Binding var atMenuSelection: Int
    let atMenuItemCount: () -> Int
    let onAtCommit: () -> Bool
    /// Notifies the composer card that the @ token in the buffer has
    /// changed (e.g. user kept typing letters after `@`), so the popover
    /// can re-filter its entries.
    let onAtQueryChange: (String?) -> Void
    /// Holder the parent passes in so it can hand the coordinator
    /// pointer back to SwiftUI menu callbacks (used by the @-token
    /// replacement helper). Filled in inside `makeCoordinator`.
    let coordinatorRef: ComposerCoordinatorRef

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onPasteImage: onPasteImage,
            historyProvider: historyProvider,
            slashMenuVisible: $slashMenuVisible,
            slashMenuSelection: $slashMenuSelection,
            slashMenuItemCount: slashMenuItemCount,
            onSlashCommit: onSlashCommit,
            atMenuVisible: $atMenuVisible,
            atMenuSelection: $atMenuSelection,
            atMenuItemCount: atMenuItemCount,
            onAtCommit: onAtCommit,
            onAtQueryChange: onAtQueryChange
        )
        coordinatorRef.coordinator = coord
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = text
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Track programmatic text changes so the history cursor
            // doesn't think the user kept typing on top of a recalled
            // message — this also covers the slash-command path
            // emptying the buffer after running an action.
            context.coordinator.markTextReplacedExternally(to: text)
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onPasteImage: () -> Void
        let historyProvider: () -> [String]
        var slashMenuVisible: Binding<Bool>
        var slashMenuSelection: Binding<Int>
        let slashMenuItemCount: () -> Int
        let onSlashCommit: () -> Bool
        var atMenuVisible: Binding<Bool>
        var atMenuSelection: Binding<Int>
        let atMenuItemCount: () -> Int
        let onAtCommit: () -> Bool
        let onAtQueryChange: (String?) -> Void

        // History cursor state. `historyIndex` counts back from the most
        // recent user message: 0 = newest, 1 = next-newest, etc. nil
        // means "not cycling — the buffer holds the user's own draft".
        private var historyIndex: Int? = nil
        private var savedDraft: String = ""
        /// The exact string the composer last published from history, so
        /// we can tell whether the user has edited on top of it.
        private var lastHistoryString: String? = nil
        /// Tracks the active NSTextView so textDidChange handlers can
        /// inspect the live selection (NSTextStorage's didChange fires
        /// before selection updates, so we use the cached pointer rather
        /// than relying on the notification's object).
        fileprivate weak var activeTextView: NSTextView?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onPasteImage: @escaping () -> Void,
            historyProvider: @escaping () -> [String],
            slashMenuVisible: Binding<Bool>,
            slashMenuSelection: Binding<Int>,
            slashMenuItemCount: @escaping () -> Int,
            onSlashCommit: @escaping () -> Bool,
            atMenuVisible: Binding<Bool>,
            atMenuSelection: Binding<Int>,
            atMenuItemCount: @escaping () -> Int,
            onAtCommit: @escaping () -> Bool,
            onAtQueryChange: @escaping (String?) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImage = onPasteImage
            self.historyProvider = historyProvider
            self.slashMenuVisible = slashMenuVisible
            self.slashMenuSelection = slashMenuSelection
            self.slashMenuItemCount = slashMenuItemCount
            self.onSlashCommit = onSlashCommit
            self.atMenuVisible = atMenuVisible
            self.atMenuSelection = atMenuSelection
            self.atMenuItemCount = atMenuItemCount
            self.onAtCommit = onAtCommit
            self.onAtQueryChange = onAtQueryChange
        }

        func markTextReplacedExternally(to newValue: String) {
            // If something other than the user typed (slash action,
            // history binding push), reset our cursor so the next ↑
            // starts fresh.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            activeTextView = textView
            let newValue = textView.string
            text.wrappedValue = newValue
            // Any user edit invalidates the history cursor and re-derives
            // slash + @ visibility.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
            updateSlashMenuVisibility(for: newValue)
            updateAtMenuVisibility(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            activeTextView = textView
            // Slash command palette takes priority over history + submit
            // while it's open.
            if slashMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    return onSlashCommit()
                case #selector(NSResponder.cancelOperation(_:)):
                    slashMenuVisible.wrappedValue = false
                    return true
                default:
                    break
                }
            }

            // @ skill picker takes priority over submit while it's open,
            // but defers caret motion (↑/↓) ONLY when the menu actually
            // has items to step through — keeps multi-line composition
            // unaffected when there are no skill matches.
            if atMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    if onAtCommit() { return true }
                case #selector(NSResponder.cancelOperation(_:)):
                    atMenuVisible.wrappedValue = false
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let wantsLineBreak = modifiers.contains(.shift)
                    || modifiers.contains(.option)
                    || modifiers.contains(.control)
                if !wantsLineBreak {
                    onSubmit()
                    historyIndex = nil
                    lastHistoryString = nil
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let recalled = stepHistory(direction: -1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let recalled = stepHistory(direction: +1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            return false
        }

        /// Returns the next/previous history entry (or the saved draft on
        /// the way back down) — or nil to let the text view's normal
        /// caret-movement command run.
        private func stepHistory(direction: Int, currentText: String) -> String? {
            let history = historyProvider()
            guard !history.isEmpty else { return nil }

            // Only intercept ↑/↓ when the buffer is empty OR currently
            // showing a recalled history entry. Anything else means the
            // user is editing prose and expects caret motion.
            let isOnHistory = historyIndex != nil && currentText == lastHistoryString
            let isEmpty = currentText.isEmpty
            guard isEmpty || isOnHistory else { return nil }

            if direction < 0 {
                // ↑ — walk further back. If we weren't cycling yet, save
                // whatever was in the buffer (probably empty) as the draft.
                if historyIndex == nil {
                    savedDraft = currentText
                    historyIndex = 0
                } else if let i = historyIndex, i + 1 < history.count {
                    historyIndex = i + 1
                } else {
                    return nil // already at oldest
                }
            } else {
                // ↓ — walk forward toward the draft.
                guard let i = historyIndex else { return nil }
                if i == 0 {
                    historyIndex = nil
                    return savedDraft
                }
                historyIndex = i - 1
            }
            guard let i = historyIndex else { return savedDraft }
            return history[history.count - 1 - i]
        }

        private func applyHistory(_ value: String, to textView: NSTextView) {
            textView.string = value
            text.wrappedValue = value
            lastHistoryString = value
            // Park the caret at end so the user can keep typing.
            let end = (value as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        private func updateSlashMenuVisibility(for newValue: String) {
            // Show the palette only when the buffer starts with "/" and
            // has no embedded newline yet. A trailing space ends the
            // command name and dismisses the menu.
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            let shouldShow = newValue.hasPrefix("/")
                && !newValue.contains("\n")
                && !trimmed.isEmpty
            if slashMenuVisible.wrappedValue != shouldShow {
                slashMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    slashMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Looks at the caret position and decides whether the user is
        /// inside an `@token` (counting backwards from the caret to the
        /// nearest `@`, stopping at whitespace/newline/another `@`).
        /// Returns the substring after `@` so the popover can filter.
        fileprivate func currentAtQuery(in textView: NSTextView) -> String? {
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return nil }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                let scalar = UnicodeScalar(ch)
                if ch == 0x40 { // '@'
                    // Require that '@' sits at the start of the buffer
                    // or right after whitespace — avoids matching email
                    // addresses, file paths, etc.
                    if i == 0 {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    let prev = nsString.character(at: i - 1)
                    if let prevScalar = UnicodeScalar(prev),
                       CharacterSet.whitespacesAndNewlines.contains(prevScalar) {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    return nil
                }
                if let s = scalar, CharacterSet.whitespacesAndNewlines.contains(s) {
                    return nil
                }
                i -= 1
            }
            return nil
        }

        private func updateAtMenuVisibility(for textView: NSTextView) {
            let query = currentAtQuery(in: textView)
            onAtQueryChange(query)
            let shouldShow = query != nil
            if atMenuVisible.wrappedValue != shouldShow {
                atMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    atMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Replace the in-progress `@token` at the caret with the chosen
        /// skill's identifier (kept around for transparency — actual
        /// skill content gets spliced in at send time) and dismiss the
        /// popover. Returns true if it edited the buffer.
        func replaceCurrentAtToken(with replacement: String) -> Bool {
            guard let textView = activeTextView else { return false }
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return false }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                if ch == 0x40 { break }
                if let s = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) { return false }
                i -= 1
            }
            guard i >= 0 else { return false }
            let replaceRange = NSRange(location: i, length: caret - i)
            let mutable = NSMutableString(string: textView.string)
            mutable.replaceCharacters(in: replaceRange, with: replacement)
            textView.string = mutable as String
            text.wrappedValue = mutable as String
            let newCaret = i + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            atMenuVisible.wrappedValue = false
            return true
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {}
}

fileprivate final class ComposerNSTextView: NSTextView {
    fileprivate weak var coordinator: ComposerTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasImage = (pasteboard.pasteboardItems ?? []).contains { item in
            item.data(forType: .png) != nil
                || item.data(forType: .tiff) != nil
        }
        if hasImage {
            coordinator?.onPasteImage()
            if pasteboard.string(forType: .string) != nil {
                super.paste(sender)
            }
            return
        }
        super.paste(sender)
    }
}

// MARK: - Slash commands

/// A single command shown in the "/" palette. Pure local actions — no
/// network, no LLM round-trip. Each one runs synchronously against
/// AppState. The model-picker case opens the existing model picker
/// surface; the others call public AppState APIs directly.
struct SlashCommand: Identifiable {
    let id: String          // canonical name without slash, used for filter
    let title: String       // e.g. "/new"
    let subtitle: String    // one-liner shown under the title
    let symbol: String      // SF Symbol name
    let action: () -> Void

    static func builtIn(state: AppState) -> [SlashCommand] {
        [
            SlashCommand(id: "new", title: "/new", subtitle: "Start a fresh chat in this workspace", symbol: "square.and.pencil") {
                state.startNewAgentSession()
            },
            SlashCommand(id: "clear", title: "/clear", subtitle: "Clear the current chat's messages", symbol: "eraser") {
                state.clearAgentConversation()
            },
            SlashCommand(id: "compress", title: "/compress", subtitle: "Summarize older turns to free context", symbol: "rectangle.compress.vertical") {
                state.compressAgentContext()
            },
            SlashCommand(id: "stop", title: "/stop", subtitle: "Stop the current model response", symbol: "stop.circle") {
                state.stopAgentResponse()
            },
            SlashCommand(id: "clear-queue", title: "/clear-queue", subtitle: "Drop any pending queued messages", symbol: "tray.2") {
                state.clearAgentQueue()
            },
            SlashCommand(id: "copy-last", title: "/copy-last", subtitle: "Copy the last assistant message", symbol: "doc.on.doc") {
                guard let last = state.agentMessages.last(where: { $0.role == .assistant }) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.content, forType: .string)
            },
        ]
    }

    /// Filters by fuzzy-ish prefix on the slash-stripped query. The text
    /// view passes `"/cl"` etc. — we strip the leading slash and match
    /// either the canonical id or the title prefix. Empty query (just
    /// `/`) lists everything.
    static func filter(_ rawInput: String, allCommands: [SlashCommand]) -> [SlashCommand] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        guard !query.isEmpty else { return allCommands }
        return allCommands.filter { c in
            c.id.lowercased().contains(query) || c.title.lowercased().contains(query)
        }
    }
}

private struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    @Binding var selection: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    SlashCommandRow(
                        command: command,
                        isSelected: index == selection
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .alignmentGuide(.top) { $0[.bottom] }   // sit above the input
        .fixedSize()
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(command.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - @ skill picker

/// Thin holder so the composer card can hand its coordinator reference
/// out to SwiftUI menu callbacks. NSViewRepresentable's `makeCoordinator`
/// is the canonical owner; we just need to surface a way to call
/// `replaceCurrentAtToken` from outside the text view's own delegate.
final class ComposerCoordinatorRef {
    weak var coordinator: ComposerTextEditor.Coordinator?
}

/// Chips of currently-attached skills, sitting above the text editor so
/// the user always sees what's about to ride along with the next send.
struct AgentComposerSkillStrip: View {
    let skills: [AgentSkillEntry]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(skills) { skill in
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text("@\(skill.identifier)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Button {
                            onRemove(skill.identifier)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                    )
                    .help(skill.description)
                }
            }
        }
    }
}

/// Chips for non-skill attachments: workspace overview + per-file
/// references. Same removable pill design as the skill strip, but in a
/// distinct accent so users can tell at a glance which kind of context
/// is riding along this turn.
struct AgentComposerAttachmentStrip: View {
    let includeWorkspace: Bool
    let files: [AgentFileAttachment]
    let onRemoveWorkspace: () -> Void
    let onRemoveFile: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if includeWorkspace {
                    chip(
                        symbol: "folder",
                        label: "@workspace",
                        help: "Workspace root + file list will ride along",
                        onRemove: onRemoveWorkspace
                    )
                }
                ForEach(files) { file in
                    chip(
                        symbol: "doc.text",
                        label: "@\(file.relativePath)",
                        help: file.url.path,
                        onRemove: { onRemoveFile(file.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func chip(symbol: String, label: String, help: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.purple)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.purple.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.purple.opacity(0.30), lineWidth: 1)
        )
        .help(help)
    }
}

/// One row in the `@` popover. Skills, project files, and the special
/// `workspace` shortcut are unified so the user can fuzzy-match across
/// every attachable thing in one list.
enum AtPickerEntry: Identifiable, Equatable {
    case workspace
    case skill(AgentSkillEntry)
    case file(url: URL, relativePath: String)

    var id: String {
        switch self {
        case .workspace: return "@workspace"
        case .skill(let s): return "skill:\(s.identifier)"
        case .file(let url, _): return "file:\(url.standardizedFileURL.path)"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: return "folder"
        case .skill: return "wand.and.stars"
        case .file: return "doc.text"
        }
    }

    var title: String {
        switch self {
        case .workspace: return "workspace"
        case .skill(let s): return s.identifier
        case .file(_, let rel): return rel
        }
    }

    var subtitle: String {
        switch self {
        case .workspace: return "Attach the current workspace root + file list"
        case .skill(let s): return s.description
        case .file(let url, _): return url.deletingLastPathComponent().lastPathComponent
        }
    }
}

private struct AtPickerMenu: View {
    let entries: [AtPickerEntry]
    @Binding var selection: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No matching skills, files, or shortcuts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AtPickerRow(entry: entry, isSelected: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .fixedSize()
    }
}

private struct AtPickerRow: View {
    let entry: AtPickerEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - Sidebar session mode badges

/// Tiny right-aligned indicators on each session row that summarise the
/// session's plan/goal progress at a glance. Plan badge shows
/// `done/total`; goal badge shows `done/total` of the checklist. Skipped
/// here for sessions in Normal mode or with empty plan/goal so we don't
/// add visual noise to ordinary chats.
private struct AgentSessionModeBadges: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            if let plan = session.currentPlan, !plan.steps.isEmpty {
                badge(
                    symbol: "list.number",
                    color: planBadgeColor(plan),
                    text: planProgress(plan),
                    help: planHelp(plan)
                )
            }
            if let goal = session.currentGoal, !goal.checklist.isEmpty {
                let doneCount = goal.checklist.filter(\.done).count
                badge(
                    symbol: "target",
                    color: doneCount == goal.checklist.count ? .green : .accentColor,
                    text: "\(doneCount)/\(goal.checklist.count)",
                    help: goal.statement.isEmpty ? "Goal progress" : goal.statement
                )
            }
        }
    }

    @ViewBuilder
    private func badge(symbol: String, color: Color, text: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
        .help(help)
    }

    private func planProgress(_ plan: AgentPlan) -> String {
        let done = plan.steps.filter { $0.status == .done }.count
        return "\(done)/\(plan.steps.count)"
    }

    private func planBadgeColor(_ plan: AgentPlan) -> Color {
        switch plan.status {
        case .proposed, .rejected: return .orange
        case .approved, .executing: return .accentColor
        case .done: return .green
        }
    }

    private func planHelp(_ plan: AgentPlan) -> String {
        switch plan.status {
        case .proposed: return "Plan awaiting approval"
        case .approved: return "Plan approved, not started"
        case .executing: return "Plan executing"
        case .done: return "Plan complete"
        case .rejected: return "Plan rejected"
        }
    }
}

// MARK: - Mode picker (Normal / Plan / Goal)

private struct AgentModePickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var showingGoalEditor = false

    var body: some View {
        Menu {
            ForEach(AgentInteractionMode.allCases) { mode in
                Button {
                    if mode == .goal {
                        // Goal mode requires a definition; if there's
                        // already a goal we just flip the mode, otherwise
                        // open the editor sheet first.
                        appState.setAgentInteractionMode(.goal)
                        if appState.agentCurrentGoal == nil { showingGoalEditor = true }
                    } else {
                        appState.setAgentInteractionMode(mode)
                    }
                } label: {
                    Label(mode.displayName, systemImage: mode.symbol)
                }
            }
            if appState.agentInteractionMode == .goal {
                Divider()
                Button("Edit goal…") { showingGoalEditor = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentInteractionMode.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentInteractionMode.displayName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Conversation mode — Plan locks writes until you approve; Goal pins an objective to every reply.")
        .sheet(isPresented: $showingGoalEditor) {
            AgentGoalEditorSheet { statement, items in
                appState.setAgentGoal(statement: statement, items: items)
                if appState.agentInteractionMode != .goal {
                    appState.setAgentInteractionMode(.goal)
                }
                showingGoalEditor = false
            } onCancel: {
                showingGoalEditor = false
            }
        }
    }

    private var pillForeground: Color {
        appState.agentInteractionMode == .normal ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        switch appState.agentInteractionMode {
        case .normal: return Color.secondary.opacity(0.10)
        case .plan: return Color.orange
        case .goal: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        appState.agentInteractionMode == .normal ? Color.secondary.opacity(0.25) : Color.clear
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

private struct AgentGoalEditorSheet: View {
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
