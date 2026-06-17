//
//  AgentChatHeader.swift
//  WillDeep
//
//  Title bar for the active agent session, split out of AgentModeView.swift
//  in rc42. Keeps the session title readable and exposes one right-aligned
//  escape hatch back to the editor.
//
//  Previously `private struct` inside the main file; now internal so
//  `AgentModeView`'s body can compose it across the file boundary.
//

import SwiftUI

struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

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

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return L10n.Header.newChat
        }
        return session.title
    }
}
