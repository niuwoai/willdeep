import AppKit
import Foundation
import Testing
@testable import WillDeep

/// Tables in the TextKit transcript used to be monospace text padded with
/// spaces, aligned by a "CJK is about two columns" guess. They are now laid
/// out with the body font: cells measured, columns fitted to the paragraph,
/// tab stops doing the alignment, grid lines drawn from those same stops.
/// These pin the layout maths and the attributed-string contract the layout
/// manager draws from.
@Suite
struct AgentChatHistoryTableLayoutTests {
    private let font = NSFont.systemFont(ofSize: 13)
    private let bold = NSFont.boldSystemFont(ofSize: 13)

    private func plainCell(_ raw: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: raw, attributes: [.font: font])
    }

    @Test("columns take their natural width when the paragraph has room")
    func naturalWidthsWhenTheyFit() throws {
        let layout = try #require(AgentChatHistoryTableLayout.layout(
            headers: ["时间", "提交"],
            rows: [["06-04 13:47", "1633595"], ["06-05 09:00", "abc"]],
            availableWidth: 800,
            bodyFont: font,
            headerFont: bold,
            makeCell: plainCell
        ))

        #expect(layout.columnCount == 2)
        #expect(layout.tabStopOffsets.count == 1)
        // The second column starts after the first one plus one separator gap.
        #expect(layout.tabStopOffsets[0] == layout.columnWidths[0] + AgentChatHistoryTableLayout.cellPadding)
        // Nothing was cut.
        for row in layout.rows {
            for cell in row {
                #expect(!cell.string.hasSuffix(AgentChatHistoryTableLayout.ellipsis))
            }
        }
        #expect(layout.rows[0][0].attribute(.font, at: 0, effectiveRange: nil) as? NSFont == bold)
    }

    @Test("a column that cannot fit is cut with an ellipsis, the others keep their width")
    func overlongColumnIsTruncated() throws {
        let long = String(repeating: "很长的单元格内容", count: 12)
        let layout = try #require(AgentChatHistoryTableLayout.layout(
            headers: ["名称", "说明"],
            rows: [["a", long]],
            availableWidth: 320,
            bodyFont: font,
            headerFont: bold,
            makeCell: plainCell
        ))

        let cut = layout.rows[1][1]
        #expect(cut.string.hasSuffix(AgentChatHistoryTableLayout.ellipsis))
        #expect(cut.string.count < long.count)
        #expect(ceil(cut.size().width) <= layout.columnWidths[1])
        // The narrow column kept its natural width instead of paying for the wide one.
        let short = layout.rows[1][0]
        #expect(!short.string.hasSuffix(AgentChatHistoryTableLayout.ellipsis))
        #expect(layout.columnWidths.reduce(0, +) <= 320 + 0.5)
    }

    @Test("water-filling leaves narrow columns alone and shares the rest")
    func fittedWidthsWaterFill() {
        let widths = AgentChatHistoryTableLayout.fittedTextWidths(
            natural: [40, 400, 400],
            availableWidth: 400
        )
        #expect(widths[0] == 40)
        #expect(widths[1] == widths[2])
        let padding = AgentChatHistoryTableLayout.cellPadding * 3 + AgentChatHistoryTableLayout.cellPadding * 2
        #expect(abs(widths.reduce(0, +) - (400 - padding)) < 0.5)
    }

    @Test("truncation never splits a grapheme cluster")
    func truncationRespectsCharacters() {
        let cell = NSAttributedString(string: "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦", attributes: [.font: font])
        let cut = AgentChatHistoryTableLayout.truncate(cell, toWidth: 40)
        let body = cut.string.dropLast()   // drop the ellipsis
        for character in body {
            #expect(character == "👨‍👩‍👧‍👦")
        }
    }

    @Test("short rows are padded so every row has the full column count")
    func shortRowsArePadded() throws {
        let layout = try #require(AgentChatHistoryTableLayout.layout(
            headers: ["a", "b", "c"],
            rows: [["1"], ["1", "2"]],
            availableWidth: 600,
            bodyFont: font,
            headerFont: bold,
            makeCell: plainCell
        ))
        for row in layout.rows {
            #expect(row.count == 3)
        }
    }

    // MARK: Rendered transcript

    private func render(_ markdown: String, layoutWidth: CGFloat = 900) -> NSAttributedString {
        AgentChatHistoryRenderer.render(
            messages: [AgentMessage(role: .assistant, content: markdown)],
            isDark: false,
            layoutWidth: layoutWidth
        )
    }

    @Test("a rendered table is tab-separated rows carrying tab stops, not padded monospace")
    func renderedTableUsesTabStops() throws {
        let rendered = render("""
        | 时间 | 提交 | 说明 |
        | --- | --- | --- |
        | 06-04 13:47 | 1633595 | 修复 |
        | 06-05 09:00 | abc | 新增 |
        """)
        let text = rendered.string

        #expect(!text.contains("│"))
        #expect(!text.contains("─┼─"))
        let headerLocation = try #require(text.range(of: "时间\t提交\t说明"))
        #expect(text.contains("06-04 13:47\t1633595\t修复"))

        let location = NSRange(headerLocation, in: text).location
        let columns = try #require(
            rendered.attribute(.agentChatHistoryTableColumns, at: location, effectiveRange: nil) as? [NSNumber]
        )
        #expect(columns.count == 2)
        let style = try #require(
            rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(style.tabStops.count == 2)
        // Tab locations are absolute: the block's head indent plus the offset.
        #expect(style.tabStops[0].location == style.firstLineHeadIndent + CGFloat(columns[0].doubleValue))
        // Cells wear the body font, not the code font.
        let cellFont = try #require(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(!cellFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(cellFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("a narrow transcript cuts wide cells instead of letting rows wrap")
    func narrowTranscriptTruncatesCells() throws {
        let long = String(repeating: "这一格非常长", count: 20)
        let rendered = render("""
        | 键 | 值 |
        | --- | --- |
        | k | \(long) |
        """, layoutWidth: 420)
        let text = rendered.string
        #expect(text.contains(AgentChatHistoryTableLayout.ellipsis))
        #expect(!text.contains(long))
    }

    // MARK: List markers

    @Test("unordered lists render as discs, nested levels as circles and squares")
    func listMarkersAreBullets() {
        let text = render("- 顶层\n  - 二级\n    - 三级").string
        #expect(text.contains("• 顶层"))
        #expect(text.contains("◦ 二级"))
        #expect(text.contains("▪ 三级"))
        #expect(!text.contains("- 顶层"))
    }

    @Test("copying a list puts the Markdown dash back")
    func copyRestoresDashes() {
        let copied = AgentCopyTextSanitizer.restoringMarkdownListMarkers("• 顶层\n  ◦ 二级\n    ▪ 三级\n正文里的 • 不动")
        #expect(copied == "- 顶层\n  - 二级\n    - 三级\n正文里的 • 不动")
    }

    @Test("a bullet without a trailing space is prose, not a marker")
    func bulletWithoutSpaceIsLeftAlone() {
        #expect(AgentCopyTextSanitizer.restoringMarkdownListMarkers("•重点") == "•重点")
        #expect(AgentCopyTextSanitizer.restoringMarkdownListMarkers("plain") == "plain")
    }
}
