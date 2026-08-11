//
//  AgentGitReviewFileCardsView.swift
//  WillDeep
//
//  Codex-style file-first diff cards for the Agent review panel.
//

import SwiftUI

nonisolated enum AgentGitReviewFileCardsMetrics {
    static let visibleLineBatchSize = 100

    /// Used before the card has been measured, so the first frame still paints
    /// a usable row width instead of collapsing to the longest line.
    static let fallbackRowWidth: CGFloat = 480

    static func nextVisibleLineCount(current: Int, total: Int) -> Int {
        min(total, current + visibleLineBatchSize)
    }

    /// Rows must never be narrower than the visible card: the added/deleted
    /// tint is painted on the row container, so a row that only spans its own
    /// text leaves the highlight visibly short of the right edge.
    static func rowWidth(viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth.isFinite, viewportWidth > 0 else { return fallbackRowWidth }
        return viewportWidth
    }

    /// Sub-point width jitter must never reach `rowWidth`. The measured width
    /// feeds the row frames, the row frames feed the stack's content size, and
    /// a content size that nudges the measurement back by a fraction of a
    /// point turns SwiftUI's layout pass into a loop that never settles —
    /// observed as a permanently pegged main thread inside
    /// `LazySubviewPlacements.placeSubviews`. Quantizing the adopted value
    /// makes the sequence converge in at most one step.
    static let viewportWidthEpsilon: CGFloat = 0.5

    static func shouldAdoptViewportWidth(current: CGFloat, measured: CGFloat) -> Bool {
        guard measured.isFinite, measured > 0 else { return false }
        return abs(measured - current) >= viewportWidthEpsilon
    }
}

struct AgentGitReviewFileCardsView: View {
    let snapshot: AgentGitReviewSnapshot
    let palette: EditorInterfaceSkinPalette
    @Binding var collapsedPaths: Set<String>
    let openFile: (AgentFileChangeSummary) -> Void
    @State private var visibleLineCounts: [String: Int] = [:]

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
                        visibleLineCount: visibleLineCounts[file.path]
                            ?? AgentGitReviewFileCardsMetrics.visibleLineBatchSize,
                        showMore: {
                            showMoreRows(for: file)
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

    private func showMoreRows(for file: AgentGitReviewDiffFile) {
        let current = visibleLineCounts[file.path]
            ?? AgentGitReviewFileCardsMetrics.visibleLineBatchSize
        visibleLineCounts[file.path] = AgentGitReviewFileCardsMetrics.nextVisibleLineCount(
            current: current,
            total: file.rows.count
        )
    }
}

private struct AgentGitReviewFileCard: View {
    let file: AgentGitReviewDiffFile
    let palette: EditorInterfaceSkinPalette
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let visibleLineCount: Int
    let showMore: () -> Void
    let openFile: () -> Void
    @State private var viewportWidth: CGFloat = 0

    private var rowWidth: CGFloat {
        AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth: viewportWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider().opacity(0.42)
                diffRows
            }
        }
        // Measured on the card, never on the horizontal ScrollView inside it.
        // The card's width comes from the enclosing list, so it cannot be
        // pushed around by the row widths this measurement produces; measuring
        // the ScrollView instead closes that loop and hangs the layout pass.
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size.width) {
                    let measured = proxy.size.width
                    guard AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(
                        current: viewportWidth,
                        measured: measured
                    ) else { return }
                    viewportWidth = measured
                }
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
                ForEach(Array(file.rows.prefix(visibleLineCount).enumerated()), id: \.offset) { _, row in
                    AgentGitReviewDiffRowView(row: row, palette: palette, minimumWidth: rowWidth)
                }
                if remainingLineCount > 0 {
                    Button(action: showMore) {
                        Text(L10n.AgentGitReview.showMoreLines(String(remainingLineCount)))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(
                                minWidth: rowWidth,
                                maxWidth: .infinity,
                                minHeight: 30,
                                alignment: .center
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .frame(minWidth: rowWidth, alignment: .leading)
        }
    }

    private var remainingLineCount: Int {
        max(0, file.rows.count - visibleLineCount)
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
    /// Visible card width. `maxWidth: .infinity` then stretches every row out
    /// to the widest line in the stack, so the tint spans the full scrollable
    /// content instead of stopping at each line's own text.
    let minimumWidth: CGFloat

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
        .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
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
        .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
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
