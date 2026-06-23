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
        .padding(.horizontal, 12)
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
                        ForEach(visibleMessages) { message in
                            if shouldShowMessageBubble(message) {
                                AgentMessageBubble(message: message)
                                    .id(message.id)
                            }
                            let calls = toolCalls(for: message.id)
                            if !calls.isEmpty {
                                AgentToolCallGroup(calls: calls)
                                    .id(toolGroupScrollID(for: message.id))
                            }
                        }
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
                        } else if appState.isAgentResponding {
                            AgentBreathingIndicator()
                        }
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                    }

                    if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomScrollID)
                }
                .padding(10)
            }
            // Watch count, not the array — token-by-token streaming
            // mutates `messages[i].content`, and observing the whole
            // array fires `scrollTo` on every token. See the longer
            // comment in AgentChatTranscript.
            .onCompatibleChange(of: appState.agentMessages.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
            }
            .onCompatibleChange(of: appState.agentToolCalls.count) { _, _ in
                proxy.scrollTo(Self.bottomScrollID, anchor: .bottom)
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
            message.role != .tool && message.role != .system && !isEmptyThinkingPlaceholder(message)
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
    var body: some View {
        AgentInlineStatusDivider(text: "正在自动压缩上下文")
    }
}

struct AgentThinkingDivider: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // When we have a turn start timestamp, render a live ticker so the
            // user can see the seconds advance — proof that the request hasn't
            // silently hung. When we don't (e.g. legacy code paths that don't
            // stamp the start), fall back to the static label.
            if let startedAt = appState.agentTurnStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    AgentInlineStatusDivider(
                        text: "正在思考",
                        trailing: formatThinkingElapsed(
                            context.date.timeIntervalSince(startedAt)
                        )
                    )
                }
            } else {
                AgentInlineStatusDivider(text: "正在思考")
            }

            // 两行实时预览：reasoning 流到哪里就显示到哪里的尾部。
            // reservesSpace 把高度钉死在两行 —— 流式追加时整个
            // transcript 不会跟着抖。思考结束（首个正文 token 到达）
            // 整个 divider 连预览一起消失，由 shouldShow… 统一控制。
            if let reasoning = appState.agentLiveThinkingPreview {
                Text(AppState.agentThinkingPreviewTail(reasoning))
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.72))
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .accessibilityLabel("思考内容实时预览")
            }
        }
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

private struct AgentInlineStatusDivider: View {
    let text: String
    /// Optional trailing caption rendered next to the label — used by the
    /// thinking divider to show live elapsed seconds.
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.62)
                    .frame(width: 10, height: 10)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let trailing {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.55))
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .fixedSize()
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel(trailing.map { "\(text) · \($0)" } ?? text)
    }
}

struct AgentWorktreeChangeCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showsAllFiles = false
    private let collapsedFileLimit = 3

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
                    appState.showAgentWorktreeDiff()
                } label: {
                    Text("审查")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("查看当前未提交 diff")
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
                openInXeditWindow(change)
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
        appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty
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
