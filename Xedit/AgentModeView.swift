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
    @State private var lastTaskMonitorSnapshot: AgentTaskMonitorSnapshot?
    @State private var didObserveAgentTaskMonitorActivity = false
    /// User-resizable width of the right side panel. Persisted so the
    /// choice survives relaunch. The leftmost sessions sidebar stays
    /// fixed; only the chat ↔ side-panel boundary is draggable.
    @AppStorage("agentSidePanelWidth") private var sidePanelWidth: Double = 320
    private let sidePanelWidthRange: ClosedRange<Double> = 240...760

    var body: some View {
        let skin = appState.editorSettings.interfaceSkin
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                // `.frame(width:)` 是 SwiftUI 的「建议」宽度,父 HStack
                // 在窗口宽度不够时仍会把它继续压缩。`.fixedSize(...)`
                // 把宽度锁死为 sidebarWidth(230),收窄窗口只会从 chat
                // 区域吃掉空间,不会再动 sidebar —— rc12 用户反馈:
                // 「最左栏还是会被缩小,要不就固定个宽度」。
                .fixedSize(horizontal: true, vertical: false)
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

            if sidePanel != nil {
                // 可拖动的分隔条:拖它来调聊天主区 ↔ 侧栏的边界。
                // 侧栏在右侧,所以向左拖(translation.width 变负)= 加宽侧栏。
                AgentSidePanelResizeHandle(
                    width: $sidePanelWidth,
                    range: sidePanelWidthRange
                )
                AgentSidePanelHost(
                    kind: $sidePanel,
                    selectedFile: $sidePanelFile,
                    width: CGFloat(sidePanelWidth)
                )
                    // 固定到用户选定的宽度,父 HStack 不靠压缩它来腾位置。
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(skin.windowBackground)
        .animation(.easeInOut(duration: 0.18), value: sidePanel)
        .onAppear {
            let snapshot = currentTaskMonitorSnapshot
            lastTaskMonitorSnapshot = snapshot
            didObserveAgentTaskMonitorActivity = snapshot.isAgentActivityActive
        }
        .onCompatibleChange(of: currentTaskMonitorSnapshot) { oldSnapshot, newSnapshot in
            handleTaskMonitorSnapshotChange(from: oldSnapshot, to: newSnapshot)
        }
        .onCompatibleChange(of: sidePanel) { oldPanel, newPanel in
            guard oldPanel == .backgroundTasks, newPanel == nil else { return }
            lastTaskMonitorSnapshot = currentTaskMonitorSnapshot
        }
        .onCompatibleChange(of: appState.agentSidePanelRequest) { _, request in
            guard let request else { return }
            if let url = request.file { sidePanelFile = url }
            sidePanel = request.kind
            // Consume:让下一次同样的请求(同 kind 同 file)也能再触
            // 发,且不会在 sheet dismiss / 视图重绘时被重放。
            appState.agentSidePanelRequest = nil
        }
    }

    private var currentTaskMonitorSnapshot: AgentTaskMonitorSnapshot {
        AgentTaskMonitorSnapshot.capture(from: appState)
    }

    private func handleTaskMonitorSnapshotChange(
        from oldSnapshot: AgentTaskMonitorSnapshot,
        to newSnapshot: AgentTaskMonitorSnapshot
    ) {
        if oldSnapshot.sessionID != newSnapshot.sessionID {
            lastTaskMonitorSnapshot = newSnapshot
            didObserveAgentTaskMonitorActivity = newSnapshot.isAgentActivityActive
            return
        }

        if newSnapshot.isAgentActivityActive {
            didObserveAgentTaskMonitorActivity = true
        }

        let baseline = lastTaskMonitorSnapshot ?? oldSnapshot
        defer { lastTaskMonitorSnapshot = newSnapshot }
        if sidePanel == .backgroundTasks, !newSnapshot.hasVisibleMonitorContent {
            sidePanel = nil
            return
        }

        guard didObserveAgentTaskMonitorActivity,
              newSnapshot.hasVisibleMonitorContent,
              newSnapshot != baseline,
              sidePanel == nil else {
            return
        }
        sidePanel = .backgroundTasks
    }
}

/// Thin draggable divider between the chat content and the right side
/// panel. Shows a resize cursor on hover and drives `width` (clamped to
/// `range`). The panel sits on the right, so dragging left widens it.
private struct AgentSidePanelResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var dragStartWidth: Double?
    @State private var isHovering = false

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 7)
                    .contentShape(Rectangle())
            )
            .background(isHovering ? Color.accentColor.opacity(0.25) : Color.clear)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = base }
                        let proposed = base - Double(value.translation.width)
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
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
