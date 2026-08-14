//
//  AgentTerminalSnapshotMirror.swift
//  WillDeep
//
//  A head-less SwiftTerm `Terminal` that mirrors an interactive terminal's
//  PTY output on a dedicated background queue, so `terminal_snapshot` can
//  read a *fresh* screen even while the main thread is saturated (typically
//  mid-render while streaming a rich agent reply).
//
//  Why this exists — the "一直显示旧内容" bug:
//  SwiftTerm's `LocalProcessTerminalView` delivers PTY bytes on the main
//  queue and parses them into its buffer model there, because the visible
//  NSView reads that same model on the main thread when it draws. When the
//  main thread is busy, the parse is starved and the model lags behind the
//  actual output — so a snapshot read off the visible model returns stale
//  content. This mirror is a *second*, view-less model fed on a queue that
//  the main thread can never starve, giving the snapshot a live screen.
//
//  Threading contract (load-bearing): the wrapped `Terminal` is NOT thread
//  safe. Every access — feed, resize, capture — MUST happen on `queue`.
//  The owning terminal view configures its `LocalProcess` to deliver PTY
//  bytes on this very queue, so `feedOnQueue` runs there for free and stays
//  ordered with the visible feed. `@unchecked Sendable` is sound ONLY under
//  that contract.
//

import Foundation
import SwiftTerm

struct AgentTerminalSnapshotCapture: Sendable {
    let viewport: String
    let markedViewport: String
    /// Output that scrolled above the visible screen, oldest first. Empty
    /// when nothing has scrolled off yet.
    let scrollback: String
    let cursorLine: String
    let cursorRow: Int
    let cursorColumn: Int
    let topVisibleRow: Int
    let rows: Int
    let cols: Int
}

final class AgentTerminalSnapshotMirror: @unchecked Sendable {
    /// How many scrolled-off lines a capture reports by default.
    ///
    /// A single viewport is not what the operator sees. The side panel is
    /// narrow, so one long command echoes across several visual rows, and a
    /// build that printed fifty lines leaves only the last handful on screen
    /// — the rest is one scroll-wheel away for a human but used to be
    /// invisible to the agent, which then reported "no output" for work that
    /// plainly ran. The mirror already retains scrollback; this is how much
    /// of it a snapshot is allowed to look back through. The tool still
    /// bounds the final payload by characters.
    static let defaultHistoryLines = 200

    /// Serial queue that exclusively owns `terminal`. Also the queue the
    /// owning `LocalProcess` delivers PTY bytes on, so feeds are ordered and
    /// never contend with the main thread's rendering.
    let queue: DispatchQueue
    private let terminal: Terminal
    /// `Terminal` holds its delegate `weak`; keep the driver alive here.
    private let driver = MirrorDriver()

    init(cols: Int, rows: Int, scrollback: Int, label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        let safeCols = max(cols, 1)
        let safeRows = max(rows, 1)
        let options = TerminalOptions(
            cols: safeCols,
            rows: safeRows,
            scrollback: max(scrollback, 0)
        )
        terminal = Terminal(delegate: driver, options: options)
    }

    /// Feed raw PTY bytes into the mirror. MUST be called on `queue` (the
    /// owning view calls it straight from its `dataReceived`, which the
    /// `LocalProcess` already dispatches on `queue`).
    func feedOnQueue(_ bytes: [UInt8]) {
        terminal.feed(buffer: bytes[...])
    }

    /// Keep the mirror's geometry in step with the visible terminal so line
    /// wrapping agrees. Safe to call from any thread; hops onto `queue`.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        queue.async { [terminal] in
            guard terminal.cols != cols || terminal.rows != rows else { return }
            terminal.resize(cols: cols, rows: rows)
        }
    }

    /// Capture the currently visible viewport as text. Safe to call from any
    /// thread *except* `queue`; it blocks on `queue` until in-flight feeds
    /// drain (bounded by one feed call — never by the main thread). This is
    /// the read the snapshot tool uses instead of the starved visible model.
    func captureViewport() -> String {
        capture().viewport
    }

    /// Capture the visible viewport with cursor context, plus the output that
    /// already scrolled above it. The cursor row is authoritative for "where
    /// the shell is now"; other visible rows can be old output or prompts
    /// from before an SSH hop.
    func capture(
        historyLines: Int = AgentTerminalSnapshotMirror.defaultHistoryLines
    ) -> AgentTerminalSnapshotCapture {
        queue.sync {
            let rows = terminal.rows
            let cols = terminal.cols
            guard rows > 0, cols > 0 else {
                return AgentTerminalSnapshotCapture(
                    viewport: "",
                    markedViewport: "",
                    scrollback: "",
                    cursorLine: "",
                    cursorRow: 0,
                    cursorColumn: 0,
                    topVisibleRow: 0,
                    rows: rows,
                    cols: cols
                )
            }
            // `yDisp` is the absolute index of the top visible row inside the
            // scrollback line array; `getText` indexes that array directly.
            // Mirror the exact region the visible terminal would show.
            let startRow = terminal.buffer.yDisp
            let bottom = startRow + rows - 1
            let cursor = terminal.getCursorLocation()
            let visibleCursorRow = min(max(cursor.y, 0), rows - 1)
            let cursorColumn = min(max(cursor.x, 0), max(cols - 1, 0))
            let absoluteCursorRow = startRow + visibleCursorRow
            let viewport = terminal.getText(
                start: Position(col: 0, row: startRow),
                end: Position(col: cols - 1, row: bottom)
            )
            // `getText` indexes the same line array, so rows below the top
            // visible row are exactly the scrolled-off history. Reading a
            // bounded tail of it is what turns "I see nothing" into the
            // output the operator can see by scrolling up.
            let historyStart = max(0, startRow - max(historyLines, 0))
            let scrollback = historyStart < startRow
                ? terminal.getText(
                    start: Position(col: 0, row: historyStart),
                    end: Position(col: cols - 1, row: startRow - 1)
                )
                : ""
            let cursorLine = terminal.getText(
                start: Position(col: 0, row: absoluteCursorRow),
                end: Position(col: cols - 1, row: absoluteCursorRow)
            )
            var markedRows: [String] = []
            markedRows.reserveCapacity(rows)
            for visibleRow in 0..<rows {
                let absoluteRow = startRow + visibleRow
                let line = terminal.getText(
                    start: Position(col: 0, row: absoluteRow),
                    end: Position(col: cols - 1, row: absoluteRow)
                )
                let marker = visibleRow == visibleCursorRow ? "=> " : "   "
                markedRows.append("\(marker)\(line)")
            }
            return AgentTerminalSnapshotCapture(
                viewport: viewport,
                markedViewport: markedRows.joined(separator: "\n"),
                scrollback: scrollback,
                cursorLine: cursorLine,
                cursorRow: visibleCursorRow,
                cursorColumn: cursorColumn,
                topVisibleRow: startRow,
                rows: rows,
                cols: cols
            )
        }
    }
}

/// Minimal `TerminalDelegate`. The one method with no protocol default is
/// `send` — and it MUST stay a no-op: the mirror shares the PTY's byte
/// stream with the visible terminal, which already answers device queries
/// (DA / DSR / cursor-position reports). A second responder writing to the
/// PTY would double-answer and corrupt the stream.
private final class MirrorDriver: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
