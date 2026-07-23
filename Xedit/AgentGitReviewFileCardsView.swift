//
//  AgentGitReviewFileCardsView.swift
//  WillDeep
//
//  Codex-style file-first diff cards for the Agent review panel.
//

import SwiftUI

struct AgentGitReviewFileCardsView: View {
    let snapshot: AgentGitReviewSnapshot
    let palette: EditorInterfaceSkinPalette
    @Binding var collapsedPaths: Set<String>
    let openFile: (AgentFileChangeSummary) -> Void

    private var document: AgentGitReviewDiffDocument {
        AgentGitReviewDiffDocument.parse(
            snapshot.overviewDiff,
            changes: snapshot.changes
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(document.files) { file in
                    AgentGitReviewFileCard(
                        file: file,
                        palette: palette,
                        isCollapsed: collapsedPaths.contains(file.path),
                        toggleCollapsed: {
                            toggle(file.path)
                        },
                        openFile: {
                            openFile(file.change)
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(palette.previewBase)
    }

    private func toggle(_ path: String) {
        if collapsedPaths.contains(path) {
            collapsedPaths.remove(path)
        } else {
            collapsedPaths.insert(path)
        }
    }
}

private struct AgentGitReviewFileCard: View {
    let file: AgentGitReviewDiffFile
    let palette: EditorInterfaceSkinPalette
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let openFile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider().opacity(0.42)
                diffRows
            }
        }
        .background(palette.previewBase)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.hairline.opacity(0.92), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)

                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor)

                    Text(file.path)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.previewInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            Spacer(minLength: 4)

            if file.change.hasKnownLineStats {
                HStack(spacing: 4) {
                    Text("+\(file.change.addedLines)")
                        .foregroundStyle(Color.green.opacity(0.9))
                    Text("-\(file.change.deletedLines)")
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospacedDigit()
            }

            Button(action: openFile) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentGitReview.openFileDiff)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(palette.controlFill.opacity(0.62))
    }

    private var diffRows: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.rows.enumerated()), id: \.offset) { _, row in
                    AgentGitReviewDiffRowView(row: row, palette: palette)
                }
            }
            .frame(minWidth: 480, alignment: .leading)
        }
    }

    private var statusColor: Color {
        switch file.change.kind {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

private struct AgentGitReviewDiffRowView: View {
    let row: AgentGitReviewDiffRow
    let palette: EditorInterfaceSkinPalette

    var body: some View {
        switch row {
        case .collapsed(let count):
            collapsedRow(count: count)
        case .context(let oldLine, let newLine, let text):
            codeRow(oldLine: oldLine, newLine: newLine, marker: " ", text: text, kind: .context)
        case .addition(let newLine, let text):
            codeRow(oldLine: nil, newLine: newLine, marker: "+", text: text, kind: .addition)
        case .deletion(let oldLine, let text):
            codeRow(oldLine: oldLine, newLine: nil, marker: "-", text: text, kind: .deletion)
        case .meta(let text):
            codeRow(oldLine: nil, newLine: nil, marker: " ", text: text, kind: .meta)
        }
    }

    private func collapsedRow(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(L10n.AgentGitReview.unmodifiedLines(String(count)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(minWidth: 480, alignment: .leading)
        .background(palette.controlFill.opacity(0.46))
    }

    private func codeRow(
        oldLine: Int?,
        newLine: Int?,
        marker: String,
        text: String,
        kind: CodeKind
    ) -> some View {
        HStack(spacing: 0) {
            lineNumber(oldLine)
            lineNumber(newLine)
            Text(marker)
                .foregroundStyle(foreground(for: kind))
                .frame(width: 16, alignment: .center)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(foreground(for: kind))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 19)
        .frame(minWidth: 480, alignment: .leading)
        .background(background(for: kind))
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.secondary.opacity(0.72))
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 7)
    }

    private func foreground(for kind: CodeKind) -> Color {
        switch kind {
        case .addition: return Color(red: 0.18, green: 0.62, blue: 0.31)
        case .deletion: return Color(red: 0.83, green: 0.24, blue: 0.30)
        case .context: return palette.previewInk
        case .meta: return palette.secondaryText
        }
    }

    private func background(for kind: CodeKind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.11)
        case .deletion: return Color.red.opacity(0.11)
        case .context, .meta: return .clear
        }
    }

    private enum CodeKind {
        case addition
        case deletion
        case context
        case meta
    }
}
