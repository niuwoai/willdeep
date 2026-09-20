//
//  AgentWorkerDispatchHintTests.swift
//  WillDeepTests
//
//  The deterministic delegation nudge (skill-workers.v1 Phase 2 §7).
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentWorkerDispatchHintTests {
    private func hint(_ command: String, exitCode: Int32? = 1) -> String? {
        AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: ["command": .string(command)],
            exitCode: exitCode
        )
    }

    // MARK: Classification

    @Test("test commands route to the test fixer across stacks")
    func testCommandsClassify() {
        for command in [
            "swift test --filter AuthTests",
            "npm test",
            "pytest tests/auth",
            "go test ./...",
            "cargo test",
            "bundle exec rspec spec/models",
            "ruby scripts/run_tests_fast.rb",
        ] {
            #expect(AgentWorkerDispatchHint.classify(command: command) == .testFixer, "\(command)")
        }
    }

    @Test("build and lint commands route to the build fixer")
    func buildCommandsClassify() {
        for command in ["swift build", "tsc --noEmit", "cargo check", "eslint src", "make"] {
            #expect(AgentWorkerDispatchHint.classify(command: command) == .buildFixer, "\(command)")
        }
    }

    @Test("a test command that also builds is still a test failure")
    func testWinsOverBuild() {
        // `swift test` compiles too, but what failed is the test, and only the
        // test fixer may legitimately edit a test file.
        #expect(AgentWorkerDispatchHint.classify(command: "swift test") == .testFixer)
        #expect(AgentWorkerDispatchHint.classify(command: "xcodebuild test -scheme App") == .testFixer)
    }

    @Test("a pipeline tail does not hide the command")
    func pipelineTailIgnored() {
        #expect(AgentWorkerDispatchHint.classify(command: "swift test 2>&1 | tail -20") == .testFixer)
    }

    @Test("unrelated commands get no hint")
    func unrelatedCommandsClassifyNil() {
        for command in ["git status", "ls -la", "curl https://example.com", "cat README.md"] {
            #expect(AgentWorkerDispatchHint.classify(command: command) == nil, "\(command)")
        }
    }

    // MARK: Firing rules

    @Test("the hint names the trade and reuses the failed command as verifier")
    func hintNamesTradeAndVerifier() throws {
        let text = try #require(hint("swift test --filter AuthTests"))

        #expect(text.contains("test_fixer"))
        #expect(text.contains("swift test --filter AuthTests"))
        #expect(text.contains("target_files"))
        #expect(text.contains("exits 0"))
    }

    @Test("no hint without an exit code")
    func noHintWithoutExitCode() {
        // Launch failures, timeouts and cancellations produce no exit code.
        // Sending a fixer to repair those wastes a whole run on a machine
        // problem it cannot touch.
        #expect(hint("swift test", exitCode: nil) == nil)
    }

    @Test("no hint on success or for other tools")
    func noHintOnSuccessOrOtherTools() {
        #expect(hint("swift test", exitCode: 0) == nil)
        #expect(AgentWorkerDispatchHint.hint(
            toolName: "read_file",
            arguments: ["path": .string("a.swift")],
            exitCode: 1
        ) == nil)
        #expect(AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: [:],
            exitCode: 1
        ) == nil)
    }

    @Test("a very long command is referenced rather than quoted back")
    func longCommandIsNotQuoted() throws {
        let long = "swift test " + String(repeating: "--filter Something ", count: 20)
        let text = try #require(hint(long))

        // The command is already directly above in the transcript; repeating a
        // 400-character line on every failure is pure token cost.
        #expect(text.contains("the command above"))
        #expect(!text.contains(long))
    }

    @Test("the hint stays short enough to ride every failure")
    func hintIsCompact() throws {
        let text = try #require(hint("npm test"))
        #expect(text.count < 600)
    }

    // MARK: - Trade correction from the log

    @Test("a compile failure under a test command is corrected to build_fixer")
    func compileFailureUnderATestCommandBecomesBuildFixer() {
        // A test command compiles first. `run_tests_fast.rb` matching
        // "run_tests" is how a Swift compile error arrived labelled
        // `test_fixer`, whose brief points it at test files.
        let corrected = AgentWorkerDispatchHint.refinedKind(
            for: .testFixer,
            failureOutput: "Xedit/AppState.swift:12:5: error: cannot find 'foo' in scope\n** BUILD FAILED **"
        )

        #expect(corrected == .buildFixer)
    }

    @Test("a test that actually ran stays with test_fixer")
    func realTestFailureKeepsTestFixer() {
        // Ambiguity stays with the command-shape verdict: any trace of a test
        // having executed keeps the trade, even alongside compiler wording.
        for output in [
            "✘ Test foo() recorded an issue at Foo.swift:9:1: error: expected 3",
            "--- FAIL: TestThing (0.01s)\n\terror: cannot find match",
            "AssertionError: 1 != 2",
        ] {
            #expect(
                AgentWorkerDispatchHint.refinedKind(for: .testFixer, failureOutput: output) == .testFixer,
                "output: \(output)"
            )
        }
    }

    @Test("correction is one-directional and never touches the other trades")
    func correctionLeavesBuildAndOpsAlone() {
        let compileLog = "** BUILD FAILED **\nerror: cannot find 'x'"

        #expect(AgentWorkerDispatchHint.refinedKind(for: .buildFixer, failureOutput: compileLog) == .buildFixer)
        #expect(AgentWorkerDispatchHint.refinedKind(for: .opsRunner, failureOutput: compileLog) == .opsRunner)
        // No log to judge by leaves the verdict alone.
        #expect(AgentWorkerDispatchHint.refinedKind(for: .testFixer, failureOutput: "") == .testFixer)
    }

    @Test("a repo's own build wrapper is recognised as a build command")
    func repoBuildWrapperIsClassified() {
        #expect(AgentWorkerDispatchHint.classify(command: "ruby scripts/build_fast.rb") == .buildFixer)
        #expect(AgentWorkerDispatchHint.classify(command: "./build.sh --release") == .buildFixer)
        // Release detection still wins over the build wrapper.
        #expect(AgentWorkerDispatchHint.classify(command: "ruby scripts/release.rb") == .opsRunner)
    }

    @Test("deploy and publish only count as whole tokens")
    func releaseVerbsNeedAWholeToken() {
        // A bare substring sent these to ops_runner, which is never
        // auto-dispatched — so build_fixer did not get them either.
        #expect(AgentWorkerDispatchHint.classify(command: "make deploy-dev") == .buildFixer)
        #expect(AgentWorkerDispatchHint.classify(command: "npm run build:publish-docs") == .buildFixer)
        #expect(AgentWorkerDispatchHint.classify(command: "go build ./cmd/deployment") == .buildFixer)
        // Whole tokens, script names and paths still read as a release.
        #expect(AgentWorkerDispatchHint.classify(command: "make deploy") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "./deploy.sh prod") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "ruby scripts/deploy") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "npm run publish") == .opsRunner)
        #expect(AgentWorkerDispatchHint.classify(command: "npm publish --access public") == .opsRunner)
    }
}
