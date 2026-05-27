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
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File…") {
                    appState.openFile()
                }
                .keyboardShortcut("O", modifiers: .command)

                Button("Open Folder…") {
                    appState.openFolder()
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.saveCurrentFile()
                }
                .keyboardShortcut("S", modifiers: .command)

                Button("Save As…") {
                    appState.saveCurrentFileAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }

        Settings {
            EditorSettingsView()
                .environmentObject(appState)
        }
    }
}
