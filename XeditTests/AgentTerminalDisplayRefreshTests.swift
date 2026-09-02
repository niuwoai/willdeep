import AppKit
import SwiftTerm
import Testing
@testable import WillDeep

@Suite
struct AgentTerminalInputStateTests {
    @Test("PTY ownership separates a ready shell from foreground jobs and interactive programs")
    func classifiesInputOwner() {
        #expect(AgentTerminalInputState.classify(
            processIsRunning: false,
            shellProcessGroupID: 10,
            foregroundProcessGroupID: 10,
            echoEnabled: true,
            canonicalInputEnabled: true
        ) == .exited)
        #expect(AgentTerminalInputState.classify(
            processIsRunning: true,
            shellProcessGroupID: 10,
            foregroundProcessGroupID: 10,
            echoEnabled: true,
            canonicalInputEnabled: true
        ) == .shellReady)
        #expect(AgentTerminalInputState.classify(
            processIsRunning: true,
            shellProcessGroupID: 10,
            foregroundProcessGroupID: 20,
            echoEnabled: true,
            canonicalInputEnabled: true
        ) == .foregroundTask)
        #expect(AgentTerminalInputState.classify(
            processIsRunning: true,
            shellProcessGroupID: 10,
            foregroundProcessGroupID: 20,
            echoEnabled: false,
            canonicalInputEnabled: false
        ) == .interactiveProgram)
        #expect(AgentTerminalInputState.classify(
            processIsRunning: true,
            shellProcessGroupID: nil,
            foregroundProcessGroupID: nil,
            echoEnabled: nil,
            canonicalInputEnabled: nil
        ) == .unknown)
    }

    @Test("arrows are recognized narrowly without swallowing arbitrary escape input")
    func recognizesNavigationEscapes() {
        #expect(AgentLocalProcessTerminalView.isNavigationEscapeSequence([0x1B, 0x5B, 0x41]))
        #expect(AgentLocalProcessTerminalView.isNavigationEscapeSequence([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x42]))
        #expect(AgentLocalProcessTerminalView.isNavigationEscapeSequence([0x1B, 0x4F, 0x43]))
        #expect(!AgentLocalProcessTerminalView.isNavigationEscapeSequence([0x1B]))
        #expect(!AgentLocalProcessTerminalView.isNavigationEscapeSequence(Array("clear".utf8)))
        #expect(!AgentLocalProcessTerminalView.isNavigationEscapeSequence([0x1B, 0x5B, 0x32, 0x7E]))
    }

    @Test("only canonical foreground tasks block Agent command injection")
    func dispatchPolicyIsNarrow() {
        #expect(AgentTerminalCommandDispatchPolicy.refusalMessage(for: .foregroundTask) != nil)
        #expect(AgentTerminalCommandDispatchPolicy.refusalMessage(for: .shellReady) == nil)
        #expect(AgentTerminalCommandDispatchPolicy.refusalMessage(for: .interactiveProgram) == nil)
        #expect(AgentTerminalCommandDispatchPolicy.refusalMessage(for: .unknown) == nil)
    }

    @Test("only Agent-owned commands and tabs publish semantic terminal events")
    func semanticTransitionsRequireAgentOwnership() {
        #expect(AgentInteractiveTerminalController.semanticTransition(
            from: .foregroundTask,
            to: .shellReady,
            hasPendingAgentCommand: false,
            isAgentCreatedTab: false
        ) == nil)
        #expect(AgentInteractiveTerminalController.semanticTransition(
            from: .foregroundTask,
            to: .shellReady,
            hasPendingAgentCommand: true,
            isAgentCreatedTab: false
        ) == .commandCompleted)
        #expect(AgentInteractiveTerminalController.semanticTransition(
            from: .shellReady,
            to: .exited,
            hasPendingAgentCommand: false,
            isAgentCreatedTab: false
        ) == nil)
        #expect(AgentInteractiveTerminalController.semanticTransition(
            from: .shellReady,
            to: .exited,
            hasPendingAgentCommand: false,
            isAgentCreatedTab: true
        ) == .exited)
    }
}

@Suite(.serialized)
struct AgentTerminalForegroundOwnershipIntegrationTests {
    @Test("a live foreground job is detected and rejects command injection")
    @MainActor
    func liveForegroundJobBlocksDispatch() async throws {
        let tab = AgentTerminalTab(
            kind: .delegatedShell,
            originAgentSessionID: UUID(),
            title: "Foreground ownership test",
            settings: .default
        )
        tab.start(
            settings: .default,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            profile: nil,
            skin: nil
        )
        defer { tab.terminate() }

        // The two waits below are preconditions, not the thing under test, so
        // they use `#require`: if the PTY never reaches the state this test is
        // *about*, stop here. The old `#expect` let the run continue into the
        // injection assertions, which then failed too — a setup timeout
        // presented itself as "command injection was not rejected", the single
        // most alarming way this test could possibly lie.
        let shellReady = await waitForInputState(.shellReady, tab: tab)
        try #require(shellReady.matched, "the PTY never handed its foreground group to the shell — \(shellReady.diagnosis)")

        tab.terminalView.send(txt: "sleep \(Self.foregroundJobSeconds)\n")
        let foregroundOwned = await waitForInputState(.foregroundTask, tab: tab)
        try #require(foregroundOwned.matched, "`sleep` never took the PTY's foreground process group — \(foregroundOwned.diagnosis)")

        do {
            _ = try tab.sendApprovedCommand("printf 'must-not-run\\n'")
            Issue.record("expected a foreground task to reject command injection")
        } catch let error as AgentToolError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Nothing was sent"))
            #expect(message.contains("ctrl_c"))
        }
        #expect(throws: AgentToolError.self) {
            try tab.sendAutomationCommand(
                "printf 'automation-must-not-run\\n'",
                displayCommand: "blocked automation"
            )
        }
        #expect(tab.recentCommands.isEmpty)

        tab.sendUserControl(.ctrlC)
        let backToShell = await waitForInputState(.shellReady, tab: tab)
        #expect(backToShell.matched, "ctrl-C did not return the PTY to the shell — \(backToShell.diagnosis)")
    }

    /// How long the foreground job stays observable.
    ///
    /// This is the number that actually made the test flaky, and it is not a
    /// budget — it is a *window*. The observer polls on the main actor, and in
    /// a full-target run hundreds of other `@MainActor` tests are queued on
    /// that same actor, so the poll loop can be frozen out for many seconds at
    /// a stretch. Measured under emulated contention: **one single poll in 18
    /// seconds**. With `sleep 10` the job had already exited and the shell was
    /// back at its prompt before the observer got its first look, so
    /// `.foregroundTask` was missed even though the product had produced it
    /// perfectly. Widening the *timeout* alone could never fix that — the
    /// evidence itself expires.
    ///
    /// 600s is ~33x the worst gap measured, and still bounded so a hard-killed
    /// test run cannot leak a `sleep` for the rest of the day. ctrl-C ends it
    /// in the happy path; `tab.terminate()` kills the process tree regardless.
    private static let foregroundJobSeconds = 600

    /// Budget for a state this test cannot make happen faster: the shell has
    /// to spawn, take the controlling terminal, read the typed line, and hand
    /// the PTY's foreground process group to `sleep`.
    ///
    /// Was 3s, then 10s — both were sized against how long the *PTY* takes,
    /// not against how long the main actor can be held away from the poll
    /// loop, which is the real variable (18s measured, and it scales with how
    /// many main-actor tests the run schedules alongside this one). At 10s the
    /// first wait alone already blew through its budget on a loaded machine.
    ///
    /// Widening this does not weaken the assertion: a genuine regression never
    /// reaches the expected state at all, so it still fails, just later. It
    /// stays an order of magnitude below `foregroundJobSeconds` so the state
    /// being waited for is still there when a starved poll finally runs.
    private static let inputStateTimeout = Duration.seconds(60)
    private static let inputStatePollInterval = Duration.milliseconds(50)

    /// What a wait saw, so a failure reports the actual PTY story instead of a
    /// bare `false`. The state sequence separates "never got there" from
    /// "got there and moved on", and the mirrored screen shows whether the
    /// shell ever read the line — the mirror is fed on its own queue, so it
    /// stays readable exactly when the main actor is too busy to be trusted.
    private struct InputStateWatch {
        let matched: Bool
        let elapsed: Duration
        let polls: Int
        let observed: [AgentTerminalInputState]
        let screen: String

        var diagnosis: String {
            let trail = observed.map { String(describing: $0) }.joined(separator: " → ")
            return """
            waited \(elapsed) across \(polls) poll(s), states: \(trail.isEmpty ? "none" : trail), \
            terminal showed \(screen.debugDescription)
            """
        }
    }

    @MainActor
    private func waitForInputState(
        _ expected: AgentTerminalInputState,
        tab: AgentTerminalTab
    ) async -> InputStateWatch {
        let started = ContinuousClock.now
        let deadline = started + Self.inputStateTimeout
        var polls = 0
        var observed: [AgentTerminalInputState] = []

        func sample() -> Bool {
            tab.refreshInputState()
            polls += 1
            if observed.last != tab.inputState { observed.append(tab.inputState) }
            return tab.inputState == expected
        }

        func result(matched: Bool) -> InputStateWatch {
            InputStateWatch(
                matched: matched,
                elapsed: started.duration(to: .now),
                polls: polls,
                observed: observed,
                screen: matched ? "" : tab.terminalView.snapshotMirror.capture().viewport
            )
        }

        while ContinuousClock.now < deadline {
            if sample() { return result(matched: true) }
            try? await Task.sleep(for: Self.inputStatePollInterval)
        }
        // One last look after the budget. Under main-actor starvation the loop
        // above can be frozen out entirely, and the state we are waiting for
        // may have arrived while it was — with a 600s window it is still there
        // to be seen. Losing that check is how a merely slow machine turns
        // into a red build.
        return result(matched: sample())
    }
}

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

    /// The screenshot bug distilled: a WINCH-style redraw (cursor-up + CR +
    /// prompt reprint with NO erase-to-EOL) bakes mixed-generation rows and
    /// a mid-screen cursor into the buffer. The renderer must faithfully
    /// track the model — caret exactly where the model cursor is — because
    /// the fix for the bug lives upstream (resize debounce), not in drawing.
    @Test("caret tracks the model cursor even after a mid-screen redraw")
    @MainActor
    func caretMatchesModelAfterMidScreenRedraw() async throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        view.feed(text: "Waiting for deployment rollout: 1 old replicas are pending termination...\r\n")
        view.feed(text: "deployment successfully rolled out\r\n")
        view.feed(text: "[root@k8s-c-master-01 ~]# ")
        // WINCH-style redraw: two rows up, CR, reprint prompt, no \e[K.
        view.feed(text: "\u{1b}[2A\r[root@k8s-c-master-01 ~]# ")
        view.refreshVisibleTerminalDisplay()
        try await waitForDisplayPass()

        let caret = try #require(
            view.subviews.first {
                String(describing: type(of: $0)).contains("CaretView")
            }
        )
        let terminal = view.getTerminal()
        // The model cursor sits mid-screen on the reprinted prompt row.
        // The caret's visible row (derived from its y origin) must agree.
        let cellHeight = caret.frame.height
        let visibleRow = Int(((view.frame.height - caret.frame.origin.y) / cellHeight).rounded()) - 1
        let expectedRow = terminal.getCursorLocation().y
        #expect(visibleRow == expectedRow)
    }

    @MainActor
    private func waitForDisplayPass() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}

@Suite(.serialized)
struct AgentTerminalWinsizeDebounceTests {
    @MainActor
    private final class SizeSpy: AgentTerminalProcessDelegate {
        var calls: [(cols: Int, rows: Int)] = []
        func sizeChanged(source: AgentLocalProcessTerminalView, newCols: Int, newRows: Int) {
            calls.append((newCols, newRows))
        }
        func setTerminalTitle(source: AgentLocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: AgentLocalProcessTerminalView, directory: String?) {}
        func processTerminated(source: AgentLocalProcessTerminalView, exitCode: Int32?) {}
    }

    @Test("transient size bursts collapse into one settled winsize commit")
    @MainActor
    func sizeBurstCommitsOnce() async throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        let spy = SizeSpy()
        view.processDelegate = spy

        // A mount-animation style burst: two transient flips then settle.
        view.sizeChanged(source: view, newCols: 78, newRows: 22)
        view.sizeChanged(source: view, newCols: 80, newRows: 24)
        view.sizeChanged(source: view, newCols: 79, newRows: 23)
        // Nothing may reach the child before the debounce window closes.
        #expect(spy.calls.isEmpty)

        // 旧写法固定睡 250ms 等 0.12s 的 debounce 落地,只有 ~2x 余量——主队列
        // asyncAfter 在满载全量下延迟轻易超过这点空隙,于是假红。改成轮询到
        // 提交出现为止,上限 10s 只作挂死兜底:负载高只是变慢,不再假失败。
        let deadline = Date().addingTimeInterval(10)
        while spy.calls.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Exactly one commit, carrying the live settled geometry.
        #expect(spy.calls.count == 1)
        let live = view.getTerminal()
        #expect(spy.calls.first?.cols == live.cols)
        #expect(spy.calls.first?.rows == live.rows)
    }

    @Test("degenerate transitional sizes never propagate")
    @MainActor
    func degenerateSizesAreIgnored() async throws {
        let view = AgentLocalProcessTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320)
        )
        let spy = SizeSpy()
        view.processDelegate = spy

        view.sizeChanged(source: view, newCols: 0, newRows: 0)
        view.sizeChanged(source: view, newCols: 1, newRows: 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(spy.calls.isEmpty)
    }
}

@Suite(.serialized)
struct TerminalZModemDetectorNegativeTests {
    @Test("plain text that merely resembles ZMODEM never triggers a session")
    func textNeverTriggers() {
        var detector = TerminalZModemDetector()
        // The needle is the 4-byte binary header `**` CAN `B` — text-only
        // lookalikes (an rz mention, bare stars, no CAN byte) must not eat
        // the visible terminal's byte stream.
        let rz = Array("rz\r".utf8)
        #expect(detector.detect(in: rz) == .display(rz))
        let hexLookalike = Array("**B0100000023be50\r\n".utf8)
        #expect(detector.detect(in: hexLookalike) == .display(hexLookalike))
        let kubectl = Array("kubectl rollout status deployment/tokenhub\r\n".utf8)
        #expect(detector.detect(in: kubectl) == .display(kubectl))
    }

    @Test("the real binary header is matched even when split across chunks")
    func splitHeaderIsDetected() {
        // The matcher spans PTY read boundaries (lrzsz's opening frame
        // routinely arrives split over SSH) — but plain text must still
        // never trigger consumption, hence the paired negative test above.
        var detector = TerminalZModemDetector()
        let first = Array("rz\r*".utf8)
        #expect(detector.detect(in: first) == .display(first))
        guard case .start(let start) = detector.detect(in: [0x2A, 0x18, 0x42, 0x30, 0x30]) else {
            Issue.record("split ZMODEM header was not detected")
            return
        }
        #expect(start.displayPrefix.isEmpty)
        #expect(start.protocolBytes.prefix(4) == [0x2A, 0x2A, 0x18, 0x42])
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
