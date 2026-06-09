//
//  EmptyStateViews.swift
//  Xedit
//
//  "There's nothing to edit yet" screens, split out of ContentView.swift
//  in rc39. Three states:
//
//    1. `EmptyProjectEditorView` — workspace IS open but no file is
//       focused (the detail pane); offers Quick Open + Open File.
//    2. `EmptyWorkspaceView` — no workspace at all; scrollable hero
//       plus optional Recent Folders / Recent Files columns.
//    3. `EmptyWorkspaceHero` / `EmptyWorkspaceRecentSection` —
//       internal pieces of the workspace-level empty state.
//
//  All four share `EmptyWorkspaceButtonStyle` for visual consistency
//  (rounded, slight shadow, optional accent tint for the primary CTA).
//

import SwiftUI

/// Detail-pane empty state shown when a folder is open but no file is
/// in focus. Two quick actions: open the Quick Open panel or browse
/// for a file. The icon + copy mirror the workspace-level empty state
/// so the user feels the same affordance everywhere.
struct EmptyProjectEditorView: View {
    let onQuickOpen: () -> Void
    let onOpenFile: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            VStack(spacing: 18) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text(L10n.EmptyState.noFileOpenTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.EmptyState.noFileOpenSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        onQuickOpen()
                    } label: {
                        Label(L10n.EmptyState.quickOpen, systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(EmptyWorkspaceButtonStyle())
                    .help(L10n.EmptyState.quickOpenHelp)
                    .accessibilityLabel(L10n.EmptyState.quickOpenAccessibilityLabel)

                    Button {
                        onOpenFile()
                    } label: {
                        Label(L10n.EmptyState.openFile, systemImage: "doc")
                    }
                    .buttonStyle(EmptyWorkspaceButtonStyle())
                    .help(L10n.EmptyState.openFileHelp)
                    .accessibilityLabel(L10n.EmptyState.openFileAccessibilityLabel)
                }
                .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Window-level empty state when no folder is open. Composes the
/// hero call-to-action with two optional Recent columns (folders /
/// files). `ViewThatFits` lets the two columns collapse to a vertical
/// stack on narrow windows.
struct EmptyWorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    let onOpenFile: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            ScrollView {
                VStack(spacing: 34) {
                    EmptyWorkspaceHero(
                        onOpenFile: onOpenFile,
                        onOpenFolder: onOpenFolder
                    )

                    if hasRecentItems {
                        recentContent
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 72)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, minHeight: 520)
            }
        }
    }

    private var hasRecentItems: Bool {
        !appState.recentFolders.isEmpty || !appState.recentFiles.isEmpty
    }

    private var recentContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                recentFoldersSection
                recentFilesSection
            }

            VStack(spacing: 18) {
                recentFoldersSection
                recentFilesSection
            }
        }
        .frame(maxWidth: 660)
    }

    @ViewBuilder
    private var recentFoldersSection: some View {
        if !appState.recentFolders.isEmpty {
            EmptyWorkspaceRecentSection(
                title: L10n.EmptyState.recentFolders,
                urls: Array(appState.recentFolders.prefix(5)),
                icon: "folder",
                action: { url in
                    appState.openRecentFolder(url) { folderURL in
                        openWindow(value: folderURL)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var recentFilesSection: some View {
        if !appState.recentFiles.isEmpty {
            EmptyWorkspaceRecentSection(
                title: L10n.EmptyState.recentFiles,
                urls: Array(appState.recentFiles.prefix(5)),
                icon: "doc",
                action: { url in
                    appState.openRecentFile(url)
                }
            )
        }
    }
}

/// Big folder icon + two-line headline + three primary actions. The
/// third button (Agent Mode) is tinted so a brand-new user has a
/// clear path into the AI experience even without opening a file.
struct EmptyWorkspaceHero: View {
    @EnvironmentObject var appState: AppState
    let onOpenFile: () -> Void
    let onOpenFolder: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(L10n.EmptyState.noFolderOpenTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.EmptyState.noFolderOpenSubtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button {
                    onOpenFile()
                } label: {
                    Label(L10n.EmptyState.openFile, systemImage: "doc")
                }
                .buttonStyle(EmptyWorkspaceButtonStyle())
                .help(L10n.EmptyState.openFileHelp)
                .accessibilityLabel(L10n.EmptyState.openFileAccessibilityLabel)

                Button {
                    onOpenFolder()
                } label: {
                    Label(L10n.EmptyState.openFolder, systemImage: "folder")
                }
                .buttonStyle(EmptyWorkspaceButtonStyle())
                .help(L10n.EmptyState.openFolderHelp)
                .accessibilityLabel(L10n.EmptyState.openFolderAccessibilityLabel)

                Button {
                    appState.setAppMode(.agent)
                } label: {
                    Label(L10n.EmptyState.agentMode, systemImage: "sparkles")
                }
                .buttonStyle(EmptyWorkspaceButtonStyle(tint: .accentColor))
                .help(L10n.EmptyState.agentModeHelp)
                .accessibilityLabel(L10n.EmptyState.agentModeAccessibilityLabel)
            }
            .labelStyle(.titleAndIcon)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)
            }
        }
    }
}

/// One column of "Recent X" entries (folders OR files). Each row is a
/// borderless button that calls back with the URL; the column itself
/// is fixed-width so the two columns align inside the hero.
struct EmptyWorkspaceRecentSection: View {
    let title: String
    let urls: [URL]
    let icon: String
    let action: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(urls, id: \.self) { url in
                    recentButton(for: url)
                }
            }
        }
        .frame(width: 318, alignment: .topLeading)
    }

    private func recentButton(for url: URL) -> some View {
        Button {
            action(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.06))
        }
    }
}

/// Shared button style for the empty-state CTAs: rounded card with a
/// subtle drop-shadow + optional accent tint. The accent variant
/// renders white text on color for the "primary action" button.
struct EmptyWorkspaceButtonStyle: ButtonStyle {
    /// Optional accent — when non-nil the button fills with this color
    /// and renders white-on-color (used for the "primary call to
    /// action" button in the empty-state hero).
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint ?? Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.08), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint == nil ? Color.primary.opacity(0.08) : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
