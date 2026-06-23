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
    /// 共享给 Files 和 Preview 两个子面板:Files 里点击 markdown/html
    /// 时写入,Preview 直接读它 render。lift 到 AgentModeView 是因为
    /// 同一时间只有一个面板挂着,Files 切到 Preview 时子 view 会被
    /// 拆掉,@State 留在父 view 才能跨面板保活。
    @State private var sidePanelFile: URL?

    var body: some View {
        let skin = appState.editorSettings.interfaceSkin
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                .background(
                    skin.sidebarBackground
                        .overlay(skin.palette.hoverFill.opacity(0.35))
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
            .background(skin.windowBackground)

            Divider()
            if sidePanel != nil {
                AgentSidePanelHost(kind: $sidePanel, selectedFile: $sidePanelFile)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                AgentTaskMonitorRail()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(skin.windowBackground)
        .animation(.easeInOut(duration: 0.18), value: sidePanel)
    }
}

// MARK: - Design tokens
//
// Centralized so the next time we want to tweak spacing/colors, it's all
// in one place. Uses macOS semantic colors so the look follows system
// appearance (light / dark) automatically.

enum AgentDesign {
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
    static let sidebarTodoRowHeight: CGFloat = 42

    // Typography.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let secondaryFont = Font.system(size: 11)
    static let captionFont = Font.system(size: 10)
    static let sidebarSectionFont = Font.system(size: 11, weight: .semibold)
    static let sidebarRowFont = Font.system(size: 12)
}
