//
//  AgentSidePanelDiffView.swift
//  WillDeep
//
//  File-first worktree diff browser for the Agent side panel. The list is
//  cheap Git status/numstat metadata; a file's actual diff is loaded only
//  after selection. Diff text is rendered by TextKit with non-contiguous
//  layout so opening a large worktree never asks SwiftUI to measure one huge
//  Text inside an unbounded two-axis ScrollView.
//

import AppKit
import SwiftUI

struct AgentSidePanelDiffView: View {
    @EnvironmentObject private var appState: AppState
    @State private var state: LoadState = .idle
    @State private var selectedPath: String?
    @State private var detailState: DetailState = .idle
    @State private var refreshTick = 0

    private enum LoadState {
        case idle
        case loading
        case loaded(AgentSidePanelDiffSnapshot)
        case empty
        case noWorkspace
        case notRepo
    }

    private enum DetailState {
        case idle
        case loading
        case loaded(text: String, cacheKey: String)
        case unavailable(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
        }
        .task(id: refreshTick) {
            await reloadFileList()
        }
        .task(id: selectedPath) {
            await reloadSelectedDiff()
        }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            selectedPath = nil
            detailState = .idle
            refreshTick &+= 1
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if selectedPath != nil {
                Button {
                    selectedPath = nil
                    detailState = .idle
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(L10n.AgentSidePanel.diffBackToFiles)
            }

            Group {
                if let selectedChange {
                    Text(selectedChange.path)
                } else {
                    switch state {
                    case .loaded(let snapshot):
                        Text(L10n.AgentSidePanel.diffSummary(Self.dateFormatter.string(from: snapshot.loadedAt)))
                    case .loading:
                        Text(L10n.AgentSidePanel.diffLoading)
                    default:
                        Text(" ")
                    }
                }
            }
            .font(AgentDesign.captionFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                selectedPath = nil
                detailState = .idle
                refreshTick &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(L10n.AgentSidePanel.refresh)
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            progress
        case .loaded(let snapshot):
            if selectedPath == nil {
                fileList(snapshot.changes)
            } else {
                diffDetail
            }
        case .empty:
            placeholder(systemImage: "checkmark.seal", text: L10n.AgentSidePanel.diffEmpty)
        case .noWorkspace:
            AgentSidePanelWorkspaceRequiredView()
        case .notRepo:
            placeholder(systemImage: "exclamationmark.triangle", text: L10n.AgentSidePanel.diffNotRepo)
        }
    }

    private func fileList(_ changes: AgentWorktreeChangeSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(
                    L10n.AgentSidePanel.diffFilesSummary(
                        String(changes.fileCount),
                        String(changes.totalAddedLines),
                        String(changes.totalDeletedLines)
                    )
                )
                .font(AgentDesign.captionFont)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.35)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(changes.files) { change in
                        Button {
                            selectedPath = change.path
                        } label: {
                            AgentSidePanelDiffFileRow(change: change)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)

                        Divider()
                            .opacity(0.28)
                            .padding(.leading, 34)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var diffDetail: some View {
        switch detailState {
        case .idle, .loading:
            progress
        case .loaded(let text, let cacheKey):
            let palette = appState.editorSettings.interfaceSkin.palette
            AgentSidePanelColoredDiffView(
                diff: text,
                cacheKey: "\(appState.editorSettings.interfaceSkin.id)|\(cacheKey)",
                palette: palette
            )
        case .unavailable(let message):
            placeholder(systemImage: "doc.questionmark", text: message)
        }
    }

    private var progress: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var selectedChange: AgentFileChangeSummary? {
        guard case .loaded(let snapshot) = state, let selectedPath else { return nil }
        return snapshot.changes.change(for: selectedPath)
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        if case .loading = detailState { return true }
        return false
    }

    private func reloadFileList() async {
        guard let root = resolveWorkspaceRoot() else {
            state = .noWorkspace
            return
        }
        state = .loading

        let result = await Task.detached(priority: .userInitiated) {
            let status = AppState.loadGitStatus(for: root)
            guard status.isRepository else { return LoadState.notRepo }
            let changes = AppState.loadAgentWorktreeChangeSummary(status: status)
            guard !changes.isEmpty, let repositoryRoot = status.repositoryRoot else {
                return LoadState.empty
            }
            return LoadState.loaded(
                AgentSidePanelDiffSnapshot(
                    repositoryRoot: repositoryRoot,
                    changes: changes,
                    loadedAt: Date()
                )
            )
        }.value

        guard !Task.isCancelled else { return }
        state = result
    }

    private func reloadSelectedDiff() async {
        guard let change = selectedChange,
              case .loaded(let snapshot) = state else {
            detailState = .idle
            return
        }
        let requestedPath = change.path
        detailState = .loading

        let result = await Task.detached(priority: .userInitiated) {
            let rawDiff: String
            if change.kind == .untracked {
                switch AppState.loadUntrackedDiffPreviewSection(
                    change,
                    repositoryRoot: snapshot.repositoryRoot
                ) {
                case .diff(let diff):
                    rawDiff = diff
                case .summaryReason(let reason):
                    return DetailState.unavailable(reason)
                }
            } else {
                rawDiff = AppState.runGit(
                    arguments: ["diff", "--no-ext-diff", "HEAD", "--", change.path],
                    in: snapshot.repositoryRoot
                )
            }

            guard !rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return DetailState.unavailable(L10n.AgentSidePanel.diffFileUnavailable)
            }
            return DetailState.loaded(
                text: AgentSidePanelDiffLimiter.displayText(for: rawDiff),
                cacheKey: "\(snapshot.loadedAt.timeIntervalSinceReferenceDate)|\(requestedPath)"
            )
        }.value

        guard !Task.isCancelled, selectedPath == requestedPath else { return }
        detailState = result
    }

    private func resolveWorkspaceRoot() -> URL? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct AgentSidePanelDiffSnapshot {
    let repositoryRoot: URL
    let changes: AgentWorktreeChangeSummary
    let loadedAt: Date
}

private struct AgentSidePanelDiffFileRow: View {
    let change: AgentFileChangeSummary

    var body: some View {
        HStack(spacing: 8) {
            Text(change.kind.rawValue)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if change.path != change.fileName {
                    Text(change.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if change.hasKnownLineStats {
                HStack(spacing: 4) {
                    Text("+\(change.addedLines)")
                        .foregroundStyle(Color.green.opacity(0.85))
                    Text("-\(change.deletedLines)")
                        .foregroundStyle(Color.red.opacity(0.85))
                }
                .font(.system(size: 10, design: .monospaced))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch change.kind {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

private struct AgentSidePanelColoredDiffView: View {
    let diff: String
    let cacheKey: String
    let palette: EditorInterfaceSkinPalette
    @State private var cachedKey = ""
    @State private var cachedText: AttributedString?

    var body: some View {
        Group {
            if cachedKey == cacheKey, let cachedText {
                AgentSidePanelDiffTextView(text: cachedText, contentID: cacheKey)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentDiffColorizer.background(for: palette))
        .task(id: cacheKey) {
            await refreshIfNeeded()
        }
    }

    private func refreshIfNeeded() async {
        guard cachedKey != cacheKey else { return }
        cachedText = nil
        let nextKey = cacheKey
        let nextDiff = diff
        let nextPalette = palette
        let text = await Task.detached(priority: .userInitiated) {
            AgentDiffColorizer.attributed(nextDiff, palette: nextPalette)
        }.value
        guard !Task.isCancelled, cacheKey == nextKey else { return }
        cachedText = text
        cachedKey = nextKey
    }
}

/// TextKit-backed diff surface. `allowsNonContiguousLayout` is the key:
/// TextKit lays out the visible viewport instead of asking SwiftUI to measure
/// every glyph before the side panel can paint its first frame.
struct AgentSidePanelDiffTextView: NSViewRepresentable {
    let text: AttributedString
    let contentID: String

    final class Coordinator {
        var displayedContentID: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = scrollView.contentSize
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.layoutManager?.allowsNonContiguousLayout = true
        applyText(to: textView, in: scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.displayedContentID != contentID,
              let textView = scrollView.documentView as? NSTextView else { return }
        applyText(to: textView, in: scrollView, context: context)
    }

    private func applyText(
        to textView: NSTextView,
        in scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.displayedContentID = contentID
        textView.textStorage?.setAttributedString(NSAttributedString(text))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

enum AgentSidePanelDiffLimiter {
    nonisolated static let maximumDisplayUTF8Bytes = 32 * 1024
    nonisolated static let maximumDisplayLines = 600
    nonisolated static let sampleUTF8Bytes = 24 * 1024

    nonisolated static func displayText(for diff: String) -> String {
        let utf8ByteCount = diff.utf8.count
        let lineCount = lineCount(in: diff)
        guard utf8ByteCount > maximumDisplayUTF8Bytes || lineCount > maximumDisplayLines else {
            return diff
        }

        let sample = utf8Prefix(diff, maximumBytes: sampleUTF8Bytes)
        return L10n.AgentSidePanel.diffTruncated(
            String(utf8ByteCount),
            String(lineCount),
            String(maximumDisplayUTF8Bytes),
            String(maximumDisplayLines),
            sample
        )
    }

    nonisolated static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    nonisolated static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0, text.utf8.count > maximumBytes else {
            return maximumBytes > 0 ? text : ""
        }
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
        while end > utf8.startIndex,
              end < utf8.endIndex,
              utf8[end] & 0b1100_0000 == 0b1000_0000 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }
}

/// Colorizes a unified diff off the main thread. Font is baked into the
/// attributed string because the AppKit surface no longer inherits a SwiftUI
/// `.font` modifier.
enum AgentDiffColorizer {
    nonisolated static func background(for palette: EditorInterfaceSkinPalette) -> Color {
        palette.previewBase
    }

    nonisolated static func attributed(
        _ diff: String,
        palette: EditorInterfaceSkinPalette
    ) -> AttributedString {
        let addition = Color(red: 0.18, green: 0.62, blue: 0.31)
        let deletion = Color(red: 0.83, green: 0.24, blue: 0.30)
        let hunk = palette.accent
        let meta = palette.secondaryText
        let context = palette.previewInk
        let font = Font.system(size: 11, design: .monospaced)

        var result = AttributedString()
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.font = font
            piece.foregroundColor = color(
                forDiffLine: line,
                addition: addition,
                deletion: deletion,
                hunk: hunk,
                meta: meta,
                context: context
            )
            result.append(piece)
            if index < lines.count - 1 {
                var newline = AttributedString("\n")
                newline.font = font
                newline.foregroundColor = context
                result.append(newline)
            }
        }
        return result
    }

    nonisolated private static func color(
        forDiffLine line: String,
        addition: Color,
        deletion: Color,
        hunk: Color,
        meta: Color,
        context: Color
    ) -> Color {
        if line.hasPrefix("@@") { return hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
            return meta
        }
        if line.hasPrefix("+") { return addition }
        if line.hasPrefix("-") { return deletion }
        return context
    }
}
