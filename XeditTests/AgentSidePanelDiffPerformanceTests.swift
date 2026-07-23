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
            .backgroundColor,
            at: deletionRange.location,
            effectiveRange: nil
        ) as? NSColor
        let additionBackground = rendered.attribute(
            .backgroundColor,
            at: additionRange.location,
            effectiveRange: nil
        ) as? NSColor
        let fileHeaderBackground = rendered.attribute(
            .backgroundColor,
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
        #expect(source.contains("NSTextView.scrollableTextView()"))
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
