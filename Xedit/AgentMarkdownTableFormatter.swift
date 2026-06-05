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
    /// Returns the table as a multi-line string with `│`-separated
    /// columns and a `─┼─` rule under the header. Returns an empty
    /// string when there are no headers and no rows.
    static func formatted(headers: [String], rows: [[String]]) -> String {
        let allRows: [[String]] = headers.isEmpty ? rows : ([headers] + rows)
        guard !allRows.isEmpty else { return "" }
        let columnCount = allRows.map { $0.count }.max() ?? 0
        guard columnCount > 0 else { return "" }

        var widths = Array(repeating: 0, count: columnCount)
        for row in allRows {
            for (index, cell) in row.enumerated() where index < columnCount {
                widths[index] = max(widths[index], displayWidth(of: cell))
            }
        }

        func renderRow(_ row: [String]) -> String {
            var pieces: [String] = []
            for index in 0..<columnCount {
                let cell = index < row.count ? row[index] : ""
                let padding = max(0, widths[index] - displayWidth(of: cell))
                pieces.append(cell + String(repeating: " ", count: padding))
            }
            return pieces.joined(separator: " │ ")
        }

        var lines: [String] = []
        var bodyStartIndex = 0
        if !headers.isEmpty {
            lines.append(renderRow(headers))
            let rule = widths
                .map { String(repeating: "─", count: max(1, $0)) }
                .joined(separator: "─┼─")
            lines.append(rule)
            bodyStartIndex = 1
        }
        for row in allRows.dropFirst(bodyStartIndex) {
            lines.append(renderRow(row))
        }
        return lines.joined(separator: "\n")
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
