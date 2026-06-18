//
//  AgentModeView.swift
//  WillDeep
//
//  Top-level Agent mode. Layout inspired by Cursor: a project-grouped
//  session sidebar on the left, a chat pane on the right, and a thin
//  status bar at the bottom of the chat pane.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentModeView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 230
    @State private var sidePanel: AgentSidePanelKind?

    var body: some View {
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                .background(
                    AgentDesign.sidebarBackground
                        .overlay(AgentDesign.sidebarTint)
                )

            Divider()

            VStack(spacing: 0) {
                AgentChatHeader(sidePanel: $sidePanel)
                Divider().opacity(0.5)
                AgentChatTranscript()
                AgentChatComposer()
                AgentChatStatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentDesign.chatBackground)

            if sidePanel != nil {
                Divider()
                AgentSidePanelHost(kind: $sidePanel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(AgentDesign.chatBackground)
        .animation(.easeInOut(duration: 0.18), value: sidePanel)
    }
}

// MARK: - Design tokens
//
// Centralized so the next time we want to tweak spacing/colors, it's all
// in one place. Uses macOS semantic colors so the look follows system
// appearance (light / dark) automatically.

enum AgentDesign {
    // Backgrounds — semantic so light/dark adapt for free. Earlier
    // revisions used `underPageBackgroundColor` for the sidebar and the
    // status bar; on light appearance that paints a fairly dark grey
    // band that fights with the white chat area. Now everything sits on
    // a single `windowBackgroundColor` plane, separated by dividers and
    // very light overlays so the eye reads it as one calm canvas.
    static let chatBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let statusBarBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    /// Very faint tint to set the sidebar apart from the chat without
    /// the heavy grey of `underPageBackgroundColor`.
    static let sidebarTint = Color(nsColor: .labelColor).opacity(0.025)

    // Corner radii.
    static let cardCornerRadius: CGFloat = 8
    static let pillCornerRadius: CGFloat = 6
    static let inputCornerRadius: CGFloat = 10

    // Paddings & sizes.
    static let chatMaxContentWidth: CGFloat = 1040
    static let userMessageMaxWidthRatio: CGFloat = 0.82
    static let messageVerticalSpacing: CGFloat = 18
    static let composerHeight: CGFloat = 124
    static let headerHeight: CGFloat = 42
    static let statusBarHeight: CGFloat = 26
    static let sidebarRowHeight: CGFloat = 26

    // Typography.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let secondaryFont = Font.system(size: 11)
    static let captionFont = Font.system(size: 10)
    static let sidebarSectionFont = Font.system(size: 11, weight: .semibold)
    static let sidebarRowFont = Font.system(size: 12)
}


