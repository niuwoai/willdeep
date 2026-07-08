//
//  XeditApp.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit
import Combine

@main
struct WillDeepApp: App {
    @NSApplicationDelegateAdaptor(WillDeepAppDelegate.self) private var appDelegate

    var body: some Scene {
        let defaultSize = Self.defaultWindowSize

        // Agent is the default launch surface. Keep this scene first so a
        // plain app launch creates the Agent window directly; explicit file
        // or folder opens still land in the URL-backed editor WindowGroup
        // below.
        Window(L10n.AgentWindow.title, id: AgentWindowID.value) {
            AgentWindowRootView()
        }
        .defaultSize(width: defaultSize.width, height: defaultSize.height)
        .commands {
            WillDeepCommands()
        }

        WindowGroup(id: EditorWindowID.value) {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: defaultSize.width, height: defaultSize.height)
        WindowGroup(for: URL.self) { $url in
            WindowRootView(initialExternalURL: url)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: defaultSize.width, height: defaultSize.height)
        .commands {
            WillDeepCommands()
        }

        Settings {
            SettingsRootView()
        }
    }

    /// First-launch default window size: ~80% of the main screen's
    /// visible width and ~85% of its height, centered by SwiftUI. Only
    /// applies when there's no restored frame, so a user's later resize
    /// is respected across relaunches.
    private static var defaultWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = max(900, visible.width * 0.80)
        let height = max(600, visible.height * 0.85)
        return CGSize(width: width, height: height)
    }
}

private struct SettingsRootView: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared

    var body: some View {
        Group {
            if let appState = registry.current {
                EditorSettingsView()
                    .environmentObject(appState)
                    .id(ObjectIdentifier(appState))
            } else {
                Color.clear
            }
        }
        .onAppear {
            registry.ensureHeadlessFallback()
        }
    }
}

/// Window id 字符串字面值集中放一处，菜单 / openWindow / SwiftUI 三处
/// 都用同一个，避免拼错。
enum AgentWindowID {
    static let value = "agent-window"
}

enum EditorWindowID {
    static let value = "editor-window"
}

/// Agent 窗口在前台时发的标记。⌘N 是 app 全局命令，靠这个分流：
/// agent 窗口 key 时 ⌘N = 新聊天，否则 = 开新 editor 窗口。
/// **故意用常量 `true`**：focusedSceneValue 只在窗口聚焦切换时变化，
/// 不随 AppState 流式重算 republish —— 不能在这里捕获 appState 闭包，
/// 否则又踩回 WillDeepCommands 那个「每 token 重算菜单树」的坑。
private struct AgentWindowActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var agentWindowActive: Bool? {
        get { self[AgentWindowActiveKey.self] }
        set { self[AgentWindowActiveKey.self] = newValue }
    }
}

/// 菜单命令独立成 Commands 结构体，@FocusedObject 只能放这里、
/// 不能放回 App 顶层：@FocusedObject 订阅 AppState.objectWillChange，
/// 挂在 App 上时每次 publish（流式期间每个 token、动画期间每帧的
/// focused-value preference 重算）都会重跑 App.body → WindowGroup
/// 场景重建 → 全窗口布局缓存作废 → transcript 全量 CoreText 重排，
/// 配合常驻呼吸动画曾把主线程钉死在 98% CPU（1.58.0-rc9 修复）。
/// 放在 Commands 里，invalidation 只波及菜单树。
private struct WillDeepCommands: Commands {
    @FocusedObject private var appState: AppState?
    /// agent 窗口 key 时为 true，editor 窗口 key 时为 nil。
    @FocusedValue(\.agentWindowActive) private var agentWindowActive
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                // agent 窗口前台时 ⌘N 走「新聊天」，名实相符（侧边栏那
                // 个 ⌘N 标签过去只是画着看，从不真的触发）。editor 窗口
                // 前台时维持原行为：开一个新 editor 窗口。
                Button(agentWindowActive == true ? L10n.Sidebar.newChatAction : L10n.Menu.fileNewWindow) {
                    if agentWindowActive == true {
                        // agent 窗口不走 setCurrent，@FocusedObject 取不到，
                        // 直接问 registry 要当前跟随的 AppState。
                        if let agentAppState = EditorAppStateRegistry.shared.current {
                            agentAppState.startNewAgentSession()
                            // 键盘新建会话后焦点直接落到输入框，立刻能打字。
                            agentAppState.agentComposerFocusRevision += 1
                        }
                    } else {
                        openWindow(id: EditorWindowID.value)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(L10n.Menu.fileNewTab) {
                    appState?.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(L10n.Menu.fileOpenFile) {
                    appState?.openFile()
                }
                .keyboardShortcut("O", modifiers: .command)

                Button(L10n.Menu.fileOpenFolder) {
                    appState?.openFolder { url in
                        openWindow(value: url)
                    }
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button(L10n.Menu.fileSave) {
                    appState?.saveCurrentFile()
                }
                .keyboardShortcut("S", modifiers: .command)

                Button(L10n.Menu.fileSaveAs) {
                    appState?.saveCurrentFileAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Button(L10n.Menu.editCommandPalette) {
                    appState?.showCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button(L10n.Menu.editQuickOpen) {
                    appState?.showQuickOpen()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(appState?.rootDirectory == nil)

                Button(L10n.Menu.editGoToLine) {
                    appState?.showGoToLine()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.editGoToSymbol) {
                    appState?.showSymbolJump()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.editFind) {
                    appState?.showFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.editFindNext) {
                    appState?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState?.findMatchRanges.isEmpty ?? true)

                Button(L10n.Menu.editFindPrevious) {
                    appState?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState?.findMatchRanges.isEmpty ?? true)

                Button(L10n.Menu.editDuplicateLine) {
                    appState?.duplicateCurrentLine()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.editMoveLineUp) {
                    appState?.moveCurrentLineUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.editMoveLineDown) {
                    appState?.moveCurrentLineDown()
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(appState?.activeTabID == nil)
            }

            CommandGroup(after: .toolbar) {
                Button(L10n.Menu.viewToggleFocusMode) {
                    appState?.toggleFocusMode()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.viewTogglePreview) {
                    appState?.togglePreview()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState?.canShowPreview != true)

                Button(L10n.Menu.viewShowEditor) {
                    if appState?.showEditor() != true {
                        openWindow(id: EditorWindowID.value)
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .option])

                Button(L10n.Menu.viewToggleTerminal) {
                    appState?.toggleEditorTerminal(appState?.openedFileURL ?? appState?.rootDirectory)
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(appState?.rootDirectory == nil && appState?.openedFileURL == nil)

                Button(L10n.Menu.viewOpenSplitFile) {
                    appState?.openSplitFile()
                }
                .keyboardShortcut("\\", modifiers: [.command, .option])

                Button(L10n.Menu.viewOpenContainingFolder) {
                    appState?.openContainingFolder()
                }
                .disabled(appState?.openedFileURL == nil)

                Button(L10n.Menu.viewToggleInspector) {
                    appState?.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(appState?.activeTabID == nil)

                Button(L10n.Menu.viewToggleAgent) {
                    appState?.toggleAgentPanel()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])

                // 1.80.0-rc1：不再 toggle editor↔agent，而是打开
                // (或聚焦) 独立的 Agent 窗口。SwiftUI `openWindow(id:)`
                // 对单例 Window scene 来说是幂等的 —— 已经存在就抬起，
                // 不存在就创建。
                Button(L10n.AgentWindow.openMenuItem) {
                    openWindow(id: AgentWindowID.value)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                // Already in the Agent window → opening it is a no-op (the
                // singleton just refocuses itself), so disable the item to
                // make that obvious.
                .disabled(agentWindowActive == true)
            }

            CommandGroup(before: .windowArrangement) {
                Button(L10n.Menu.windowPreviousTab) {
                    appState?.activatePreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((appState?.tabs.count ?? 0) < 2)

                Button(L10n.Menu.windowNextTab) {
                    appState?.activateNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((appState?.tabs.count ?? 0) < 2)

                ForEach(1...9, id: \.self) { index in
                    Button(L10n.Menu.windowSelectTabIndex(String(index))) {
                        appState?.activateTab(atDisplayIndex: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((appState?.tabs.count ?? 0) < index)
                }

                Button(L10n.Menu.windowReopenClosedTab) {
                    appState?.reopenClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(L10n.Menu.windowCloseTab) {
                    appState?.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState?.activeTabID == nil)
            }
    }

}

private struct WindowRootView: View {
    @StateObject private var appState = AppState()
    /// 桥到 NSWindow.didBecomeKeyNotification，本窗口被聚焦时把
    /// self.appState 写到 EditorAppStateRegistry —— 这样独立的 Agent
    /// 窗口（1.80.0-rc1+）通过 registry 跟随当前 editor 窗口的上下文。
    /// 用 @StateObject 持有 observer 的生命周期；deinit 时自动摘
    /// 通知。
    @StateObject private var windowFocus = WindowFocusObserver()
    /// 1.88.0:首次启动 onboarding sheet 控制器。每个 WindowRootView
    /// 都 .sheet 绑这个,但 OnboardingFlowController.presentIfNeeded()
    /// 只让第一窗口翻 isPresented = true。
    @ObservedObject private var onboarding = OnboardingFlowController.shared
    @Environment(\.openWindow) private var openWindow
    let initialExternalURL: URL?
    @State private var didHandleInitialExternalURL = false

    init(initialExternalURL: URL? = nil) {
        self.initialExternalURL = initialExternalURL
    }

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneObject(appState)
            // A tapped agent notification asks (via the responder) to open
            // / focus the Agent window; only a live SwiftUI view can call
            // openWindow, so we bridge it here.
            .onReceive(NotificationCenter.default.publisher(for: .willDeepRevealAgentSession)) { _ in
                openWindow(id: AgentWindowID.value)
            }
            .background(
                WindowAccessor { window in
                    windowFocus.attach(to: window, appState: appState)
                }
            )
            .onOpenURL { url in
                handleExternalURL(url)
            }
            .onAppear {
                // 注册到全局 registry —— 第一个 editor 窗口顺便会被
                // 设为 current，后面 NSWindow becomeKey 通知再做精确
                // 切换。
                EditorAppStateRegistry.shared.register(appState)
                if !didHandleInitialExternalURL, let initialExternalURL {
                    didHandleInitialExternalURL = true
                    handleExternalURL(initialExternalURL)
                }
                onboarding.presentIfNeeded()
            }
            .onDisappear {
                EditorAppStateRegistry.shared.unregister(appState)
                windowFocus.detach()
            }
            .sheet(isPresented: $onboarding.isPresented) {
                OnboardingView()
                    .environmentObject(appState)
            }
    }

    private func handleExternalURL(_ url: URL) {
        if let fileURL = WillDeepExternalURLParser.fileURL(fromOpenURL: url) {
            appState.openExternalURL(fileURL, createsMissingFileIfNeeded: true)
            return
        }

        if CollaborationConnectorOAuthCoordinator.handleCallback(url) {
            return
        }
        appState.openExternalURL(url)
    }
}

enum WillDeepExternalURLParser {
    static func fileURL(fromOpenURL url: URL) -> URL? {
        guard url.scheme == "willdeep",
              url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

enum InitialLaunchPolicy {
    static let plainLaunchWindowID = AgentWindowID.value

    static func shouldOpenEditor(forInitialExternalURL url: URL?) -> Bool {
        url != nil
    }
}

/// SwiftUI ↔ AppKit 桥：从 view tree 拿到所在的 NSWindow，回调一次。
/// 用 `.background(WindowAccessor { ... })` 挂在任意 view 上。
private struct WindowAccessor: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // view.window 在 makeNSView 阶段还没接上窗口树，下一轮 runloop
        // 才有值。async 一下。
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                onWindowReady(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 监听单个 NSWindow 的 didBecomeKey 通知，本窗口聚焦时把对应的
/// AppState 推到 EditorAppStateRegistry。@StateObject 持有它就跟着
/// WindowRootView 的生命周期；deinit 摘通知，零泄漏。
///
/// 故意**只**在 editor 窗口（这里）attach；Agent 窗口、Settings 窗口
/// 都不 attach，所以它们获焦不会污染 registry.current —— 用户切到
/// agent 窗口看 transcript 时，registry 仍然指向上一个 editor。
@MainActor
private final class WindowFocusObserver: ObservableObject {
    private var observer: NSObjectProtocol?

    func attach(to window: NSWindow, appState: AppState) {
        detach()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak appState, weak window] _ in
            guard let appState, let window else { return }
            Task { @MainActor in
                EditorAppStateRegistry.shared.setCurrent(appState, window: window)
            }
        }
        // 启动场景：第一个窗口创建时往往已经是 key，notification 错过了
        // 第一次。手动补一发。
        if window.isKeyWindow {
            EditorAppStateRegistry.shared.setCurrent(appState, window: window)
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit {
        // NotificationCenter.removeObserver 是 nonisolated，可以在
        // deinit 安全调用。这里兜底，防止 detach 没被显式调到。
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
