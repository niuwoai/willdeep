//
//  AgentMarkdownTableFormatter.swift
//  Xedit
//
//  Formats a parsed GFM-style pipe table (headers + rows of `String`)
//  into a monospace-aligned plain text block. Used by both rendering
//  paths in the chat pane:
//
//    1. The NSTextView-baked history (AgentChatHistoryTextView) bakes
//       the whole transcript into one NSAttributedString — it cannot
//       host a SwiftUI Grid, so tables degrade to padded text.
//    2. The live streaming assistant bubble renders one
//       Text(AttributedString) (AgentAssistantMarkdownRenderer) — same
//       constraint.
//
//  Pre-rc38 each path inlined a `cells.joined(" │ ")` and produced
//  misaligned rows whenever rows mixed CJK and ASCII (the case that
//  prompted the rc37 fix). This file is the single source of truth for
//  that fallback layout so both paths and any future plain-text export
//  (logs, copy-as-plain-text, tests) stay consistent.
//
//  CJK width heuristic: most full-width glyphs (CJK ideographs,
//  fullwidth punctuation, most emoji) render at ~2 monospace columns on
//  macOS's system monospaced font, while Latin/digits/halfwidth punct
//  render at ~1 column. We pad by visual columns rather than by
//  `String.count`, otherwise `时间 | 提交` drifts out of alignment with
//  `06-04 13:47 | 1633595` below it. This is *approximate* — the actual
//  rendered width depends on the font fallback chain — but it gets the
//  common case right.
//

import Foundation

enum AgentMarkdownTableFormatter {
    /// An inline-Markdown style applied to a run of the laid-out plain
    /// text. Offsets are *Character* offsets into the formatted string
    /// (not UTF-16), so callers convert to whatever index space their
    /// attributed-string API needs.
    nonisolated struct StyledSpan: Equatable {
        enum Style: Equatable { case bold, italic, code }
        /// Character-offset range into the formatted text.
        let range: Range<Int>
        let style: Style
    }

    /// Returns the table as a multi-line string with `│`-separated
    /// columns and a `─┼─` rule under the header. Returns an empty
    /// string when there are no headers and no rows.
    ///
    /// Inline Markdown inside cells (`**bold**`, `*italic*`, `` `code` ``)
    /// is *parsed away* — the returned plain text holds the visible text
    /// only, and column widths are measured on that visible text so the
    /// `**` markers don't push columns out of alignment. Use
    /// `formattedWithSpans` when you also need the style runs to restyle
    /// an attributed string.
    static func formatted(headers: [String], rows: [[String]]) -> String {
        formattedWithSpans(headers: headers, rows: rows).text
    }

    /// Same layout as `formatted`, plus the list of inline-Markdown style
    /// runs (bold/italic/code) discovered inside the cells, expressed as
    /// Character-offset ranges into the returned `text`. Both chat
    /// rendering paths use this to bake `**bold**` etc. into the
    /// monospaced fallback while keeping the columns aligned.
    static func formattedWithSpans(
        headers: [String],
        rows: [[String]]
    ) -> (text: String, spans: [StyledSpan]) {
        let allRows: [[String]] = headers.isEmpty ? rows : ([headers] + rows)
        guard !allRows.isEmpty else { return ("", []) }
        let columnCount = allRows.map { $0.count }.max() ?? 0
        guard columnCount > 0 else { return ("", []) }

        let rendered = allRows.map { row in row.map(renderCell) }

        var widths = Array(repeating: 0, count: columnCount)
        for row in rendered {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], displayWidth(of: cell.visible))
            }
        }

        var text = ""
        var spans: [StyledSpan] = []
        var offset = 0          // running Character offset, == text.count
        var wroteLine = false

        func append(_ string: String) {
            text += string
            offset += string.count
        }

        func newline() {
            if wroteLine { append("\n") }
            wroteLine = true
        }

        func appendRow(_ row: [RenderedCell]) {
            for index in 0..<columnCount {
                if index > 0 { append(" │ ") }
                let cell = index < row.count ? row[index] : RenderedCell(visible: "", spans: [])
                let cellStart = offset
                for span in cell.spans {
                    spans.append(StyledSpan(
                        range: (cellStart + span.range.lowerBound)..<(cellStart + span.range.upperBound),
                        style: span.style
                    ))
                }
                append(cell.visible)
                let padding = max(0, widths[index] - displayWidth(of: cell.visible))
                if padding > 0 { append(String(repeating: " ", count: padding)) }
            }
        }

        var bodyStartIndex = 0
        if !headers.isEmpty {
            newline(); appendRow(rendered[0])
            newline()
            let rule = widths
                .map { String(repeating: "─", count: max(1, $0)) }
                .joined(separator: "─┼─")
            append(rule)
            bodyStartIndex = 1
        }
        for row in rendered.dropFirst(bodyStartIndex) {
            newline(); appendRow(row)
        }
        return (text, spans)
    }

    /// A single cell after inline-Markdown parsing: the visible text plus
    /// the style runs (offsets are Character offsets *within `visible`*).
    private struct RenderedCell {
        let visible: String
        let spans: [StyledSpan]
    }

    /// Parse a cell's inline Markdown into visible text + style runs.
    /// Uses `.inlineOnlyPreservingWhitespace` so leading/trailing spaces
    /// (which matter for column alignment) survive and the cell is never
    /// promoted to a block element. Falls back to the raw string when the
    /// parser throws.
    private nonisolated static func renderCell(_ raw: String) -> RenderedCell {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let attributed = try? AttributedString(markdown: raw, options: options) else {
            return RenderedCell(visible: raw, spans: [])
        }
        let visible = String(attributed.characters)
        var spans: [StyledSpan] = []
        var offset = 0
        for run in attributed.runs {
            let length = attributed.characters[run.range].count
            defer { offset += length }
            guard length > 0, let intent = run.inlinePresentationIntent else { continue }
            let range = offset..<(offset + length)
            if intent.contains(.code) {
                spans.append(StyledSpan(range: range, style: .code))
            } else if intent.contains(.stronglyEmphasized) {
                spans.append(StyledSpan(range: range, style: .bold))
            } else if intent.contains(.emphasized) {
                spans.append(StyledSpan(range: range, style: .italic))
            }
        }
        return RenderedCell(visible: visible, spans: spans)
    }

    /// Approximate the visual column width of `text` in a monospaced
    /// font. CJK ideographs, fullwidth punctuation, and most emoji
    /// count as 2 columns; everything else counts as 1.
    static func displayWidth(of text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            width += isFullWidth(scalar) ? 2 : 1
        }
        return width
    }

    /// Returns the user-visible text of one inline-Markdown table cell.
    /// Shared with the SwiftUI table layout so formatting markers do not
    /// inflate the measured column width.
    static func visibleText(in raw: String) -> String {
        renderCell(raw).visible
    }

    /// True when this scalar is laid out as ~2 monospace columns.
    /// Ranges chosen for common CJK + emoji blocks; not exhaustive
    /// (CJK Ext G+ stop after the BMP ext range here).
    static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (0x1100...0x115F).contains(value) { return true } // Hangul Jamo
        if (0x2E80...0x303E).contains(value) { return true } // CJK Radicals, Kangxi, CJK Symbols
        if (0x3041...0x33FF).contains(value) { return true } // Hiragana/Katakana/Bopomofo/Hangul Compat
        if (0x3400...0x4DBF).contains(value) { return true } // CJK Ext A
        if (0x4E00...0x9FFF).contains(value) { return true } // CJK Unified
        if (0xA000...0xA4CF).contains(value) { return true } // Yi
        if (0xAC00...0xD7A3).contains(value) { return true } // Hangul Syllables
        if (0xF900...0xFAFF).contains(value) { return true } // CJK Compat Ideographs
        if (0xFE30...0xFE4F).contains(value) { return true } // CJK Compat Forms
        if (0xFF00...0xFF60).contains(value) { return true } // Fullwidth Forms
        if (0xFFE0...0xFFE6).contains(value) { return true } // Fullwidth signs
        if (0x1F300...0x1F64F).contains(value) { return true } // Misc symbols & pictographs, emoticons
        if (0x1F680...0x1F6FF).contains(value) { return true } // Transport & map
        if (0x1F900...0x1F9FF).contains(value) { return true } // Supplemental symbols
        if (0x20000...0x2FFFD).contains(value) { return true } // CJK Ext B–F
        if (0x30000...0x3FFFD).contains(value) { return true } // CJK Ext G
        return false
    }
}
