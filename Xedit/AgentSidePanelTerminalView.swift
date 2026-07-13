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
            sessionIdentityBar
            Divider().opacity(0.35)
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

                if controller.isRecording {
                    recordingStatusPill(now: timeline.date)
                        .transition(.opacity)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if controller.shortcuts.isEmpty {
                            Text(L10n.AgentTerminal.noShortcuts)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        } else {
                            ForEach(controller.shortcuts) { shortcut in
                                shortcutControl(shortcut, now: timeline.date)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: controller.isRecording ? 40 : 36)
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
            HStack(spacing: 5) {
                Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 11, weight: .bold))
                Text(controller.isRecording ? L10n.AgentTerminal.stopRecording : L10n.AgentTerminal.startRecording)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(controller.isRecording ? Color.white : Color.red)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(controller.isRecording ? Color.red : Color.red.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(controller.activeTab?.isRunning != true && !controller.isRecording)
        .help(controller.isRecording ? L10n.AgentTerminal.stopRecording : L10n.AgentTerminal.startRecording)
    }

    private func recordingStatusPill(now: Date) -> some View {
        let elapsed = controller.recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        return HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text(L10n.AgentTerminal.recording)
                .font(.system(size: 11, weight: .semibold))
            Text(formatElapsed(elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }

    private func shortcutControl(_ shortcut: TerminalShortcut, now: Date) -> some View {
        let playbackState = playbackState(for: shortcut)
        let isRunning = playbackState?.isRunning == true
        return HStack(spacing: 0) {
            Button {
                if isRunning {
                    controller.cancelActiveShortcutPlayback()
                } else {
                    controller.playShortcut(shortcut)
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 24)
            }
            .disabled(
                (!isRunning && controller.isRecording) ||
                    controller.activeTab?.isRunning != true ||
                    (!isRunning && controller.activeTab?.isPlayingShortcut == true) ||
                    shortcut.hasPendingProtectedInput
            )
            .buttonStyle(.plain)
            .help(isRunning ? L10n.AgentTerminal.shortcutStopReplay : L10n.AgentTerminal.shortcutReplay)

            TerminalShortcutChip(
                shortcut: shortcut,
                playbackState: playbackState,
                now: now,
                accent: skinAccent
            )
            .padding(.trailing, 2)

            Menu {
                Button {
                    editShortcut(shortcut)
                } label: {
                    Label(L10n.AgentTerminal.shortcutEdit, systemImage: "square.and.pencil")
                }

                Button {
                    renameDraft = TerminalShortcutRenameDraft(shortcut: shortcut)
                } label: {
                    Label(L10n.AgentTerminal.shortcutRename, systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    controller.deleteShortcut(id: shortcut.id)
                } label: {
                    Label(L10n.AgentTerminal.shortcutDelete, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(L10n.AgentTerminal.shortcutActions)
        }
        .padding(.leading, 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(playbackState?.isRunning == true ? skinAccent.opacity(0.14) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(playbackState?.isRunning == true ? skinAccent.opacity(0.38) : Color.primary.opacity(0.10), lineWidth: 1)
        )
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

    private var sessionIdentityBar: some View {
        HStack(spacing: 8) {
            if let tab = controller.activeTab {
                Image(systemName: tab.kind.isSSH ? "network" : "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tab.isRunning ? Color.green : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(sessionKindLabel(tab))
                            .font(.system(size: 11, weight: .semibold))
                        Text(sessionTargetLabel(tab))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(sessionDetailLabel(tab))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(tab.isRunning ? L10n.AgentTerminal.sessionRunning : L10n.AgentTerminal.sessionExited)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tab.isRunning ? Color.green : Color.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tab.isRunning ? Color.green.opacity(0.11) : Color.primary.opacity(0.06))
                    )
            } else {
                Text(L10n.AgentTerminal.disconnectedRuntime)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 10)
        .background(terminalBackground.opacity(0.96))
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

    private func sessionKindLabel(_ tab: AgentTerminalTab) -> String {
        tab.kind.isSSH ? L10n.AgentTerminal.sessionSSH : L10n.AgentTerminal.sessionLocal
    }

    private func sessionTargetLabel(_ tab: AgentTerminalTab) -> String {
        switch tab.kind {
        case .localShell:
            return tab.title
        case .ssh(_, let displayName, let target):
            return displayName.isEmpty ? target : displayName
        }
    }

    private func sessionDetailLabel(_ tab: AgentTerminalTab) -> String {
        switch tab.kind {
        case .localShell:
            return L10n.AgentTerminal.localSessionCaution
        case .ssh(_, _, let target):
            return target
        }
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
            lines.append(L10n.AgentTerminal.shortcutPendingProtected("\(shortcut.pendingProtectedInputCount)"))
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

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):\(String(format: "%02d", remainder))"
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
            Text(L10n.AgentTerminal.shortcutRenameTitle)
                .font(.headline)
            TextField(L10n.AgentTerminal.shortcutNamePlaceholder, text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button(L10n.AgentTerminal.shortcutRenameCancel, action: onCancel)
                Button(L10n.AgentTerminal.shortcutRenameSave) {
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
            terminalView.refreshVisibleTerminalDisplay()
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: AgentLocalProcessTerminalView, context: Context) {
        DispatchQueue.main.async {
            nsView.refreshVisibleTerminalDisplay()
        }
    }
}
