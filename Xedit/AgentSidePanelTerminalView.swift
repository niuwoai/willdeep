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

private enum SessionIdentityMetrics {
    static let barHeight: CGFloat = 42
    static let controlHeight: CGFloat = 22
    static let dividerHeight: CGFloat = 18
    static let dividerPadding: CGFloat = 8
    static let popoverWidth: CGFloat = 330
    static let hostnameCommand = "hostname"
}

private enum TerminalRecordingMetrics {
    static let controlRowHeight: CGFloat = 42
    static let recordButtonHeight: CGFloat = 28
    static let historyHeaderHeight: CGFloat = 26
    static let historyRowHeight: CGFloat = 42
    static let emptyHistoryHeight: CGFloat = 34
    static let visibleHistoryRows = 2
    static let playButtonSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 8
}

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
    @State private var showsHostVerificationPopover = false
    @State private var hostnameCommandCopied = false

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

    private var terminalForeground: Color {
        if settings.followsInterfaceSkin, let skin = skinColors {
            return Color(nsColor: skin.foreground)
        }
        return Color(nsColor: settings.colorScheme.foreground)
    }

    /// Accent pulled from the active interface skin so the tab chips match the
    /// app's skin instead of the system accent color (which reads as an
    /// off-theme purple regardless of the chosen skin).
    private var skinAccent: Color {
        appState.editorSettings.interfaceSkin.palette.accent
    }

    private var interfacePalette: EditorInterfaceSkinPalette {
        appState.editorSettings.interfaceSkin.palette
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
        // Buttons and menus in the side-panel chrome opt out individually;
        // the container does as well so it can never become a fallback focus
        // target. The embedded terminal remains an intentional text-input
        // surface and manages its own AppKit first responder.
        .focusable(false)
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
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            scheduleTerminalBootstrap()
        }
        .onCompatibleChange(of: controller.activeTabID) { _, _ in
            showsHostVerificationPopover = false
            hostnameCommandCopied = false
        }
    }

    // MARK: Recording bar

    private var shortcutsBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 0) {
                recordingControlRow(now: timeline.date)

                Divider()
                    .opacity(0.45)

                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.AgentTerminal.recentRecordings)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(interfacePalette.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .frame(height: TerminalRecordingMetrics.historyHeaderHeight)
                    .padding(.horizontal, TerminalRecordingMetrics.horizontalPadding + 2)

                    if controller.shortcuts.isEmpty {
                        HStack {
                            Text(L10n.AgentTerminal.noShortcuts)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(interfacePalette.secondaryText)
                            Spacer(minLength: 0)
                        }
                        .frame(height: TerminalRecordingMetrics.emptyHistoryHeight)
                        .padding(.horizontal, TerminalRecordingMetrics.horizontalPadding + 2)
                    } else {
                        ScrollView(.vertical, showsIndicators: controller.shortcuts.count > TerminalRecordingMetrics.visibleHistoryRows) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(controller.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                    shortcutControl(shortcut, now: timeline.date)

                                    if index < controller.shortcuts.count - 1 {
                                        Divider()
                                            .padding(.leading, TerminalRecordingMetrics.horizontalPadding + TerminalRecordingMetrics.playButtonSize + 10)
                                    }
                                }
                            }
                        }
                        .frame(height: shortcutHistoryHeight)
                    }
                }
                .background(interfacePalette.panelFill.opacity(0.96))
            }
        }
    }

    private func recordingControlRow(now: Date) -> some View {
        HStack(spacing: 10) {
            recordButton
                .layoutPriority(1)

            if controller.isRecording {
                recordingStatus(now: now)
                    .transition(.opacity)
            } else {
                Text(L10n.AgentTerminal.recordingHelp)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(terminalForeground.opacity(0.64))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(height: TerminalRecordingMetrics.controlRowHeight)
        .padding(.horizontal, TerminalRecordingMetrics.horizontalPadding)
        .background(terminalBackground.opacity(0.96))
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
                    .foregroundStyle(Color.red)
                Text(controller.isRecording ? L10n.AgentTerminal.stopRecording : L10n.AgentTerminal.startRecording)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(terminalForeground)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: TerminalRecordingMetrics.recordButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(controller.isRecording ? Color.red.opacity(0.18) : terminalForeground.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        controller.isRecording ? Color.red.opacity(0.46) : terminalForeground.opacity(0.16),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(controller.activeTab?.isRunning != true && !controller.isRecording)
        .help(controller.isRecording ? L10n.AgentTerminal.stopRecording : L10n.AgentTerminal.startRecording)
    }

    private func recordingStatus(now: Date) -> some View {
        let elapsed = controller.recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        return HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text(L10n.AgentTerminal.recording)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(terminalForeground.opacity(0.84))
            Text(formatElapsed(elapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(terminalForeground.opacity(0.64))
        }
        .lineLimit(1)
    }

    private func shortcutControl(_ shortcut: TerminalShortcut, now: Date) -> some View {
        let playbackState = playbackState(for: shortcut)
        let isRunning = playbackState?.isRunning == true
        return HStack(spacing: 10) {
            Button {
                if isRunning {
                    controller.cancelActiveShortcutPlayback()
                } else {
                    controller.playShortcut(shortcut)
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isRunning ? skinAccent : interfacePalette.primaryText)
                    .frame(
                        width: TerminalRecordingMetrics.playButtonSize,
                        height: TerminalRecordingMetrics.playButtonSize
                    )
                    .background(
                        Circle()
                            .fill(isRunning ? skinAccent.opacity(0.16) : interfacePalette.controlFill.opacity(0.74))
                    )
                    .overlay(
                        Circle()
                            .stroke(isRunning ? skinAccent.opacity(0.4) : interfacePalette.hairline, lineWidth: 1)
                    )
            }
            .disabled(
                (!isRunning && controller.isRecording) ||
                    controller.activeTab?.isRunning != true ||
                    (!isRunning && controller.activeTab?.isPlayingShortcut == true) ||
                    shortcut.hasPendingProtectedInput
            )
            .buttonStyle(.plain)
            .focusable(false)
            .help(isRunning ? L10n.AgentTerminal.shortcutStopReplay : L10n.AgentTerminal.shortcutReplay)

            shortcutDetails(shortcut, playbackState: playbackState, now: now)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    editShortcut(shortcut)
                } label: {
                    Label(L10n.AgentTerminal.shortcutEdit, systemImage: "square.and.pencil")
                }
                .focusable(false)

                Button {
                    renameDraft = TerminalShortcutRenameDraft(shortcut: shortcut)
                } label: {
                    Label(L10n.AgentTerminal.shortcutRename, systemImage: "pencil")
                }
                .focusable(false)

                Divider()

                Button(role: .destructive) {
                    controller.deleteShortcut(id: shortcut.id)
                } label: {
                    Label(L10n.AgentTerminal.shortcutDelete, systemImage: "trash")
                }
                .focusable(false)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(interfacePalette.secondaryText)
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .focusable(false)
            .help(L10n.AgentTerminal.shortcutActions)
        }
        .frame(height: TerminalRecordingMetrics.historyRowHeight)
        .padding(.horizontal, TerminalRecordingMetrics.horizontalPadding)
        .background(playbackState?.isRunning == true ? skinAccent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .help(shortcutTooltip(shortcut, playbackState: playbackState, now: now))
    }

    @ViewBuilder
    private func shortcutDetails(
        _ shortcut: TerminalShortcut,
        playbackState: TerminalShortcutPlaybackState?,
        now: Date
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                shortcutTitle(shortcut)
                Spacer(minLength: 6)
                shortcutMetadata(shortcut, playbackState: playbackState, now: now)
            }

            VStack(alignment: .leading, spacing: 2) {
                shortcutTitle(shortcut)
                shortcutMetadata(shortcut, playbackState: playbackState, now: now)
            }
        }
    }

    private func shortcutTitle(_ shortcut: TerminalShortcut) -> some View {
        HStack(spacing: 5) {
            Text(shortcut.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(interfacePalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            if shortcut.hasProtectedInput {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(interfacePalette.secondaryText)
            }
        }
    }

    private func shortcutMetadata(
        _ shortcut: TerminalShortcut,
        playbackState: TerminalShortcutPlaybackState?,
        now: Date
    ) -> some View {
        HStack(spacing: 6) {
            Text(
                L10n.AgentTerminal.shortcutMeta(
                    formatShortcutDuration(shortcut.durationMilliseconds),
                    "\(shortcut.eventCount)"
                )
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(interfacePalette.secondaryText)
            .lineLimit(1)

            if let playbackState {
                shortcutStatus(playbackState, now: now)
            }
        }
    }

    private func shortcutStatus(_ playbackState: TerminalShortcutPlaybackState, now: Date) -> some View {
        let presentation = shortcutStatusPresentation(playbackState, now: now)
        return HStack(spacing: 4) {
            Image(systemName: presentation.icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(presentation.color)
            Text(presentation.text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(interfacePalette.secondaryText)
                .lineLimit(1)
        }
    }

    private func shortcutStatusPresentation(
        _ playbackState: TerminalShortcutPlaybackState,
        now: Date
    ) -> (icon: String, text: String, color: Color) {
        switch playbackState.status {
        case .running:
            let remaining = formatShortcutDuration(playbackState.remainingMilliseconds(now: now))
            let progress = L10n.AgentTerminal.shortcutProgress(
                "\(playbackState.currentEventIndex)",
                "\(playbackState.totalEvents)"
            )
            return ("play.circle.fill", "\(remaining) · \(progress)", skinAccent)
        case .finished:
            return ("checkmark.circle", L10n.AgentTerminal.shortcutFinished, .green)
        case .cancelled:
            return ("exclamationmark.circle", L10n.AgentTerminal.shortcutCancelled, .orange)
        }
    }

    private var shortcutHistoryHeight: CGFloat {
        let visibleRows = min(controller.shortcuts.count, TerminalRecordingMetrics.visibleHistoryRows)
        return CGFloat(visibleRows) * TerminalRecordingMetrics.historyRowHeight
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
        .background(interfacePalette.panelFill.opacity(0.72))
    }

    private func tabChip(_ tab: AgentTerminalTab) -> some View {
        let isActive = controller.activeTabID == tab.id
        let isBound = controller.isTab(tab.id, boundTo: appState.activeAgentSessionID)
        return HStack(spacing: 5) {
            Image(systemName: tab.kind.isSSH ? "network" : "terminal")
                .font(.system(size: 9))
                .foregroundStyle(tab.isRunning ? interfacePalette.accent : interfacePalette.secondaryText)
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? interfacePalette.primaryText : interfacePalette.secondaryText)
                // 标题封顶,避免 `rocky@host:/` 这种长 OSC 标题把
                // 整个 chip 撑得占满侧栏、把 `+` 顶出去。
                .frame(maxWidth: 130)
            if isBound {
                Image(systemName: "link")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(interfacePalette.accent)
            }
            Button {
                controller.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(tab.isAutomationBusy)
            .focusable(false)
            .foregroundStyle(interfacePalette.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? interfacePalette.selectionFill : interfacePalette.controlFill.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tabBorderColor(tab, isActive: isActive), lineWidth: 1)
        )
        .help(tabTooltip(tab))
        .contentShape(Rectangle())
        .onTapGesture {
            controller.activateTab(id: tab.id, bindingTo: appState.activeAgentSessionID)
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
            .focusable(false)
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
                    .focusable(false)
                }
            }
            Button {
                EditorSettingsNavigation.shared.open(.remoteRuntimes, appState: appState)
            } label: {
                Label(L10n.AgentTerminal.manageSSHHosts, systemImage: "gearshape")
            }
            .focusable(false)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help(L10n.AgentTerminal.newTab)
    }

    private var sessionIdentityBar: some View {
        HStack(spacing: 0) {
            if let tab = controller.activeTab {
                HStack(spacing: 6) {
                    Image(systemName: tab.kind.isSSH ? "network" : "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tab.isRunning ? interfacePalette.accent : interfacePalette.secondaryText)
                    Text(sessionKindLabel(tab))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(interfacePalette.primaryText)
                }
                .fixedSize()

                sessionIdentityDivider

                Text(sessionTargetLabel(tab))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(interfacePalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sessionDetailLabel(tab))

                Spacer(minLength: 8)

                sessionStatusPill(tab)

                if !tab.kind.isSSH {
                    sessionIdentityDivider
                    hostVerificationButton
                }
            } else {
                Text(L10n.AgentTerminal.disconnectedRuntime)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(interfacePalette.secondaryText)
                Spacer()
            }
        }
        .frame(height: SessionIdentityMetrics.barHeight)
        .padding(.horizontal, 10)
        .background(interfacePalette.panelFill.opacity(0.96))
    }

    private var sessionIdentityDivider: some View {
        Rectangle()
            .fill(interfacePalette.hairline)
            .frame(width: 1, height: SessionIdentityMetrics.dividerHeight)
            .padding(.horizontal, SessionIdentityMetrics.dividerPadding)
    }

    private func sessionStatusPill(_ tab: AgentTerminalTab) -> some View {
        let color = tab.isRunning ? interfacePalette.accent : interfacePalette.secondaryText
        return Text(tab.isRunning ? L10n.AgentTerminal.sessionRunning : L10n.AgentTerminal.sessionExited)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: SessionIdentityMetrics.controlHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.11))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            )
    }

    private var hostVerificationButton: some View {
        Button {
            hostnameCommandCopied = false
            showsHostVerificationPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "shield")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.AgentTerminal.sessionVerifyHost)
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(showsHostVerificationPopover ? 180 : 0))
            }
            .foregroundStyle(interfacePalette.secondaryAccent)
            .padding(.horizontal, 8)
            .frame(height: SessionIdentityMetrics.controlHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(interfacePalette.secondaryAccent.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(interfacePalette.secondaryAccent.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.AgentTerminal.localSessionCaution)
        .popover(isPresented: $showsHostVerificationPopover, arrowEdge: .bottom) {
            hostVerificationPopover
        }
    }

    private var hostVerificationPopover: some View {
        AgentHostVerificationPopover(
            hostnameCommandCopied: hostnameCommandCopied,
            palette: interfacePalette,
            copyAction: copyHostnameCommand
        )
    }

    private func copyHostnameCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SessionIdentityMetrics.hostnameCommand, forType: .string)
        hostnameCommandCopied = true
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
            controller.activateBoundTab(for: originAgentSessionID)
            controller.applyAppearanceToAll(terminalSettings, skin: colors)
        }
    }

    private func isOpenedByCurrentSession(_ tab: AgentTerminalTab) -> Bool {
        guard let origin = tab.originAgentSessionID,
              let active = appState.activeAgentSessionID else { return false }
        return origin == active
    }

    private func tabBorderColor(_ tab: AgentTerminalTab, isActive: Bool) -> Color {
        if isOpenedByCurrentSession(tab) {
            return interfacePalette.accent.opacity(0.55)
        }
        return isActive ? interfacePalette.hairline.opacity(0.92) : interfacePalette.hairline.opacity(0.56)
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
        return Self.shortcutDurationFormatter.string(from: TimeInterval(seconds))
            ?? L10n.AgentTerminal.shortcutDurationFallback("\(seconds)")
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

    private static let shortcutDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()
}

struct AgentHostVerificationPopover: View {
    let hostnameCommandCopied: Bool
    let palette: EditorInterfaceSkinPalette
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.secondaryAccent)
                Text(L10n.AgentTerminal.sessionVerifyHostTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }

            Text(L10n.AgentTerminal.localSessionCaution)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            Button(action: copyAction) {
                HStack(spacing: 7) {
                    Image(systemName: hostnameCommandCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        hostnameCommandCopied
                            ? L10n.AgentTerminal.sessionHostnameCommandCopied
                            : L10n.AgentTerminal.sessionCopyHostnameCommand
                    )
                    .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(14)
        .frame(width: SessionIdentityMetrics.popoverWidth)
        .background(palette.panelFill)
        .focusable(false)
    }
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
                    .focusable(false)
                Button(L10n.AgentTerminal.shortcutRenameSave) {
                    onSave(title)
                }
                .focusable(false)
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
