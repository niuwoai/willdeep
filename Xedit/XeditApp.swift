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

    var body: some Scene {
        WindowGroup {
            WindowRootView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File…") {
                    appState?.openFile()
                }
                .keyboardShortcut("O", modifiers: .command)

                Button("Open Folder…") {
                    appState?.openFolder()
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
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Inspector") {
                    appState?.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(appState?.activeTabID == nil)
            }

            CommandGroup(before: .windowArrangement) {
                Button("Close Tab") {
                    appState?.closeActiveTab()
                }
                .keyboardShortcut(.tab, modifiers: .option)
                .disabled(appState?.activeTabID == nil)
            }
        }

        Settings {
            EditorSettingsView()
                .environmentObject(AppState())
        }
    }
}

private struct WindowRootView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneObject(appState)
            .onAppear {
                appState.restoreSessionIfAvailable()
            }
    }
}
