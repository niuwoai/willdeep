//
//  AgentChatHeader.swift
//  VeilWriter
//
//  Title bar for the active agent session, split out of AgentModeView.swift
//  in rc42. Three pieces sit in one row at the top of the chat pane:
//  the session title (single-line, middle-truncated) with a copy-title
//  glyph next to it, plus a right-aligned action cluster — new chat
//  and "switch to editor" — that bridges back to the rest of the app.
//
//  Previously `private struct` inside the main file; now internal so
//  `AgentModeView`'s body can compose it across the file boundary.
//

import AppKit
import SwiftUI

struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                copyTitle()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.Header.copyTitle)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    appState.startNewAgentSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.Header.newChat)

                Button {
                    appState.setAppMode(.editor)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.Header.switchToEditor)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.headerHeight)
    }

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return "New Chat"
        }
        return session.title
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }
}
