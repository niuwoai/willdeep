//
//  AgentWindowRootView.swift
//  WillDeep
//
//  Root view for the standalone Agent window (1.80.0-rc1+). Agent is no
//  longer a fullscreen mode toggled inside an editor window — it has its
//  own singleton Window scene that *follows* whichever editor window was
//  focused last. Same idea as codex / cursor: "agent is always talking
//  about the project I'm looking at."
//
//  We DO NOT create our own AppState here. Instead we read
//  EditorAppStateRegistry.shared.current and inject that into the
//  environment. When the user focuses a different editor window, the
//  registry updates and SwiftUI re-injects + rebuilds AgentModeView (forced
//  via `.id(ObjectIdentifier(appState))`) so no stale @State (scroll
//  position, composer draft, …) leaks across workspace contexts.
//

import SwiftUI
import AppKit

struct AgentWindowRootView: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared

    var body: some View {
        Group {
            if let appState = registry.current {
                AgentModeView()
                    .environmentObject(appState)
                    // Force-rebuild AgentModeView when the source AppState
                    // changes — otherwise SwiftUI re-uses the same view
                    // instances and the AgentSessionsSidebar / Composer
                    // keep showing the previous workspace's draft / scroll
                    // position. ObjectIdentifier is stable for an
                    // AppState's lifetime.
                    .id(ObjectIdentifier(appState))
            } else {
                AgentWindowEmptyState()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// Shown when there's no active editor window — typically because the
/// user closed every workspace but kept the Agent window floating, or
/// SwiftUI restored the Agent window on app launch before any editor
/// window has been opened.
private struct AgentWindowEmptyState: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(L10n.AgentWindow.emptyTitle)
                    .font(.headline)
                Text(L10n.AgentWindow.emptySubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(L10n.AgentWindow.emptyOpenButton) {
                openFolderInNewWindow()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Opens the standard folder picker and routes the choice through
    /// the URL-typed WindowGroup so the new workspace lands in its own
    /// editor window — same path as Cmd+N "New Window" from the menu.
    /// As soon as that editor window's `onAppear` runs, it'll register
    /// itself in EditorAppStateRegistry and this empty state goes away.
    private func openFolderInNewWindow() {
        let panel = AppState.folderOpenPanel()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openWindow(value: url)
        }
    }
}
