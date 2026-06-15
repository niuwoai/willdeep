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
                appState.setAppMode(.editor)
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
