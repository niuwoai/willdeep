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
    /// Whether the leftmost session list is shown. Toggled from the chat
    /// header (rc24) so a user who lives in one long conversation can
    /// reclaim the 230pt for the transcript. Persisted across relaunch.
    @AppStorage("agentSessionsSidebarVisible") private var sessionsSidebarVisible = true
    /// Drives the title-only session search overlay (rc24).
    @State private var isSessionSearchPresented = false
    /// User-resizable width of the right side panel. Persisted so the
    /// choice survives relaunch. The leftmost sessions sidebar stays
    /// fixed; only the chat ↔ side-panel boundary is draggable.
    @AppStorage("agentSidePanelWidth") private var sidePanelWidth: Double = 320
    @State private var liveSidePanelWidth: Double?
    private let sidePanelWidthRange: ClosedRange<Double> = 240...760

    /// 收窄窗口时的列宽规约(rc 用户反馈:最左列被挤出窗体左缘 /
    /// composer 盖住侧栏 / 右侧内容被文件面板遮住):左右两栏(会话列表、
    /// 文件面板)宽度恒定(`.fixedSize`),中间 chat 列是**唯一**可被压缩
    /// 的列 —— 它**不**设硬 `minWidth`,窗口变窄时由它独自吃掉差额并
    /// `.clipped()` 自我裁切,绝不按本征宽度居中外溢盖住左右邻居。
    ///
    /// 下面 `chatColumnComfortWidth` 只是喂给窗口 `contentMinSize` 的
    /// 「舒适下限」,保证正常拖拽时 chat 列不至于被拖成没法用的细条;
    /// 但它**不**作为中间列的布局硬下限,所以即便平铺工具 / 编程式
    /// resize 把窗口强行压到它以下(`contentMinSize` 只挡交互式拖拽,
    /// 挡不住这些),中间列也只是继续裁切,不会再发生列间相互遮盖。
    /// 右面板打开时把它的宽度计进窗口下限,否则 `sidebar + panel` 早
    /// 就超过旧的固定 720 窗口宽。
    private var chatColumnComfortWidth: CGFloat { sidebarWidth * 1.4 }
    private var currentSidePanelWidth: Double {
        min(max(liveSidePanelWidth ?? sidePanelWidth, sidePanelWidthRange.lowerBound), sidePanelWidthRange.upperBound)
    }

    /// 窗口绝对最小宽 / 高。侧栏自动隐藏、右面板关闭时,按内容算出的
    /// 下限会掉到「只剩 chat 舒适宽」(~320),窗口能被拖成一条没法用的
    /// 竖窄条(用户反馈截图)。这里钉一个硬地板,任何情况下都不许更窄。
    static let absoluteMinContentWidth: CGFloat = 720
    static let absoluteMinContentHeight: CGFloat = 480

    private func contentMinWidth(isSidebarVisible: Bool) -> CGFloat {
        let content = (isSidebarVisible ? sidebarWidth : 0)
            + chatColumnComfortWidth
            // 面板宽度现在会随窗口宽度自适应封顶(见 panelWidthCap),
            // 窗口下限只需保证「最窄面板」放得下,不再跟着持久化宽度
            // 走 —— 也就免了拖拽提交后反复改写 contentMinSize。
            + (appState.agentSidePanelKind != nil ? CGFloat(sidePanelWidthRange.lowerBound) : 0)
        return max(content, Self.absoluteMinContentWidth)
    }

    /// 侧栏(含 1pt 分隔线)当前占用的宽度。
    private func sidebarOccupiedWidth(isSidebarVisible: Bool) -> CGFloat {
        isSidebarVisible ? sidebarWidth + 1 : 0
    }

    /// 窗口宽度给面板的封顶:面板再宽也必须给「会话侧栏 + chat 舒适
    /// 宽」留出空间。否则小窗口(如 ~655pt)下持久化的 320+ 宽度会
    /// 直接吃掉半个窗口(rc 用户截图:预览面板占了一半还多),chat
    /// 列被裁得没法看。窗口拉大后自动恢复到用户拖出来的偏好宽度。
    private func panelWidthCap(totalWidth: CGFloat, isSidebarVisible: Bool) -> Double {
        guard totalWidth > 0 else { return sidePanelWidthRange.upperBound }
        let available = Double(totalWidth - sidebarOccupiedWidth(isSidebarVisible: isSidebarVisible) - 1)
            - Double(chatColumnComfortWidth)
        return min(sidePanelWidthRange.upperBound, max(sidePanelWidthRange.lowerBound, available))
    }

    var body: some View {
        GeometryReader { proxy in
            let autoHidden = AgentModeResponsiveLayout.shouldAutoHideSessionsSidebar(
                totalWidth: proxy.size.width,
                userPrefersVisible: sessionsSidebarVisible,
                activeSidePanel: appState.agentSidePanelKind,
                sidePanelMinimumWidth: CGFloat(sidePanelWidthRange.lowerBound)
            )
            mainContent(totalWidth: proxy.size.width, isSidebarAutoHidden: autoHidden)
                .background {
                    AgentSessionsSidebarWindowChromeToggle(
                        isVisible: sidebarVisibilityBinding(isAutoHidden: autoHidden),
                        isAutoHidden: autoHidden
                    )
                    .frame(width: 0, height: 0)
                }
        }
    }

    @ViewBuilder
    private func mainContent(totalWidth: CGFloat, isSidebarAutoHidden: Bool) -> some View {
        let skin = appState.editorSettings.interfaceSkin
        let effectiveSidebarVisible = sessionsSidebarVisible && !isSidebarAutoHidden
        let occupiedSidebarWidth = sidebarOccupiedWidth(isSidebarVisible: effectiveSidebarVisible)
        let minimumContentWidth = contentMinWidth(isSidebarVisible: effectiveSidebarVisible)
        let cap = panelWidthCap(totalWidth: totalWidth, isSidebarVisible: effectiveSidebarVisible)
        // 「已提交」宽度在整个拖拽过程中保持不变(AppStorage 只在松手
        // 时写入),拖拽期间面板/chat 的**内容**都按它排版,只有 frame
        // 跟着鼠标走 —— 这是消除拖拽闪动的关键:文本不再逐鼠标事件
        // 重折行,WebView/终端也不逐帧重排。
        let committedPanelWidth = min(max(sidePanelWidth, sidePanelWidthRange.lowerBound), cap)
        let panelWidth = min(currentSidePanelWidth, cap)
        let isResizingPanel = liveSidePanelWidth != nil
        let hasWallpaper = appState.editorSettings.hasConfiguredAgentWallpaper
        let frozenChatWidth = max(totalWidth - occupiedSidebarWidth - 1 - CGFloat(committedPanelWidth), 0)
        // `.backgroundTasks` remains decodable for persisted sessions, but it
        // is never a renderable destination after the monitor rail redesign.
        let activeSidePanel: AgentSidePanelKind? = if appState.agentPrimaryDestination == .scheduledTasks {
            nil
        } else if appState.agentSidePanelKind == .backgroundTasks {
            nil
        } else {
            appState.agentSidePanelKind
        }
        HStack(spacing: 0) {
            if effectiveSidebarVisible {
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
                            .opacity(hasWallpaper ? appState.editorSettings.agentWallpaperSurfaceOpacity : 1)
                            .overlay(skin.palette.hoverFill.opacity(0.35))
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            VStack(spacing: 0) {
                if appState.agentPrimaryDestination == .scheduledTasks {
                    AgentScheduledTasksPage()
                } else {
                    AgentChatHeader(
                        sidePanel: sidePanelBinding,
                        sessionsSidebarVisible: $sessionsSidebarVisible,
                        isSessionSearchPresented: $isSessionSearchPresented
                    )
                    Divider().opacity(0.5)
                    AgentChatTranscript()
                    AgentChatComposer()
                    AgentChatStatusBar()
                }
            }
            // 拖拽调宽期间把 chat 内容冻结在拖拽起点的宽度上:文本不随
            // 每个鼠标事件重折行(重折行时单词在行间跳动,肉眼就是
            // 「闪」),多出的部分被下面的 `.clipped()` 裁掉;左缘
            // (`.leading`)钉死不动,松手后一次性按新宽度重排。
            .frame(
                width: activeSidePanel != nil && isResizingPanel ? frozenChatWidth : nil,
                alignment: .leading
            )
            // `minWidth: 0` 是关键:frame 只写 `maxWidth: .infinity` 时,
            // 最小宽度会回退为子内容的本征最小宽(SwiftUI frame 语义),
            // 统计卡片 / composer 这类压不动的子 view 会把中间列的下限
            // 顶得比可用空间还宽 → 整条 HStack 溢出、被父级居中,左栏
            // 被挤出窗体左缘、chat 内容溢出右缘(rc47 用户截图)。显式
            // `minWidth: 0` 让中间列无条件接受父级提议的宽度,成为真正
            // 的唯一可压缩列;压不下的内容按 `.leading` 靠左,在右缘被
            // `.clipped()` 裁掉,不再外溢盖住左右邻居。
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                skin.windowBackground
                    .opacity(hasWallpaper ? appState.editorSettings.agentWallpaperSurfaceOpacity : 1)
                    .overlay(
                        skin.palette.panelFill.opacity(hasWallpaper ? 0.12 : 0.18)
                    )
            )
            .overlay(alignment: .topTrailing) {
                if appState.agentPrimaryDestination == .conversation {
                    AgentConversationActivityOverlay()
                        .padding(.top, AgentDesign.headerHeight + 12)
                        .padding(.trailing, 14)
                        .zIndex(20)
                }
            }
            .clipped()

            if activeSidePanel != nil {
                // 可拖动的分隔条:拖它来调聊天主区 ↔ 侧栏的边界。
                // 侧栏在右侧,所以向左拖(translation.width 变负)= 加宽侧栏。
                AgentSidePanelResizeHandle(
                    width: Binding(
                        get: { min(currentSidePanelWidth, cap) },
                        set: { liveSidePanelWidth = $0 }
                    ),
                    // 上限同样吃窗口封顶:小窗口下不允许把面板拖到把
                    // chat 列挤没的宽度。
                    range: sidePanelWidthRange.lowerBound...cap,
                    onCommit: { committedWidth in
                        liveSidePanelWidth = nil
                        sidePanelWidth = committedWidth
                    }
                )
                AgentSidePanelHost(
                    kind: sidePanelBinding,
                    selectedFile: sidePanelFileBinding,
                    width: CGFloat(panelWidth),
                    contentWidth: CGFloat(committedPanelWidth)
                )
                    // 固定到用户选定的宽度,父 HStack 不靠压缩它来腾位置。
                    .fixedSize(horizontal: true, vertical: false)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // `alignment: .leading`:万一窗口仍被压到比「左栏 + 分隔线 +
        // 右面板」的固定宽度之和还窄(contentMinSize 只挡交互式拖拽,
        // 挡不住平铺工具 / 编程式 resize),HStack 溢出时不再默认居中
        // 把左栏推出窗体左缘 —— 靠左钉住,溢出只从右缘裁掉。
        .frame(minWidth: minimumContentWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            WorkspaceWallpaperBackground(
                settings: appState.editorSettings,
                appliesAgentEffects: true
            )
        )
        .background(AgentWindowMinWidthSetter(minWidth: minimumContentWidth))
        .overlay(alignment: .leading) {
            if !effectiveSidebarVisible {
                AgentRecentSessionEdgeRail()
                    .zIndex(10)
            }
        }
        .overlay {
            if appState.agentPrimaryDestination == .conversation {
                AgentComputerUsePresentationLayer(
                    activity: appState.activeRuntime?.latestComputerUseActivity,
                    isActive: appState.activeRuntime?.isResponding == true,
                    sessionID: appState.activeAgentSessionID,
                    turnStartedAt: appState.activeRuntime?.turnStartedAt,
                    thumbnailTrailingInset: activeSidePanel == nil ? 0 : CGFloat(panelWidth + 1)
                )
            }
        }
        .sheet(isPresented: $isSessionSearchPresented) {
            AgentSessionSearchView()
                .environmentObject(appState)
        }
        .onAppear {
            DesktopPetWindowManager.shared.attach(to: appState)
            // Keep decoding the legacy enum case for persisted sessions, but
            // never resurrect the retired task-monitor rail.
            if appState.agentSidePanelKind == .backgroundTasks {
                appState.agentSidePanelKind = nil
            }
        }
        .onCompatibleChange(of: appState.agentSidePanelKind) { _, newPanel in
            if newPanel == .backgroundTasks {
                appState.agentSidePanelKind = nil
                appState.agentSidePanelRequest = nil
                liveSidePanelWidth = nil
                return
            }
            if newPanel == nil {
                liveSidePanelWidth = nil
            }
        }
        .onCompatibleChange(of: appState.agentSidePanelRequest) { _, request in
            guard let request else { return }
            guard request.kind != .backgroundTasks else {
                appState.agentSidePanelRequest = nil
                appState.agentSidePanelKind = nil
                return
            }
            guard request.kind.isAvailable(activeExperts: appState.agentActiveExperts) else {
                appState.agentSidePanelRequest = nil
                return
            }
            // A generic Diff request must clear an older file focus; a
            // file-targeted request carries the exact change the panel should
            // open. Other panels keep their previous selection when no file
            // was supplied.
            if request.kind == .diff {
                appState.agentSidePanelSelectedFile = request.file
            } else if let url = request.file {
                appState.agentSidePanelSelectedFile = url
            }
            if request.kind == .mediaTasks {
                appState.agentMediaTaskPanelScope = request.mediaTaskScope
            }
            appState.agentSidePanelKind = request.kind
            // Consume:让下一次同样的请求(同 kind 同 file)也能再触
            // 发,且不会在 sheet dismiss / 视图重绘时被重放。
            appState.agentSidePanelRequest = nil
        }
        .onCompatibleChange(of: appState.agentActiveExperts) { _, activeExperts in
            guard let current = appState.agentSidePanelKind,
                  !current.isAvailable(activeExperts: activeExperts) else {
                return
            }
            appState.agentSidePanelKind = nil
        }
    }

    private var sidePanelBinding: Binding<AgentSidePanelKind?> {
        Binding(
            get: {
                appState.agentSidePanelKind == .backgroundTasks
                    ? nil
                    : appState.agentSidePanelKind
            },
            set: { newPanel in
                appState.agentSidePanelKind = newPanel == .backgroundTasks ? nil : newPanel
            }
        )
    }

    private func sidebarVisibilityBinding(isAutoHidden: Bool) -> Binding<Bool> {
        Binding(
            get: { sessionsSidebarVisible && !isAutoHidden },
            set: { sessionsSidebarVisible = $0 }
        )
    }

    private var sidePanelFileBinding: Binding<URL?> {
        Binding(
            get: { appState.agentSidePanelSelectedFile },
            set: { appState.agentSidePanelSelectedFile = $0 }
        )
    }

}

/// Puts the Agent-session sidebar button in the native titlebar, immediately
/// after the macOS close/minimize/zoom controls. Keeping it in AppKit's
/// titlebar container makes its vertical position match the traffic lights;
/// a SwiftUI overlay would instead be anchored in the content area below them.
private struct AgentSessionsSidebarWindowChromeToggle: NSViewRepresentable {
    @Binding var isVisible: Bool
    let isAutoHidden: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible, isAutoHidden: isAutoHidden)
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        context.coordinator.attach(to: anchor)
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isVisible: $isVisible, isAutoHidden: isAutoHidden)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeButton()
    }

    final class Coordinator: NSObject {
        private let buttonWidth: CGFloat = 26
        private let buttonGapFromZoom: CGFloat = 7
        private weak var anchorView: NSView?
        private weak var button: NSButton?
        private var isVisible: Binding<Bool>
        private var isAutoHidden: Bool

        init(isVisible: Binding<Bool>, isAutoHidden: Bool) {
            self.isVisible = isVisible
            self.isAutoHidden = isAutoHidden
        }

        func update(isVisible: Binding<Bool>, isAutoHidden: Bool) {
            self.isVisible = isVisible
            self.isAutoHidden = isAutoHidden
            configureButton()
        }

        func attach(to anchorView: NSView) {
            self.anchorView = anchorView
            DispatchQueue.main.async { [weak self] in
                self?.installButtonIfNeeded()
            }
        }

        func removeButton() {
            button?.removeFromSuperview()
            button = nil
        }

        private func installButtonIfNeeded() {
            guard let window = anchorView?.window,
                  let zoomButton = window.standardWindowButton(.zoomButton),
                  let titlebarView = zoomButton.superview else {
                return
            }

            let button = button ?? makeButton()
            if button.superview !== titlebarView {
                button.removeFromSuperview()
                titlebarView.addSubview(button, positioned: .above, relativeTo: zoomButton)
            }
            self.button = button
            position(button, after: zoomButton)
            configureButton()
        }

        private func makeButton() -> NSButton {
            let button = NSButton(frame: .zero)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.focusRingType = .none
            button.target = self
            button.action = #selector(toggleSidebar)
            button.setButtonType(.momentaryPushIn)
            button.keyEquivalent = "\\"
            button.keyEquivalentModifierMask = .command
            if let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }
            return button
        }

        private func position(_ button: NSButton, after zoomButton: NSButton) {
            let zoomFrame = zoomButton.frame
            button.frame = NSRect(
                x: zoomFrame.maxX + buttonGapFromZoom,
                y: zoomFrame.minY,
                width: buttonWidth,
                height: zoomFrame.height
            )
        }

        private func configureButton() {
            guard let button else { return }
            let title = isAutoHidden
                ? L10n.Header.sidebarAutoHidden
                : (isVisible.wrappedValue ? L10n.Header.hideSidebar : L10n.Header.showSidebar)
            button.isEnabled = !isAutoHidden
            button.alphaValue = isAutoHidden ? 0.72 : 1
            button.toolTip = title
            button.setAccessibilityLabel(title)
        }

        @objc private func toggleSidebar() {
            guard !isAutoHidden else { return }
            isVisible.wrappedValue.toggle()
            configureButton()
        }
    }
}

enum AgentModeResponsiveLayout {
    /// Base width where chat + composer still feel usable with the session list.
    /// Add the minimum right-panel width when that panel is open.
    static let sidebarAutoHideBaseWidth: CGFloat = 800

    static func shouldAutoHideSessionsSidebar(
        totalWidth: CGFloat,
        userPrefersVisible: Bool,
        activeSidePanel: AgentSidePanelKind?,
        sidePanelMinimumWidth: CGFloat
    ) -> Bool {
        guard userPrefersVisible, totalWidth > 0 else { return false }
        let threshold = sidebarAutoHideBaseWidth + (activeSidePanel == nil ? 0 : sidePanelMinimumWidth)
        return totalWidth < threshold
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
        let targetHeight = AgentModeView.absoluteMinContentHeight
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if abs(window.contentMinSize.width - target) > 0.5 {
                window.contentMinSize.width = target
            }
            // 高度下限固定(不随内容变),之前完全没设,窗口能被拖成
            // 一条横扁条 —— 一并钉住。
            if abs(window.contentMinSize.height - targetHeight) > 0.5 {
                window.contentMinSize.height = targetHeight
            }
            // 只更新最小尺寸约束,不在侧栏打开的同一帧同步 setFrame。
            // setFrame(display: true) 会强制窗口立即布局和重绘,在右侧
            // 终端 / 媒体面板首次挂载时容易把打开动作拖成可感知卡顿。
        }
    }
}

/// Thin draggable divider between the chat content and the right side
/// panel. Shows a resize cursor on hover and drives `width` (clamped to
/// `range`). The panel sits on the right, so dragging left widens it.
private struct AgentSidePanelResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void

    @State private var dragStartWidth: Double?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 7)
                    .contentShape(Rectangle())
            )
            .background(isHovering || isDragging ? Color.accentColor.opacity(0.25) : Color.clear)
            .onHover { hovering in
                isHovering = hovering
                // 快速拖动时鼠标会瞬时冲出 7pt 热区再被布局追上,hover
                // 会 true/false 高频翻转;若照常 push/pop,光标就在箭头
                // ↔ 左右缩放之间闪。拖拽期间光标交给 onChanged 钉住。
                guard !isDragging else { return }
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        NSCursor.resizeLeftRight.set()
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
                    .onEnded { _ in
                        let committedWidth = width
                        dragStartWidth = nil
                        isDragging = false
                        // 拖拽中被吞掉的 hover 退出在这里补一次 pop,保持
                        // NSCursor push/pop 配平。
                        if !isHovering { NSCursor.pop() }
                        onCommit(committedWidth)
                    }
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
    static let chatHorizontalInset: CGFloat = 26
    static let userMessageMaxWidthRatio: CGFloat = 0.78
    static let messageVerticalSpacing: CGFloat = 20
    static let composerHeight: CGFloat = 124
    static let headerHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 26
    // Codex sidebar reference: 14 pt SF text on a stable 31 pt vertical
    // rhythm. Keep the geometry as named tokens so workspace rows,
    // conversation rows, hover surfaces, and visual regression tests do
    // not drift independently.
    static let sidebarRowFontSize: CGFloat = 14
    static let sidebarRowHeight: CGFloat = 31
    static let sidebarTodoRowHeight: CGFloat = 47
    static let sidebarWorkspaceHorizontalInset: CGFloat = 18
    static let sidebarWorkspaceIconSize: CGFloat = 14
    static let sidebarWorkspaceIconToTitleSpacing: CGFloat = 8
    static let sidebarSelectionHorizontalInset: CGFloat = 8
    static let sidebarSessionContentHorizontalInset: CGFloat = 32
    static let sidebarSessionTrailingActionsWidth: CGFloat = 40
    // Global pins are top-level navigation, so their title column starts at
    // 12 pt like Codex instead of inheriting the 40 pt workspace-child inset.
    static let sidebarPinnedSessionContentHorizontalInset: CGFloat = 4
    static let sidebarSelectionCornerRadius: CGFloat = 10
    static let sidebarWorkspaceGroupSpacing: CGFloat = 6
    static let sidebarPrimaryTextOpacity: Double = 0.86
    // Keep the conversation readable while allowing the configured image to
    // show through. Navigation and utility panels intentionally stay opaque.
    // Automations are first-class sidebar content, not caption metadata.
    // Keep every user-visible automation label on the same regular text
    // scale as workspace and conversation rows.
    static let sidebarAutomationFontSize: CGFloat = sidebarRowFontSize

    // Typography.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let secondaryFont = Font.system(size: 11)
    static let captionFont = Font.system(size: 10)
    static let sidebarSectionFont = Font.system(size: 11, weight: .semibold)
    static let sidebarRowFont = Font.system(size: sidebarRowFontSize)
    static let sidebarWorkspaceFont = Font.system(size: sidebarRowFontSize)
    static let sidebarAutomationFont = Font.system(size: sidebarAutomationFontSize)
}
