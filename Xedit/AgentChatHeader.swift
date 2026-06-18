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
    @Binding var sidePanel: AgentSidePanelKind?

    var body: some View {
        HStack(spacing: 8) {
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
                // 跟踪。
                EditorAppStateRegistry.shared.focusCurrentEditorWindow()
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(.secondary)
            .help(L10n.Header.switchToEditor)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.headerHeight)
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
