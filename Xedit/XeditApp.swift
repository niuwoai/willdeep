//
//  XeditApp.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

@main
struct VeilWriterApp: App {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

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
            CommandGroup(replacing: .newItem) {
                Button("New Window…") {
                    chooseFolderForNewWindow()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") {
                    appState?.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Open File…") {
                    appState?.openFile()
                }
                .keyboardShortcut("O", modifiers: .command)

                Button("Open Folder…") {
                    appState?.openFolder { url in
                        openWindow(value: url)
                    }
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState?.saveCurrentFile()
                }
                .keyboardShortcut("S", modifiers: .command)

                Button("Save As…") {
                    appState?.saveCurrentFileAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Button("Command Palette") {
                    appState?.showCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Quick Open") {
                    appState?.showQuickOpen()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(appState?.rootDirectory == nil)

                Button("Go to Line") {
                    appState?.showGoToLine()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button("Go to Symbol") {
                    appState?.showSymbolJump()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState?.activeTabID == nil)

                Button("Find") {
                    appState?.showFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button("Find Next") {
                    appState?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState?.findMatchRanges.isEmpty ?? true)

                Button("Find Previous") {
                    appState?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState?.findMatchRanges.isEmpty ?? true)

                Button("Duplicate Line") {
                    appState?.duplicateCurrentLine()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState?.activeTabID == nil)

                Button("Move Line Up") {
                    appState?.moveCurrentLineUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(appState?.activeTabID == nil)

                Button("Move Line Down") {
                    appState?.moveCurrentLineDown()
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(appState?.activeTabID == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Focus Mode") {
                    appState?.toggleFocusMode()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(appState?.activeTabID == nil)

                Button("Toggle Preview") {
                    appState?.togglePreview()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(appState?.canShowPreview != true)

                Button("Open Split File…") {
                    appState?.openSplitFile()
                }
                .keyboardShortcut("\\", modifiers: [.command, .option])

                Button("Open Containing Folder") {
                    appState?.openContainingFolder()
                }
                .disabled(appState?.openedFileURL == nil)

                Button("Toggle Inspector") {
                    appState?.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(appState?.activeTabID == nil)
            }

            CommandGroup(before: .windowArrangement) {
                Button("Previous Tab") {
                    appState?.activatePreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((appState?.tabs.count ?? 0) < 2)

                Button("Next Tab") {
                    appState?.activateNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((appState?.tabs.count ?? 0) < 2)

                ForEach(1...9, id: \.self) { index in
                    Button("Select Tab \(index)") {
                        appState?.activateTab(atDisplayIndex: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled((appState?.tabs.count ?? 0) < index)
                }

                Button("Reopen Closed Tab") {
                    appState?.reopenClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Close Tab") {
                    appState?.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState?.activeTabID == nil)
            }
        }

        Settings {
            EditorSettingsView()
                .environmentObject(AppState())
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
                    return
                }
                appState.restoreSessionIfAvailable()
            }
    }
}
