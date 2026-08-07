import AppKit
import SwiftTerm
import Testing
@testable import WillDeep

/// The "side panel shows no characters but still has a scrollbar" bug.
///
/// SwiftTerm turns every frame change into `terminal.resize`, whose own floor
/// is 2 cols x 1 row, and it reflows the buffer on the way down. A populated
/// scrollback rewrapped through two columns explodes past `rows + scrollback`,
/// so the buffer trims from the top; widening back cannot undo it. SwiftUI
/// hands the view degenerate frames routinely (mount, unmount, panel switch,
/// detach-to-window), which is why the tab intermittently came back blank or
/// mangled while the scroller still advertised scrollback.
///
/// The rc19 resize-storm fix only debounced the SIGWINCH side; the emulator's
/// own resize stayed unguarded. These tests lock the grid floor.
@Suite(.serialized)
struct AgentTerminalDegenerateResizeTests {
    @Test("a degenerate frame round-trip leaves the visible viewport intact")
    @MainActor
    func degenerateCollapsePreservesViewport() throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        for index in 1...40 {
            view.feed(text: "line \(index) rocky@mac ~/Sites/tokenhub deployment output row\r\n")
        }
        view.feed(text: "[root@k8s-c-master-01 ~]# ")

        let live = view.getTerminal()
        let before = (cols: live.cols, rows: live.rows)
        let viewportBefore = Self.viewportText(view)
        #expect(viewportBefore.contains("[root@k8s-c-master-01 ~]#"))
        #expect(view.canScroll)

        // A collapsing / detached SwiftUI host hands the view a zero frame,
        // then the real one again once it is remounted.
        view.setFrameSize(NSSize(width: 0, height: 0))
        #expect(live.cols == before.cols)
        #expect(live.rows == before.rows)

        view.setFrameSize(NSSize(width: 640, height: 320))
        #expect(Self.viewportText(view) == viewportBefore)
        #expect(view.canScroll)
    }

    @Test("the grid floor still accepts the narrowest real side-panel layout")
    @MainActor
    func narrowestRealPanelIsAccepted() throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        // AgentModeView clamps the side panel to 240pt and the terminal
        // surface insets it by 8pt on each side.
        #expect(view.acceptsFrameSize(NSSize(width: 240 - 16, height: 120)))
        #expect(!view.acceptsFrameSize(.zero))
        #expect(!view.acceptsFrameSize(NSSize(width: 640, height: 0)))
        #expect(!view.acceptsFrameSize(NSSize(width: 0, height: 320)))
    }

    /// Exactly what `drawTerminalContents` paints: rows `yDisp ..< yDisp+rows`.
    @MainActor
    private static func viewportText(_ view: AgentLocalProcessTerminalView) -> String {
        let terminal = view.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return "" }
        let start = terminal.buffer.yDisp
        return terminal.getText(
            start: Position(col: 0, row: start),
            end: Position(col: cols - 1, row: start + rows - 1)
        )
    }
}
