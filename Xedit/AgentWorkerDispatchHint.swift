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
        /// 发布/部署类脚本 → ops_runner 的单命令授权通道（target_command）。
        case opsRunner

        var tradeID: String {
            switch self {
            case .testFixer: return AgentSubagentProfileCatalog.testFixerID
            case .buildFixer: return AgentSubagentProfileCatalog.buildFixerID
            case .opsRunner: return AgentSubagentProfileCatalog.opsRunnerID
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
        exitCode: Int32?,
        /// Used only to correct a test-shaped command whose log shows a build
        /// failure. Absent leaves the command-shape verdict as-is.
        failureOutput: String = ""
    ) -> String? {
        guard toolName == "run_command" else { return nil }
        // No exit code means the command never produced a verdict: it failed
        // to launch, timed out, or was cancelled. Suggesting a fixer there
        // sends a worker to repair a machine problem.
        guard let exitCode, exitCode != 0 else { return nil }
        guard let command = arguments["command"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return nil }
        guard let commandKind = classify(command: command) else { return nil }
        let kind = refinedKind(for: commandKind, failureOutput: failureOutput)

        let quoted = command.count <= quotedCommandLimit ? "`\(command)`" : "the command above"
        switch kind {
        case .testFixer, .buildFixer:
            return """

            (WillDeep: this looks like a \(kind == .testFixer ? "test" : "build") failure a worker can own. \
            Spawn `profile="\(kind.tradeID)"` with `target_files` (the files it may edit) and a \
            `task` whose `verifier.command` is \(quoted) — the worker then iterates until that command \
            exits 0, on a cheaper model, without spending your context on the loop. Fix it yourself \
            instead when the cause is already obvious to you or spans files outside a small set.)
            """
        case .opsRunner:
            // 发布失败与测试失败的分野：worker 能拥有的是"重试并盯梢"，
            // 不是"决定回滚"。提示词把这条边界写死。
            return """

            (WillDeep: this looks like a release/deploy command. If the failure is transient \
            (network, registry, lock, notarization queue — anything a retry can clear), spawn \
            `profile="ops_runner"` with `target_command` set to EXACTLY \(quoted) and a `task` whose \
            `verifier.command` is a read-only health/status check — the user approves that one \
            command on the spawn card, and the worker re-runs and watches it on a cheaper model. \
            Keep the failure diagnosis, rollback, and any irreversible decision in this session.)
            """
        }
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
        // 发布检测优先于构建：`make deploy` 也含 "make"，但失败的是部署，
        // 而部署的正确出路是 ops_runner 的单命令授权，不是 build_fixer
        // 改代码。
        if releaseMarkers.contains(where: { head.contains($0) }) { return .opsRunner }
        if buildMarkers.contains(where: { head.contains($0) }) { return .buildFixer }
        return nil
    }

    /// Correct the trade using what the log actually shows.
    ///
    /// `classify` reads the command's shape, and a test command builds before
    /// it runs anything — so a compile error surfaced by `swift test` or by a
    /// repo's own `run_tests` script arrives labelled `test_fixer`, whose
    /// brief points it at test files it has no business changing. When the log
    /// shows the build never got far enough to execute a test, the trade is
    /// `build_fixer`.
    ///
    /// Deliberately one-directional and conservative: only a `testFixer`
    /// verdict is revisited, and only when compiler failure markers are
    /// present *and* nothing in the log looks like a test that ran. A test
    /// that genuinely failed always leaves one of those traces, so the
    /// ambiguous middle stays with `test_fixer`.
    static func refinedKind(for kind: Kind, failureOutput: String) -> Kind {
        guard kind == .testFixer else { return kind }
        let lowered = failureOutput.lowercased()
        guard compileFailureMarkers.contains(where: { lowered.contains($0) }) else { return kind }
        guard !testExecutionMarkers.contains(where: { lowered.contains($0) }) else { return kind }
        return .buildFixer
    }

    /// Markers specific enough that a *test* failure would not print them.
    /// A bare "error:" is deliberately absent — test output is full of it.
    private static let compileFailureMarkers: [String] = [
        "compilation failed", "compile error", "** build failed **",
        "command swiftcompile failed", "command compileswift failed",
        "error: cannot find", "error: value of type", "error: no such module",
        "does not conform to protocol", "use of unresolved identifier",
        "clang: error", "linker command failed", "ld: symbol",
        "error ts", "error[e0", "cannot borrow", "undefined reference to",
        "syntaxerror:", "indentationerror:",
    ]

    /// Anything that means a test actually executed. One of these present
    /// keeps the failure with `test_fixer`.
    private static let testExecutionMarkers: [String] = [
        "test run with", "recorded an issue", "✘ test", "test case '",
        "** test failed **", "--- fail:", "=== failures ===", "== failures ==",
        "assertionerror", "assertion failed", "expected:", "tests failed",
        "test suites:", "examples,", "failures:", "● ",
    ]

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

    /// 发布/部署形状的命令。特征取"这个仓库群和常见栈实际在用的"，不追求
    /// 穷举——漏判只是少一条提示，误判则会把构建失败指去发布通道。
    private static let releaseMarkers: [String] = [
        "release.rb", "release.sh", "release_mac_app", "scripts/release",
        "deploy", "publish", "fastlane",
        "helm upgrade", "helm install", "kubectl apply", "kubectl rollout",
        "terraform apply", "ansible-playbook",
        "gh release create", "npm publish", "cargo publish", "gem push",
    ]

    private static let buildMarkers: [String] = [
        "swift build", "xcodebuild", "make", "cmake",
        // A repo's own build wrapper is how most of these projects are
        // actually compiled; without this a `ruby scripts/build_fast.rb`
        // failure matched nothing and no trade was ever named. Release
        // markers are checked first, so `scripts/release.rb` still wins.
        "scripts/build", "build.sh", "build.rb",
        "npm run build", "yarn build", "pnpm build", "tsc", "vite build",
        "go build", "go vet", "cargo build", "cargo check", "cargo clippy",
        "gradle build", "mvn compile", "dotnet build",
        "eslint", "swiftlint", "rubocop", "ruff", "mypy", "flake8", "golangci-lint",
    ]
}
