//
//  AgentChatHistoryTableLayout.swift
//  WillDeep
//
//  Column layout for Markdown tables in the TextKit transcript.
//
//  The transcript bakes each conversation into one attributed string and
//  cannot host a real table view, so tables used to degrade to monospace
//  text padded with spaces — column alignment rested on a "CJK is about two
//  columns wide" guess and every table wore a code-block font. This lays
//  the same rows out with the body font and proportional widths instead:
//  every cell is measured once, column widths are fitted to the space the
//  paragraph actually has, overlong cells are cut with an ellipsis, and the
//  result is expressed as tab stops so TextKit does the alignment during
//  normal line layout. Nothing here touches the layout manager at draw
//  time; the grid lines are drawn from the same tab positions later.
//
//  Cost model: one `size()` per distinct cell string per bake, cached by
//  string; the transcript already caches bakes per message hash, so a
//  table is measured when its message changes, not when the view scrolls.
//

import AppKit

nonisolated enum AgentChatHistoryTableLayout {
    /// Horizontal breathing room between a column separator and the text
    /// on either side of it. The first column has no leading pad: the
    /// table background already insets it from the paragraph edge.
    static let cellPadding: CGFloat = 12
    /// Below this a column carries nothing legible; the fitter never
    /// squeezes a column past it, so a table with more columns than the
    /// paragraph can hold overflows and truncates the row instead.
    static let minimumColumnWidth: CGFloat = 48
    static let ellipsis = "…"

    struct Layout: Equatable {
        /// Header first, then body rows. Each cell is already truncated to
        /// its column and carries its font/colour attributes.
        let rows: [[NSAttributedString]]
        /// Full column widths including padding, in the same order as cells.
        let columnWidths: [CGFloat]
        /// Tab stop offsets measured from the first column's text origin:
        /// one per column after the first. The caller adds the paragraph's
        /// head indent to turn them into `NSTextTab` locations.
        let tabStopOffsets: [CGFloat]

        var columnCount: Int { columnWidths.count }
    }

    /// Lay out `headers` + `rows` to fit within `availableWidth`.
    ///
    /// `makeCell` renders a cell's inline Markdown with the given font; it is
    /// the transcript's own inline renderer, injected so this file stays free
    /// of the formatter's private helpers and testable on its own.
    static func layout(
        headers: [String],
        rows: [[String]],
        availableWidth: CGFloat,
        bodyFont: NSFont,
        headerFont: NSFont,
        makeCell: (String, NSFont) -> NSAttributedString
    ) -> Layout? {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return nil }

        var measured: [String: CGFloat] = [:]
        func width(of cell: NSAttributedString, key: String) -> CGFloat {
            if let cached = measured[key] { return cached }
            let value = ceil(cell.size().width)
            measured[key] = value
            return value
        }

        // Build every cell once, padding short rows so each row has a
        // full complement of columns and the tab count never drifts.
        var builtRows: [[NSAttributedString]] = []
        var naturalTextWidths = [CGFloat](repeating: 0, count: columnCount)
        let sourceRows: [(cells: [String], font: NSFont)] =
            [(headers, headerFont)] + rows.map { ($0, bodyFont) }
        for source in sourceRows {
            var built: [NSAttributedString] = []
            for column in 0..<columnCount {
                let raw = column < source.cells.count ? source.cells[column] : ""
                let cell = makeCell(raw, source.font)
                built.append(cell)
                let key = "\(source.font.fontName)\u{0}\(source.font.pointSize)\u{0}\(raw)"
                naturalTextWidths[column] = max(naturalTextWidths[column], width(of: cell, key: key))
            }
            builtRows.append(built)
        }

        let textWidths = fittedTextWidths(
            natural: naturalTextWidths,
            availableWidth: availableWidth
        )

        var columnWidths: [CGFloat] = []
        var tabStopOffsets: [CGFloat] = []
        var cursor: CGFloat = 0
        for (index, textWidth) in textWidths.enumerated() {
            // Column 0 starts at the text origin; every other column pays
            // for the separator gap on its left.
            let leading: CGFloat = index == 0 ? 0 : cellPadding
            let columnWidth = leading + textWidth + cellPadding
            columnWidths.append(columnWidth)
            if index > 0 {
                tabStopOffsets.append(cursor + leading)
            }
            cursor += columnWidth
        }

        let truncatedRows = builtRows.map { row in
            row.enumerated().map { index, cell in
                truncate(cell, toWidth: textWidths[index])
            }
        }
        return Layout(
            rows: truncatedRows,
            columnWidths: columnWidths,
            tabStopOffsets: tabStopOffsets
        )
    }

    /// Water-fill the natural text widths into `availableWidth`.
    ///
    /// Columns that already fit their fair share keep their natural width;
    /// the space they leave over is redistributed to the wider ones. Only
    /// the columns that genuinely cannot fit get cut, and they are cut to
    /// an equal share rather than the widest one eating everything.
    static func fittedTextWidths(natural: [CGFloat], availableWidth: CGFloat) -> [CGFloat] {
        let columnCount = natural.count
        guard columnCount > 0 else { return [] }
        let paddingTotal = cellPadding * CGFloat(columnCount) + cellPadding * CGFloat(max(columnCount - 1, 0))
        let budget = availableWidth - paddingTotal
        let naturalTotal = natural.reduce(0, +)
        guard naturalTotal > budget else { return natural }

        var result = [CGFloat](repeating: 0, count: columnCount)
        var remainingBudget = budget
        var remainingColumns = columnCount
        // Ascending so the narrow columns settle first and donate their
        // unused share to the wide ones that follow.
        for index in natural.indices.sorted(by: { natural[$0] < natural[$1] }) {
            let share = remainingBudget / CGFloat(remainingColumns)
            let width = max(minimumColumnWidth - cellPadding, min(natural[index], share))
            result[index] = width
            remainingBudget -= width
            remainingColumns -= 1
        }
        return result
    }

    /// Cut `cell` so it fits `width`, replacing the tail with an ellipsis.
    /// Cuts on `Character` boundaries: an emoji or a composed CJK cluster is
    /// never split in half.
    static func truncate(_ cell: NSAttributedString, toWidth width: CGFloat) -> NSAttributedString {
        guard ceil(cell.size().width) > width, cell.length > 0 else { return cell }
        let string = cell.string
        let characters = Array(string.indices)
        guard !characters.isEmpty else { return cell }
        let tailAttributes = cell.attributes(at: cell.length - 1, effectiveRange: nil)
        let ellipsisString = NSAttributedString(string: ellipsis, attributes: tailAttributes)
        func candidate(_ count: Int) -> NSAttributedString {
            let end = count < characters.count ? characters[count] : string.endIndex
            let prefixRange = NSRange(string.startIndex..<end, in: string)
            let prefix = NSMutableAttributedString(attributedString: cell.attributedSubstring(from: prefixRange))
            prefix.append(ellipsisString)
            return prefix
        }
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if ceil(candidate(mid).size().width) <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return candidate(low)
    }
}
