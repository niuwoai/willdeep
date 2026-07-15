//
//  AgentModeComposerView.swift
//  WillDeep
//
//  Composer, status bar, slash/@/$ pickers, and compact session badges
//  used by the dedicated Agent mode surface. Split from AgentModeView
//  to keep the top-level view file reviewable.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Composer

struct AgentChatComposer: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    /// Per-plan banner 显示状态。用 plan summary 做"指纹"识别"是不
    /// 是同一个 plan"，避免用户拒绝后下一次 body 重算又把 banner 弹
    /// 回来。一旦用户拒绝、开始打字、或确认完成 → dismissedPlanFingerprint
    /// 记下这个 plan 的指纹，本 plan 不再弹。下一个新 plan 来时
    /// 指纹不同会重置。
    @State private var dismissedPlanFingerprint: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if !appState.agentWorktreeChanges.isEmpty {
                    AgentComposerWorktreeSummaryBar()
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                }

                if appState.shouldShowComposerGoalCard, let goal = appState.agentCurrentGoal {
                    AgentComposerGoalCard(goal: goal)
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                }

                if shouldShowActivityStatus {
                    AgentSemanticActivityStatusLine(style: .composer)
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                }

                if let suggestion = planModeSuggestion() {
                    AgentPlanModeSuggestionBanner(
                        onEnterPlan: {
                            appState.resolveAgentPlanModeSuggestion(enterPlanMode: true)
                        },
                        onContinueNormally: {
                            appState.resolveAgentPlanModeSuggestion(enterPlanMode: false)
                        }
                    )
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    .id(suggestion.id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let plan = bannerPlan() {
                    AgentPlanAutoExecutionBanner(
                        plan: plan,
                        workspacePath: appState.rootDirectory?.path,
                        onConfirm: {
                            dismissedPlanFingerprint = planFingerprint(plan)
                            appState.confirmAgentPlanAndExecute()
                        },
                        onReject: {
                            dismissedPlanFingerprint = planFingerprint(plan)
                        },
                        onRememberChange: { _ in }
                    )
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    .id(planFingerprint(plan))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                ComposerCard(onUserEdit: { oldValue, newValue in
                    if appState.agentPendingPlanModeSuggestion != nil,
                       newValue != oldValue {
                        appState.cancelAgentPlanModeSuggestion()
                    }
                    // 用户在 composer 继续打字（输入框字数变多）→ 视作"我有
                    // 补充，留在 Plan 模式"，立刻 dismiss banner。**只在 banner
                    // 还显示时记 fingerprint**，否则任何普通输入都会无意义地写
                    // state。rc482 起从 `onChange(of: appState.agentInput)` 改走
                    // 这个回调（打字不再重渲染 appState）。
                    guard let plan = currentProposedPlanIfBannerVisible() else { return }
                    if newValue.count > oldValue.count {
                        dismissedPlanFingerprint = planFingerprint(plan)
                    }
                })
                .frame(maxWidth: AgentDesign.chatMaxContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AgentDesign.chatHorizontalInset)
            .padding(.vertical, 14)
        }
        .onAppear {
            appState.refreshActiveAgentWorktreeChanges()
        }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            appState.refreshActiveAgentWorktreeChanges()
            // 切 session 后重置 banner 状态：新 session 的 plan 该弹照弹。
            dismissedPlanFingerprint = nil
        }
        .onCompatibleChange(of: appState.agentCurrentPlan?.status) { _, newStatus in
            // 新 plan 刚解析出来变成 .proposed —— 如果用户之前在本
            // workspace 勾过「记住」，跳过 banner 直接 confirm。
            guard newStatus == .proposed,
                  appState.agentInteractionMode == .plan,
                  AgentSettingsStore.loadPlanAutoExecuteSilently(
                    workspacePath: appState.rootDirectory?.path
                  ) else { return }
            appState.confirmAgentPlanAndExecute()
        }
        .sheet(item: $appState.agentWorktreeDiffPreview) { preview in
            AgentWorktreeDiffPreviewSheet(preview: preview)
        }
    }

    private func bannerPlan() -> AgentPlan? {
        guard appState.agentInteractionMode == .plan,
              let plan = appState.agentCurrentPlan,
              plan.status == .proposed else {
            return nil
        }
        if dismissedPlanFingerprint == planFingerprint(plan) {
            return nil
        }
        return plan
    }

    private func planModeSuggestion() -> AgentPlanModeSuggestion? {
        guard appState.agentInteractionMode == .normal else { return nil }
        return appState.agentPendingPlanModeSuggestion
    }

    private func currentProposedPlanIfBannerVisible() -> AgentPlan? {
        guard let plan = appState.agentCurrentPlan,
              plan.status == .proposed,
              appState.agentInteractionMode == .plan,
              dismissedPlanFingerprint != planFingerprint(plan) else {
            return nil
        }
        return plan
    }

    private var shouldShowActivityStatus: Bool {
        appState.isAgentResponding
            || appState.isCompressingAgentContext
            || appState.agentRunningTaskCount > 0
            || appState.agentToolCalls.contains { call in
                call.status == .pendingApproval
                    || call.status == .awaitingConfirm
                    || call.status == .awaitingUserAnswer
            }
    }

    private func planFingerprint(_ plan: AgentPlan) -> String {
        // summary + 每步 text 的拼接哈希就够区分两个不同 plan；
        // agent 重新规划时 summary 或步骤会变。
        let body = plan.summary + "\u{1F}" + plan.steps.map(\.text).joined(separator: "\u{1F}")
        var hash: UInt64 = 5381
        for byte in body.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

private struct AgentComposerWorktreeSummaryBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.AgentWorktreeSummary.filesChanged(appState.agentWorktreeChanges.fileCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("+\(appState.agentWorktreeChanges.totalAddedLines)")
                .foregroundStyle(.green)
            Text("-\(appState.agentWorktreeChanges.totalDeletedLines)")
                .foregroundStyle(.red)

            Spacer(minLength: 8)

            Button {
                appState.showAgentWorktreeDiff()
            } label: {
                Text(L10n.AgentWorktreeSummary.review)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.primary)
            .help(L10n.AgentWorktreeSummary.reviewHelp)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    appState.isAgentWorktreeChangeCardExpanded.toggle()
                }
            } label: {
                Image(systemName: appState.isAgentWorktreeChangeCardExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help(appState.isAgentWorktreeChangeCardExpanded ? "收起已变更文件列表" : "展开已变更文件列表")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

private struct AgentComposerGoalCard: View {
    let goal: AgentGoal
    @EnvironmentObject var appState: AppState
    @State private var showingEditor = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(statusPrefix)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(summaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let startedAt = appState.agentTurnStartedAt, appState.isAgentResponding {
                    Text("· \(Self.formatElapsed(context.date.timeIntervalSince(startedAt)))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if !goal.checklist.isEmpty {
                    Text(progressText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Button {
                    showingEditor = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
                .help(L10n.GoalCard.editButtonHelp)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.26), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .onTapGesture {
                showingEditor = true
            }
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

    private var summaryText: String {
        let statement = goal.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !statement.isEmpty { return statement }
        return goal.checklist.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.GoalStatusBar.untitled
    }

    private var helpText: String {
        guard !goal.checklist.isEmpty else { return summaryText }
        let done = goal.checklist.filter(\.done).count
        return L10n.GoalStatusBar.progressHelp("\(done)", "\(goal.checklist.count)")
    }

    private var progressText: String {
        let done = goal.checklist.filter(\.done).count
        return "\(done)/\(goal.checklist.count)"
    }

    private var accessibilityLabel: String {
        "\(statusPrefix) \(summaryText)"
    }

    private var statusPrefix: String {
        appState.isAgentResponding ? L10n.GoalStatusBar.runningPrefix : L10n.GoalStatusBar.pinnedPrefix
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remaining = total % 60
        if minutes < 60 { return "\(minutes)m \(remaining)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

struct AgentWorktreeDiffPreviewSheet: View {
    let preview: AgentWorktreeDiffPreview
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .focusable(false)

                Spacer(minLength: 0)

                Button {
                    copyDiff()
                } label: {
                    Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "square.on.square")
                }
                .buttonStyle(.borderless)
                .focusable(false)

                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .focusable(false)
            }
            .padding(14)
            .focusable(false)

            Divider()
                .focusable(false)

            ScrollView([.vertical, .horizontal]) {
                Text(coloredDiff)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .focusable(false)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .focusable(false)
        }
        .frame(minWidth: 760, minHeight: 520)
        .focusable(false)
    }

    /// 给 diff 文本按行上色:新增行绿、删除行红、hunk 头青、文件头次要
    /// 色,其余正文用主色。用 AttributedString 整块上色,保持仍是单个
    /// 可选中 / 可复制的 Text(逐行 Text 会破坏跨行选择)。
    private var coloredDiff: AttributedString {
        var result = AttributedString()
        let lines = preview.diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.foregroundColor = diffLineColor(line)
            result += piece
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private func diffLineColor(_ line: String) -> Color {
        // 顺序要紧:文件头 `+++/---` 必须先于单字符 `+/-` 判断,否则会被
        // 误当成新增 / 删除行。
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("@@") { return .cyan }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.diff, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            didCopy = false
        }
    }
}

private struct ComposerCard: View {
    /// Called on every composer edit with (oldText, newText). rc482: typing
    /// no longer repaints `appState`, so the plan-banner "dismiss when the
    /// user keeps typing" rule — which used to ride `onChange(of:
    /// appState.agentInput)` up in `AgentChatComposer` — is driven through
    /// this callback instead.
    let onUserEdit: (_ oldText: String, _ newText: String) -> Void

    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool
    @State private var slashMenuVisible: Bool = false
    @State private var slashMenuSelection: Int = 0
    /// Live buffer mirror that drives the slash palette's filtering. Pushed
    /// by the text view's coordinator (`onSlashQueryChange`) because typing
    /// no longer re-evaluates this view through `appState` (rc482).
    @State private var slashMenuQuery: String = ""
    @State private var atMenuVisible: Bool = false
    @State private var atMenuSelection: Int = 0
    @State private var atMenuQuery: String = ""
    @State private var skillMenuVisible: Bool = false
    @State private var skillMenuSelection: Int = 0
    @State private var skillMenuQuery: String = ""
    /// Cached skill list — re-fetched whenever the $ popover opens so we
    /// pick up newly installed skills without recomputing on every
    /// keystroke.
    @State private var skillCatalog: [AgentSkillEntry] = []
    /// Strong ref to the coordinator so the @-token replacement helper
    /// can call back into it from SwiftUI callbacks.
    @State private var coordinatorRef = ComposerCoordinatorRef()
    @State private var isSecretSheetPresented = false
    @State private var isConsultationSheetPresented = false
    /// A terminal recording may deliberately omit echo-off values so the
    /// agent can never see them. When that happens, surface a focused secure
    /// prompt instead of making the user hunt for the completed tool card.
    @State private var pendingTerminalProtectedInput: TerminalShortcutProtectedPromptSet?
    @State private var lastAutoPresentedTerminalShortcutID: UUID?

    private var filteredSlashCommands: [SlashCommand] {
        SlashCommand.filter(
            slashMenuQuery,
            allCommands: SlashCommand.builtIn(state: appState)
        )
    }

    /// Unified entries for the `@` picker — workspace shortcut + project
    /// files (from the already-cached Quick Open list, which honors the
    /// project file cache). `$` owns skills.
    private var filteredAtEntries: [AtPickerEntry] {
        let q = atMenuQuery.lowercased()
        var entries: [AtPickerEntry] = []

        // Workspace shortcut — only shows when a folder is open, and
        // either the query is empty or matches "workspace".
        if appState.activeRuntime?.workspaceLocation?.localPath != nil,
           q.isEmpty || "workspace".contains(q) {
            entries.append(.workspace)
        }

        // Project files — limit to 30 matches so the popover stays
        // navigable. Match by last path component first, then full
        // relative path. Files already attached are filtered out so
        // the user can't double-add.
        let alreadyAttached = Set(appState.agentPendingFiles.map(\.url.standardizedFileURL.path))
        if let root = appState.activeRuntime?.workspaceLocation?.localPath {
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

    /// `$` picker entries are only skills / reusable capability packs.
    private var filteredSkillEntries: [SkillPickerEntry] {
        let q = skillMenuQuery.lowercased()
        // Match against the full multilingual searchable text (identifier +
        // every language's name/description/aliases) so e.g. "日报" or
        // "浏览器" recalls the English-authored daily-report / browser
        // skills, and English keywords still work for zh users.
        let skills = q.isEmpty ? skillCatalog : skillCatalog.filter {
            AgentSkillLocalization.searchableText(for: $0).contains(q)
        }
        return skills.map { .skill($0) }
    }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        let pendingFileIDs = Set(appState.agentPendingFiles.map(\.id))
        let retainedSessionDocuments = appState.agentSessionDocuments.filter { !pendingFileIDs.contains($0.id) }
        let hasDocumentContext = !appState.agentPendingFiles.isEmpty
            || !appState.agentSessionDocuments.isEmpty
            || !appState.agentKnowledgeFolders.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if !appState.agentPendingImages.isEmpty {
                AgentComposerImageStrip(images: appState.agentPendingImages) { id in
                    appState.removeAgentImage(id: id)
                }
            }

            if !appState.agentPendingTextAttachments.isEmpty {
                AgentComposerTextAttachmentStrip(attachments: appState.agentPendingTextAttachments) { id in
                    appState.removeAgentTextAttachment(id: id)
                }
            }

            if !appState.agentPendingSkills.isEmpty {
                AgentComposerSkillStrip(skills: appState.agentPendingSkills) { identifier in
                    appState.detachAgentSkill(identifier: identifier)
                }
            }

            if hasDocumentContext {
                AgentDocumentContextControls(
                    mode: appState.agentDocumentTaskMode,
                    redactsSensitiveContent: appState.agentRedactsSensitiveAttachmentContent,
                    makePreview: appState.agentDocumentSendPreview,
                    onSetMode: appState.setAgentDocumentTaskMode,
                    onSetRedaction: appState.setAgentSensitiveAttachmentRedaction
                )
            }

            if !retainedSessionDocuments.isEmpty {
                AgentSessionDocumentLibraryStrip(
                    files: retainedSessionDocuments,
                    onToggleEnabled: { appState.toggleAgentSessionDocumentEnabled(id: $0) },
                    onRemove: { appState.removeAgentSessionDocument(id: $0) },
                    onToggleSection: { fileID, sectionID in
                        appState.toggleAgentSessionDocumentSection(fileID: fileID, sectionID: sectionID)
                    },
                    onSetAllSections: { fileID, included in
                        appState.setAllAgentSessionDocumentSections(fileID: fileID, included: included)
                    }
                )
            }

            if !appState.agentKnowledgeFolders.isEmpty {
                AgentKnowledgeFolderStrip(
                    folders: appState.agentKnowledgeFolders,
                    onToggleEnabled: { appState.toggleAgentKnowledgeFolderEnabled(id: $0) },
                    onRemove: { appState.removeAgentKnowledgeFolder(id: $0) },
                    onUpdateExclusions: { folderID, patterns in
                        appState.updateAgentKnowledgeFolderExclusions(id: folderID, rawPatterns: patterns)
                    }
                )
            }

            if !appState.agentPendingFiles.isEmpty || appState.agentPendingIncludeWorkspaceOverview {
                AgentComposerAttachmentStrip(
                    includeWorkspace: appState.agentPendingIncludeWorkspaceOverview,
                    files: appState.agentPendingFiles,
                    onRemoveWorkspace: { appState.toggleAgentWorkspaceOverview() },
                    onRemoveFile: { appState.detachAgentFile(id: $0) },
                    onToggleFileSection: { fileID, sectionID in
                        appState.toggleAgentFileSection(fileID: fileID, sectionID: sectionID)
                    },
                    onSetAllFileSections: { fileID, included in
                        appState.setAllAgentFileSections(fileID: fileID, included: included)
                    }
                )
            }

            if atMenuVisible {
                AtPickerMenu(
                    entries: filteredAtEntries,
                    query: $atMenuQuery,
                    selection: $atMenuSelection,
                    onPick: { index in
                        atMenuSelection = index
                        _ = commitSelectedAtEntry()
                    },
                    onClose: { closeAtMenu() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(20)
            }

            if skillMenuVisible {
                SkillPickerMenu(
                    entries: filteredSkillEntries,
                    query: $skillMenuQuery,
                    selection: $skillMenuSelection,
                    onPick: { index in
                        skillMenuSelection = index
                        _ = commitSelectedSkillEntry()
                    },
                    onClose: { closeSkillMenu() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(21)
            }

            ZStack(alignment: .topLeading) {
                ComposerTextEditor(
                    text: Binding(
                        get: { appState.agentInput },
                        set: { newValue in
                            let oldValue = appState.agentInput
                            // rc482: a keystroke must NOT repaint the composer
                            // pill row. Setting `agentInput` writes the active
                            // runtime's `@Published input`, whose change is
                            // normally forwarded into `appState.objectWillChange`
                            // (repainting every pill, ×3 via ViewThatFits). We
                            // gate just this write so the buffer still updates
                            // for send / external readers, but the pills stay put.
                            //
                            // EXCEPT when the buffer crosses empty↔non-empty:
                            // `SendStopButton.canSend` keys off emptiness, so
                            // that one transition (≈twice per message) must get
                            // through to flip the button enabled/disabled. Mid-
                            // word keystrokes stay suppressed.
                            let wasEmpty = oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let nowEmpty = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            appState.suppressActiveRuntimeForward = (wasEmpty == nowEmpty)
                            defer { appState.suppressActiveRuntimeForward = false }
                            appState.agentInput = newValue
                            onUserEdit(oldValue, newValue)
                        }
                    ),
                    placeholder: L10n.Composer.inputPlaceholder,
                    onSubmit: { submitComposer() },
                    onPasteImage: handlePastedImage,
                    onPasteText: handlePastedText,
                    historyProvider: { appState.agentMessages
                        .filter { $0.role == .user }
                        .map(\.content)
                        .filter { !$0.isEmpty }
                    },
                    slashMenuVisible: $slashMenuVisible,
                    slashMenuSelection: $slashMenuSelection,
                    slashMenuItemCount: { filteredSlashCommands.count },
                    onSlashCommit: { runSelectedSlashCommand() },
                    onSlashQueryChange: { newValue in
                        // 只有在斜杠命令上下文（缓冲以 "/" 开头）才更新查询。
                        // 否则普通打字每键都改这个 @State，会让 ComposerCard
                        // 重渲染、`ViewThatFits` 重新测量整排 pill —— 正是
                        // rc482 要消除的逐键重建。普通 prose 下 next 恒为 ""，
                        // 与现值相等不触发重渲染。
                        let next = newValue.hasPrefix("/") ? newValue : ""
                        if slashMenuQuery != next { slashMenuQuery = next }
                    },
                    atMenuVisible: $atMenuVisible,
                    atMenuSelection: $atMenuSelection,
                    atMenuItemCount: { filteredAtEntries.count },
                    onAtCommit: { commitSelectedAtEntry() },
                    onAtCancel: { closeAtMenu() },
                    onAtQueryChange: { handleAtQueryChange($0) },
                    skillMenuVisible: $skillMenuVisible,
                    skillMenuSelection: $skillMenuSelection,
                    skillMenuItemCount: { filteredSkillEntries.count },
                    onSkillCommit: { commitSelectedSkillEntry() },
                    onSkillCancel: { closeSkillMenu() },
                    onSkillQueryChange: { handleSkillQueryChange($0) },
                    coordinatorRef: coordinatorRef
                )
                .focused($inputFocused)
                // 1.85.0-rc15:封顶从 ~7 行收到 ~3 行(对齐 codex 默认体感;
                // claude 是 1 行,这里取中间)。超出后内部 NSScrollView 的
                // vertical scroller 自动接上,长内容不会被截。
                .frame(minHeight: 26, maxHeight: 70)
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

            }

            HStack(spacing: 6) {
                AttachButton(action: attachFilesFromPanel)
                ComposerAdaptiveControlStrip()
                ConsultationButton {
                    isConsultationSheetPresented = true
                }
                Spacer(minLength: 0)
                if !appState.agentQueuedMessages.isEmpty {
                    QueueBadge()
                }
                InsertSecretButton {
                    isSecretSheetPresented = true
                }
                MicPushToTalkButton()
                SendStopButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius)
                .stroke(palette.hairline, lineWidth: 1)
        )
        .onAppear {
            // 窗口新开时 AppKit 会把默认 first responder 给到窗口里第一个
            // 可聚焦控件（侧边栏「新聊天」按钮），同步在 onAppear 里设
            // inputFocused 会被那次默认指派盖掉。下一拍 async 再设，抢在
            // 默认指派之后，焦点稳稳落在输入框 —— agent mode 开门见山能打字。
            DispatchQueue.main.async { inputFocused = true }
        }
        .onCompatibleChange(of: appState.agentComposerFocusRevision) { _, _ in
            inputFocused = true
        }
        .onCompatibleChange(of: appState.agentToolCalls) { _, _ in
            presentPendingTerminalProtectedInputIfNeeded()
        }
        .sheet(isPresented: $isSecretSheetPresented) {
            AgentSecretInsertSheet(
                onCancel: {
                    isSecretSheetPresented = false
                    inputFocused = true
                },
                onInsert: { secrets in
                    insertSecrets(secrets)
                    isSecretSheetPresented = false
                    inputFocused = true
                }
            )
        }
        .sheet(isPresented: $isConsultationSheetPresented) {
            AgentConsultationSetupSheet(
                task: appState.agentInput,
                onCancel: {
                    isConsultationSheetPresented = false
                    inputFocused = true
                },
                onStart: { taskText, configuration in
                    if appState.startAgentConsultation(
                        task: taskText,
                        configuration: configuration
                    ) {
                        isConsultationSheetPresented = false
                    }
                    inputFocused = true
                }
            )
        }
        .sheet(item: $pendingTerminalProtectedInput) { promptSet in
            AgentTerminalProtectedInputSheet(promptSet: promptSet) {
                inputFocused = true
            }
        }
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
        // 先把当前 raw input 里的 args 切出来 —— workflow 命令需要它，
        // core 命令忽略。然后再清空输入框。
        let args = SlashCommand.argsForCommand(appState.agentInput)
        if command.argumentMode.acceptsArguments && args.isEmpty {
            stageSlashCommandForArguments(command)
            return true
        }
        executeSlashCommand(command, args: args)
        return true
    }

    /// Enter outside the palette executes an exact slash invocation that was
    /// previously staged for arguments. Non-command text keeps the ordinary
    /// composer send path.
    private func submitComposer() {
        let commands = SlashCommand.builtIn(state: appState)
        guard let invocation = SlashCommand.invocation(in: appState.agentInput, commands: commands) else {
            appState.sendAgentMessage()
            return
        }

        if invocation.command.argumentMode.requiresArguments && invocation.args.isEmpty {
            // Let the workflow surface its localized missing-arguments error,
            // but keep the staged command in the composer for correction.
            invocation.command.action(invocation.args)
            inputFocused = true
            return
        }
        executeSlashCommand(invocation.command, args: invocation.args)
    }

    private func stageSlashCommandForArguments(_ command: SlashCommand) {
        let staged = command.title + " "
        slashMenuVisible = false
        slashMenuSelection = 0
        slashMenuQuery = ""
        if coordinatorRef.coordinator?.replaceComposerText(with: staged) != true {
            appState.agentInput = staged
        }
        inputFocused = true
    }

    private func executeSlashCommand(_ command: SlashCommand, args: String) {
        slashMenuVisible = false
        slashMenuSelection = 0
        slashMenuQuery = ""
        appState.agentInput = ""
        command.action(args)
    }

    private func handleAtQueryChange(_ query: String?) {
        if let q = query {
            if skillMenuVisible {
                closeSkillMenu()
            }
            atMenuQuery = q
        } else {
            atMenuQuery = ""
            atMenuVisible = false
        }
    }

    private func handleSkillQueryChange(_ query: String?) {
        if let q = query {
            if atMenuVisible {
                closeAtMenu()
            }
            // Refresh the catalog on transition from closed → open so a
            // newly installed skill shows up the next time `$` is typed.
            if !skillMenuVisible || skillCatalog.isEmpty {
                skillCatalog = AgentSkillDirectory.list()
            }
            skillMenuQuery = q
        } else {
            skillMenuQuery = ""
            skillMenuVisible = false
        }
    }

    private func insertSecrets(_ secrets: [AgentSecretInput]) {
        let placeholders = AgentSecretStore.saveSecrets(secrets)
        guard !placeholders.isEmpty else { return }
        let current = appState.agentInput
        let separator: String
        if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
            separator = ""
        } else {
            separator = " "
        }
        appState.agentInput = current + separator + placeholders.joined(separator: " ")
    }

    private func presentPendingTerminalProtectedInputIfNeeded() {
        guard !isSecretSheetPresented,
              pendingTerminalProtectedInput == nil,
              let call = appState.agentToolCalls.last(where: {
                  $0.toolName == "terminal_create_shortcut" && $0.status == .succeeded
              }),
              let payload = call.result?.payload,
              let promptSet = TerminalShortcutProtectedPromptSet.parse(payload: payload),
              promptSet.shortcutID != lastAutoPresentedTerminalShortcutID else {
            return
        }

        let pendingEventIndexes = Set(
            appState.agentTerminalController.shortcuts
                .first(where: { $0.id == promptSet.shortcutID })?
                .events.enumerated()
                .filter { $0.element.needsProtectedInputValue }
                .map(\.offset) ?? []
        )
        let pendingPrompts = promptSet.prompts.filter { pendingEventIndexes.contains($0.eventIndex) }
        guard !pendingPrompts.isEmpty else { return }

        lastAutoPresentedTerminalShortcutID = promptSet.shortcutID
        pendingTerminalProtectedInput = TerminalShortcutProtectedPromptSet(
            shortcutID: promptSet.shortcutID,
            title: promptSet.title,
            prompts: pendingPrompts
        )
    }

    private func closeAtMenu() {
        atMenuVisible = false
        atMenuSelection = 0
        atMenuQuery = ""
    }

    private func closeSkillMenu() {
        skillMenuVisible = false
        skillMenuSelection = 0
        skillMenuQuery = ""
    }

    @discardableResult
    private func commitSelectedAtEntry() -> Bool {
        let entries = filteredAtEntries
        guard !entries.isEmpty else { return false }
        let safeIndex = min(max(0, atMenuSelection), entries.count - 1)
        let entry = entries[safeIndex]
        // Drop the @-token from the buffer. AppState side-effects then
        // surface as chips above the composer; the actual context
        // (file contents, workspace overview) is
        // spliced into the prompt by composeAttachedPrompt at send time.
        _ = coordinatorRef.coordinator?.replaceCurrentAtToken(with: "")
        switch entry {
        case .workspace:
            if !appState.agentPendingIncludeWorkspaceOverview {
                appState.toggleAgentWorkspaceOverview()
            }
        case .file(let url, _):
            appState.attachAgentFile(url: url)
        }
        closeAtMenu()
        return true
    }

    @discardableResult
    private func commitSelectedSkillEntry() -> Bool {
        let entries = filteredSkillEntries
        guard !entries.isEmpty else { return false }
        let safeIndex = min(max(0, skillMenuSelection), entries.count - 1)
        let entry = entries[safeIndex]
        _ = coordinatorRef.coordinator?.replaceCurrentSkillToken(with: "")
        switch entry {
        case .skill(let skill):
            appState.attachAgentSkill(skill)
        }
        closeSkillMenu()
        return true
    }

    private func handlePastedImage() {
        for (data, mime) in AgentImagePasteboardHelper.readImages(from: NSPasteboard.general) {
            ingest(data: data, mimeType: mime)
        }
    }

    private func handlePastedText(_ text: String) {
        appState.addAgentTextAttachment(content: text)
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let fileURL = item as? URL {
                        url = fileURL
                    } else if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    DispatchQueue.main.async { attachFile(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let png = Self.pngData(for: image) else { return }
                    DispatchQueue.main.async { ingest(data: png, mimeType: "image/png") }
                }
            }
        }
    }

    private func attachFilesFromPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.Composer.attachFilePanelTitle
        panel.allowedContentTypes = AgentComposerAttachmentSupport.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                attachFile(url)
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

    private func attachFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            appState.addAgentKnowledgeFolder(url: url)
            return
        }

        if let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path),
           let data = try? Data(contentsOf: url) {
            ingest(data: data, mimeType: mime)
            return
        }

        guard AgentComposerAttachmentSupport.isSupportedDocument(url) else {
            appState.agentErrorMessage = L10n.Composer.unsupportedAttachment(url.lastPathComponent)
            return
        }
        guard !AgentComposerAttachmentSupport.documentExceedsSizeLimit(url) else {
            appState.agentErrorMessage = L10n.Composer.attachmentTooLarge(url.lastPathComponent)
            return
        }
        appState.attachAgentFile(url: url)
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

private struct ConsultationButton: View {
    @EnvironmentObject private var appState: AppState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stethoscope")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canStart ? Color.accentColor : Color.secondary)
        .help(L10n.Consultation.buttonHelp)
        .disabled(!canStart)
    }

    private var canStart: Bool {
        !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appState.isAgentResponding
            && !appState.hasActiveAgentConsultation
    }
}

private struct AgentSecretInsertSheet: View {
    @State private var rows: [AgentSecretInput] = [AgentSecretInput(label: "", secret: "")]

    let onCancel: () -> Void
    let onInsert: (_ secrets: [AgentSecretInput]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(L10n.Composer.insertSecretTitle)
                    .font(.headline)
            }

            Text(L10n.Composer.insertSecretDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.Composer.insertSecretUsage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    AgentSecretInputRow(
                        ordinal: index + 1,
                        label: $rows[index].label,
                        secret: $rows[index].secret,
                        shouldFocusOnAppear: index == 0,
                        canRemove: rows.count > 1,
                        onRemove: { removeRow(at: index) }
                    )
                }
                if rows.count < AgentSecretStore.maxBatchInsertCount {
                    Button {
                        rows.append(AgentSecretInput(label: "", secret: ""))
                    } label: {
                        Label(L10n.Composer.addSecretAction, systemImage: "plus")
                    }
                    .buttonStyle(.link)
                    .help(L10n.Composer.addSecretHelp)
                }
            }

            HStack {
                Spacer()
                Button(L10n.Automation.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.Composer.insertSecretAction) {
                    onInsert(rows)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validSecretCount == 0)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    private var validSecretCount: Int {
        rows.filter { !$0.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private func removeRow(at index: Int) {
        guard rows.indices.contains(index), rows.count > 1 else { return }
        rows.remove(at: index)
    }
}

private struct AgentSecretInputRow: View {
    let ordinal: Int
    @Binding var label: String
    @Binding var secret: String
    let shouldFocusOnAppear: Bool
    let canRemove: Bool
    let onRemove: () -> Void
    @FocusState private var secretFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(ordinal)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                TextField(L10n.Composer.secretLabelPlaceholder, text: $label)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.Composer.secretValuePlaceholder, text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .focused($secretFocused)
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(canRemove ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .help(L10n.Composer.removeSecretHelp)
            .padding(.top, 4)
        }
        .onAppear {
            guard shouldFocusOnAppear else { return }
            DispatchQueue.main.async { secretFocused = true }
        }
    }
}

private struct AgentTerminalProtectedInputSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var valuesByEventIndex: [Int: String] = [:]
    @FocusState private var focusedEventIndex: Int?

    let promptSet: TerminalShortcutProtectedPromptSet
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(L10n.AgentTerminal.shortcutPasswordCardTitle(promptSet.title))
                    .font(.headline)
            }

            Text(L10n.AgentTerminal.shortcutPasswordCardDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(promptSet.prompts) { prompt in
                    SecureField(prompt.label, text: valueBinding(for: prompt.eventIndex))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedEventIndex, equals: prompt.eventIndex)
                }
            }

            HStack {
                Spacer()
                Button(L10n.AgentTerminal.shortcutRenameCancel) {
                    dismissSheet()
                }
                Button(L10n.AgentTerminal.shortcutPasswordSave) {
                    guard appState.fillTerminalShortcutProtectedInputs(
                        shortcutID: promptSet.shortcutID,
                        valuesByEventIndex: valuesByEventIndex
                    ) else {
                        return
                    }
                    dismissSheet()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasAllValues)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            focusedEventIndex = promptSet.prompts.first?.eventIndex
        }
    }

    private var hasAllValues: Bool {
        promptSet.prompts.allSatisfy {
            !(valuesByEventIndex[$0.eventIndex] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private func valueBinding(for eventIndex: Int) -> Binding<String> {
        Binding(
            get: { valuesByEventIndex[eventIndex] ?? "" },
            set: { valuesByEventIndex[eventIndex] = $0 }
        )
    }

    private func dismissSheet() {
        dismiss()
        onDismiss()
    }
}

// MARK: - Status bar

struct AgentChatStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        HStack(spacing: 14) {
            if activeRemoteWorkspaceLabel == nil, let branch = appState.gitStatus.branchName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let remote = activeRemoteWorkspaceLabel {
                HStack(spacing: 4) {
                    Image(systemName: activeRemoteWorkspaceIconName)
                        .font(.system(size: 9))
                        .foregroundStyle(activeRemoteWorkspaceTint)
                    Text(remote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let localPath = appState.activeRuntime?.workspaceLocation?.localPath {
                let root = URL(fileURLWithPath: localPath)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(root.lastPathComponent.isEmpty ? localPath : root.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(L10n.Workspace.noWorkspace)
            }

            // 文件变更 summary 只保留 composer 顶部那条
            // (AgentComposerWorktreeSummaryBar)。这里底部状态栏原本还有
            // 一个 AgentWorktreeSummaryPill,和顶部那条重复,移除。
            Spacer(minLength: 0)

            CompressButton()
            ContextRingIndicator()

            // Quick access: gear opens Settings (keeping the last tab),
            // phone jumps straight to the Mobile Gateway section.
            if #available(macOS 14.0, *) {
                AgentChatStatusBarSettingsButtonsModern()
            } else {
                AgentChatStatusBarSettingsButtons {
                    EditorSettingsNavigation.shared.openWindow(appState: appState)
                }
            }
        }
        .font(AgentDesign.captionFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.statusBarHeight)
        .background(palette.panelFill)
        .overlay(Rectangle().fill(palette.hairline).frame(height: 1), alignment: .top)
    }

    private var activeRemoteWorkspaceLabel: String? {
        guard case .remote(let runtimeID, let path) = appState.activeRuntime?.workspaceLocation else {
            return nil
        }
        let runtime = AgentRuntimeStore.descriptor(id: runtimeID)
        return WorkspacePresentation.remoteDisplayName(runtime: runtime, path: path)
    }

    private var activeRemoteWorkspaceIconName: String {
        guard case .remote(let runtimeID, _) = appState.activeRuntime?.workspaceLocation else {
            return "globe"
        }
        return WorkspacePresentation.remoteSymbolName(for: AgentRuntimeStore.descriptor(id: runtimeID))
    }

    private var activeRemoteWorkspaceTint: Color {
        guard case .remote(let runtimeID, _) = appState.activeRuntime?.workspaceLocation else {
            return Color.accentColor
        }
        return WorkspacePresentation.remoteTint(for: AgentRuntimeStore.descriptor(id: runtimeID))
    }
}

private struct AgentChatStatusBarSettingsButtons: View {
    let openSettings: () -> Void

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help(L10n.Settings.agentBarSettings)

        Button {
            EditorSettingsNavigation.shared.selectedTab = .mobileGateway
            openSettings()
        } label: {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .help(L10n.Settings.agentBarMobileGateway)
    }
}

@available(macOS 14.0, *)
private struct AgentChatStatusBarSettingsButtonsModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AgentChatStatusBarSettingsButtons {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
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
                    Text(L10n.ContextCompression.compressing)
                }
            } else if shouldOffer {
                Button {
                    appState.compressAgentContext()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9))
                        Text(L10n.ContextCompression.compress)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.ContextCompression.compressHelp)
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
        .help(L10n.ContextRing.tooltip(
            formatTokens(conversationUsed),
            formatTokens(usableWindow),
            formatTokens(baseline),
            formatTokens(remaining)
        ))
    }

    private var window: Int { max(1, appState.agentContextWindow) }
    private var used: Int { appState.estimatedAgentTokens }
    /// Fixed system-prompt + tool-schema overhead, present before the user
    /// sends anything. Clamped to `used` so we never report negative
    /// conversation usage if the estimate jitters.
    private var baseline: Int { min(appState.estimatedAgentBaselineTokens, used) }
    /// Window left for the conversation once the fixed overhead is set aside.
    private var usableWindow: Int { max(1, window - baseline) }
    /// Tokens the conversation itself has added — what the ring tracks. A
    /// brand-new chat (no messages) has 0 here, so the ring reads 0%.
    private var conversationUsed: Int { max(0, used - baseline) }
    private var usedFraction: CGFloat { min(1, max(0, CGFloat(conversationUsed) / CGFloat(usableWindow))) }
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
