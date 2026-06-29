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

struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Binding var sidePanel: AgentSidePanelKind?
    @Binding var sessionsSidebarVisible: Bool
    @Binding var isSessionSearchPresented: Bool

    /// When the session sidebar is hidden the chat column slides to the
    /// window's left edge, where the macOS traffic lights float over the
    /// first ~72pt. Pad the header so our leading icons clear them; when
    /// the sidebar is visible it already reserves that space, so 0.
    private var leadingTrafficLightInset: CGFloat {
        sessionsSidebarVisible ? 0 : 72
    }

    var body: some View {
        HStack(spacing: 8) {
            sidebarToggle

            sessionSearchButton

            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            sidePanelMenu

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
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help(L10n.Header.switchToEditor)
        }
        .padding(.leading, 18 + leadingTrafficLightInset)
        .padding(.trailing, 18)
        .frame(height: AgentDesign.headerHeight)
    }

    private var sidebarToggle: some View {
        Button {
            sessionsSidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(sessionsSidebarVisible ? L10n.Header.hideSidebar : L10n.Header.showSidebar)
        .keyboardShortcut("\\", modifiers: .command)
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

    private var sidePanelMenu: some View {
        Menu {
            ForEach(visibleKinds) { item in
                Button {
                    // 再点同一项就关闭——和 Claude Code 那个菜单一致。
                    sidePanel = (sidePanel == item) ? nil : item
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
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
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
