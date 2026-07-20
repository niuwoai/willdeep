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

        #expect(AgentSidePanelDiffLimiter.displayText(for: diff) == diff)
    }

    @Test("UTF-8 byte budget catches large CJK diff before the old character budget")
    func multibyteDiffUsesByteBudget() {
        let diff = String(repeating: "变更内容\n", count: 5_000)

        #expect(diff.count < 96 * 1024)
        #expect(diff.utf8.count > AgentSidePanelDiffLimiter.maximumDisplayUTF8Bytes)
        #expect(AgentSidePanelDiffLimiter.displayText(for: diff) != diff)
    }

    @Test("Line budget truncates narrow but very tall diff")
    func tallDiffUsesLineBudget() {
        let diff = Array(
            repeating: "+x",
            count: AgentSidePanelDiffLimiter.maximumDisplayLines + 1
        ).joined(separator: "\n")

        #expect(diff.utf8.count < AgentSidePanelDiffLimiter.maximumDisplayUTF8Bytes)
        #expect(AgentSidePanelDiffLimiter.displayText(for: diff) != diff)
    }

    @Test("UTF-8 prefix never splits a multibyte scalar")
    func utf8PrefixKeepsValidScalarBoundary() {
        let text = String(repeating: "你", count: 20)
        let prefix = AgentSidePanelDiffLimiter.utf8Prefix(text, maximumBytes: 17)

        #expect(prefix.utf8.count <= 17)
        #expect(!prefix.contains("�"))
        #expect(text.hasPrefix(prefix))
    }

    @Test("TextKit diff keeps native foreground and line background colors")
    func appKitDiffKeepsNativeColors() throws {
        let diff = "-old\n+new\n@@ -1 +1 @@\n context"
        let rendered = AgentDiffColorizer.appKitAttributed(
            diff,
            palette: EditorInterfaceSkin.mistForest.palette
        ).value
        let source = rendered.string as NSString
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
        let hunkForeground = rendered.attribute(
            .foregroundColor,
            at: hunkRange.location,
            effectiveRange: nil
        ) as? NSColor

        #expect(deletionForeground != additionForeground)
        #expect(deletionBackground != nil)
        #expect(additionBackground != nil)
        #expect(hunkForeground == NSColor(EditorInterfaceSkin.mistForest.palette.accent))
    }

    @Test("Diff panel is file-first and uses non-contiguous TextKit layout")
    func diffPanelAvoidsWholeDocumentSwiftUILayout() throws {
        let source = try Self.source(named: "AgentSidePanelDiffView.swift")

        #expect(source.contains("LazyVStack(spacing: 0)"))
        #expect(source.contains("loadAgentWorktreeChangeSummary(status: status)"))
        #expect(source.contains("loadUntrackedDiffPreviewSection"))
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
