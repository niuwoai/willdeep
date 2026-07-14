//
//  AgentChatHeader.swift
//  WillDeep
//
//  Title bar for the active agent session, split out of AgentModeView.swift
//  in rc42. Keeps the session title readable and exposes two right-aligned
//  escape hatches: a side-panel `Menu` (rc21+) and the original
//  「raise editor window」button.
//

import SwiftUI
import AppKit

struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var desktopPet = DesktopPetWindowManager.shared
    @Binding var sidePanel: AgentSidePanelKind?
    @Binding var sessionsSidebarVisible: Bool
    @Binding var isSessionSearchPresented: Bool

    /// When the session sidebar is hidden the chat column slides to the
    /// window's left edge, where the macOS traffic lights and their
    /// companion sidebar toggle live. Pad the header so search/title
    /// content clears that chrome; when the sidebar is visible it already
    /// reserves that band, so 0.
    private var leadingWindowChromeInset: CGFloat {
        sessionsSidebarVisible ? 0 : 104
    }

    var body: some View {
        HStack(spacing: 8) {
            sessionSearchButton

            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            sidePanelShortcutStrip
            sidePanelMenu
            desktopPetToggle
            editorModeSeparator

            Button {
                // 1.80.0-rc1：editor / agent 已经分窗口，这个按钮的
                // 语义从「切回 editor 模式」变成「把对应的 editor
                // 窗口抬到前台」。当前 AppState（agent 窗口跟随的）
                // 对应的 editor NSWindow 由 EditorAppStateRegistry
                // 跟踪。若 editor 窗口此前已关闭,则重新打开主窗口。
                if !appState.showEditor() {
                    openWindow(id: EditorWindowID.value)
                }
            } label: {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(appState.editorSettings.interfaceSkin.palette.accent.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(appState.editorSettings.interfaceSkin.palette.accent.opacity(0.34), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
            .help(L10n.Header.switchToEditor)
        }
        .padding(.leading, 18 + leadingWindowChromeInset)
        .padding(.trailing, 18)
        .frame(height: AgentDesign.headerHeight)
        .background(
            appState.editorSettings.interfaceSkin.palette.panelFill
                .opacity(0.72)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(appState.editorSettings.interfaceSkin.palette.hairline.opacity(0.55))
                        .frame(height: 1)
                }
        )
    }

    private var sessionSearchButton: some View {
        Button {
            isSessionSearchPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.Header.searchSessions)
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private var sidePanelShortcutStrip: some View {
        HStack(spacing: 6) {
            ForEach(frequentSidePanelKinds) { item in
                sidePanelShortcutButton(for: item)
            }
        }
        .fixedSize()
    }

    private func sidePanelShortcutButton(for item: AgentSidePanelKind) -> some View {
        let isSelected = sidePanel == item
        let palette = appState.editorSettings.interfaceSkin.palette
        return AgentSidePanelShortcutControl(
            systemImage: item.systemImage,
            title: sidePanelTitle(for: item),
            isSelected: isSelected,
            selectedColor: NSColor(palette.accent),
            normalColor: NSColor(palette.secondaryText)
        ) {
            toggleSidePanel(item)
        }
        .frame(width: 28, height: 24)
    }

    private var sidePanelMenu: some View {
        Menu {
            ForEach(sidePanelMenuKinds) { item in
                Button {
                    toggleSidePanel(item)
                } label: {
                    Label(sidePanelTitle(for: item), systemImage: item.systemImage)
                }
            }
            if sidePanel != nil {
                Divider()
                Button {
                    sidePanel = nil
                } label: {
                    Label(L10n.AgentSidePanel.close, systemImage: "xmark")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                if let badge = mediaTaskMenuBadge {
                    Text(badge.text)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(badge.color))
                        .offset(x: 7, y: -7)
                        .accessibilityLabel(badge.accessibilityLabel)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help(L10n.Header.openSidePanel)
    }

    private var editorModeSeparator: some View {
        Rectangle()
            .fill(appState.editorSettings.interfaceSkin.palette.hairline.opacity(0.9))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var desktopPetToggle: some View {
        Button {
            desktopPet.attach(to: appState)
            desktopPet.toggle()
        } label: {
            Image(systemName: desktopPet.isEnabled ? "pawprint.fill" : "pawprint")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(
            desktopPet.isEnabled
                ? appState.editorSettings.interfaceSkin.palette.accent
                : appState.editorSettings.interfaceSkin.palette.secondaryText
        )
        .help(L10n.DesktopPet.toggleHelp)
        .accessibilityLabel(Text(L10n.DesktopPet.toggleHelp))
    }

    private var frequentSidePanelKinds: [AgentSidePanelKind] {
        [.diff, .terminal, .devServer, .preview, .files].filter { kind in
            visibleKinds.contains(kind)
        }
    }

    private var sidePanelMenuKinds: [AgentSidePanelKind] {
        visibleKinds.filter { kind in
            !frequentSidePanelKinds.contains(kind)
        }
    }

    /// Plan 一项只在 active runtime 真的有 plan 时出现 — 没有 plan
    /// 还展示这个入口是浪费一行 + 误导用户。其它项始终可见。
    private var visibleKinds: [AgentSidePanelKind] {
        AgentSidePanelKind.allCases.filter { kind in
            guard kind.isAvailable(activeExperts: appState.agentActiveExperts) else { return false }
            switch kind {
            case .plan: return appState.agentCurrentPlan != nil
            default: return true
            }
        }
    }

    private var visibleMediaTasks: [AgentMediaTask] {
        appState.agentMediaTaskRegistry.tasks(forRuntime: appState.activeRuntime?.id)
    }

    private var mediaTaskCounts: (active: Int, failed: Int) {
        let tasks = visibleMediaTasks
        return (
            active: tasks.filter(\.isActive).count,
            failed: tasks.filter(\.needsAttention).count
        )
    }

    private var staleMediaTaskCount: Int {
        visibleMediaTasks.filter { $0.isStaleActive() }.count
    }

    private var mediaTaskMenuBadge: (text: String, color: Color, accessibilityLabel: String)? {
        let counts = mediaTaskCounts
        if counts.failed > 0 {
            return (
                text: clippedBadgeCount(counts.failed),
                color: .red,
                accessibilityLabel: "\(counts.failed) 个媒体任务需要处理"
            )
        }
        let stale = staleMediaTaskCount
        if stale > 0 {
            return (
                text: clippedBadgeCount(stale),
                color: .orange,
                accessibilityLabel: "\(stale) 个媒体任务长时间未更新"
            )
        }
        if counts.active > 0 {
            return (
                text: clippedBadgeCount(counts.active),
                color: .accentColor,
                accessibilityLabel: "\(counts.active) 个媒体任务运行中"
            )
        }
        return nil
    }

    private func sidePanelTitle(for kind: AgentSidePanelKind) -> String {
        guard kind == .mediaTasks else { return kind.title }
        let counts = mediaTaskCounts
        if counts.failed > 0 {
            return "\(kind.title) · \(counts.failed) 需处理"
        }
        let stale = staleMediaTaskCount
        if stale > 0 {
            return "\(kind.title) · \(stale) 卡住"
        }
        if counts.active > 0 {
            return "\(kind.title) · \(counts.active) 运行中"
        }
        return kind.title
    }

    private func toggleSidePanel(_ item: AgentSidePanelKind) {
        if sidePanel == item {
            sidePanel = nil
            return
        }
        sidePanel = item
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: item)
    }

    private func clippedBadgeCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return L10n.Header.newChat
        }
        return session.title
    }
}

private struct AgentSidePanelShortcutControl: NSViewRepresentable {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let selectedColor: NSColor
    let normalColor: NSColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: NSButton) {
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: weight)
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)
        button.contentTintColor = isSelected ? selectedColor : normalColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}
