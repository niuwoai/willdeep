//
//  AgentWorkerDispatchHint.swift
//  WillDeep
//
//  The deterministic half of getting workers used.
//
//  A cheap worker tier only pays off if work actually reaches it, and the
//  parent model deciding to delegate is the least reliable step in the chain:
//  it is mid-task, it already has the file open, and fixing the thing itself
//  feels faster than writing a task packet. So the loop does not rely on that
//  judgement. When a test or build command fails, the failure itself carries
//  the nudge — with the packet's ingredients already assembled, because the
//  cost of delegating has to be one sentence, not a paragraph of setup.
//
//  Deliberately a hint, not an interception: the parent stays in charge of
//  whether to delegate. What changes is that delegating is now the cheaper
//  option to reach for.
//
//  See docs/SMALL_MODEL_SKILL_WORKERS_DESIGN.md §7.
//

import Foundation

nonisolated enum AgentWorkerDispatchHint {
    /// Which trade a failed command points at.
    enum Kind: Equatable {
        case testFixer
        case buildFixer

        var tradeID: String {
            switch self {
            case .testFixer: return AgentSubagentProfileCatalog.testFixerID
            case .buildFixer: return AgentSubagentProfileCatalog.buildFixerID
            }
        }
    }

    /// A command long enough to be a script invocation rather than a verdict
    /// is not quoted back into the hint — the model already has it above.
    private static let quotedCommandLimit = 160

    /// The nudge appended to a failed command's tool result, or nil when the
    /// failure is not worker-shaped.
    ///
    /// Returns nil for anything that is not a recognisably test/build-shaped
    /// command, and for failures with no exit code (those are launch failures,
    /// timeouts and cancellations — nothing for a fixer to repair).
    static func hint(
        toolName: String,
        arguments: [String: AgentJSONValue],
        exitCode: Int32?
    ) -> String? {
        guard toolName == "run_command" else { return nil }
        // No exit code means the command never produced a verdict: it failed
        // to launch, timed out, or was cancelled. Suggesting a fixer there
        // sends a worker to repair a machine problem.
        guard let exitCode, exitCode != 0 else { return nil }
        guard let command = arguments["command"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        guard let kind = classify(command: command) else { return nil }

        let quoted = command.count <= quotedCommandLimit ? "`\(command)`" : "the command above"
        return """

        (WillDeep: this looks like a \(kind == .testFixer ? "test" : "build") failure a worker can own. \
        Spawn `profile="\(kind.tradeID)"` with `target_files` (the files it may edit) and a \
        `task` whose `verifier.command` is \(quoted) — the worker then iterates until that command \
        exits 0, on a cheaper model, without spending your context on the loop. Fix it yourself \
        instead when the cause is already obvious to you or spans files outside a small set.)
        """
    }

    /// Classify a command by shape, not by trying to run it.
    ///
    /// Test detection wins over build detection: `swift test` builds too, but
    /// what failed is the test, and the test fixer is the trade that may
    /// legitimately change a test file.
    static func classify(command: String) -> Kind? {
        let lowered = command.lowercased()
        // Strip an obvious pipeline tail so `swift test | tail -20` still
        // reads as a test command.
        let head = lowered.split(separator: "|").first.map(String.init) ?? lowered

        if testMarkers.contains(where: { head.contains($0) }) { return .testFixer }
        if buildMarkers.contains(where: { head.contains($0) }) { return .buildFixer }
        return nil
    }

    /// Substrings that identify a test run across the stacks this app is used
    /// on. Matched against the command's head segment, so a bare `test` inside
    /// a path (`src/testing/build.sh`) does not qualify on its own.
    private static let testMarkers: [String] = [
        "swift test", "xcodebuild test", "run_tests", "run-tests",
        "npm test", "npm run test", "yarn test", "pnpm test", "bun test",
        "pytest", "python -m pytest", "go test", "cargo test",
        "rspec", "rake test", "bundle exec rspec",
        "jest", "vitest", "mocha", "phpunit", "gradle test", "mvn test",
        "ctest", "dotnet test",
    ]

    private static let buildMarkers: [String] = [
        "swift build", "xcodebuild", "make", "cmake",
        "npm run build", "yarn build", "pnpm build", "tsc", "vite build",
        "go build", "go vet", "cargo build", "cargo check", "cargo clippy",
        "gradle build", "mvn compile", "dotnet build",
        "eslint", "swiftlint", "rubocop", "ruff", "mypy", "flake8", "golangci-lint",
    ]
}
