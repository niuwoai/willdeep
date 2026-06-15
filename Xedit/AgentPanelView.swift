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
                    AgentJobsDrawer(isOpen: $isJobsDrawerOpen)
                        .frame(width: 260)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: isJobsDrawerOpen ? 560 : 300)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The panel transcript is small enough to lay out eagerly,
                // and avoiding LazyVStack keeps scroll-time placement out
                // of SwiftUI's fragile lazy stack cache.
                VStack(alignment: .leading, spacing: 10) {
                    if appState.agentMessages.isEmpty {
                        AgentEmptyState()
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
        .onChange(of: appState.agentComposerFocusRevision) { _, _ in
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
        return "No workspace"
    }

    private var contextHint: String {
        if appState.rootDirectory == nil {
            return "Open a folder to enable tools"
        }
        if !appState.agentPendingTextAttachments.isEmpty {
            return L10n.AgentSelection.selectionAttachedHint
        }
        if appState.selectedCharacterCount > 0 {
            return "Selection included · Tools available"
        }
        return "Active file included · Tools available"
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

// MARK: - Background jobs drawer

/// Right-side companion panel listing background `run_command` jobs
/// for the active runtime. Lives only as long as the drawer is open
/// (parent `if isJobsDrawerOpen` gates it), so SwiftUI tears it down
/// when the user collapses the panel — no need to manually manage
/// observation lifecycles. Reads from
/// `appState.agentJobRegistry` (auto-republished through AppState).
struct AgentJobsDrawer: View {
    @EnvironmentObject var appState: AppState
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let runtimeID = appState.activeAgentSessionID {
                let jobs = appState.agentJobRegistry.jobs(forRuntime: runtimeID)
                if jobs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(jobs) { job in
                                AgentJobRow(job: job)
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text(L10n.AgentJobs.title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                isOpen = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(L10n.AgentJobs.collapseHelp)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "play.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentJobs.empty)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row per background job. Shows the short handle, status badge,
/// duration ticker (live for alive jobs), the command, and a kill /
/// view-output cluster. Expanded view tails the captured output.
struct AgentJobRow: View {
    @EnvironmentObject var appState: AppState
    let job: AgentBackgroundJob
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                statusDot
                Text(job.displayHandle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                durationText
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
                if job.isAlive {
                    Button {
                        _ = appState.agentJobRegistry.kill(id: job.id)
                    } label: {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.AgentJobs.kill)
                }
            }
            Text(job.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                statusLabel
                if let exit = job.exitCode {
                    Text("exit \(exit)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(exit == 0 ? .green : .red)
                }
                Text("pid \(job.pid)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if isExpanded {
                let output = appState.agentJobRegistry.output(id: job.id, tailLines: 200)
                ScrollView {
                    Text(output.isEmpty ? L10n.AgentJobs.noOutput : output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusDot: some View {
        switch job.status {
        case .running:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .completed:
            Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .killed, .timedOut, .launchFailed:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var durationText: some View {
        if job.isAlive {
            TimelineView(.periodic(from: job.startedAt, by: 1)) { ctx in
                Text(Self.formatDuration(ctx.date.timeIntervalSince(job.startedAt)))
                    .font(.system(size: 10).monospacedDigit())
            }
        } else {
            Text(Self.formatDuration(job.duration))
                .font(.system(size: 10).monospacedDigit())
        }
    }

    private var statusLabel: some View {
        Text(localizedStatus)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(statusBackground)
            .foregroundStyle(statusForeground)
            .clipShape(Capsule())
    }

    private var localizedStatus: String {
        switch job.status {
        case .running: return L10n.AgentJobs.statusRunning
        case .completed: return L10n.AgentJobs.statusCompleted
        case .failed: return L10n.AgentJobs.statusFailed
        case .killed: return L10n.AgentJobs.statusKilled
        case .timedOut: return L10n.AgentJobs.statusTimedOut
        case .launchFailed: return L10n.AgentJobs.statusLaunchFailed
        }
    }

    private var statusForeground: Color {
        switch job.status {
        case .running: return .green
        case .completed: return .secondary
        case .failed, .launchFailed: return .red
        case .killed, .timedOut: return .orange
        }
    }

    private var statusBackground: Color {
        statusForeground.opacity(0.14)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60, mm = m % 60
        return "\(h)h\(mm)m"
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

struct AgentToolCallGroup: View {
    let calls: [AgentToolCall]
    /// Optional codex-style headline ("已运行 3 条命令"). When set, it
    /// replaces the default "N tools" label and we also swap the icon
    /// to match the kind.
    var headline: String? = nil
    var headlineIcon: String? = nil
    @State private var isExpanded = false

    var body: some View {
        let status = statusSummary
        VStack(alignment: .leading, spacing: detailsVisible ? 8 : 0) {
            Button {
                if canToggleDetails {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: groupIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(groupIconColor)
                        .frame(width: 14)
                    Text(titleText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let previewSummary {
                        Text(previewSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Image(systemName: detailsVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(canToggleDetails ? .secondary : Color.clear)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggleDetails)
            .help(detailsVisible ? L10n.ToolCard.collapse : L10n.ToolCard.expand)

            if detailsVisible {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { call in
                        AgentToolCallCard(call: call)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, detailsVisible ? 8 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(groupBorderColor, lineWidth: 1)
        )
        // The expanded card paints padding above its title row. Give that
        // expanded chrome its own external breathing room so it never
        // visually climbs into the previous assistant bubble.
        .padding(.top, detailsVisible ? 8 : 0)
    }

    private var detailsVisible: Bool {
        // Interactive states (ask_user / pendingApproval / awaitingConfirm)
        // need the user's attention NOW — if the group stayed collapsed
        // the user would have to first hunt down the activity summary
        // header and click it to even see the question / approval prompt.
        // Force-expand whenever any inner call is interactive; respect
        // `isExpanded` otherwise so non-interactive bundles stay tidy.
        isExpanded || containsInteractiveCall
    }

    private var canToggleDetails: Bool {
        // While the group has an interactive call we lock it open. The
        // user can still collapse historic groups (no waiting calls)
        // freely.
        !calls.isEmpty && !containsInteractiveCall
    }

    private var containsInteractiveCall: Bool {
        calls.contains { call in
            switch call.status {
            case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
                return true
            case .running, .succeeded, .failed, .denied:
                return false
            }
        }
    }

    private var titleText: String {
        if let headline, !headline.isEmpty { return headline }
        if let activityText = AgentToolActivitySummary(calls: calls).activityText {
            return activityText
        }
        if calls.count == 1, let first = calls.first {
            return "已调用 \(first.toolName)"
        }
        return "已调用 \(calls.count) 个工具"
    }

    private var statusSummary: String {
        let waiting = calls.filter {
            $0.status == .pendingApproval || $0.status == .awaitingConfirm || $0.status == .awaitingUserAnswer
        }.count
        let running = calls.filter { $0.status == .running }.count
        let failed = calls.filter { $0.status == .failed }.count
        let denied = calls.filter { $0.status == .denied }.count
        let succeeded = calls.filter { $0.status == .succeeded }.count
        var parts: [String] = []
        if succeeded == calls.count, waiting == 0, running == 0, failed == 0, denied == 0 {
            return ""
        }
        if waiting > 0 { parts.append("\(waiting) 待处理") }
        if running > 0 { parts.append("\(running) 运行中") }
        if failed > 0 { parts.append("\(failed) 失败") }
        if denied > 0 { parts.append("\(denied) 已拒绝") }
        if succeeded > 0 { parts.append("\(succeeded) 完成") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String? {
        guard detailsVisible else { return nil }
        let previews = calls.prefix(3).map { call in
            var text = call.toolName
            if let summary = call.result?.summary, !summary.isEmpty {
                text += " \(summary)"
            } else if let compactArguments = compactArguments(for: call), !compactArguments.isEmpty {
                text += " \(compactArguments)"
            }
            return text
        }
        let suffix = calls.count > previews.count ? " · +\(calls.count - previews.count) more" : ""
        let summary = previews.joined(separator: " · ") + suffix
        return summary.isEmpty ? nil : summary
    }

    private func compactArguments(for call: AgentToolCall) -> String? {
        if call.toolName == "run_command", let command = call.arguments["command"]?.stringValue() {
            let cwd = call.arguments["cwd"]?.stringValue().map { "  cwd: \(trimmed($0, limit: 72))" } ?? ""
            return "command: \(trimmed(command, limit: 140))\(cwd)"
        }
        if call.toolName == "spawn_agent" {
            let label = call.arguments["label"]?.stringValue()
                ?? call.arguments["prompt"]?.stringValue()
                ?? ""
            return label.isEmpty ? nil : "task: \(trimmed(label, limit: 120))"
        }
        if ["claude_code", "codex_cli", "cursor_agent"].contains(call.toolName) {
            let prompt = call.arguments["prompt"]?.stringValue() ?? ""
            let mode = call.arguments["permission_mode"]?.stringValue().map { "  mode: \($0)" } ?? ""
            return prompt.isEmpty ? nil : "task: \(trimmed(prompt, limit: 120))\(mode)"
        }
        if let path = call.arguments["path"]?.stringValue() {
            return "path: \(trimmed(path, limit: 120))"
        }
        if let pattern = call.arguments["pattern"]?.stringValue() {
            return "pattern: \(trimmed(pattern, limit: 120))"
        }
        if let query = call.arguments["query"]?.stringValue() {
            return "query: \(trimmed(query, limit: 120))"
        }
        return nil
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "…"
    }

    private var groupIconName: String {
        // Status-derived icons (failed / running / asking) take precedence
        // so the user can see a problem at a glance, even when the row is
        // collapsed. A static headline icon is only the calm-state default.
        if calls.contains(where: { $0.status == .failed }) { return "exclamationmark.triangle.fill" }
        if calls.contains(where: { $0.status == .running }) { return "hourglass" }
        if containsInteractiveCall { return "questionmark.circle" }
        if let headlineIcon, !headlineIcon.isEmpty { return headlineIcon }
        return "checkmark.circle.fill"
    }

    private var groupIconColor: Color {
        if calls.contains(where: { $0.status == .failed }) { return .orange }
        if calls.contains(where: { $0.status == .running }) { return .secondary }
        if containsInteractiveCall { return .blue }
        return .secondary
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return Color.blue.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed }) { return Color.orange.opacity(0.28) }
        return Color.primary.opacity(0.04)
    }
}

struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    @State private var isExpanded = false
    @State private var answerInput = ""
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: isInteractive ? 6 : 3) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(call.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(argumentsSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let label = approvalSourceLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                        .help(approvalSourceTooltip ?? "")
                }
                if hasExpandableContent {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
                }
            }
            .frame(minHeight: 20)
            .help("\(riskBadge): \(argumentsSummary)")

            if isExpanded {
                if !argumentsLines.isEmpty {
                    expandableBlock(title: L10n.ToolCard.arguments, text: argumentsLines)
                }
                if let payload = call.result?.payload, !payload.isEmpty {
                    expandableBlock(title: L10n.ToolCard.output, text: payload)
                }
                if let errorMessage = call.errorMessage, !errorMessage.isEmpty {
                    expandableBlock(title: L10n.ToolCard.error, text: errorMessage)
                }
            }

            if call.status == .pendingApproval {
                VStack(alignment: .leading, spacing: 6) {
                    approvalCommandBlock
                    HStack {
                        Spacer(minLength: 0)
                        Button(L10n.ToolCard.allow) { appState.approveAgentToolCall(id: call.id) }
                        if let signature = alwaysAllowSignature {
                            Button(L10n.ToolCard.alwaysAllow) { appState.alwaysAllowAgentToolCall(id: call.id) }
                                .help(L10n.ToolCard.alwaysAllowHelp(signature))
                        }
                        Button(L10n.ToolCard.deny) { appState.denyAgentToolCall(id: call.id) }
                    }
                    .font(.caption)
                }
            } else if call.status == .awaitingConfirm {
                VStack(alignment: .leading, spacing: 6) {
                    approvalCommandBlock
                    Text(L10n.ToolCard.destructiveWarning)
                        .font(.caption2)
                        .foregroundStyle(destructiveAccentColor)
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: "confirm")
                        } label: {
                            Text(L10n.ToolCard.confirmRun)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(destructiveAccentColor)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(destructiveAccentColor.opacity(0.62), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        Button(L10n.ToolCard.deny) {
                            appState.denyAgentToolCall(id: call.id)
                        }
                    }
                    .font(.caption)
                }
            } else if call.status == .awaitingUserAnswer {
                askUserBody
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, isInteractive ? 7 : 4)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var approvalCommandBlock: some View {
        if let command = fullCommand {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.ToolCard.command)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private var askUserBody: some View {
        let question = call.arguments["question"]?.stringValue() ?? ""
        // rc3: option labels are LLM-authored. Defang first so the button
        // the user clicks shows the same string the model gets back as the
        // user's answer — and so options can't smuggle control characters
        // or `<system>` framing through the chat UI.
        let rawOptions = call.arguments["options"]?.stringArrayValue() ?? []
        let options = AgentInjectionDefense.sanitizeAskUserOptions(rawOptions)
        let isMultiSelect = call.arguments["multi_select"]?.boolValue() ?? false

        VStack(alignment: .leading, spacing: 8) {
            if !question.isEmpty {
                Text(question)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !options.isEmpty {
                if isMultiSelect {
                    multiSelectChoices(options)
                } else {
                    singleSelectChoices(options)
                }
            }

            // Free-form text input is always available — even with preset
            // options, the user may want to write "none of these".
            TextField(options.isEmpty ? "Your answer" : "Other answer (optional)",
                      text: $answerInput,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...4)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Send") {
                    submitAnswer(options: options, isMultiSelect: isMultiSelect)
                }
                .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
                Button("Skip") {
                    appState.denyAgentToolCall(id: call.id)
                    resetAskUserInputs()
                }
            }
            .font(.caption)
        }
    }

    private func singleSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    appState.answerAgentToolCall(id: call.id, answer: option)
                    resetAskUserInputs()
                } label: {
                    HStack(spacing: 8) {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.purple.opacity(0.65))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
                    .background(Color.purple.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.purple.opacity(0.28), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func multiSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedOptions.contains(option) },
                    set: { isOn in
                        if isOn { selectedOptions.insert(option) }
                        else { selectedOptions.remove(option) }
                    }
                )) {
                    Text(option)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedOptions.contains(option) ? Color.purple.opacity(0.10) : Color(nsColor: .textBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selectedOptions.contains(option) ? Color.purple.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private func canSubmitAskUser(isMultiSelect: Bool) -> Bool {
        if !answerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if isMultiSelect { return !selectedOptions.isEmpty }
        return false
    }

    private func submitAnswer(options: [String], isMultiSelect: Bool) {
        // Free-form text wins if the user typed anything — gives them an
        // escape hatch from the preset options.
        let typed = answerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if !typed.isEmpty {
            answer = typed
        } else if isMultiSelect {
            // Preserve the order the model offered them so the
            // assistant can correlate.
            answer = options.filter { selectedOptions.contains($0) }.joined(separator: ", ")
        } else {
            return
        }
        appState.answerAgentToolCall(id: call.id, answer: answer)
        resetAskUserInputs()
    }

    private func resetAskUserInputs() {
        answerInput = ""
        selectedOptions = []
    }

    private func expandableBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var argumentsSummary: String {
        guard !call.arguments.isEmpty else { return "(no arguments)" }
        return call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displaySummary)" }
            .joined(separator: " · ")
    }

    private var argumentsLines: String {
        call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displaySummary)" }
            .joined(separator: "\n")
    }

    private var fullCommand: String? {
        guard call.toolName == "run_command",
              let command = call.arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    private var alwaysAllowSignature: String? {
        AgentToolAuthorization.signature(for: call)
    }

    private var iconName: String {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return "questionmark.circle"
        case .awaitingUserAnswer: return "bubble.left.and.text.bubble.right"
        case .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch call.status {
        case .pendingApproval: return .blue
        case .awaitingConfirm: return destructiveAccentColor
        case .awaitingUserAnswer: return .purple
        case .running: return .secondary
        case .succeeded: return .secondary
        case .failed: return .orange
        case .denied: return .secondary
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pendingApproval: return .blue
        case .awaitingConfirm: return destructiveAccentColor
        case .awaitingUserAnswer: return .purple
        case .failed: return .orange
        case .running, .succeeded, .denied: return .secondary
        }
    }

    private var isInteractive: Bool {
        switch call.status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return isExpanded
        }
    }

    private var hasExpandableContent: Bool {
        !argumentsLines.isEmpty
        || !(call.result?.payload.isEmpty ?? true)
        || !(call.errorMessage?.isEmpty ?? true)
    }

    /// Show a small badge next to the status text when a write-tier
    /// tool call ran without the user clicking Allow, so it's auditable
    /// after the fact.
    private var approvalSourceLabel: String? {
        guard call.risk == .write,
              call.status == .running || call.status == .succeeded || call.status == .failed,
              let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil // explicit user clicks don't need a badge
        case .alwaysAllowList: return "ALWAYS"
        case .staticAllowlist: return "AUTO"
        case .llmJudge: return "AI OK"
        case .goalMode: return "GOAL"
        case .workspaceAccess: return "WORKSPACE"
        case .escalated: return "ESCALATED"
        case .trustedServer: return "TRUSTED"
        }
    }

    private var approvalSourceTooltip: String? {
        guard let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil
        case .alwaysAllowList: return "You pinned this command signature as always-allowed."
        case .staticAllowlist: return "Matched the built-in read-only allowlist (safe shell commands / read-style MCP tools)."
        case .llmJudge: return "An LLM judge classified this call as read-only / safe."
        case .goalMode: return "Auto-approved because this session is in Goal mode. Danger-tier commands still ask."
        case .workspaceAccess: return "Auto-approved by this session's Workspace Access approval mode. Danger-tier commands still ask."
        case .escalated: return "You approved this call to run outside the default sandbox boundary."
        case .trustedServer: return "You marked this MCP server as fully trusted — all its calls auto-run."
        }
    }

    private var cardBackground: Color {
        if isInteractive {
            return Color(nsColor: .controlBackgroundColor).opacity(0.72)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.38)
    }

    private var statusText: String {
        switch call.status {
        case .pendingApproval: return L10n.ToolCard.statusAwaitingApproval
        case .awaitingConfirm: return L10n.ToolCard.statusConfirmRequired
        case .awaitingUserAnswer: return L10n.ToolCard.statusAskingYou
        case .running: return L10n.ToolCard.statusRunning
        case .succeeded:
            if let summary = call.result?.summary, !summary.isEmpty {
                return summary
            }
            return L10n.ToolCard.statusDone
        case .failed: return L10n.ToolCard.statusFailed
        case .denied: return L10n.ToolCard.statusDenied
        }
    }

    private var riskBadge: String {
        switch call.risk {
        case .read: return "READ"
        case .write: return "WRITE"
        case .danger: return "DANGER"
        case .userInput: return "ASK"
        }
    }

    private var riskBadgeColor: Color {
        switch call.risk {
        case .read: return .secondary
        case .write: return .blue
        case .danger: return .orange
        case .userInput: return .purple
        }
    }

    private var borderColor: Color {
        switch call.status {
        case .pendingApproval: return Color.blue.opacity(0.4)
        case .awaitingConfirm: return destructiveAccentColor.opacity(0.42)
        case .awaitingUserAnswer: return Color.purple.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }

    private var destructiveAccentColor: Color {
        Color(red: 0.68, green: 0.16, blue: 0.16)
    }
}

struct AgentErrorCard: View {
    @EnvironmentObject var appState: AppState
    let message: String
    let details: AgentErrorDetails?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if appState.canRetryLastAgentTurn {
                    Button {
                        appState.retryLastAgentTurn()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("重新发送上一条消息")
                }
                if details != nil {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(isExpanded ? "收起详情" : "详情",
                              systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(isExpanded ? "隐藏详细错误信息" : "查看详细错误信息")
                }
                Button {
                    appState.dismissAgentError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            if isExpanded, let details {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // Vertical-only scrolling on purpose: with a
                            // horizontal axis the Text gets an unbounded
                            // width proposal, and a single 8 KB JSON line
                            // (tool results stay one-line in pretty print)
                            // blows the renderer's texture limit — the
                            // whole section then draws blank. Wrapping
                            // keeps it readable and renderable.
                            ScrollView(.vertical) {
                                Text(section.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: section.title == "Request Body" ? 180 : 120)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }
}

struct AgentPatchProposalCard: View {
    @EnvironmentObject var appState: AppState
    let proposal: AgentPatchProposal
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide Diff" : "Show Diff")
            }

            if isExpanded {
                ScrollView(.horizontal) {
                    Text(proposal.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    appState.applyAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .disabled(proposal.status != .pending)

                Button {
                    appState.rejectAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .disabled(proposal.status != .pending)

                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var iconName: String {
        switch proposal.status {
        case .pending:
            return "doc.text.magnifyingglass"
        case .applied:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch proposal.status {
        case .pending:
            return .secondary
        case .applied:
            return .green
        case .rejected:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private var statusText: String {
        proposal.statusMessage ?? proposal.status.rawValue.capitalized
    }
}

private struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask about this project")
                .font(.system(size: 14, weight: .semibold))
            Text("The agent can read files, search, list directories, run commands (with approval), and check Git status.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
    }
}

struct AgentMessageBubble: View {
    let message: AgentMessage

    @State private var didJustCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !message.textAttachments.isEmpty {
                AgentTextAttachmentBubbleStrip(attachments: message.textAttachments)
            }
            if !displayContent.isEmpty {
                Text(displayContent)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if shouldShowFooter {
                footer
            }
        }
        .padding(9)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var shouldShowFooter: Bool {
        // System / tool rows are pure plumbing — no copy button needed
        // there. For user/assistant rows we always show at least the
        // copy button (timing + tokens are assistant-only).
        switch message.role {
        case .system, .tool: return false
        case .user, .assistant:
            return !message.content.isEmpty || !message.textAttachments.isEmpty
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: copyToClipboard) {
                Image(systemName: didJustCopy ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(didJustCopy ? "Copied" : "Copy message")

            if message.role == .assistant, let elapsed = message.elapsedSeconds, elapsed > 0 {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant, let summary = tokenSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var tokenSummary: String? {
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            return "\(formatTokens(prompt))→\(formatTokens(completion))"
        }
        if let total = message.usageTokens, total > 0 {
            return "\(formatTokens(total))t"
        }
        return nil
    }

    private func formatElapsed(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000.0) : String(count)
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(message.copyableContent, forType: .string)
        didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
        }
    }

    private var displayContent: String {
        if message.content.isEmpty {
            if !message.toolCalls.isEmpty {
                return "Using tools…"
            }
            if !message.images.isEmpty {
                return ""
            }
            if !message.textAttachments.isEmpty {
                return ""
            }
            return "…"
        }
        return message.content
    }

    private var title: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .system:
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        case .user:
            return Color.accentColor.opacity(0.12)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        case .tool:
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
        }
    }
}
