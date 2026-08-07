import AppKit
import SwiftTerm
import Testing
@testable import WillDeep

/// The "test host dies with EXC_BREAKPOINT while closing a terminal tab" bug.
///
/// `LocalProcess.terminate()` and the exit handler of its `DispatchSourceProcess`
/// both call `childStopped()`, which cancels and nils the *same* source. Upstream
/// SwiftTerm never races there because it delivers on `DispatchQueue.main`;
/// `AgentLocalProcessTerminalView` deliberately hands it the snapshot mirror's
/// background queue so the PTY parse cannot be starved by a busy main thread.
/// That reintroduces the race: `AgentTerminalTab.terminate()` kills the process
/// tree first, so the exit event is already in flight on the mirror queue while
/// main tears the source down — an over-release that traps inside
/// `_os_object_retain`. It surfaced once in a full-load run as a crashed test
/// host, and in production it would take the app down when closing a tab.
///
/// The fix runs the teardown on the delivery queue.
///
/// Honest scope: an unsynchronized-memory race cannot be pinned down by
/// timing, and these tests do NOT reliably reproduce the crash — they passed
/// with the fix reverted. They are smoke coverage for both teardown orderings
/// (kill-then-tear-down, and tear down after the shell exited on its own), and
/// they are the harness Thread Sanitizer runs against. TSan does confirm that
/// `childStopped()` is entered concurrently from the mirror queue and another
/// thread; it reports that as the `running` flag rather than `childMonitor`
/// because both fields are written from the same function and it dedupes
/// reports by stack. Note that `running` race is upstream's, not ours: it is
/// between the mirror queue and `LocalProcess`'s private `readQueue`, it
/// survives this fix, and it is unreachable without patching SwiftTerm.
@Suite(.serialized)
struct AgentTerminalTerminationRaceTests {
    @MainActor
    private static func makeTab() -> AgentTerminalTab {
        let tab = AgentTerminalTab(
            kind: .localShell,
            originAgentSessionID: nil,
            title: "race",
            settings: EditorTerminalSettings.default
        )
        tab.start(
            settings: EditorTerminalSettings.default,
            workingDirectory: FileManager.default.temporaryDirectory.path,
            profile: nil,
            skin: nil
        )
        return tab
    }

    @Test("terminating a live tab while its exit event is in flight does not crash")
    @MainActor
    func terminateRacesExitEventWithoutCrashing() async throws {
        // Each round kills the tree and tears the source down back-to-back —
        // exactly the ordering that used to over-release the dispatch source.
        for _ in 0..<12 {
            let tab = Self.makeTab()
            let ready = await AgentTerminalTestSupport.waitForShellReady(tab)
            #expect(ready == .shellReady || ready == .exited)
            tab.terminate()
            #expect(tab.terminalView.process.running == false)
        }
    }

    @Test("terminate is idempotent once the shell has already exited on its own")
    @MainActor
    func terminateAfterNaturalExitIsIdempotent() async throws {
        let tab = Self.makeTab()
        let ready = await AgentTerminalTestSupport.waitForShellReady(tab)
        #expect(ready == .shellReady || ready == .exited)

        // Let the shell exit by itself, so the exit source fires without any
        // help from terminate(), then tear down twice over the top of it.
        tab.terminalView.send(txt: "exit\n")
        let deadline = Date().addingTimeInterval(20)
        while tab.terminalView.process.running, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        // Straight at the view, not `tab.terminate()`: the tab guards on
        // `isRunning`, which the exit callback has already cleared, so going
        // through it would skip the very teardown this test is about. The
        // exit source has run `childStopped()` on the mirror queue by now;
        // this is main running the same teardown with no ordering between
        // them — the pair that over-releases the dispatch source.
        tab.terminalView.terminate()
        tab.terminalView.terminate()
        #expect(tab.terminalView.process.running == false)
    }
}
