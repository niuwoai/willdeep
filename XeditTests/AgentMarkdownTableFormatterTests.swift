//
//  AgentMarkdownTableFormatterTests.swift
//  XeditTests
//
//  Locks in the column-width contract for the plain-text table fallback
//  used by both chat rendering paths. Regressions here show up as
//  misaligned CJK/ASCII tables in the assistant transcript (rc37 fix).
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentMarkdownTableFormatterTests {

    /// No headers and no rows produces empty output — the chat renderer
    /// uses this as the "drop the table block" signal.
    @Test
    func emptyHeadersAndRowsReturnsEmptyString() {
        let out = AgentMarkdownTableFormatter.formatted(headers: [], rows: [])
        #expect(out.isEmpty)
    }

    /// Header-only tables still render the header line + the `─┼─` rule
    /// underneath, even when there are no data rows yet.
    @Test
    func headersOnlyRendersHeaderAndRule() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["File", "Lines"],
            rows: []
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("File"))
        #expect(lines[0].contains("Lines"))
        // Rule line is composed of ─ and the ─┼─ joiner.
        #expect(lines[1].contains("─"))
        #expect(lines[1].contains("┼"))
    }

    /// Rows-only (no headers) skips the rule line — the formatter only
    /// emits the `─┼─` divider when a header row exists.
    @Test
    func rowsOnlyRendersWithoutRule() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: [],
            rows: [["a", "b"], ["c", "d"]]
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(!out.contains("┼"))
        #expect(lines[0].contains("a"))
        #expect(lines[0].contains("b"))
    }

    /// Single-column tables collapse to one cell per line with no
    /// separator anywhere — `cells.joined(" │ ")` would produce a
    /// trailing pipe; we don't.
    @Test
    func singleColumnHasNoColumnSeparator() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["Name"],
            rows: [["Alice"], ["Bob"]]
        )
        #expect(!out.contains("│"))
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        // header + rule + 2 data rows
        #expect(lines.count == 4)
    }

    /// Short rows are padded out to the table's column count instead of
    /// truncating the row to its declared length.
    @Test
    func shortRowGetsPaddedToColumnCount() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["A", "B", "C"],
            rows: [["1", "2"]]
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        // Header + rule + 1 row
        #expect(lines.count == 3)
        // Last row should still contain two ` │ ` separators
        let lastRow = String(lines.last ?? "")
        let separatorCount = lastRow.components(separatedBy: " │ ").count - 1
        #expect(separatorCount == 2)
    }

    /// Mixed CJK + ASCII rows must align by visual column width, not by
    /// `String.count`. The header cell and the data cell in a CJK column
    /// must occupy the same number of display columns.
    @Test
    func cjkAndAsciiColumnsAlignByDisplayWidth() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["时间", "提交"],
            rows: [["06-04 13:47", "1633595"]]
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        // 3 lines: header, rule, 1 row
        #expect(lines.count == 3)

        let headerWidth = AgentMarkdownTableFormatter.displayWidth(of: String(lines[0]))
        let bodyWidth   = AgentMarkdownTableFormatter.displayWidth(of: String(lines[2]))
        #expect(headerWidth == bodyWidth)
    }

    /// Emoji count as 2 display columns. A row whose ASCII counterpart
    /// is exactly twice as long should land on the same total width.
    @Test
    func emojiTreatedAsDoubleWidth() {
        let emojiWidth = AgentMarkdownTableFormatter.displayWidth(of: "🚀")
        #expect(emojiWidth == 2)

        let mixed = AgentMarkdownTableFormatter.displayWidth(of: "a🚀b")
        #expect(mixed == 4)
    }

    /// ASCII-only widths match `String.count`.
    @Test
    func asciiWidthMatchesCharacterCount() {
        #expect(AgentMarkdownTableFormatter.displayWidth(of: "hello") == 5)
        #expect(AgentMarkdownTableFormatter.displayWidth(of: "") == 0)
    }

    /// The widest cell in a column dictates the column's width — a
    /// short header above a long body row should be padded out to match.
    @Test
    func columnWidthExpandsToLongestCell() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["A", "B"],
            rows: [["short", "longer-than-header"]]
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let headerWidth = AgentMarkdownTableFormatter.displayWidth(of: String(lines[0]))
        let bodyWidth   = AgentMarkdownTableFormatter.displayWidth(of: String(lines.last ?? ""))
        #expect(headerWidth == bodyWidth)
    }

    /// CJK full-width punctuation falls under the 2-column heuristic so
    /// `（` doesn't slip through as 1 column and misalign the row.
    @Test
    func fullWidthPunctuationCountsAsTwoColumns() {
        #expect(AgentMarkdownTableFormatter.isFullWidth(Unicode.Scalar(0xFF08)!)) // （
        #expect(AgentMarkdownTableFormatter.isFullWidth(Unicode.Scalar(0x3002)!)) // 。
    }

    /// Plain ASCII letters and digits stay single-width.
    @Test
    func asciiScalarsAreHalfWidth() {
        #expect(!AgentMarkdownTableFormatter.isFullWidth(Unicode.Scalar(0x41))) // A
        #expect(!AgentMarkdownTableFormatter.isFullWidth(Unicode.Scalar(0x30))) // 0
        #expect(!AgentMarkdownTableFormatter.isFullWidth(Unicode.Scalar(0x20))) // space
    }

    /// Inline `**bold**` markers are parsed away in the plain text — the
    /// fallback layout shows the visible word, never the literal asterisks.
    @Test
    func boldMarkersAreStrippedFromPlainText() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["类别", "说明"],
            rows: [["**截图**", "大量截图文件"]]
        )
        #expect(!out.contains("**"))
        #expect(out.contains("截图"))
    }

    /// Column widths are measured on the *visible* text, not on the raw
    /// markers — a `**bold**` cell aligns with a plain cell of the same
    /// visible length below it.
    @Test
    func columnWidthIgnoresInlineMarkers() {
        let out = AgentMarkdownTableFormatter.formatted(
            headers: ["A"],
            rows: [["**hello**"], ["world"]]
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        // header + rule + 2 body rows
        #expect(lines.count == 4)
        let row1 = AgentMarkdownTableFormatter.displayWidth(of: String(lines[2]))
        let row2 = AgentMarkdownTableFormatter.displayWidth(of: String(lines[3]))
        #expect(row1 == row2)
        #expect(row1 == 5) // "hello" / "world"
    }

    /// `formattedWithSpans` reports a bold run covering exactly the visible
    /// characters of the cell, at the right offset in the laid-out text.
    @Test
    func reportsBoldSpanOverVisibleText() {
        let layout = AgentMarkdownTableFormatter.formattedWithSpans(
            headers: [],
            rows: [["**hi**"]]
        )
        #expect(layout.text == "hi")
        #expect(layout.spans.count == 1)
        let span = layout.spans[0]
        #expect(span.style == .bold)
        #expect(span.range == 0..<2)
    }

    /// Spans land at the correct global offset once a cell sits after a
    /// column separator, so attributes don't drift onto the wrong run.
    @Test
    func spanOffsetAccountsForColumnSeparator() {
        let layout = AgentMarkdownTableFormatter.formattedWithSpans(
            headers: [],
            rows: [["ab", "**cd**"]]
        )
        #expect(layout.text == "ab │ cd")
        #expect(layout.spans.count == 1)
        let span = layout.spans[0]
        #expect(span.style == .bold)
        // "ab │ " == 5 chars, then "cd".
        #expect(span.range == 5..<7)
    }

    /// Inline code and italic are recognised alongside bold.
    @Test
    func reportsCodeAndItalicSpans() {
        let codeLayout = AgentMarkdownTableFormatter.formattedWithSpans(
            headers: [],
            rows: [["`x`"]]
        )
        #expect(codeLayout.text == "x")
        #expect(codeLayout.spans == [.init(range: 0..<1, style: .code)])

        let italicLayout = AgentMarkdownTableFormatter.formattedWithSpans(
            headers: [],
            rows: [["*y*"]]
        )
        #expect(italicLayout.text == "y")
        #expect(italicLayout.spans == [.init(range: 0..<1, style: .italic)])
    }
}
