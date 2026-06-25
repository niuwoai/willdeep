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

    /// 收窄窗口时的列宽规约(rc 用户反馈:最左列被挤出窗体左缘):
    /// 最左会话列表(`sidebarWidth`)与右侧面板宽度恒定,只压中间 chat
    /// 列;但中间列不允许小于 2×sidebar,也就是「整体宽度 ≥ 3×sidebar」。
    /// 这个下限同时喂给中间列(`minWidth`)和根 HStack(`minWidth` →
    /// 窗口 contentMinSize),窗口因此压不到内容会溢出的程度,sidebar
    /// 不会再被挤出左缘。右面板打开时把它的宽度也计进窗口下限,否则
    /// `sidebar + panel` 早就超过旧的固定 720 窗口宽。
    private var chatColumnMinWidth: CGFloat { sidebarWidth * 2 }
    private var contentMinWidth: CGFloat {
        sidebarWidth + chatColumnMinWidth + (sidePanel != nil ? CGFloat(sidePanelWidth) : 0)
    }

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
            .frame(minWidth: chatColumnMinWidth, maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(minWidth: contentMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.windowBackground)
        .background(AgentWindowMinWidthSetter(minWidth: contentMinWidth))
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

/// 把 Agent 窗口的 `contentMinSize.width` 钉到内容真正需要的最小宽度
/// (随右侧面板开合 / 拖宽而变)。纯 SwiftUI 的 `.frame(minWidth:)` 在
/// 这个嵌套布局里不会动态更新 NSWindow 的 contentMinSize —— 它停在
/// scene 根创建时的静态值,于是侧面板一打开、内容需要的宽度超过那个
/// 静态下限,窗口仍能被拖窄、HStack 溢出、最左会话列表被挤出窗体
/// 左缘。直接写 NSWindow 才压得住。
private struct AgentWindowMinWidthSetter: NSViewRepresentable {
    let minWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        applyAsync(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyAsync(from: nsView)
    }

    private func applyAsync(from view: NSView) {
        let target = minWidth
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if abs(window.contentMinSize.width - target) > 0.5 {
                window.contentMinSize.width = target
            }
            // 面板刚打开、窗口当前比新下限还窄时,主动撑回下限,不必等
            // 用户手动拖宽(否则打开瞬间内容已经溢出、左栏被挤出去)。
            if window.frame.width < target {
                var frame = window.frame
                frame.size.width = target
                window.setFrame(frame, display: true, animate: false)
            }
        }
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
                        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
                        // 闪动根因有二:① 拖动给出的是亚像素位移,落到亚像素
                        // 宽度后面板内容(终端/文本)每帧在分数偏移上重栅格化,
                        // 肉眼就是抖;对齐到整数点后栅格稳定。② 宽度变化若被
                        // 祖先 `.animation` 捕捉会插值出迟滞/重影,这里显式关掉
                        // 隐式动画,让拖动跟手、所见即所得。
                        let snapped = clamped.rounded()
                        guard snapped != width else { return }
                        var txn = Transaction()
                        txn.disablesAnimations = true
                        withTransaction(txn) { width = snapped }
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
