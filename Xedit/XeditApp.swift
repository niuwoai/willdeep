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
        WindowGroup {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        WindowGroup(for: URL.self) { $url in
            WindowRootView(initialExternalURL: url)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            WillDeepCommands()
        }

        // 1.80.0-rc1：Agent 独立成单例窗口。窗口本身不持有 AppState，
        // 通过 EditorAppStateRegistry 跟随当前聚焦的 editor 窗口 ——
        // 切到另一个 workspace 的窗口，agent 窗口 transcript 跟着切。
        Window(L10n.AgentWindow.title, id: AgentWindowID.value) {
            AgentWindowRootView()
        }

        Settings {
            EditorSettingsView()
                .environmentObject(AppState())
        }
    }
}

/// Window id 字符串字面值集中放一处，菜单 / openWindow / SwiftUI 三处
/// 都用同一个，避免拼错。
enum AgentWindowID {
    static let value = "agent-window"
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.Menu.fileNewWindow) {
                    chooseFolderForNewWindow()
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

    private func chooseFolderForNewWindow() {
        let panel = AppState.folderOpenPanel()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            appState?.registerRecentFolder(url)
            openWindow(value: url)
        }
    }
}

private struct WindowRootView: View {
    @Environment(\.openWindow) private var openWindow
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
    let initialExternalURL: URL?
    @State private var didHandleInitialExternalURL = false

    init(initialExternalURL: URL? = nil) {
        self.initialExternalURL = initialExternalURL
    }

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneObject(appState)
            .background(
                WindowAccessor { window in
                    windowFocus.attach(to: window, appState: appState)
                }
            )
            .onOpenURL { url in
                if AppState.isExistingDirectory(url) {
                    appState.registerRecentFolder(url)
                    openWindow(value: url)
                    return
                }
                appState.openExternalURL(url)
            }
            .onAppear {
                // 注册到全局 registry —— 第一个 editor 窗口顺便会被
                // 设为 current，后面 NSWindow becomeKey 通知再做精确
                // 切换。
                EditorAppStateRegistry.shared.register(appState)
                if !didHandleInitialExternalURL, let initialExternalURL {
                    didHandleInitialExternalURL = true
                    appState.openExternalURL(initialExternalURL)
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
