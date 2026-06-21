//
//  AgentModeComposerView.swift
//  WillDeep
//
//  Composer, status bar, slash/at pickers, and compact session badges
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

                if appState.shouldShowGoalRunningStatusBar, let goal = appState.agentCurrentGoal {
                    AgentGoalRunningStatusBar(goal: goal)
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth)
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

                ComposerCard()
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .onAppear {
            appState.refreshActiveAgentWorktreeChanges()
        }
        .onChange(of: appState.activeAgentSessionID) { _, _ in
            appState.refreshActiveAgentWorktreeChanges()
            // 切 session 后重置 banner 状态：新 session 的 plan 该弹照弹。
            dismissedPlanFingerprint = nil
        }
        .onChange(of: appState.agentInput) { oldValue, newValue in
            // 用户在 composer 开始打字（输入框从空变非空，或非空状态下
            // 字数变多） → 视作"我有补充，留在 Plan 模式"，立刻 dismiss
            // banner。**只在 banner 还显示时记 fingerprint**，否则
            // 任何普通输入都会无意义地写 state。
            guard let plan = currentProposedPlanIfBannerVisible() else { return }
            if newValue.count > oldValue.count {
                dismissedPlanFingerprint = planFingerprint(plan)
            }
        }
        .onChange(of: appState.agentCurrentPlan?.status) { _, newStatus in
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

    private func currentProposedPlanIfBannerVisible() -> AgentPlan? {
        guard let plan = appState.agentCurrentPlan,
              plan.status == .proposed,
              appState.agentInteractionMode == .plan,
              dismissedPlanFingerprint != planFingerprint(plan) else {
            return nil
        }
        return plan
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
            Text("\(appState.agentWorktreeChanges.fileCount) 个文件已更改")
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
                Text("审查")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("查看当前未提交 diff")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

private struct AgentGoalRunningStatusBar: View {
    let goal: AgentGoal
    @EnvironmentObject var appState: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(L10n.GoalStatusBar.runningPrefix)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(summaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let startedAt = appState.agentTurnStartedAt {
                    Text("· \(Self.formatElapsed(context.date.timeIntervalSince(startedAt)))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .contentShape(Rectangle())
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
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

    private var accessibilityLabel: String {
        "\(L10n.GoalStatusBar.runningPrefix) \(summaryText)"
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

                Spacer(minLength: 0)

                Button {
                    copyDiff()
                } label: {
                    Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "square.on.square")
                }
                .buttonStyle(.borderless)

                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(preview.diff)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
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
        if appState.activeRuntime?.workspaceLocation?.localPath != nil,
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

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
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
                    atMenuVisible: $atMenuVisible,
                    atMenuSelection: $atMenuSelection,
                    atMenuItemCount: { filteredAtEntries.count },
                    onAtCommit: { commitSelectedAtEntry() },
                    onAtQueryChange: { handleAtQueryChange($0) },
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
                WorkspacePickerPill()
                ModelPickerPill()
                AgentExecutionPickerPill()
                AgentModePickerPill()
                AgentApprovalModePickerPill()
                AgentPluginPickerPill()
                Spacer(minLength: 0)
                if !appState.agentQueuedMessages.isEmpty {
                    QueueBadge()
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
        // 先把当前 raw input 里的 args 切出来 —— workflow 命令需要它，
        // core 命令忽略。然后再清空输入框。
        let args = SlashCommand.argsForCommand(appState.agentInput)
        slashMenuVisible = false
        appState.agentInput = ""
        command.action(args)
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

    private func handlePastedText(_ text: String) {
        appState.addAgentTextAttachment(content: text)
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

// MARK: - Status bar

struct AgentChatStatusBar: View {
    @EnvironmentObject var appState: AppState
    // 1.85.0-rc9：独立 Agent 窗口里 `NSApp.sendAction(showSettingsWindow:)`
    // 找不到 target(responder chain 不经过 Settings scene),齿轮/手机按钮
    // 之前点了无反应。改用 macOS 14+ 的 `\.openSettings` 环境值。
    @Environment(\.openSettings) private var openSettings

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

            if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                AgentWorktreeSummaryPill()
            }

            Spacer(minLength: 0)

            CompressButton()
            ContextRingIndicator()

            // Quick access: gear opens Settings (keeping the last tab),
            // phone jumps straight to the Mobile Gateway section.
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(L10n.Settings.agentBarSettings)

            Button {
                EditorSettingsNavigation.shared.selectedTab = .mobileGateway
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help(L10n.Settings.agentBarMobileGateway)
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
