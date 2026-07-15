//
//  AgentChatHeader.swift
//  WillDeep
//
//  Title bar for the active agent session, split out of AgentModeView.swift
//  in rc42. Keeps the session title readable and exposes every available
//  side-panel shortcut without duplicating app-level navigation commands.
//

import SwiftUI
import AppKit

struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState
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
            desktopPetToggle
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
            ForEach(visibleKinds) { item in
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
