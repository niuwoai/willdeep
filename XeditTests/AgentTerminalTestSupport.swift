import Foundation
@testable import WillDeep

/// Readiness helpers for tests that drive a *real* pty through
/// `AgentInteractiveTerminalController`.
///
/// A local tab launches the user's login shell (`zsh -l`), so every command in
/// the rc files runs as a foreground child of that pty. While it does,
/// `AgentTerminalInputState.classify` correctly reports `.foregroundTask` and
/// `sendApprovedCommand` refuses with "A non-interactive foreground task
/// currently owns this terminal." That is not test cross-talk — each test owns
/// its own controller and pty — it is the tab's own shell still booting. A
/// fixed `Task.sleep` before dispatch is therefore a race: it holds on an idle
/// machine and loses under a full-load parallel test run.
enum AgentTerminalTestSupport {
    /// Consecutive `.shellReady` samples required before a tab counts as ready.
    /// One sample can land in the gap between two rc-file children, so a single
    /// hit is not proof the shell reached its prompt.
    private static let requiredStableSamples = 3
    private static let pollInterval = Duration.milliseconds(50)

    /// Poll until the tab's shell owns its own pty (prompt reached) or the
    /// deadline passes. Returns the last observed state so callers can assert
    /// on a readable value instead of failing later with a confusing dispatch
    /// refusal.
    @MainActor
    @discardableResult
    static func waitForShellReady(
        _ tab: AgentTerminalTab,
        timeout: TimeInterval = 30
    ) async -> AgentTerminalInputState {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSamples = 0
        while true {
            tab.refreshInputState()
            let state = tab.inputState
            if state == .exited { return state }
            if state == .shellReady {
                stableSamples += 1
                if stableSamples >= requiredStableSamples { return state }
            } else {
                stableSamples = 0
            }
            guard Date() < deadline else { return state }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
