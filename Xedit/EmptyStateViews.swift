//
//  EmptyStateViews.swift
//  Xedit
//
//  "There's nothing to edit yet" screens, split out of ContentView.swift
//  in rc39.
//
//  1.153.0-rc3: `EmptyWorkspaceView` (the "no folder open" welcome
//  hero with Recent Folders / Recent Files) was removed. Plain app
//  launches go straight to the Agent window, and a fresh editor
//  window auto-creates an empty untitled tab — the welcome screen no
//  longer had a code path that should reach it.
//
//  What remains:
//    1. `EmptyProjectEditorView` — detail-pane empty state when no
//       tab is focused; offers Quick Open + Open File.
//    2. `EmptyWorkspaceButtonStyle` — shared CTA button style
//       (rounded, slight shadow, optional accent tint).
//

import SwiftUI

/// Detail-pane empty state shown when no file is in focus. Two quick
/// actions: open the Quick Open panel or browse for a file.
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
                .focusEffectDisabledCompat()
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
