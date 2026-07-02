//
//  AgentSidePanelTerminalView.swift
//  WillDeep
//
//  Right-side Agent-mode terminal panel. Multi-tab, SwiftTerm-backed.
//  Each tab is a full terminal emulator; tabs default to a local login
//  shell and remember which Agent session opened them.
//

import AppKit
import SwiftUI

struct AgentSidePanelTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        AgentSidePanelTerminalContentView(controller: appState.agentTerminalController)
    }
}

private struct AgentSidePanelTerminalContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: AgentInteractiveTerminalController
    @State private var renameDraft: TerminalShortcutRenameDraft?
    @State private var bootstrapTask: Task<Void, Never>?

    private var settings: EditorTerminalSettings {
        appState.editorTerminalSettings.normalized()
    }

    private var skinColors: TerminalSkinColors? {
        settings.followsInterfaceSkin
            ? .from(palette: appState.editorSettings.interfaceSkin.palette)
            : nil
    }

    /// Resolved terminal background, mirroring `TerminalAppearance.apply`.
    /// Used to fill the horizontal padding gutter so the inset reads as the
    /// terminal breathing from the edges rather than a stripe of window chrome.
    private var terminalBackground: Color {
        if settings.followsInterfaceSkin, let skin = skinColors {
            return Color(nsColor: skin.background)
        }
        return Color(nsColor: settings.colorScheme.background)
    }

    /// Accent pulled from the active interface skin so the tab chips match the
    /// app's skin instead of the system accent color (which reads as an
    /// off-theme purple regardless of the chosen skin).
    private var skinAccent: Color {
        appState.editorSettings.interfaceSkin.palette.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            shortcutsBar
            Divider().opacity(0.5)
            tabBar
            Divider().opacity(0.5)
            terminalSurface
        }
        .onAppear {
            scheduleTerminalBootstrap()
        }
        .onDisappear {
            bootstrapTask?.cancel()
            bootstrapTask = nil
        }
        .sheet(item: $renameDraft) { draft in
            TerminalShortcutRenameSheet(
                initialTitle: draft.title,
                onCancel: { renameDraft = nil },
                onSave: { title in
                    controller.renameShortcut(id: draft.shortcutID, title: title)
                    renameDraft = nil
                }
            )
        }
        .onCompatibleChange(of: appState.editorTerminalSettings) { _, _ in
            // Live-apply font / color / cursor changes (e.g. switching to a
            // Nerd Font or the skin palette) to already-open tabs.
            controller.applyAppearanceToAll(settings, skin: skinColors)
        }
    }

    // MARK: Tab bar

    private var shortcutsBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 6) {
                recordButton
                    .layoutPriority(1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(controller.shortcuts) { shortcut in
                            shortcutMenu(shortcut, now: timeline.date)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)
            .padding(.horizontal, 8)
            .background(terminalBackground.opacity(0.92))
        }
    }

    private var recordButton: some View {
        Button {
            if controller.isRecording {
                controller.stopRecording()
            } else {
                controller.startRecordingActiveTab()
            }
        } label: {
            Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(controller.isRecording ? Color.white : Color.red)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(controller.isRecording ? Color.red : Color.red.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(controller.activeTab?.isRunning != true && !controller.isRecording)
        .help(controller.isRecording ? "停止录制终端捷径" : "开始录制终端捷径")
    }

    private func shortcutMenu(_ shortcut: TerminalShortcut, now: Date) -> some View {
        let playbackState = playbackState(for: shortcut)
        return Menu {
            Button {
                controller.playShortcut(shortcut)
            } label: {
                Label("回放", systemImage: "play.fill")
            }
            .disabled(
                controller.isRecording ||
                    controller.activeTab?.isRunning != true ||
                    controller.activeTab?.isPlayingShortcut == true ||
                    shortcut.hasPendingProtectedInput
            )

            Button {
                editShortcut(shortcut)
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }

            Button {
                renameDraft = TerminalShortcutRenameDraft(shortcut: shortcut)
            } label: {
                Label("改名…", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                controller.deleteShortcut(id: shortcut.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            TerminalShortcutChip(
                shortcut: shortcut,
                playbackState: playbackState,
                now: now,
                accent: skinAccent
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(shortcutTooltip(shortcut, playbackState: playbackState, now: now))
    }

    private func editShortcut(_ shortcut: TerminalShortcut) {
        controller.prepareShortcutsFileForEditing()
        let url = TerminalShortcutStore.fileURL
        guard appState.openEditorFile(url, allowLargeFile: true, performsSafetyChecks: false) else {
            NSSound.beep()
            return
        }
        if let line = TerminalShortcutStore.lineNumber(for: shortcut.id, in: appState.fileContent) {
            appState.navigateEditor(toLine: line)
        }
        if !appState.showEditor() {
            openWindow(value: url)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 6)
            }
            // 让 tab 滚动区只吃「剩余」宽度,窄侧栏时长标签横向滚动,
            // 不会把右侧「+」挤出可视区。`+` 用 layoutPriority 先拿空间。
            .frame(maxWidth: .infinity, alignment: .leading)
            addTabMenu
                .layoutPriority(1)
        }
        .frame(height: 30)
        .padding(.trailing, 6)
    }

    private func tabChip(_ tab: AgentTerminalTab) -> some View {
        let isActive = controller.activeTabID == tab.id
        return HStack(spacing: 5) {
            Image(systemName: tab.kind.isSSH ? "network" : "terminal")
                .font(.system(size: 9))
                .foregroundStyle(tab.isRunning ? Color.green : Color.secondary)
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                // 标题封顶,避免 `rocky@host:/` 这种长 OSC 标题把
                // 整个 chip 撑得占满侧栏、把 `+` 顶出去。
                .frame(maxWidth: 130)
            Button {
                controller.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? skinAccent.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(originBadgeColor(tab), lineWidth: isOpenedByCurrentSession(tab) ? 1 : 0)
        )
        .help(tabTooltip(tab))
        .contentShape(Rectangle())
        .onTapGesture {
            controller.activeTabID = tab.id
        }
    }

    private var addTabMenu: some View {
        Menu {
            Button {
                controller.openLocalTab(
                    originAgentSessionID: appState.activeAgentSessionID,
                    workingDirectory: workingDirectory,
                    settings: settings,
                    skin: skinColors
                )
            } label: {
                Label(L10n.AgentTerminal.newLocalTab, systemImage: "terminal")
            }
            Divider()
            Text(L10n.AgentTerminal.sshHostsSection)
            if controller.runtimeOptions.isEmpty {
                Text(L10n.AgentTerminal.noSSHHostsConfigured)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.runtimeOptions) { runtime in
                    Button {
                        controller.openSSHTab(
                            runtime: runtime,
                            originAgentSessionID: appState.activeAgentSessionID,
                            settings: settings,
                            skin: skinColors
                        )
                    } label: {
                        Label(L10n.AgentTerminal.newSSHTab(runtime.displayName), systemImage: "network")
                    }
                }
            }
            Button {
                EditorSettingsNavigation.shared.open(.remoteRuntimes, appState: appState)
            } label: {
                Label(L10n.AgentTerminal.manageSSHHosts, systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.AgentTerminal.newTab)
    }

    // MARK: Terminal surface

    @ViewBuilder
    private var terminalSurface: some View {
        if let tab = controller.activeTab {
            AgentTerminalViewRepresentable(terminalView: tab.terminalView)
                .padding(.horizontal, 8)
                .background(terminalBackground)
                .id(tab.id)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(L10n.AgentTerminal.emptyOutput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Helpers

    private var workingDirectory: String? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return path
        }
        return appState.rootDirectory?.standardizedFileURL.path
    }

    private func scheduleTerminalBootstrap() {
        bootstrapTask?.cancel()
        let originAgentSessionID = appState.activeAgentSessionID
        let directory = workingDirectory
        let terminalSettings = settings
        let colors = skinColors
        bootstrapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            controller.selectRuntimeIfNeeded()
            controller.ensureAtLeastOneTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: directory,
                settings: terminalSettings,
                skin: colors
            )
            controller.applyAppearanceToAll(terminalSettings, skin: colors)
        }
    }

    private func isOpenedByCurrentSession(_ tab: AgentTerminalTab) -> Bool {
        guard let origin = tab.originAgentSessionID,
              let active = appState.activeAgentSessionID else { return false }
        return origin == active
    }

    private func originBadgeColor(_ tab: AgentTerminalTab) -> Color {
        isOpenedByCurrentSession(tab) ? skinAccent.opacity(0.55) : Color.clear
    }

    private func tabTooltip(_ tab: AgentTerminalTab) -> String {
        var lines = [tab.title]
        switch tab.kind {
        case .localShell:
            lines.append(L10n.AgentTerminal.localShellTooltip)
        case .ssh(_, _, let target):
            lines.append(target)
        }
        if isOpenedByCurrentSession(tab) {
            lines.append(L10n.AgentTerminal.openedByThisSession)
        }
        return lines.joined(separator: " · ")
    }

    private func playbackState(for shortcut: TerminalShortcut) -> TerminalShortcutPlaybackState? {
        guard let state = controller.activeShortcutPlaybackState,
              state.shortcutID == shortcut.id else {
            return nil
        }
        return state
    }

    private func shortcutTooltip(
        _ shortcut: TerminalShortcut,
        playbackState: TerminalShortcutPlaybackState?,
        now: Date
    ) -> String {
        var lines = [
            shortcut.title,
            L10n.AgentTerminal.shortcutMeta(
                formatShortcutDuration(shortcut.durationMilliseconds),
                "\(shortcut.eventCount)"
            ),
            L10n.AgentTerminal.shortcutReplayWait(
                formatShortcutDuration(shortcut.playbackDurationMilliseconds)
            )
        ]
        if let playbackState {
            switch playbackState.status {
            case .running:
                lines.append(L10n.AgentTerminal.shortcutRunning)
                lines.append(
                    L10n.AgentTerminal.shortcutRemaining(
                        formatShortcutDuration(playbackState.remainingMilliseconds(now: now))
                    )
                )
                lines.append(L10n.AgentTerminal.shortcutEstimatedFinish(Self.shortcutETAFormatter.string(from: playbackState.estimatedFinishedAt)))
                lines.append(
                    L10n.AgentTerminal.shortcutProgress(
                        "\(playbackState.currentEventIndex)",
                        "\(playbackState.totalEvents)"
                    )
                )
            case .finished:
                lines.append(L10n.AgentTerminal.shortcutFinished)
            case .cancelled:
                lines.append(L10n.AgentTerminal.shortcutCancelled)
            }
        }
        if shortcut.hasProtectedInput {
            lines.append(L10n.AgentTerminal.shortcutProtected)
        }
        if shortcut.hasPendingProtectedInput {
            lines.append("还有 \(shortcut.pendingProtectedInputCount) 个密码占位待填写")
        }
        return lines.joined(separator: " · ")
    }

    private func formatShortcutDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, Int(ceil(Double(milliseconds) / 1000)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(String(format: "%02ds", remainder))"
        }
        let hours = minutes / 60
        let minuteRemainder = minutes % 60
        return minuteRemainder == 0 ? "\(hours)h" : "\(hours)h \(String(format: "%02dm", minuteRemainder))"
    }

    private static let shortcutETAFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct TerminalShortcutRenameDraft: Identifiable {
    let id = UUID()
    let shortcutID: UUID
    let title: String

    init(shortcut: TerminalShortcut) {
        self.shortcutID = shortcut.id
        self.title = shortcut.title
    }
}

private struct TerminalShortcutChip: View {
    let shortcut: TerminalShortcut
    let playbackState: TerminalShortcutPlaybackState?
    let now: Date
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(statusColor)
            Text(shortcut.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 124)
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
                .monospacedDigit()
                .lineLimit(1)
            if shortcut.hasProtectedInput {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var statusIcon: String {
        guard let playbackState else { return "play.fill" }
        switch playbackState.status {
        case .running:
            return "play.circle.fill"
        case .finished:
            return "checkmark.circle.fill"
        case .cancelled:
            return "exclamationmark.circle.fill"
        }
    }

    private var statusText: String {
        guard let playbackState else {
            return formatDuration(shortcut.durationMilliseconds)
        }
        switch playbackState.status {
        case .running:
            let remaining = formatDuration(playbackState.remainingMilliseconds(now: now))
            let progress = L10n.AgentTerminal.shortcutProgress(
                "\(playbackState.currentEventIndex)",
                "\(playbackState.totalEvents)"
            )
            return "\(remaining) · \(progress)"
        case .finished:
            return L10n.AgentTerminal.shortcutFinished
        case .cancelled:
            return L10n.AgentTerminal.shortcutCancelled
        }
    }

    private var statusColor: Color {
        guard let playbackState else { return .secondary }
        switch playbackState.status {
        case .running:
            return accent
        case .finished:
            return .green
        case .cancelled:
            return .orange
        }
    }

    private var backgroundColor: Color {
        playbackState?.isRunning == true ? accent.opacity(0.16) : Color.primary.opacity(0.07)
    }

    private var borderColor: Color {
        playbackState?.isRunning == true ? accent.opacity(0.45) : Color.primary.opacity(0.10)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, Int(ceil(Double(milliseconds) / 1000)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(String(format: "%02ds", remainder))"
        }
        let hours = minutes / 60
        let minuteRemainder = minutes % 60
        return minuteRemainder == 0 ? "\(hours)h" : "\(hours)h \(String(format: "%02dm", minuteRemainder))"
    }
}

private struct TerminalShortcutRenameSheet: View {
    @State private var title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    init(
        initialTitle: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self._title = State(initialValue: initialTitle)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("改名终端捷径")
                .font(.headline)
            TextField("捷径名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    onSave(title)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

/// Hosts a SwiftTerm LocalProcessTerminalView (owned by the tab) inside
/// SwiftUI. The view instance is stable for the tab's lifetime, so this
/// representable just mounts/focuses it.
struct AgentTerminalViewRepresentable: NSViewRepresentable {
    let terminalView: AgentLocalProcessTerminalView

    func makeNSView(context: Context) -> AgentLocalProcessTerminalView {
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: AgentLocalProcessTerminalView, context: Context) {}
}
