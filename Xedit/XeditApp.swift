//
//  XeditApp.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

@main
struct WillDeepApp: App {
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

        Settings {
            EditorSettingsView()
                .environmentObject(AppState())
        }
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

                Button(appState?.appMode == .agent ? L10n.Menu.viewSwitchToEditorMode : L10n.Menu.viewSwitchToAgentMode) {
                    appState?.toggleAppMode()
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
    let initialExternalURL: URL?
    @State private var didHandleInitialExternalURL = false

    init(initialExternalURL: URL? = nil) {
        self.initialExternalURL = initialExternalURL
    }

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneObject(appState)
            .onOpenURL { url in
                if AppState.isExistingDirectory(url) {
                    appState.registerRecentFolder(url)
                    openWindow(value: url)
                    return
                }
                appState.openExternalURL(url)
            }
            .onAppear {
                if !didHandleInitialExternalURL, let initialExternalURL {
                    didHandleInitialExternalURL = true
                    appState.openExternalURL(initialExternalURL)
                }
            }
    }
}
