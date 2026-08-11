import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

struct AgentSidePanelDiffPerformanceTests {
    @Test("Small diff remains unchanged")
    func smallDiffRemainsUnchanged() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        -old
        +new
        """

        #expect(AgentSidePanelDiffLimiter.unavailableReason(for: diff) == nil)
    }

    @Test("UTF-8 byte budget catches large CJK diff before the old character budget")
    func multibyteDiffUsesByteBudget() {
        let diff = String(repeating: "变更内容\n", count: 5_000)

        #expect(diff.count < 96 * 1024)
        #expect(diff.utf8.count > AgentSidePanelDiffLimiter.maximumDisplayUTF8Bytes)
        #expect(AgentSidePanelDiffLimiter.unavailableReason(for: diff) != nil)
    }

    @Test("Line budget refuses narrow but very tall diff")
    func tallDiffUsesLineBudget() {
        let diff = Array(
            repeating: "+x",
            count: AgentSidePanelDiffLimiter.maximumDisplayLines + 1
        ).joined(separator: "\n")

        #expect(diff.utf8.count < AgentSidePanelDiffLimiter.maximumDisplayUTF8Bytes)
        #expect(AgentSidePanelDiffLimiter.unavailableReason(for: diff) != nil)
    }

    @Test("Source files above the editor file limit are rejected before diff generation")
    func oversizedSourceFileIsRejected() {
        let accepted = AgentSidePanelDiffLimiter.fileUnavailableReason(
            byteCount: Int64(AppState.maxFileSize)
        )
        let rejected = AgentSidePanelDiffLimiter.fileUnavailableReason(
            byteCount: Int64(AppState.maxFileSize + 1)
        )

        #expect(accepted == nil)
        #expect(rejected?.contains(String(AppState.maxFileSize)) == true)
    }

    @Test("UTF-8 prefix never splits a multibyte scalar")
    func utf8PrefixKeepsValidScalarBoundary() {
        let text = String(repeating: "你", count: 20)
        let prefix = AgentSidePanelDiffLimiter.utf8Prefix(text, maximumBytes: 17)

        #expect(prefix.utf8.count <= 17)
        #expect(!prefix.contains("�"))
        #expect(text.hasPrefix(prefix))
    }

    @Test("Requested changed file resolves to its exact nested diff path")
    func requestedFileResolvesToChangedPath() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-diff-selection")
        let changes = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "web/src/AdminGatewayTracePanel.tsx",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 4, deleted: 1)
                )
            ]
        )

        let selected = AgentSidePanelDiffSelection.relativePath(
            for: root.appendingPathComponent("web/src/AdminGatewayTracePanel.tsx"),
            changes: changes
        )
        let unrelated = AgentSidePanelDiffSelection.relativePath(
            for: root.appendingPathComponent("web/src/Other.tsx"),
            changes: changes
        )

        #expect(selected == "web/src/AdminGatewayTracePanel.tsx")
        #expect(unrelated == nil)
    }

    @MainActor
    @Test("Transcript click routes a changed file directly to focused Diff")
    func transcriptChangedFileClickRoutesToDiff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_diff_route_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("web/src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("AdminGatewayTracePanel.tsx")
        try Data("export {}".utf8).write(to: file)

        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentWorktreeChanges = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "web/src/AdminGatewayTracePanel.tsx",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 1, deleted: 0)
                )
            ]
        )

        appState.revealAgentReferencedFileInSidePanel("web/src/AdminGatewayTracePanel.tsx")

        #expect(appState.agentSidePanelRequest?.kind == .diff)
        #expect(appState.agentSidePanelRequest?.file?.standardizedFileURL == file.standardizedFileURL)

        appState.agentWorktreeChanges = AgentWorktreeChangeSummary(repositoryRoot: root)
        appState.revealAgentReferencedFileInSidePanel("web/src/AdminGatewayTracePanel.tsx")

        #expect(appState.agentSidePanelRequest?.kind == .preview)
    }

    @MainActor
    @Test("Artifact card opens a changed file directly to focused Diff")
    func artifactFileClickRoutesChangedFileToDiff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_artifact_diff_route_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("summary.md")
        try Data("# Summary".utf8).write(to: file)

        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentWorktreeChanges = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "reports/summary.md",
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: 1, deleted: 0)
                )
            ]
        )

        appState.revealAgentArtifactFileInSidePanel(file)

        #expect(appState.agentSidePanelRequest?.kind == .diff)
        #expect(appState.agentSidePanelRequest?.file?.standardizedFileURL == file.standardizedFileURL)

        appState.agentWorktreeChanges = AgentWorktreeChangeSummary(repositoryRoot: root)
        appState.revealAgentArtifactFileInSidePanel(file)

        #expect(appState.agentSidePanelRequest?.kind == .preview)
        #expect(appState.agentSidePanelRequest?.file?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test("TextKit diff keeps native foreground and line background colors")
    func appKitDiffKeepsNativeColors() throws {
        #expect(AgentDiffColorizer.fontSize == 12)
        let diff = "diff --git a/a.swift b/a.swift\n-old\n+new\n@@ -1 +1 @@\n context"
        let rendered = AgentDiffColorizer.appKitAttributed(
            diff,
            palette: EditorInterfaceSkin.mistForest.palette
        ).value
        let source = rendered.string as NSString
        let fileHeaderRange = source.range(of: "diff --git")
        let deletionRange = source.range(of: "-old")
        let additionRange = source.range(of: "+new")
        let hunkRange = source.range(of: "@@ -1 +1 @@")

        let deletionForeground = try #require(
            rendered.attribute(.foregroundColor, at: deletionRange.location, effectiveRange: nil) as? NSColor
        )
        let additionForeground = try #require(
            rendered.attribute(.foregroundColor, at: additionRange.location, effectiveRange: nil) as? NSColor
        )
        let deletionBackground = rendered.attribute(
            .agentDiffLineBackground,
            at: deletionRange.location,
            effectiveRange: nil
        ) as? NSColor
        let additionBackground = rendered.attribute(
            .agentDiffLineBackground,
            at: additionRange.location,
            effectiveRange: nil
        ) as? NSColor
        let fileHeaderBackground = rendered.attribute(
            .agentDiffLineBackground,
            at: fileHeaderRange.location,
            effectiveRange: nil
        ) as? NSColor
        let fileHeaderFont = rendered.attribute(
            .font,
            at: fileHeaderRange.location,
            effectiveRange: nil
        ) as? NSFont
        let hunkForeground = rendered.attribute(
            .foregroundColor,
            at: hunkRange.location,
            effectiveRange: nil
        ) as? NSColor

        #expect(deletionForeground != additionForeground)
        #expect(deletionBackground != nil)
        #expect(additionBackground != nil)
        #expect(fileHeaderBackground != nil)
        #expect(fileHeaderFont?.pointSize == AgentDiffColorizer.fontSize)
        #expect(hunkForeground == NSColor(EditorInterfaceSkin.mistForest.palette.accent))
        // Glyph-level backgrounds stop where the text stops; the row tint is
        // drawn per line fragment instead.
        #expect(rendered.attribute(
            .backgroundColor,
            at: additionRange.location,
            effectiveRange: nil
        ) == nil)
    }

    @Test("Diff rows tint the full line fragment, not just the glyphs")
    func diffRowsTintFullWidth() throws {
        let source = try Self.source(named: "AgentSidePanelDiffView.swift")
        let cardsSource = try Self.source(named: "AgentGitReviewFileCardsView.swift")

        #expect(source.contains("final class AgentSidePanelDiffBackingTextView: NSTextView"))
        #expect(source.contains("enumerateLineFragments(forGlyphRange:"))
        #expect(source.contains("band.size.width = bandWidth"))
        #expect(source.contains("attributes[.agentDiffLineBackground]"))
        #expect(!source.contains("attributes[.backgroundColor]"))

        #expect(cardsSource.contains("AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth:"))
        #expect(cardsSource.contains("minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading"))
        #expect(!cardsSource.contains("minWidth: 480, alignment: .leading"))
    }

    @Test("Row width never collapses below the measured card viewport")
    func rowWidthTracksViewport() {
        let fallback = AgentGitReviewFileCardsMetrics.fallbackRowWidth
        #expect(AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth: 0) == fallback)
        #expect(AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth: -12) == fallback)
        #expect(AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth: .nan) == fallback)
        #expect(AgentGitReviewFileCardsMetrics.rowWidth(viewportWidth: 720) == 720)
    }

    @Test("Sub-point width jitter never re-enters the layout pass")
    func viewportWidthAdoptionQuantizes() {
        let epsilon = AgentGitReviewFileCardsMetrics.viewportWidthEpsilon

        // A real resize is adopted.
        #expect(AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 0, measured: 720))
        #expect(AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 720, measured: 640))

        // Jitter below the epsilon is dropped, which is what stops the
        // measure → row width → content size → measure loop from spinning.
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 720, measured: 720))
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(
            current: 720,
            measured: 720 + epsilon / 2
        ))
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(
            current: 720,
            measured: 720 - epsilon / 2
        ))

        // Degenerate measurements never overwrite a good width.
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 720, measured: 0))
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 720, measured: -5))
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(current: 720, measured: .nan))

        // Adoption converges: whatever is adopted is a fixed point afterwards.
        let adopted: CGFloat = 641.25
        #expect(!AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth(
            current: adopted,
            measured: adopted
        ))
    }

    @Test("Card viewport is measured outside the horizontal ScrollView")
    func viewportMeasurementSitsOutsideScrollView() throws {
        let cardsSource = try Self.source(named: "AgentGitReviewFileCardsView.swift")

        // The GeometryReader must not hang off `diffRows`: measuring the
        // ScrollView whose content width it feeds closes a layout loop that
        // pegs the main thread inside LazySubviewPlacements.placeSubviews.
        let diffRowsRange = try #require(cardsSource.range(of: "private var diffRows: some View {"))
        let afterDiffRows = cardsSource[diffRowsRange.upperBound...]
        let nextMember = afterDiffRows.range(of: "\n    private var ")?.lowerBound
            ?? afterDiffRows.endIndex
        let diffRowsBody = afterDiffRows[..<nextMember]
        #expect(!diffRowsBody.contains("GeometryReader"))

        // ...and the write-back must go through the quantizing gate.
        #expect(cardsSource.contains("AgentGitReviewFileCardsMetrics.shouldAdoptViewportWidth("))
    }

    @Test("Worktree file signatures avoid the attributesOfItem xattr walk")
    func fileSignatureMetadataUsesStat() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xedit-signature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("sample.txt")
        let payload = Data("hello signature".utf8)
        try payload.write(to: fileURL)

        let metadata = try #require(AppState.fileSignatureMetadata(atPath: fileURL.path))
        #expect(metadata.size == Int64(payload.count))
        #expect(metadata.modified > 0)

        // Matches what attributesOfItem reported before the switch to lstat.
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let expectedSize = try #require((attributes[.size] as? NSNumber)?.int64Value)
        #expect(metadata.size == expectedSize)

        // Missing paths degrade to nil rather than a bogus zero signature.
        #expect(AppState.fileSignatureMetadata(atPath: directory.appendingPathComponent("nope").path) == nil)

        // Symlinks describe the link, not the target, so a retargeted link
        // still changes the signature.
        let linkURL = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        let linkMetadata = try #require(AppState.fileSignatureMetadata(atPath: linkURL.path))
        #expect(linkMetadata.size != metadata.size)
    }

    @Test("Diff panel uses bounded Git loading and non-contiguous TextKit layout")
    func diffPanelAvoidsWholeDocumentSwiftUILayout() throws {
        let source = try Self.source(named: "AgentSidePanelDiffView.swift")
        let loaderSource = try Self.source(named: "AgentGitReview.swift")

        #expect(source.contains("LazyVStack(spacing: 0)"))
        #expect(source.contains("AgentGitReviewLoader.load("))
        #expect(loaderSource.contains("loadAgentWorktreeChangeSummary(status: status)"))
        #expect(loaderSource.contains("loadUntrackedDiffPreviewSection"))
        #expect(source.contains(".onCompatibleChange(of: appState.agentSidePanelSelectedFile)"))
        #expect(source.contains("selectRequestedFile(appState.agentSidePanelSelectedFile"))
        #expect(source.contains("AgentSidePanelDiffBackingTextView("))
        #expect(source.contains("allowsNonContiguousLayout = true"))
        #expect(source.contains("AgentDiffColorizer.appKitAttributed"))
        #expect(source.contains("textView.textStorage?.setAttributedString(text)"))
        #expect(!source.contains("NSAttributedString(text)"))
        #expect(!source.contains("Text(cachedText)"))
        #expect(!source.contains("ScrollView([.vertical, .horizontal])"))
    }

    @Test("Global worktree preview budget counts UTF-8 bytes")
    func globalPreviewUsesByteBudget() throws {
        let source = try Self.source(named: "AppStateGitStatus.swift")

        #expect(source.contains("worktreeDiffPreviewMaxUTF8Bytes"))
        #expect(source.contains("diff.utf8.count > worktreeDiffPreviewMaxUTF8Bytes"))
        #expect(!source.contains("worktreeDiffPreviewMaxCharacters"))
    }

    /// Renders a real file card wider than its diff text: the added/deleted
    /// tint must reach the right edge of the card instead of stopping at the
    /// old fixed 480pt row width.
    @MainActor
    @Test("Rendered diff rows tint the card all the way to its right edge")
    func renderedRowsTintReachesCardEdge() async throws {
        let cardWidth: CGFloat = 900
        let changes = AgentWorktreeChangeSummary(
            repositoryRoot: URL(fileURLWithPath: "/tmp/review"),
            files: [
                AgentFileChangeSummary(
                    path: "Sources/App.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 2, deleted: 1)
                )
            ]
        )
        let snapshot = AgentGitReviewSnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/review"),
            branchName: "develop",
            scope: .uncommitted,
            changes: changes,
            overviewDiff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1234567..7654321 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,3 +1,4 @@
             let first = true
            -let title = "Old"
            +let title = "New"
            +let enabled = true
             return title
            """,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
        let root = AgentGitReviewFileCardsView(
            snapshot: snapshot,
            palette: EditorInterfaceSkin.mistForest.palette,
            collapsedPaths: .constant([]),
            openFile: { _ in }
        )
        .frame(width: cardWidth, height: 260)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 260)
        hostingView.layoutSubtreeIfNeeded()
        // The card measures its viewport asynchronously, so let SwiftUI settle
        // before sampling pixels.
        try await Task.sleep(nanoseconds: 300_000_000)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        // Sample a column near the right edge, well beyond both the diff text
        // and the previous 480pt row width.
        let sampleX = Int(cardWidth) - 40
        let column = (0..<Int(hostingView.bounds.height)).compactMap {
            bitmap.colorAt(x: sampleX, y: $0)?.usingColorSpace(.sRGB)
        }
        // Untinted card rows dominate the column, so they define the baseline
        // that the added/deleted tints are measured against.
        let baseline = try #require(
            Dictionary(grouping: column) { color in
                [color.redComponent, color.greenComponent, color.blueComponent]
                    .map { Int($0 * 255) }
            }
            .max { $0.value.count < $1.value.count }?
            .value.first
        )

        let tints = column.map { Tint($0, baseline: baseline) }
        let additionRows = tints.filter { $0 == .addition }.count
        let deletionRows = tints.filter { $0 == .deletion }.count

        // The fixture has one deleted and two added lines, all of equal height,
        // so the tinted bands near the right edge must keep that 1:2 ratio.
        #expect(deletionRows > 0)
        #expect(additionRows > 0)
        #expect(abs(additionRows - 2 * deletionRows) <= 4)
    }

    private enum Tint: Equatable {
        case addition
        case deletion
        case none

        init(_ color: NSColor, baseline: NSColor) {
            let red = color.redComponent - baseline.redComponent
            let green = color.greenComponent - baseline.greenComponent
            let blue = color.blueComponent - baseline.blueComponent
            let threshold = 0.004
            if green - max(red, blue) > threshold {
                self = .addition
            } else if red - max(green, blue) > threshold {
                self = .deletion
            } else {
                self = .none
            }
        }
    }

    private static func source(named fileName: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
