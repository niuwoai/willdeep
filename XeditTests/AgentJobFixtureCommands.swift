import Foundation

/// Shell fixtures for "a job that stays alive until someone stops it".
///
/// The obvious spelling — a TERM trap around an unbounded sleep loop — is a
/// process leak waiting for a bad day. It only ever dies because the
/// test that spawned it signals it, so any abnormal end of the test host
/// (a watchdog SIGKILL on a hung `xcodebuild`, a crashed harness, a
/// force-quit) skips every `defer`, the shell is reparented to launchd and
/// then idles forever. On 2026-09-12 two such orphans were found on a dev
/// machine, one of them 6 days old, both from the background-task panel
/// visual-QA fixture.
///
/// So every idle fixture carries its own deadline. A normal run still ends
/// in milliseconds via SIGTERM; an abandoned one reaps itself within
/// `maximumIdleSeconds`. The ceiling is far longer than any test needs it to
/// live, so it can never turn a slow machine into a flaky assertion.
enum AgentJobFixtureCommand {
    /// Hard ceiling, in seconds, on how long an abandoned fixture shell may
    /// survive its creator.
    static let maximumIdleSeconds = 60

    /// Idles quietly, exiting 143 on SIGTERM the way a well-behaved job does.
    /// `prefix` is prepended verbatim, for fixtures that must emit some
    /// output before going quiet.
    static func idle(prefix: String = "") -> String {
        prefix + "trap 'exit 143' TERM; " + boundedSleepLoop
    }

    /// Ignores SIGTERM on purpose — the fixture for proving that cleanup
    /// escalates to SIGKILL. Still deadline-bounded: an unkillable orphan is
    /// exactly the thing this file exists to prevent.
    static func idleIgnoringTerm() -> String {
        "trap '' TERM; " + boundedSleepLoop
    }

    /// Blocks until `gatePath` exists, running `body` once per 0.1 s tick,
    /// with the same deadline as `boundedSleepLoop`. For tests that assert
    /// "the job is still running" at some point: the test creates the gate
    /// file once it has checked, instead of racing a fixed `sleep` that a
    /// fully loaded test host can outlast.
    static func waitForGate(_ gatePath: String, body: String = ":") -> String {
        let ticks = maximumIdleSeconds * 10
        return "__wd=0; while [ ! -e '\(gatePath)' ] && [ \"$__wd\" -lt \(ticks) ]; "
            + "do \(body); sleep 0.1; __wd=$((__wd + 1)); done"
    }
    /// Creates the gate file a `waitForGate` fixture is waiting on.
    static func openGate(_ gatePath: String) {
        FileManager.default.createFile(atPath: gatePath, contents: Data())
    }
    /// POSIX-sh countdown rather than `while true`. `sleep 1` keeps the
    /// signal-delivery latency the kill tests rely on.
    static let boundedSleepLoop =
        "__wd=0; while [ \"$__wd\" -lt \(maximumIdleSeconds) ]; "
        + "do sleep 1; __wd=$((__wd + 1)); done"
}
