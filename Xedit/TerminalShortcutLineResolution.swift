//
//  TerminalShortcutLineResolution.swift
//  WillDeep
//
//  Turns an echo-off line captured by the shortcut recorder into the command
//  the shell actually displayed.
//
//  Interactive line editors (fish, zsh, bash readline, a remote shell behind
//  ssh) switch the PTY's ECHO flag off and draw the line themselves, so
//  termios cannot tell them apart from a password prompt. The raw keystrokes
//  are not what ran either: `ssh <Tab>` completes against hosts and history
//  that differ at replay time, and so do history recall and fish/zsh
//  autosuggestions. The screen is the ground truth — the text between the
//  prompt and the cursor when Enter is pressed is the buffer the shell runs.
//  A secret prompt never draws what was typed, so a line only leaves the
//  protected path when the screen shows it.
//

import Foundation
import SwiftTerm

/// A position on the visible grid. Rows are viewport-relative.
struct TerminalShortcutScreenPoint: Equatable {
    var row: Int
    var column: Int
}

/// Read-only view of the visible terminal grid.
protocol TerminalShortcutScreen {
    var columns: Int { get }
    /// nil when the grid is not the line editor's canvas: the alternate
    /// buffer (vim, less, full-screen fzf) or a viewport scrolled back.
    var cursor: TerminalShortcutScreenPoint? { get }
    /// One entry per column: the cell's text, `TerminalShortcutScreenCell.empty`
    /// for a cell nothing was written to, and "" for the trailing half of a
    /// wide character. nil when the row is not on screen.
    func cells(row: Int) -> [String]?
    /// True when `row` soft-wraps into `row + 1`.
    func wrapsIntoNextRow(_ row: Int) -> Bool
}

nonisolated enum TerminalShortcutScreenCell {
    static let empty = "\u{0}"
    /// Trailing half of a wide character; takes no text of its own.
    static let wideContinuation = ""

    static func isBlank(_ cell: String) -> Bool {
        cell == " " || cell == empty || cell == wideContinuation
    }
}

/// Where an echo-off line started on screen, captured before its first byte
/// reached the shell.
struct TerminalShortcutLineAnchor: Equatable {
    var row: Int
    var column: Int
    var columns: Int
    /// Cells left of the input — the prompt. Finds the line again after the
    /// screen scrolls.
    var promptCells: [String]
    /// Cells right of the input start: blank, or a right prompt
    /// (fish_right_prompt, RPROMPT) that is not part of the command.
    var trailingCells: [String]
    var continuesPreviousRow: Bool

    var promptIsBlank: Bool { promptCells.allSatisfy(TerminalShortcutScreenCell.isBlank) }

    init?(screen: TerminalShortcutScreen) {
        guard let cursor = screen.cursor,
              let cells = screen.cells(row: cursor.row),
              cells.count == screen.columns,
              cursor.column < cells.count else { return nil }
        row = cursor.row
        column = cursor.column
        columns = screen.columns
        promptCells = Array(cells[..<cursor.column])
        trailingCells = Array(cells[cursor.column...])
        continuesPreviousRow = cursor.row > 0 && screen.wrapsIntoNextRow(cursor.row - 1)
    }
}

/// What the screen showed when Enter was pressed.
struct TerminalShortcutLineCapture: Equatable {
    /// From the end of the prompt to the cursor: the buffer the shell holds,
    /// minus anything right of the cursor.
    var text: String
    var anchorRow: Int
    var cursor: TerminalShortcutScreenPoint
    /// Nothing but blanks or the original right prompt follows the cursor, so
    /// `text` is the whole buffer. An autosuggestion fails this until the
    /// shell repaints the line on submit.
    var tailIsClean: Bool
}

/// What the typed bytes of one line say about the text the screen must show.
struct TerminalShortcutTypedLine: Equatable {
    /// Characters that must still appear, in order, in the displayed line.
    var requiredText: String = ""
    /// A key whose effect depends on shell state: completion, history,
    /// autosuggestion, cursor movement, word kills, pasted escape sequences.
    var hasContextKeys = false
    /// A key that can open a completion pager or history search, where Enter
    /// accepts a candidate instead of running the command.
    var mayOpenPager = false

    private static let backspace: UInt8 = 0x7F
    private static let controlH: UInt8 = 0x08
    private static let controlU: UInt8 = 0x15
    private static let escape: UInt8 = 0x1B
    private static let pagerControls: Set<UInt8> = [0x09, 0x12, 0x13] // Tab, Ctrl-R, Ctrl-S
    private static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A]

    init(bytes: [UInt8]) {
        // Characters typed since the last context key. Backspace can only be
        // attributed to them; before them the buffer holds text we did not type.
        var segment: [Character] = []
        var earlier: [Character] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case Self.backspace, Self.controlH:
                if !segment.isEmpty { segment.removeLast() }
                index += 1
            case Self.controlU where !hasContextKeys:
                // Cursor is still at the end, so every shell clears the line.
                segment.removeAll()
                earlier.removeAll()
                index += 1
            case Self.escape:
                let length = Self.escapeSequenceLength(in: bytes, at: index)
                if Array(bytes[index..<(index + length)]) == Self.shiftTab {
                    mayOpenPager = true
                }
                markContextKey(segment: &segment, earlier: &earlier)
                index += length
            case 0x00...0x1F:
                if Self.pagerControls.contains(byte) { mayOpenPager = true }
                markContextKey(segment: &segment, earlier: &earlier)
                index += 1
            default:
                var end = index
                while end < bytes.count, bytes[end] >= 0x20, bytes[end] != Self.backspace { end += 1 }
                if let text = String(bytes: bytes[index..<end], encoding: .utf8) {
                    segment.append(contentsOf: text)
                } else {
                    markContextKey(segment: &segment, earlier: &earlier)
                }
                index = end
            }
        }
        requiredText = String(earlier + segment)
    }

    private mutating func markContextKey(segment: inout [Character], earlier: inout [Character]) {
        hasContextKeys = true
        earlier.append(contentsOf: segment)
        segment.removeAll()
    }

    /// ESC [ params final, ESC O x, or ESC x (Alt+key).
    private static func escapeSequenceLength(in bytes: [UInt8], at start: Int) -> Int {
        let next = start + 1
        guard next < bytes.count else { return 1 }
        switch bytes[next] {
        case 0x5B: // CSI
            var end = next + 1
            while end < bytes.count {
                if (0x40...0x7E).contains(bytes[end]) { return end - start + 1 }
                end += 1
            }
            return bytes.count - start
        case 0x4F: // SS3
            return min(3, bytes.count - start)
        default:
            return 2
        }
    }
}

enum TerminalShortcutLineResolver {
    /// How a submitted line looks once the shell has had a chance to react.
    enum Settlement: Equatable {
        /// The cursor is still on the line: the shell has not run it yet, or
        /// Enter accepted a pager candidate.
        case stillEditing
        /// The shell moved past the line and repainted it. `restIsClean` says
        /// nothing followed the recorded text.
        case submitted(restIsClean: Bool)
        /// The line is gone (cleared, scrolled out, alternate screen).
        case unverifiable
    }

    /// Rows one command line may span before we stop looking for its prompt.
    private static let maxLineRows = 64

    static func capture(
        anchor: TerminalShortcutLineAnchor,
        screen: TerminalShortcutScreen
    ) -> TerminalShortcutLineCapture? {
        guard let cursor = screen.cursor,
              screen.columns == anchor.columns,
              let anchorRow = anchorRow(for: anchor, cursor: cursor, screen: screen),
              let text = text(
                  from: TerminalShortcutScreenPoint(row: anchorRow, column: anchor.column),
                  to: cursor,
                  screen: screen
              ),
              !text.isEmpty else { return nil }
        return TerminalShortcutLineCapture(
            text: text,
            anchorRow: anchorRow,
            cursor: cursor,
            tailIsClean: restIsClean(
                after: cursor,
                onAnchorRow: cursor.row == anchorRow,
                anchor: anchor,
                screen: screen
            )
        )
    }

    static func settle(
        anchor: TerminalShortcutLineAnchor,
        capture: TerminalShortcutLineCapture,
        screen: TerminalShortcutScreen
    ) -> Settlement {
        guard let cursor = screen.cursor, screen.columns == anchor.columns else { return .unverifiable }
        let span = capture.cursor.row - capture.anchorRow
        // Nearest match first: older copies of the same command sit above it.
        for row in stride(from: cursor.row - span, through: 0, by: -1) {
            guard !anchor.promptIsBlank || row == capture.anchorRow,
                  promptMatches(anchor, row: row, screen: screen) else { continue }
            let end = TerminalShortcutScreenPoint(row: row + span, column: capture.cursor.column)
            guard text(
                from: TerminalShortcutScreenPoint(row: row, column: anchor.column),
                to: end,
                screen: screen
            ) == capture.text else { continue }
            var lastRow = end.row
            while screen.wrapsIntoNextRow(lastRow) { lastRow += 1 }
            if cursor.row <= lastRow { return .stillEditing }
            return .submitted(restIsClean: restIsClean(
                after: end,
                onAnchorRow: span == 0,
                anchor: anchor,
                screen: screen
            ))
        }
        return .unverifiable
    }

    /// The command to record in place of the raw keystrokes, or nil to keep
    /// the line protected. `verifiedComplete` is the post-submit verdict;
    /// without one only plain typing is trusted to the Enter-time view,
    /// because a completion may not have reached the screen yet.
    static func resolvedText(
        typed: TerminalShortcutTypedLine,
        capture: TerminalShortcutLineCapture,
        verifiedComplete: Bool?
    ) -> String? {
        guard !capture.text.isEmpty,
              isSubsequence(typed.requiredText, of: capture.text) else { return nil }
        if let verifiedComplete {
            return verifiedComplete ? capture.text : nil
        }
        return !typed.hasContextKeys && capture.tailIsClean ? capture.text : nil
    }

    // MARK: Grid reading

    private static func anchorRow(
        for anchor: TerminalShortcutLineAnchor,
        cursor: TerminalShortcutScreenPoint,
        screen: TerminalShortcutScreen
    ) -> Int? {
        let lowest = max(0, cursor.row - maxLineRows)
        var row = cursor.row
        while row >= lowest {
            let inputFits = row != cursor.row || cursor.column >= anchor.column
            if inputFits,
               !anchor.promptIsBlank || row == anchor.row,
               promptMatches(anchor, row: row, screen: screen) {
                return row
            }
            // Only a soft wrap joins the row above into the same line.
            guard row > 0, screen.wrapsIntoNextRow(row - 1) else { return nil }
            row -= 1
        }
        return nil
    }

    private static func promptMatches(
        _ anchor: TerminalShortcutLineAnchor,
        row: Int,
        screen: TerminalShortcutScreen
    ) -> Bool {
        guard let cells = screen.cells(row: row),
              cells.count == anchor.columns,
              Array(cells[..<anchor.column]) == anchor.promptCells else { return false }
        let continues = row > 0 && screen.wrapsIntoNextRow(row - 1)
        return continues == anchor.continuesPreviousRow
    }

    /// Text from `start` up to (not including) `end`, following soft wraps.
    private static func text(
        from start: TerminalShortcutScreenPoint,
        to end: TerminalShortcutScreenPoint,
        screen: TerminalShortcutScreen
    ) -> String? {
        guard end.row >= start.row, end.row != start.row || end.column >= start.column else { return nil }
        var result = ""
        for row in start.row...end.row {
            guard let cells = screen.cells(row: row) else { return nil }
            if row < end.row, !screen.wrapsIntoNextRow(row) { return nil }
            let lower = row == start.row ? start.column : 0
            let upper = row == end.row ? min(end.column, cells.count) : cells.count
            guard lower <= upper else { return nil }
            var slice = Array(cells[lower..<upper])
            // A wide character that does not fit at the edge wraps whole and
            // leaves the last cell unwritten.
            if row < end.row,
               slice.last == TerminalShortcutScreenCell.empty,
               let next = screen.cells(row: row + 1),
               next.count > 1,
               next[1] == TerminalShortcutScreenCell.wideContinuation {
                slice.removeLast()
            }
            for cell in slice {
                result += cell == TerminalShortcutScreenCell.empty ? " " : cell
            }
        }
        return result
    }

    /// True when nothing of the command follows `point`: the rest of its row
    /// is blank or still the right prompt captured at line start, and the
    /// line does not continue on a wrapped row.
    private static func restIsClean(
        after point: TerminalShortcutScreenPoint,
        onAnchorRow: Bool,
        anchor: TerminalShortcutLineAnchor,
        screen: TerminalShortcutScreen
    ) -> Bool {
        guard let cells = screen.cells(row: point.row) else { return false }
        let tail = point.column < cells.count ? Array(cells[point.column...]) : []
        if !tail.allSatisfy(TerminalShortcutScreenCell.isBlank) {
            let offset = point.column - anchor.column
            guard onAnchorRow,
                  offset >= 0,
                  offset <= anchor.trailingCells.count,
                  Array(anchor.trailingCells[offset...]) == tail else { return false }
        }
        var row = point.row
        while screen.wrapsIntoNextRow(row) {
            row += 1
            guard let next = screen.cells(row: row),
                  next.allSatisfy(TerminalShortcutScreenCell.isBlank) else { return false }
        }
        return true
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = haystack[...]
        for character in needle {
            guard let found = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: found)...]
        }
        return true
    }
}

/// The visible SwiftTerm grid as the recorder reads it. Main thread only.
struct AgentTerminalShortcutScreen: TerminalShortcutScreen {
    let terminal: Terminal
    /// The viewport shows the live bottom of the buffer. Only then do
    /// viewport rows line up with the cursor, which SwiftTerm reports
    /// relative to the live bottom.
    let isShowingLiveBottom: Bool

    var columns: Int { terminal.cols }

    var cursor: TerminalShortcutScreenPoint? {
        guard isShowingLiveBottom, !terminal.isCurrentBufferAlternate else { return nil }
        let location = terminal.getCursorLocation()
        guard location.y >= 0, location.y < terminal.rows else { return nil }
        return TerminalShortcutScreenPoint(row: location.y, column: min(max(0, location.x), terminal.cols))
    }

    func cells(row: Int) -> [String]? {
        guard let line = terminal.getLine(row: row) else { return nil }
        let count = min(line.count, terminal.cols)
        return (0..<count).map { column in
            let data = line[column]
            if data.width == 0 { return TerminalShortcutScreenCell.wideContinuation }
            return String(terminal.getCharacter(for: data))
        }
    }

    func wrapsIntoNextRow(_ row: Int) -> Bool {
        // A soft wrap always carries at least the character that overflowed.
        guard row >= 0,
              let next = cells(row: row + 1),
              next.contains(where: {
                  $0 != TerminalShortcutScreenCell.empty && $0 != TerminalShortcutScreenCell.wideContinuation
              }) else { return false }
        // SwiftTerm keeps the wrap flag internal; getText only puts a line
        // break between two rows when the second one is not a soft wrap.
        let top = terminal.buffer.yDisp
        let probe = terminal.getText(
            start: Position(col: 0, row: top + row),
            end: Position(col: 1, row: top + row + 1)
        )
        return !probe.contains("\n")
    }
}
