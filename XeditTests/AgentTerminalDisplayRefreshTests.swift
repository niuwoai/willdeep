import AppKit
import SwiftTerm
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentTerminalDisplayRefreshTests {
    @Test("terminal refresh repositions SwiftTerm caret after model output")
    @MainActor
    func refreshRepositionsCaret() async throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        view.feed(text: "first prompt")
        try await waitForDisplayPass()

        let caret = try #require(
            view.subviews.first {
                String(describing: type(of: $0)).contains("CaretView")
            }
        )
        let initialOrigin = caret.frame.origin

        view.getTerminal().feed(text: "\r\nsecond prompt")
        view.refreshVisibleTerminalDisplay()
        try await waitForDisplayPass()

        #expect(caret.frame.origin != initialOrigin)
    }

    @MainActor
    private func waitForDisplayPass() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}

@Suite(.serialized)
struct AgentTerminalSnapshotMirrorTests {
    @Test("terminal snapshot marks the cursor line separately from prior visible prompts")
    func snapshotMarksCurrentCursorLine() throws {
        let mirror = AgentTerminalSnapshotMirror(
            cols: 80,
            rows: 8,
            scrollback: 100,
            label: "test.agent-terminal.snapshot"
        )

        feed(mirror, "rocky@mac in ~/Sites/new83d % ssh root@10.0.131.57\r\n")
        feed(mirror, "Welcome to Alibaba Cloud Elastic Compute Service !\r\n")
        feed(mirror, "[root@k8s-c-master-01 ~]# ")

        let capture = mirror.capture()

        #expect(capture.viewport.contains("~/Sites/new83d"))
        #expect(capture.cursorLine.contains("[root@k8s-c-master-01 ~]#"))
        #expect(capture.markedViewport.contains("=> [root@k8s-c-master-01 ~]#"))
        #expect(!capture.cursorLine.contains("~/Sites/new83d"))
    }

    private func feed(_ mirror: AgentTerminalSnapshotMirror, _ text: String) {
        mirror.queue.sync {
            mirror.feedOnQueue(Array(text.utf8))
        }
    }
}
