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
    @Environment(\.colorScheme) private var colorScheme
    @State private var state: LoadState = .idle
    @State private var scope: AgentGitReviewScope = .uncommitted
    @State private var selectedPath: String?
    @State private var detailState: DetailState = .idle
    @State private var showsFileList = false
    @State private var showsCommitPopover = false
    @State private var commitMessage = ""
    @State private var includesUnstagedChanges = true
    @State private var commitState: CommitState = .idle
    @State private var collapsedPaths: Set<String> = []
    @State private var refreshTick = 0

    private enum LoadState {
        case idle
        case loading
        case loaded(AgentGitReviewSnapshot)
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

    private enum CommitState {
        case idle
        case running
        case finished(AgentGitCommitOutcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            content
            if canShowCommitBar {
                Divider().opacity(0.5)
                commitBar
            }
        }
        .task(id: "\(scope.rawValue)-\(refreshTick)") {
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
        .onCompatibleChange(of: appState.agentSidePanelSelectedFile) { _, file in
            selectRequestedFile(file)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if selectedPath != nil {
                Button {
                    clearSelection()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(L10n.AgentSidePanel.diffBackToFiles)
            }

            if let selectedChange {
                Text(selectedChange.path)
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Menu {
                    ForEach(AgentGitReviewScope.allCases) { candidate in
                        Button {
                            selectScope(candidate)
                        } label: {
                            if candidate == scope {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(scope.title)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer(minLength: 0)

            if case .loaded(let snapshot) = state {
                HStack(spacing: 4) {
                    Text("+\(snapshot.changes.totalAddedLines)")
                        .foregroundStyle(.green)
                    Text("-\(snapshot.changes.totalDeletedLines)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()

                Menu {
                    ForEach(snapshot.changes.files) { change in
                        Button {
                            select(change: change, in: snapshot)
                        } label: {
                            Text(change.path)
                        }
                    }
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.AgentGitReview.jumpToFile)

                Button {
                    selectedPath = nil
                    detailState = .idle
                    showsFileList.toggle()
                } label: {
                    Image(systemName: showsFileList ? "doc.text" : "list.bullet")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(showsFileList
                    ? L10n.AgentGitReview.showCombinedDiff
                    : L10n.AgentGitReview.showFileList)

                if !showsFileList, selectedPath == nil {
                    Button {
                        toggleAllFiles(in: snapshot)
                    } label: {
                        Image(systemName: allFilesCollapsed(in: snapshot)
                            ? "rectangle.expand.vertical"
                            : "rectangle.compress.vertical")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(allFilesCollapsed(in: snapshot)
                        ? L10n.AgentGitReview.expandAllFiles
                        : L10n.AgentGitReview.collapseAllFiles)
                }
            }

            Button {
                clearSelection()
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
            if selectedPath != nil {
                diffDetail
            } else if showsFileList {
                fileList(snapshot)
            } else {
                overview(snapshot)
            }
        case .empty:
            placeholder(systemImage: "checkmark.seal", text: emptyMessage)
        case .noWorkspace:
            AgentSidePanelWorkspaceRequiredView()
        case .notRepo:
            placeholder(systemImage: "exclamationmark.triangle", text: L10n.AgentSidePanel.diffNotRepo)
        }
    }

    private func fileList(_ snapshot: AgentGitReviewSnapshot) -> some View {
        let changes = snapshot.changes
        return VStack(spacing: 0) {
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
                            select(change: change, in: snapshot)
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
    private func overview(_ snapshot: AgentGitReviewSnapshot) -> some View {
        if snapshot.overviewDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder(systemImage: "checkmark.seal", text: emptyMessage)
        } else {
            let palette = appState.editorSettings.interfaceSkin.palette
            let document = AgentGitReviewDiffDocument.parse(
                snapshot.overviewDiff,
                changes: snapshot.changes
            )
            if document.files.isEmpty {
                AgentSidePanelColoredDiffView(
                    diff: snapshot.overviewDiff,
                    cacheKey: [
                        appState.editorSettings.interfaceSkin.id,
                        snapshot.scope.rawValue,
                        String(snapshot.loadedAt.timeIntervalSinceReferenceDate),
                    ].joined(separator: "|"),
                    palette: palette
                )
            } else {
                AgentGitReviewFileCardsView(
                    snapshot: snapshot,
                    palette: palette,
                    collapsedPaths: $collapsedPaths,
                    openFile: { change in
                        select(change: change, in: snapshot)
                    }
                )
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

        let requestedScope = scope
        let result = await Task.detached(priority: .userInitiated) {
            guard let snapshot = AgentGitReviewLoader.load(
                workspaceRoot: root,
                scope: requestedScope
            ) else {
                let status = AppState.loadGitStatus(for: root)
                return status.isRepository ? LoadState.empty : LoadState.notRepo
            }
            return snapshot.changes.isEmpty
                ? LoadState.empty
                : LoadState.loaded(snapshot)
        }.value

        guard !Task.isCancelled, scope == requestedScope else { return }
        state = result
        if case .loaded(let snapshot) = result {
            selectRequestedFile(appState.agentSidePanelSelectedFile, in: snapshot)
        } else {
            selectedPath = nil
            detailState = .idle
        }
    }

    private func reloadSelectedDiff() async {
        guard let change = selectedChange,
              case .loaded(let snapshot) = state else {
            detailState = .idle
            return
        }
        let requestedPath = change.path
        detailState = .loading
        let requestedScope = scope

        let result = await Task.detached(priority: .userInitiated) {
            switch AgentGitReviewLoader.loadDetail(
                scope: requestedScope,
                change: change,
                repositoryRoot: snapshot.repositoryRoot
            ) {
            case .text(let rawDiff):
                return DetailState.loaded(
                    text: rawDiff,
                    cacheKey: "\(snapshot.loadedAt.timeIntervalSinceReferenceDate)|\(requestedPath)"
                )
            case .unavailable(let reason):
                return DetailState.unavailable(reason)
            }
        }.value

        guard !Task.isCancelled,
              scope == requestedScope,
              selectedPath == requestedPath else { return }
        detailState = result
    }

    private func clearSelection() {
        appState.agentSidePanelSelectedFile = nil
        selectedPath = nil
        detailState = .idle
    }

    private func selectRequestedFile(_ file: URL?) {
        guard case .loaded(let snapshot) = state else { return }
        selectRequestedFile(file, in: snapshot)
    }

    private func selectRequestedFile(_ file: URL?, in snapshot: AgentGitReviewSnapshot) {
        selectedPath = file.flatMap {
            AgentSidePanelDiffSelection.relativePath(for: $0, changes: snapshot.changes)
        }
        detailState = .idle
    }

    private func select(change: AgentFileChangeSummary, in snapshot: AgentGitReviewSnapshot) {
        selectedPath = change.path
        showsFileList = false
        appState.agentSidePanelSelectedFile = snapshot.repositoryRoot
            .appendingPathComponent(change.path)
            .standardizedFileURL
    }

    private func selectScope(_ newScope: AgentGitReviewScope) {
        guard scope != newScope else { return }
        scope = newScope
        selectedPath = nil
        detailState = .idle
        showsFileList = false
        collapsedPaths = []
        appState.agentSidePanelSelectedFile = nil
    }

    private func allFilesCollapsed(in snapshot: AgentGitReviewSnapshot) -> Bool {
        let paths = Set(snapshot.changes.files.map(\.path))
        return !paths.isEmpty && paths.isSubset(of: collapsedPaths)
    }

    private func toggleAllFiles(in snapshot: AgentGitReviewSnapshot) {
        let paths = Set(snapshot.changes.files.map(\.path))
        collapsedPaths = allFilesCollapsed(in: snapshot) ? [] : paths
    }

    private func resolveWorkspaceRoot() -> URL? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
    }

    private var canShowCommitBar: Bool {
        guard scope != .lastCommit,
              case .loaded = state else { return false }
        return true
    }

    private var emptyMessage: String {
        switch scope {
        case .uncommitted: return L10n.AgentSidePanel.diffEmpty
        case .unstaged: return L10n.AgentGitReview.unstagedEmpty
        case .staged: return L10n.AgentGitReview.stagedEmpty
        case .lastCommit: return L10n.AgentGitReview.lastCommitEmpty
        }
    }

    /// Geometry for the monochrome commit actions. The bar button and the
    /// popover pair share it so the black/white call-to-action reads as one
    /// control wherever it appears.
    private static let commitButtonHeight: CGFloat = 22
    private static let commitButtonCornerRadius: CGFloat = 6

    private var commitActionsDisabled: Bool {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommitting
    }

    private func commitActionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: Self.commitButtonHeight)
    }

    private var commitBar: some View {
        HStack(spacing: 8) {
            if case .loaded(let snapshot) = state {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(snapshot.branchName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                commitState = .idle
                showsCommitPopover.toggle()
            } label: {
                Label(L10n.AgentGitReview.commit, systemImage: "arrow.down.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: Self.commitButtonHeight)
            }
            .buttonStyle(
                AgentApprovalPrimaryButtonStyle(
                    colorScheme: colorScheme,
                    cornerRadius: Self.commitButtonCornerRadius
                )
            )
            .focusable(false)
            .popover(isPresented: $showsCommitPopover, arrowEdge: .bottom) {
                commitPopover
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var commitPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(commitBranchName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if case .loaded(let snapshot) = state {
                    Text("+\(snapshot.changes.totalAddedLines)")
                        .foregroundStyle(.green)
                    Text("-\(snapshot.changes.totalDeletedLines)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            ZStack(alignment: .topLeading) {
                if commitMessage.isEmpty {
                    Text(L10n.AgentGitReview.commitMessagePlaceholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $commitMessage)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(2)
            }
            .frame(width: 310, height: 68)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Toggle(
                L10n.AgentGitReview.includeUnstaged,
                isOn: $includesUnstagedChanges
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            if case .finished(let outcome) = commitState {
                Label(
                    outcome.message,
                    systemImage: outcome.commitCreated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(outcome.commitCreated ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    performCommit(pushAfterCommit: false)
                } label: {
                    commitActionLabel(L10n.AgentGitReview.commit)
                }
                .buttonStyle(
                    AgentApprovalPrimaryButtonStyle(
                        colorScheme: colorScheme,
                        cornerRadius: Self.commitButtonCornerRadius
                    )
                )
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    performCommit(pushAfterCommit: true)
                } label: {
                    commitActionLabel(L10n.AgentGitReview.commitAndPush)
                }
                .buttonStyle(
                    AgentApprovalSecondaryButtonStyle(
                        colorScheme: colorScheme,
                        cornerRadius: Self.commitButtonCornerRadius
                    )
                )

                if case .running = commitState {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .controlSize(.small)
            // The monochrome styles paint their own fill, so SwiftUI's
            // automatic disabled dimming for system button styles no longer
            // applies — fade the pair explicitly or a disabled Commit still
            // looks fully live.
            .opacity(commitActionsDisabled ? 0.42 : 1)
            .disabled(commitActionsDisabled)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var commitBranchName: String {
        guard case .loaded(let snapshot) = state else {
            return L10n.AgentGitReview.detached
        }
        return snapshot.branchName
    }

    private var isCommitting: Bool {
        if case .running = commitState { return true }
        return false
    }

    private func performCommit(pushAfterCommit: Bool) {
        guard case .loaded(let snapshot) = state, !isCommitting else { return }
        let root = snapshot.repositoryRoot
        let message = commitMessage
        let includeUnstaged = includesUnstagedChanges
        commitState = .running

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AgentGitCommitService.commit(
                    repositoryRoot: root,
                    message: message,
                    includeUnstaged: includeUnstaged,
                    pushAfterCommit: pushAfterCommit
                )
            }.value
            commitState = .finished(outcome)
            guard outcome.commitCreated else { return }
            commitMessage = ""
            appState.refreshGitStatus()
            appState.refreshActiveAgentWorktreeChanges()
            refreshTick &+= 1
        }
    }
}

/// Resolves a requested absolute file URL back to the exact relative path in
/// a worktree snapshot. Comparing standardized absolute URLs avoids prefix
/// bugs (`/repo-a` vs `/repo-a-copy`) and supports nested paths and Unicode.
enum AgentSidePanelDiffSelection {
    nonisolated static func relativePath(
        for file: URL,
        changes: AgentWorktreeChangeSummary
    ) -> String? {
        guard let repositoryRoot = changes.repositoryRoot else { return nil }
        let targetPath = file.standardizedFileURL.path
        return changes.files.first { change in
            repositoryRoot
                .appendingPathComponent(change.path)
                .standardizedFileURL
                .path == targetPath
        }?.path
    }
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
    @State private var cachedText: NSAttributedString?

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
        let rendered = await Task.detached(priority: .userInitiated) {
            AgentDiffColorizer.appKitAttributed(nextDiff, palette: nextPalette)
        }.value
        guard !Task.isCancelled, cacheKey == nextKey else { return }
        cachedText = rendered.value
        cachedKey = nextKey
    }
}

/// `.backgroundColor` only tints the glyphs a line actually contains, so an
/// added or deleted line stops painting where its text ends and the highlight
/// looks half-drawn. Paint the tint per line fragment across the whole content
/// width instead, and keep the character attribute purely as the marker.
final class AgentSidePanelDiffBackingTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        drawLineBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawLineBackgrounds(in dirtyRect: NSRect) {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0 else { return }

        let origin = textContainerOrigin
        let containerRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let bandWidth = max(bounds.width, dirtyRect.maxX)

        textStorage.enumerateAttribute(
            .agentDiffLineBackground,
            in: characterRange,
            options: []
        ) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let runGlyphs = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard runGlyphs.length > 0 else { return }
            color.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: runGlyphs) { rect, _, _, _, _ in
                var band = rect.offsetBy(dx: origin.x, dy: origin.y)
                band.origin.x = 0
                band.size.width = bandWidth
                band.fill()
            }
        }
    }
}

extension NSAttributedString.Key {
    nonisolated static let agentDiffLineBackground = NSAttributedString.Key(
        "agentDiffLineBackground"
    )
}

/// TextKit-backed diff surface. `allowsNonContiguousLayout` is the key:
/// TextKit lays out the visible viewport instead of asking SwiftUI to measure
/// every glyph before the side panel can paint its first frame.
struct AgentSidePanelDiffTextView: NSViewRepresentable {
    let text: NSAttributedString
    let contentID: String

    final class Coordinator {
        var displayedContentID: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = AgentSidePanelDiffBackingTextView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 320)
        )
        scrollView.documentView = textView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

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
        textView.textStorage?.setAttributedString(text)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

enum AgentSidePanelDiffLimiter {
    nonisolated static let maximumDisplayUTF8Bytes = 32 * 1024
    nonisolated static let maximumDisplayLines = 600

    nonisolated static func fileUnavailableReason(byteCount: Int64) -> String? {
        guard byteCount > Int64(AppState.maxFileSize) else { return nil }
        return L10n.AgentSidePanel.diffSourceFileTooLarge(
            String(byteCount),
            String(AppState.maxFileSize)
        )
    }

    nonisolated static func unavailableReason(for diff: String) -> String? {
        let utf8ByteCount = diff.utf8.count
        let lineCount = lineCount(in: diff)
        guard utf8ByteCount > maximumDisplayUTF8Bytes || lineCount > maximumDisplayLines else {
            return nil
        }

        return L10n.AgentSidePanel.diffTooLarge(
            String(utf8ByteCount),
            String(lineCount),
            String(maximumDisplayUTF8Bytes),
            String(maximumDisplayLines)
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
    nonisolated static let fontSize: CGFloat = 12

    struct AppKitResult: @unchecked Sendable {
        let value: NSAttributedString
    }

    nonisolated private enum LineKind: Equatable {
        case fileHeader
        case addition
        case deletion
        case hunk
        case meta
        case context
    }

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
        let font = Font.system(size: fontSize, design: .monospaced)
        let headerFont = Font.system(size: fontSize, weight: .semibold, design: .monospaced)

        var result = AttributedString()
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.font = lineKind(line) == .fileHeader ? headerFont : font
            piece.foregroundColor = color(
                for: lineKind(line),
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

    /// The side panel is backed by `NSTextView`, so build native AppKit
    /// attributes instead of round-tripping SwiftUI attributes through
    /// `NSAttributedString`. That bridge can drop `Color` runs and leave the
    /// file-detail diff looking like unstyled plain text.
    nonisolated static func appKitAttributed(
        _ diff: String,
        palette: EditorInterfaceSkinPalette
    ) -> AppKitResult {
        let addition = NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.31, alpha: 1)
        let deletion = NSColor(calibratedRed: 0.83, green: 0.24, blue: 0.30, alpha: 1)
        let hunk = NSColor(palette.accent)
        let meta = NSColor(palette.secondaryText)
        let context = NSColor(palette.previewInk)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let result = NSMutableAttributedString()
        let lines = diff.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let kind = lineKind(line)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: kind == .fileHeader ? headerFont : font,
                .foregroundColor: appKitColor(
                    for: kind,
                    addition: addition,
                    deletion: deletion,
                    hunk: hunk,
                    meta: meta,
                    context: context
                ),
            ]
            // Row tint is drawn per line fragment by the backing text view, so
            // this attribute marks the line rather than painting the glyphs.
            switch kind {
            case .fileHeader:
                attributes[.agentDiffLineBackground] = NSColor(palette.controlFill)
            case .addition:
                attributes[.agentDiffLineBackground] = addition.withAlphaComponent(0.12)
            case .deletion:
                attributes[.agentDiffLineBackground] = deletion.withAlphaComponent(0.12)
            case .hunk, .meta, .context:
                break
            }
            result.append(NSAttributedString(string: line, attributes: attributes))
            if index < lines.count - 1 {
                var newlineAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: context,
                ]
                // Empty added/deleted lines carry no glyphs of their own; the
                // trailing newline is what gives them a line fragment to tint.
                if let tint = attributes[.agentDiffLineBackground] {
                    newlineAttributes[.agentDiffLineBackground] = tint
                }
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: newlineAttributes
                ))
            }
        }

        return AppKitResult(value: NSAttributedString(attributedString: result))
    }

    nonisolated private static func lineKind(_ line: String) -> LineKind {
        if line.hasPrefix("diff --git ") { return .fileHeader }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
            return .meta
        }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .deletion }
        return .context
    }

    nonisolated private static func color(
        for kind: LineKind,
        addition: Color,
        deletion: Color,
        hunk: Color,
        meta: Color,
        context: Color
    ) -> Color {
        switch kind {
        case .fileHeader: return context
        case .addition: return addition
        case .deletion: return deletion
        case .hunk: return hunk
        case .meta: return meta
        case .context: return context
        }
    }

    nonisolated private static func appKitColor(
        for kind: LineKind,
        addition: NSColor,
        deletion: NSColor,
        hunk: NSColor,
        meta: NSColor,
        context: NSColor
    ) -> NSColor {
        switch kind {
        case .fileHeader: return context
        case .addition: return addition
        case .deletion: return deletion
        case .hunk: return hunk
        case .meta: return meta
        case .context: return context
        }
    }
}
