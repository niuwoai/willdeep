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
        .animation(.easeInOut(duration: 0.18), value: sessionsSidebarVisible)
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
                    Label(item.title, systemImage: item.systemImage)
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
            Image(systemName: "sidebar.right")
                .foregroundStyle(.secondary)
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
            switch kind {
            case .plan: return appState.agentCurrentPlan != nil
            default: return true
            }
        }
    }

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return L10n.Header.newChat
        }
        return session.title
    }
}
