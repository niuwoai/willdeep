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
}

/// 侧边终端标签条的中性配色层次。标签条是常驻 chrome,不该用强调色长期
/// 抢注意力;「运行中 / 选中 / 本会话打开 / 带快捷方式」这些状态改由中性灰
/// 的深浅拉开层次,与错误横幅、委派进度条的灰度改造同一套思路。
private enum TerminalTabChrome {
    static let runningIconOpacity: Double = 0.78
    static let idleIconOpacity: Double = 0.62
    static let activeFillOpacity: Double = 0.10
    static let ownedBorderOpacity: Double = 0.30
    static let badgeActiveTextOpacity: Double = 0.85
    static let badgeActiveFillOpacity: Double = 0.12
    static let badgeIdleFillOpacity: Double = 0.06
    static let badgeActiveStrokeOpacity: Double = 0.24
    static let badgeIdleStrokeOpacity: Double = 0.13
}

enum TerminalRecordingMetrics {
    static let controlRowHeight: CGFloat = 42
    static let recordButtonHeight: CGFloat = 28
    static let historyHeaderHeight: CGFloat = 26
    static let historyRowHeight: CGFloat = 28
    static let emptyHistoryHeight: CGFloat = 34
    static let visibleHistoryRows = 3
    static let playButtonSize: CGFloat = 22
    static let shortcutItemSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
}

struct AgentSidePanelTerminalView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }

    var body: some View {
        AgentSidePanelTerminalContentView(controller: appState.agentTerminalController)
    }
}

private struct AgentSidePanelTerminalContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: AgentInteractiveTerminalController
    @State private var renameDraft: TerminalShortcutRenameDraft?
    @State private var bootstrapTask: Task<Void, Never>?
    @State private var showsHostIdentityPopover = false

    private var settings: EditorTerminalSettings {
        appState.editorTerminalSettings.normalized()
    }

    private var skinColors: TerminalSkinColors? {
        settings.followsInterfaceSkin
            ? .from(skin: appState.editorSettings.interfaceSkin)
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

    /// The workbench's outer tab is now the only terminal tab controller.
    /// A legacy tab without a resource id falls back once during migration.
    private var scopedTerminalTabID: UUID? {
        guard let runtime = panelScope.runtime, let panelTabID = panelScope.tabID else { return nil }
        return runtime.sidePanelState.openTabs.first(where: { $0.id == panelTabID })?.resourceID
    }

    private var currentTab: AgentTerminalTab? {
        if let scopedTerminalTabID { return controller.tab(id: scopedTerminalTabID) }
        return controller.activeTab
    }

    var body: some View {
        VStack(spacing: 0) {
            shortcutsBar
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
            if let scopedTerminalTabID {
                controller.activateTab(id: scopedTerminalTabID)
            }
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
        .onCompatibleChange(of: panelScope.sessionID) { _, _ in
            scheduleTerminalBootstrap()
        }
        .onCompatibleChange(of: controller.activeTabID) { _, _ in
            showsHostIdentityPopover = false
        }
    }

    // MARK: Recording bar

    private var shortcutsBar: some View {
        VStack(spacing: 0) {
            recordingControlRow

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
                            ForEach(controller.shortcuts) { shortcut in
                                shortcutControl(shortcut)

                                if shortcut.id != controller.shortcuts.last?.id {
                                    Divider()
                                        .padding(
                                            .leading,
                                            TerminalRecordingMetrics.horizontalPadding
                                                + TerminalRecordingMetrics.playButtonSize
                                                + TerminalRecordingMetrics.shortcutItemSpacing
                                        )
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

    private var recordingControlRow: some View {
        HStack(spacing: 10) {
            recordButton
                .layoutPriority(1)

            if controller.isRecording {
                recordingStatus
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
        // Never disabled while idle: starting a recording with no usable
        // tab opens (or activates) a local shell tab automatically.
        .help(controller.isRecording ? L10n.AgentTerminal.stopRecording : L10n.AgentTerminal.startRecording)
    }

    private var recordingStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            recordingStatusContent(now: timeline.date)
        }
    }

    private func recordingStatusContent(now: Date) -> some View {
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

    private func shortcutControl(_ shortcut: TerminalShortcut) -> some View {
        let playbackState = playbackState(for: shortcut)
        let isRunning = playbackState?.isRunning == true
        return HStack(spacing: TerminalRecordingMetrics.shortcutItemSpacing) {
            Button {
                if isRunning {
                    controller.cancelActiveShortcutPlayback()
                } else {
                    controller.playShortcut(shortcut)
                }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isRunning ? skinAccent : interfacePalette.primaryText)
                    .frame(
                        width: TerminalRecordingMetrics.playButtonSize,
                        height: TerminalRecordingMetrics.playButtonSize
                    )
                    .contentShape(Rectangle())
            }
            .disabled(
                (!isRunning && controller.isRecording) ||
                    currentTab?.isRunning != true ||
                    (!isRunning && currentTab?.inputState == .foregroundTask) ||
                    (!isRunning && currentTab?.isPlayingShortcut == true) ||
                    shortcut.hasPendingProtectedInput
            )
            .buttonStyle(.plain)
            .focusable(false)
            .help(isRunning ? L10n.AgentTerminal.shortcutStopReplay : L10n.AgentTerminal.shortcutReplay)

            shortcutDetails(shortcut, playbackState: playbackState)
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

                Button {
                    controller.cloneShortcut(
                        id: shortcut.id,
                        title: L10n.AgentTerminal.shortcutCopyTitle(shortcut.title)
                    )
                } label: {
                    Label(L10n.AgentTerminal.shortcutClone, systemImage: "plus.square.on.square")
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
            .agentQuietMenuChrome(interfacePalette.secondaryText)
            .focusable(false)
            .help(L10n.AgentTerminal.shortcutActions)
        }
        .frame(height: TerminalRecordingMetrics.historyRowHeight)
        .padding(.horizontal, TerminalRecordingMetrics.horizontalPadding)
        .background(playbackState?.isRunning == true ? skinAccent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .help(shortcutTooltip(shortcut, playbackState: playbackState, now: .now))
    }

    @ViewBuilder
    private func shortcutDetails(
        _ shortcut: TerminalShortcut,
        playbackState: TerminalShortcutPlaybackState?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                shortcutTitle(shortcut)
                Spacer(minLength: 6)
                shortcutMetadata(shortcut, playbackState: playbackState)
            }

            VStack(alignment: .leading, spacing: 2) {
                shortcutTitle(shortcut)
                shortcutMetadata(shortcut, playbackState: playbackState)
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
        playbackState: TerminalShortcutPlaybackState?
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
                shortcutStatus(playbackState)
            }
        }
    }

    @ViewBuilder
    private func shortcutStatus(_ playbackState: TerminalShortcutPlaybackState) -> some View {
        if playbackState.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                shortcutStatusContent(playbackState, now: timeline.date)
            }
        } else {
            shortcutStatusContent(playbackState, now: .now)
        }
    }

    private func shortcutStatusContent(
        _ playbackState: TerminalShortcutPlaybackState,
        now: Date
    ) -> some View {
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
        openWindow(value: TerminalShortcutEditorRequest(shortcutID: shortcut.id))
    }

    private func shortcutBadge(_ title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(
                isActive
                    ? interfacePalette.primaryText.opacity(TerminalTabChrome.badgeActiveTextOpacity)
                    : interfacePalette.secondaryText
            )
            .padding(.horizontal, 5)
            .frame(maxWidth: 74)
            .frame(height: 15)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        interfacePalette.primaryText.opacity(
                            isActive
                                ? TerminalTabChrome.badgeActiveFillOpacity
                                : TerminalTabChrome.badgeIdleFillOpacity
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        interfacePalette.primaryText.opacity(
                            isActive
                                ? TerminalTabChrome.badgeActiveStrokeOpacity
                                : TerminalTabChrome.badgeIdleStrokeOpacity
                        ),
                        lineWidth: 1
                    )
            )
    }

    private var sessionIdentityBar: some View {
        HStack(spacing: 0) {
            if let tab = currentTab {
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

                sessionIdentityDivider
                hostIdentityButton(tab)
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

    @ViewBuilder
    private func sessionStatusPill(_ tab: AgentTerminalTab) -> some View {
        if tab.isRunning {
            Menu {
                Button {
                    controller.sendUserControl(.ctrlC, toTabID: tab.id)
                } label: {
                    Label(L10n.AgentTerminal.sessionInterrupt, systemImage: "command")
                }
                .disabled(tab.isAutomationBusy)
                Button {
                    controller.sendUserControl(.ctrlRightBracket, toTabID: tab.id)
                } label: {
                    Label(L10n.AgentTerminal.sessionTelnetEscape, systemImage: "escape")
                }
                .disabled(tab.isAutomationBusy)
                Button {
                    controller.sendUserControl(.ctrlD, toTabID: tab.id)
                } label: {
                    Label(L10n.AgentTerminal.sessionSendEOF, systemImage: "text.append")
                }
                .disabled(tab.isAutomationBusy)
                Divider()
                Button(role: .destructive) {
                    controller.stopTab(id: tab.id)
                } label: {
                    Label(L10n.AgentTerminal.sessionStop, systemImage: "stop.fill")
                }
                .disabled(tab.isAutomationBusy)
                if tab.isAutomationBusy {
                    Text(L10n.AgentTerminal.sessionAutomationBusy)
                }
            } label: {
                sessionStatusLabel(tab)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help(L10n.AgentTerminal.sessionControlsHelp)
        } else {
            sessionStatusLabel(tab)
        }
    }

    private func sessionStatusLabel(_ tab: AgentTerminalTab) -> some View {
        let label: String
        let color: Color
        switch tab.inputState {
        case .starting:
            label = L10n.AgentTerminal.sessionStarting
            color = interfacePalette.secondaryText
        case .shellReady:
            label = tab.kind.isSSH
                ? L10n.AgentTerminal.sessionInteractiveProgram
                : L10n.AgentTerminal.sessionShellReady
            color = interfacePalette.accent
        case .foregroundTask:
            label = L10n.AgentTerminal.sessionForegroundTask
            color = .orange
        case .interactiveProgram:
            label = L10n.AgentTerminal.sessionInteractiveProgram
            color = interfacePalette.accent
        case .unknown:
            label = tab.isRunning ? L10n.AgentTerminal.sessionRunning : L10n.AgentTerminal.sessionExited
            color = tab.isRunning ? interfacePalette.accent : interfacePalette.secondaryText
        case .exited:
            label = L10n.AgentTerminal.sessionExited
            color = interfacePalette.secondaryText
        }
        return HStack(spacing: 4) {
            Text(label)
            if tab.isRunning {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
        }
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

    private func hostIdentityButton(_ tab: AgentTerminalTab) -> some View {
        Button {
            showsHostIdentityPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "shield")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.AgentTerminal.sessionExtractHostIdentity)
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(showsHostIdentityPopover ? 180 : 0))
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
        .help(L10n.AgentTerminal.sessionHostIdentityHint)
        .popover(isPresented: $showsHostIdentityPopover, arrowEdge: .bottom) {
            AgentHostIdentityPopover(tab: tab, palette: interfacePalette)
        }
    }

    // MARK: Terminal surface

    @ViewBuilder
    private var terminalSurface: some View {
        if let tab = currentTab {
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
        if let path = panelScope.runtime?.workspaceRootPath, !path.isEmpty {
            return path
        }
        return panelScope.workspaceRoot?.path
    }

    private func scheduleTerminalBootstrap() {
        bootstrapTask?.cancel()
        let originAgentSessionID = panelScope.sessionID
        let directory = workingDirectory
        let terminalSettings = settings
        let colors = skinColors
        bootstrapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            if let scopedTerminalTabID, controller.tab(id: scopedTerminalTabID) != nil {
                controller.activateTab(id: scopedTerminalTabID)
                controller.applyAppearanceToAll(terminalSettings, skin: colors)
                return
            }
            let terminal = controller.openLocalTab(
                originAgentSessionID: originAgentSessionID,
                workingDirectory: directory,
                settings: terminalSettings,
                skin: colors
            )
            guard let runtime = panelScope.runtime,
                  let panelTabID = panelScope.tabID else { return }
            appState.updatePanelTabs(runtime: runtime) {
                $0.updateTabResource(terminal.id, title: terminal.title, tabID: panelTabID)
            }
        }
    }

    private func isOpenedByCurrentSession(_ tab: AgentTerminalTab) -> Bool {
        guard let origin = tab.originAgentSessionID,
              let active = panelScope.sessionID else { return false }
        return origin == active
    }

    private func tabBorderColor(_ tab: AgentTerminalTab, isActive: Bool) -> Color {
        if isOpenedByCurrentSession(tab) {
            return interfacePalette.primaryText.opacity(TerminalTabChrome.ownedBorderOpacity)
        }
        return isActive ? interfacePalette.hairline.opacity(0.92) : interfacePalette.hairline.opacity(0.56)
    }

    private func tabTooltip(_ tab: AgentTerminalTab) -> String {
        var lines = [tab.title]
        switch tab.kind {
        case .localShell:
            lines.append(L10n.AgentTerminal.localShellTooltip)
        case .delegatedShell:
            lines.append(L10n.AgentTerminal.delegatedShellTooltip)
        case .ssh(_, _, let target):
            lines.append(target)
        }
        if isOpenedByCurrentSession(tab) {
            lines.append(L10n.AgentTerminal.openedByThisSession)
        }
        if let shortcutBadgeTitle = tab.shortcutBadgeTitle {
            lines.append(L10n.AgentTerminal.shortcutBadgeTooltip(shortcutBadgeTitle))
        }
        return lines.joined(separator: " · ")
    }

    private func sessionKindLabel(_ tab: AgentTerminalTab) -> String {
        switch tab.kind {
        case .localShell: return L10n.AgentTerminal.sessionLocal
        case .delegatedShell: return L10n.AgentTerminal.sessionDelegated
        case .ssh: return L10n.AgentTerminal.sessionSSH
        }
    }

    private func sessionTargetLabel(_ tab: AgentTerminalTab) -> String {
        switch tab.kind {
        case .localShell:
            return tab.title
        case .delegatedShell:
            return "/bin/sh"
        case .ssh(_, let displayName, let target):
            return displayName.isEmpty ? target : displayName
        }
    }

    private func sessionDetailLabel(_ tab: AgentTerminalTab) -> String {
        switch tab.kind {
        case .localShell:
            return L10n.AgentTerminal.localSessionCaution
        case .delegatedShell:
            return L10n.AgentTerminal.delegatedShellTooltip
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

struct AgentHostIdentityPopover: View {
    @ObservedObject var tab: AgentTerminalTab
    let palette: EditorInterfaceSkinPalette

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

            Text(L10n.AgentTerminal.sessionHostIdentityHint)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let identity = tab.hostIdentity {
                VStack(alignment: .leading, spacing: 6) {
                    identityRow(L10n.AgentTerminal.sessionHostIdentityHostname, identity.hostname)
                    identityRow(L10n.AgentTerminal.sessionHostIdentityIP, identity.ipAddress)
                    identityRow(L10n.AgentTerminal.sessionHostIdentityOS, identity.operatingSystem)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.controlFill.opacity(0.6))
                )
            }

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            Button {
                tab.extractHostIdentity()
            } label: {
                HStack(spacing: 7) {
                    if tab.isExtractingHostIdentity {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(
                        tab.isExtractingHostIdentity
                            ? L10n.AgentTerminal.sessionExtractingHostIdentity
                            : L10n.AgentTerminal.sessionExtractHostIdentity
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
            .disabled(!tab.canExtractHostIdentity)
        }
        .padding(14)
        .frame(width: SessionIdentityMetrics.popoverWidth)
        .background(palette.panelFill)
        .focusable(false)
    }

    private func identityRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 64, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.primaryText)
                .textSelection(.enabled)
                .lineLimit(2)
        }
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
        // Deliberately empty. This used to force a refresh on every SwiftUI
        // render pass. Parent state changes could therefore force the terminal
        // through layout repeatedly. Combined with the un-debounced resize →
        // SIGWINCH chain, a layout that wobbled across a cell-height boundary
        // made the remote shell redraw its prompt mid-screen and bake
        // mixed-generation rows into the buffer. Mount-time refresh
        // (makeNSView above + viewDidMoveToWindow) is sufficient; data arrival
        // already schedules its own display pass.
    }
}
