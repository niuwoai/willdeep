//
//  AgentPanelView.swift
//  WillDeep
//
//  Right-side chat panel for the project agent.
//

import SwiftUI
import AppKit

struct AgentPanelView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool
    @State private var isJobsDrawerOpen = false
    @State private var isFollowingTranscriptBottom = true
    private static let bottomScrollID = "agent-panel-transcript-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    transcript
                    Divider()
                    composer
                }
                if isJobsDrawerOpen {
                    Divider()
                    VStack(spacing: 0) {
                        taskMonitorDrawerHeader
                        Divider().opacity(0.5)
                        AgentTaskMonitorRail(width: 300)
                    }
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: isJobsDrawerOpen ? 600 : 300)
        .background(appState.editorSettings.interfaceSkin.palette.panelFill)
        .overlay(alignment: .leading) {
            Divider()
        }
        .sheet(item: $appState.agentWorktreeDiffPreview) { preview in
            AgentWorktreeDiffPreviewSheet(preview: preview)
        }
        .onAppear {
            inputFocused = true
        }
        .animation(.easeInOut(duration: 0.18), value: isJobsDrawerOpen)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                Text(appState.agentModelStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            backgroundJobsToggleButton
            Button {
                appState.clearAgentConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Chat")
            .disabled(appState.agentMessages.isEmpty && appState.agentErrorMessage == nil && appState.agentToolCalls.isEmpty)

            Button {
                appState.isAgentPanelVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Agent")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var taskMonitorDrawerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("任务监控")
                .font(AgentDesign.titleFont)
            Spacer(minLength: 0)
            Button {
                isJobsDrawerOpen = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help(L10n.AgentSidePanel.close)
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .frame(height: 38)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The panel transcript is small enough to lay out eagerly,
                // and avoiding LazyVStack keeps scroll-time placement out
                // of SwiftUI's fragile lazy stack cache.
                VStack(alignment: .leading, spacing: 10) {
                    if appState.agentMessages.isEmpty {
                        AgentPanelEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 44)
                    } else {
                        ForEach(transcriptItems) { item in
                            switch item.payload {
                            case .message(let message):
                                AgentMessageBubble(message: message)
                                    .id(message.id)
                            case .tools(let calls):
                                AgentToolCallGroup(calls: calls)
                                    .id(item.id)
                            }
                        }
                    }

                    // 消息已发出但还没抢到 provider 并发槽时,给一行
                    // 「排队中」提示 —— 否则用户只看到自己的消息、没有
                    // 任何「在处理」反馈,容易以为又没发出去。
                    if appState.activeRuntime?.isAwaitingProviderSlot == true {
                        AgentInlineStatusDivider(
                            text: L10n.AgentPanel.queueWaiting,
                            systemImage: "clock"
                        )
                    }

                    if appState.shouldShowAgentThinkingIndicator {
                        AgentThinkingDivider()
                    }

                    // 底部活动指示（参照 Claude Code）：有任务在跑就显示
                    // 「✳ N 个任务运行中」（点击展开右侧 jobs 抽屉），turn
                    // 结束后只要后台作业还活着就继续显示；没有任务但 turn
                    // 还在跑则退回纯呼吸 icon。
                    if !appState.isCompressingAgentContext {
                        let runningTasks = appState.agentRunningTaskCount
                        if runningTasks > 0 {
                            AgentRunningTasksRow(
                                count: runningTasks,
                                detail: appState.agentRunningTaskSummary
                            ) {
                                isJobsDrawerOpen = true
                            }
                        } else if appState.isAgentResponding && !appState.shouldShowAgentThinkingIndicator {
                            AgentBreathingIndicator()
                        }
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                    }

                    AgentPatchProposalList(proposals: appState.agentPatchProposals)

                    if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomScrollID)
                }
                .padding(10)
                .background {
                    AgentTranscriptScrollObserver(
                        isFollowingBottom: $isFollowingTranscriptBottom
                    )
                    .frame(width: 0, height: 0)
                }
            }
            // Watch count, not the array — token-by-token streaming
            // mutates `messages[i].content`, and observing the whole
            // array fires `scrollTo` on every token. See the longer
            // comment in AgentChatTranscript.
            .onCompatibleChange(of: appState.agentMessages.count) { oldCount, newCount in
                let appendedMessage = newCount > oldCount ? appState.agentMessages.last : nil
                guard AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                    appendedMessage,
                    isFollowingBottom: isFollowingTranscriptBottom
                ) else { return }
                if appendedMessage?.isOperatorInput == true {
                    isFollowingTranscriptBottom = true
                }
                scrollToBottom(using: proxy)
            }
            .onCompatibleChange(of: appState.agentToolCalls.count) { _, _ in
                guard isFollowingTranscriptBottom else { return }
                scrollToBottom(using: proxy)
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { message in
            // Background-job completion notices are injected as
            // `.system` so all four provider adapters carry them
            // verbatim; they should not appear as user-facing
            // bubbles (the right-side jobs drawer is the UI for
            // them). Any other `.system` message in history is
            // also internal plumbing, so filter the whole role.
            message.role != .tool
                && message.role != .system
                && !message.isHostInstruction
                && !isEmptyThinkingPlaceholder(message)
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    /// Build one linear presentation stream so adjacent tool-only messages
    /// share a single compact card. A prose bubble is a real boundary; a
    /// tool-only assistant message is not. The group's id stays anchored to
    /// its first message while more calls stream in, avoiding SwiftUI tearing
    /// down and recreating the card as the group grows.
    private var transcriptItems: [AgentPanelTranscriptItem] {
        var items: [AgentPanelTranscriptItem] = []
        for message in visibleMessages {
            if shouldShowMessageBubble(message) {
                items.append(.message(message))
            }

            let calls = toolCalls(for: message.id)
            guard !calls.isEmpty else { continue }
            if !shouldShowMessageBubble(message),
               case .tools(let existingCalls)? = items.last?.payload {
                items[items.count - 1].payload = .tools(existingCalls + calls)
            } else {
                items.append(.tools(messageID: message.id, calls: calls))
            }
        }
        return items
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

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: appState.rootDirectory == nil ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(.secondary)
                Text(contextLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            if !appState.agentPendingTextAttachments.isEmpty {
                AgentComposerTextAttachmentStrip(attachments: appState.agentPendingTextAttachments) { id in
                    appState.removeAgentTextAttachment(id: id)
                }
            }

            TextEditor(text: $appState.agentInput)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text(contextHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    appState.sendAgentMessage()
                } label: {
                    Label(appState.isAgentResponding ? "Sending" : "Send", systemImage: "paperplane.fill")
                }
                .disabled(appState.isAgentResponding || !canSend)
            }
        }
        .padding(10)
        .onCompatibleChange(of: appState.agentComposerFocusRevision) { _, _ in
            inputFocused = true
        }
    }

    private var canSend: Bool {
        !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.agentPendingTextAttachments.isEmpty
            || !appState.agentPendingImages.isEmpty
            || !appState.agentPendingFiles.isEmpty
            || appState.agentPendingIncludeWorkspaceOverview
    }

    private var contextLabel: String {
        if let openedFileURL = appState.openedFileURL {
            return openedFileURL.lastPathComponent
        }
        if let rootDirectory = appState.rootDirectory {
            return rootDirectory.lastPathComponent
        }
        return L10n.Workspace.noWorkspace
    }

    private var contextHint: String {
        if appState.rootDirectory == nil {
            return L10n.AgentPanel.openFolderHint
        }
        if !appState.agentPendingTextAttachments.isEmpty {
            return L10n.AgentSelection.selectionAttachedHint
        }
        if appState.selectedCharacterCount > 0 {
            return L10n.AgentPanel.selectionIncludedHint
        }
        return L10n.AgentPanel.activeFileIncludedHint
    }

    // MARK: - Background jobs header toggle

    /// Header button that toggles the right-side jobs drawer. Shows
    /// a small live count of alive jobs in this runtime as a green
    /// pill; falls back to a plain icon when there are no jobs at
    /// all. Hidden entirely when there's no active runtime (would
    /// only ever show "0 jobs", which is noise).
    @ViewBuilder
    private var backgroundJobsToggleButton: some View {
        if let runtimeID = appState.activeAgentSessionID {
            let runtimeJobs = appState.agentJobRegistry.jobs(forRuntime: runtimeID)
            let aliveCount = runtimeJobs.filter(\.isAlive).count
            Button {
                isJobsDrawerOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: aliveCount > 0 ? "play.circle.fill" : "play.circle")
                        .foregroundStyle(aliveCount > 0 ? Color.green : Color.secondary)
                    if aliveCount > 0 {
                        Text("\(aliveCount)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(L10n.AgentJobs.toggleHelp)
            .disabled(runtimeJobs.isEmpty && !isJobsDrawerOpen)
        }
    }
}

struct AgentContextCompressionDivider: View {
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        AgentInlineStatusDivider(
            text: L10n.AgentPanel.contextCompressing,
            systemImage: "rectangle.compress.vertical",
            leadingInset: leadingInset,
            trailingInset: trailingInset
        )
    }
}

struct AgentThinkingDivider: View {
    @EnvironmentObject var appState: AppState
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // When we have a turn start timestamp, render a live ticker so the
            // user can see the seconds advance — proof that the request hasn't
            // silently hung. When we don't (e.g. legacy code paths that don't
            // stamp the start), fall back to the static label.
            if let startedAt = appState.agentTurnStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    AgentInlineStatusDivider(
                        text: L10n.AgentPanel.thinking,
                        trailing: formatThinkingElapsed(
                            context.date.timeIntervalSince(startedAt)
                        ),
                        showsSeparator: false,
                        leadingInset: leadingInset,
                        trailingInset: trailingInset
                    )
                }
            } else {
                AgentInlineStatusDivider(
                    text: L10n.AgentPanel.thinking,
                    showsSeparator: false,
                    leadingInset: leadingInset,
                    trailingInset: trailingInset
                )
            }

            // Reasoning 与正式回答共用同一套正文渲染和流式节流。首个
            // 正文 token 到达时，AgentStreamingMessageBuffer 会原子提交
            // 两类增量；父视图随后一次性用回答替换这里，不做交叉淡入。
            if let reasoning = appState.agentLiveThinkingPreview {
                AgentAssistantMarkdownBody(
                    content: reasoning,
                    isStreaming: true,
                    baseFontSize: appState.agentChatBaseFontSize,
                    showsStreamingCursor: false
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.top, AgentChatHistoryLayoutMetrics.assistantStatusDividerBottomSpacing)
                    .padding(.bottom, 8)
                    .accessibilityLabel(L10n.AgentPanel.thinkingPreviewAccessibility)
            }
        }
    }
}

private struct AgentPanelTranscriptItem: Identifiable {
    enum Payload {
        case message(AgentMessage)
        case tools([AgentToolCall])
    }

    let id: String
    var payload: Payload

    static func message(_ message: AgentMessage) -> Self {
        Self(id: "message:\(message.id.uuidString)", payload: .message(message))
    }

    static func tools(messageID: AgentMessage.ID, calls: [AgentToolCall]) -> Self {
        Self(id: "tools:\(messageID.uuidString)", payload: .tools(calls))
    }
}

private func formatThinkingElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 {
        return "\(total)s"
    }
    let minutes = total / 60
    let remaining = total % 60
    if minutes < 60 {
        return "\(minutes)m \(remaining)s"
    }
    let hours = minutes / 60
    let mm = minutes % 60
    return "\(hours)h \(mm)m"
}

// Shared with the full-screen transcript (`AgentChatTranscript`) so the
// "waiting for a provider slot" queue hint renders consistently in both the
// sidebar and the main chat.
struct AgentInlineStatusDivider: View {
    let text: String
    /// Optional trailing caption rendered next to the label — used by the
    /// thinking status to show live elapsed seconds.
    var trailing: String? = nil
    var systemImage: String? = nil
    var showsSeparator = true
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: showsSeparator ? AgentInlineStatusLayout.ruleToLabelSpacing : 0
        ) {
            if showsSeparator {
                Rectangle()
                    .fill(Color.secondary.opacity(AgentInlineStatusLayout.separatorOpacity))
                    .frame(height: 1)
            }
            HStack(spacing: AgentInlineStatusLayout.labelSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.medium))
                        .frame(
                            width: AgentInlineStatusLayout.iconSize,
                            height: AgentInlineStatusLayout.iconSize
                        )
                }
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
                if let trailing {
                    Text("·")
                        .font(.caption)
                        .opacity(0.7)
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.secondary.opacity(AgentInlineStatusLayout.foregroundOpacity))
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, AgentInlineStatusLayout.topPadding)
        .padding(.bottom, AgentInlineStatusLayout.bottomPadding)
        .accessibilityLabel(trailing.map { "\(text) · \($0)" } ?? text)
    }
}

private enum AgentInlineStatusLayout {
    static let ruleToLabelSpacing: CGFloat = 12
    static let labelSpacing: CGFloat = 6
    static let iconSize: CGFloat = 14
    static let topPadding: CGFloat = 4
    static let bottomPadding: CGFloat = 8
    static let separatorOpacity = 0.24
    static let foregroundOpacity = 0.72
}

struct AgentWorktreeChangeCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showsAllFiles = false
    private let collapsedFileLimit = 3
    /// How "审查" / a file-row tap surfaces the diff. Agent mode passes a
    /// closure that opens the right side-panel `.diff`; the editor-dock
    /// panel leaves it nil and falls back to the standalone sheet.
    var onReview: (() -> Void)? = nil
    /// 全屏 Agent 模式的 transcript 里,composer 顶部已经吸附了一条
    /// `AgentComposerWorktreeSummaryBar`(N 个文件已更改 +X −Y 审查),
    /// 这张卡片再画一遍 summary 行就重复了 —— 那个语境传 false,只保留
    /// 有信息量的文件列表。停靠侧栏没有 composer bar,默认 true 保留。
    var showsSummaryRow: Bool = true

    private func review() {
        if let onReview {
            onReview()
        } else {
            appState.showAgentWorktreeDiff()
        }
    }

    var body: some View {
        let visibleFiles = visibleChanges
        VStack(alignment: .leading, spacing: 10) {
            if !visibleFiles.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleFiles.indices, id: \.self) { index in
                        changedFileRow(visibleFiles[index])
                        if index < visibleFiles.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )

                if hiddenFileCount > 0 {
                    Button {
                        showsAllFiles.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Text(showsAllFiles ? "收起文件" : "再显示 \(hiddenFileCount) 个文件")
                            Image(systemName: showsAllFiles ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showsSummaryRow {
                HStack(spacing: 8) {
                    Image(systemName: appState.isAgentResponding ? "pencil.line" : "checkmark.square")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summaryTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Text("+\(appState.agentWorktreeChanges.totalAddedLines)")
                                .foregroundStyle(.green)
                            Text("-\(appState.agentWorktreeChanges.totalDeletedLines)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Button {
                        review()
                    } label: {
                        Text("审查")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help("查看当前未提交 diff")
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var visibleChanges: [AgentFileChangeSummary] {
        if showsAllFiles { return appState.agentWorktreeChanges.files }
        return Array(appState.agentWorktreeChanges.files.prefix(collapsedFileLimit))
    }

    private var hiddenFileCount: Int {
        max(0, appState.agentWorktreeChanges.fileCount - collapsedFileLimit)
    }

    private var summaryTitle: String {
        let verb = appState.isAgentResponding ? "正在编辑" : "已编辑"
        return "\(verb) \(appState.agentWorktreeChanges.fileCount) 个文件"
    }

    private func changedFileRow(_ change: AgentFileChangeSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: fileIconName(for: change))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Button {
                // 点击文件行:agent 模式下打开右侧 diff 面板(看改动),
                // 而不是把文件丢进 editor 窗口;编辑器停靠面板无 onReview
                // 时仍退回到在 editor 打开。用「打开方式」菜单显式开文件。
                if onReview != nil {
                    review()
                } else {
                    openInXeditWindow(change)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.path)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileMetaText(for: change))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(appState.agentChangedFileURL(change.path) == nil)
            .help(change.path)

            AgentLineStatsView(change: change)

            Menu {
                Button("在新窗口打开") {
                    openInXeditWindow(change)
                }
                .disabled(appState.agentChangedFileURL(change.path) == nil)

                Button("用默认应用打开") {
                    openInDefaultApp(change)
                }
                .disabled(appState.agentChangedFileURL(change.path) == nil)

                Button("在 Finder 中显示") {
                    revealInFinder(change)
                }
                .disabled(appState.agentChangedFileURL(change.path) == nil)
            } label: {
                HStack(spacing: 4) {
                    Text("打开方式")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func openInXeditWindow(_ change: AgentFileChangeSummary) {
        guard let url = appState.agentChangedFileURL(change.path) else { return }
        appState.registerRecentFile(url)
        openWindow(value: url)
    }

    private func openInDefaultApp(_ change: AgentFileChangeSummary) {
        guard let url = appState.agentChangedFileURL(change.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ change: AgentFileChangeSummary) {
        guard let url = appState.agentChangedFileURL(change.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func fileIconName(for change: AgentFileChangeSummary) -> String {
        switch change.kind {
        case .added, .untracked:
            return "doc.badge.plus"
        case .deleted:
            return "doc.badge.minus"
        case .renamed:
            return "arrow.triangle.2.circlepath"
        case .modified:
            return "doc.text"
        }
    }

    private func fileMetaText(for change: AgentFileChangeSummary) -> String {
        let ext = URL(fileURLWithPath: change.path).pathExtension
        let type = ext.isEmpty ? "文件" : "\(ext.uppercased()) 文件"
        return "\(type) · \(change.kind.rawValue)"
    }
}

struct AgentTurnFileActivityCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let calls: [AgentToolCall]
    var showsToolActivity = true
    var showsEditingActivity = true

    var body: some View {
        let summary = AgentToolActivitySummary(calls: calls)
        if (showsToolActivity && summary.hasActivity) || shouldShowEditingRow {
            VStack(alignment: .leading, spacing: 5) {
                if showsToolActivity, let explorationText = summary.explorationText {
                    activityRow(
                        icon: "doc.text.magnifyingglass",
                        text: explorationText,
                        trailing: nil
                    )
                }
                if showsToolActivity, let commandText = summary.commandText {
                    activityRow(
                        icon: "terminal",
                        text: commandText,
                        trailing: latestCommandPreview
                    )
                }
                if shouldShowEditingRow, let change = appState.primaryAgentChangedFile {
                    editingRow(change)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.045), lineWidth: 1)
            )
        }
    }

    private var shouldShowEditingRow: Bool {
        showsEditingActivity && appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty
    }

    private var latestCommandPreview: String? {
        calls.reversed().compactMap { call -> String? in
            guard call.toolName == "run_command",
                  let command = call.arguments["command"]?.stringValue() else {
                return nil
            }
            return trimmed(command, limit: 96)
        }.first
    }

    private func activityRow(icon: String, text: String, trailing: String?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let trailing {
                Text(trailing)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func editingRow(_ change: AgentFileChangeSummary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: appState.isAgentResponding ? "pencil.line" : "checkmark.square")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(appState.isAgentResponding ? "正在编辑" : "已编辑")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            changedFileButton(change)
            AgentLineStatsView(change: change)
            Spacer(minLength: 0)
        }
    }

    private func changedFileButton(_ change: AgentFileChangeSummary) -> some View {
        Button {
            guard let url = appState.agentChangedFileURL(change.path) else { return }
            appState.registerRecentFile(url)
            openWindow(value: url)
        } label: {
            Text(change.fileName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(change.path)
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "…"
    }
}

struct AgentWorktreeSummaryPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.showAgentWorktreeDiff()
        } label: {
            HStack(spacing: 6) {
                Text("\(appState.agentWorktreeChanges.fileCount) 个文件已更改")
                    .foregroundStyle(.secondary)
                Text("+\(appState.agentWorktreeChanges.totalAddedLines)")
                    .foregroundStyle(.green)
                Text("-\(appState.agentWorktreeChanges.totalDeletedLines)")
                    .foregroundStyle(.red)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("查看当前未提交 diff")
    }
}

struct AgentLineStatsView: View {
    let change: AgentFileChangeSummary

    var body: some View {
        HStack(spacing: 4) {
            if change.hasKnownLineStats {
                Text("+\(change.addedLines)")
                    .foregroundStyle(.green)
                Text("-\(change.deletedLines)")
                    .foregroundStyle(.red)
            } else {
                Text(change.kind.rawValue)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}
