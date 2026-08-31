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
    @ObservedObject private var detachedPanels = AgentDetachedPanelRegistry.shared
    @Binding var sidePanel: AgentSidePanelKind?
    @Binding var sessionsSidebarVisible: Bool
    @State private var isDesktopPetHovered = false

    /// When the session sidebar is hidden the chat column slides to the
    /// window's left edge, where the macOS traffic lights and their
    /// companion sidebar/search controls live. Pad the header title clear of
    /// that chrome; when the sidebar is visible it already reserves the band.
    private var leadingWindowChromeInset: CGFloat {
        sessionsSidebarVisible ? 0 : AgentWindowChromeControlLayout.hiddenSidebarHeaderLeadingInset
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dispatchContext {
                dispatchProjectBreadcrumb(dispatchContext)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 8)

            sidePanelShortcutStrip
            if dispatchContext == nil {
                desktopPetToggle
            }
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

    private var sidePanelShortcutStrip: some View {
        HStack(spacing: 6) {
            ForEach(visibleKinds) { item in
                sidePanelShortcutButton(for: item)
            }
            if !dispatchOverflowKinds.isEmpty {
                dispatchMoreToolsMenu
            }
        }
        .fixedSize()
    }

    private func dispatchProjectBreadcrumb(_ context: DispatchContext) -> some View {
        Button {
            appState.openDispatchProject(
                goalID: context.goal.id,
                taskID: context.task.id
            )
        } label: {
            Label(
                L10n.Dispatch.taskConversationProjectBreadcrumb(context.goal.statement),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 280)
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
        .help(L10n.Dispatch.returnToDispatchBoard)
    }

    private func sidePanelShortcutButton(for item: AgentSidePanelKind) -> some View {
        // A detached panel is still an active tool surface. Keep its shortcut
        // highlighted just like the desktop-pet button remains highlighted
        // while its independent window is enabled.
        let isSelected = sidePanel == item || appState.activeRuntime?.sidePanelState.openTabs.contains(where: { $0.kind == item }) == true
        return AgentSidePanelShortcutControl(
            systemImage: item.systemImage,
            title: sidePanelTitle(for: item),
            isSelected: isSelected,
            selectedColor: .black,
            hoverColor: NSColor.labelColor.withAlphaComponent(0.72),
            normalColor: .secondaryLabelColor
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
                ? Color.black
                : (isDesktopPetHovered ? Color.primary.opacity(0.72) : Color.secondary)
        )
        .onHover { isDesktopPetHovered = $0 }
        .help(L10n.DesktopPet.toggleHelp)
        .accessibilityLabel(Text(L10n.DesktopPet.toggleHelp))
    }

    private var dispatchMoreToolsMenu: some View {
        Menu {
            ForEach(dispatchOverflowKinds) { kind in
                Button {
                    toggleSidePanel(kind)
                } label: {
                    Label(sidePanelTitle(for: kind), systemImage: kind.systemImage)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .agentQuietMenuChrome()
        .fixedSize()
        .help(L10n.Dispatch.moreTaskTools)
    }

    /// Plan 一项只在 active runtime 真的有 plan 时出现 — 没有 plan
    /// 还展示这个入口是浪费一行 + 误导用户。后台任务入口必须始终
    /// 可见：空列表也是有效状态，用户需要能从这里确认当前没有任务。
    private var visibleKinds: [AgentSidePanelKind] {
        if dispatchContext != nil {
            return AgentDispatchTaskToolPolicy.primaryKinds(
                hasPlan: appState.agentCurrentPlan != nil,
                activeExperts: appState.agentActiveExperts
            )
        }
        return AgentSidePanelKind.allCases.filter { kind in
            guard kind.isAvailable(activeExperts: appState.agentActiveExperts) else { return false }
            switch kind {
            case .plan: return appState.agentCurrentPlan != nil
            default: return true
            }
        }
    }

    private var dispatchOverflowKinds: [AgentSidePanelKind] {
        guard dispatchContext != nil else { return [] }
        return AgentDispatchTaskToolPolicy.overflowKinds(
            activeExperts: appState.agentActiveExperts
        )
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
        // Every side panel belongs to a session. Opening one from a cold
        // Agent window should create an unbound draft instead of rendering
        // against nil state and making the click appear to do nothing.
        appState.ensureActiveAgentSessionForInteractiveControl()
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: item)
    }

    private var title: String {
        guard let activeSession else {
            return L10n.Header.newChat
        }
        return activeSession.title
    }

    private var activeSession: AgentSession? {
        guard let id = appState.activeAgentSessionID else { return nil }
        return appState.agentSessions.first(where: { $0.id == id })
    }

    private var dispatchContext: DispatchContext? {
        guard let session = activeSession,
              let goalID = session.dispatchParentProjectID,
              let taskID = session.dispatchTaskID,
              let goal = appState.agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID }) else {
            return nil
        }
        return DispatchContext(goal: goal, task: task)
    }

    private struct DispatchContext: Equatable {
        let goal: AgentDispatchGoal
        let task: AgentDispatchTask
    }
}

private struct AgentSidePanelShortcutControl: NSViewRepresentable {
    let systemImage: String
    let title: String
    let isSelected: Bool
    let selectedColor: NSColor
    let hoverColor: NSColor
    let normalColor: NSColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> AgentSidePanelHoverButton {
        let button = AgentSidePanelHoverButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.onHoverChange = { [weak coordinator = context.coordinator] isHovered in
            coordinator?.isHovered = isHovered
            coordinator?.refresh?()
        }
        context.coordinator.refresh = { [weak button] in
            guard let button else { return }
            configure(button, isHovered: context.coordinator.isHovered)
        }
        configure(button, isHovered: false)
        return button
    }

    func updateNSView(_ button: AgentSidePanelHoverButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.refresh = { [weak button, weak coordinator = context.coordinator] in
            guard let button, let coordinator else { return }
            configure(button, isHovered: coordinator.isHovered)
        }
        configure(button, isHovered: context.coordinator.isHovered)
    }

    private func configure(_ button: NSButton, isHovered: Bool) {
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: weight)
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)
        button.contentTintColor = isSelected ? selectedColor : (isHovered ? hoverColor : normalColor)
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var isHovered = false
        var refresh: (() -> Void)?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

private final class AgentSidePanelHoverButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
