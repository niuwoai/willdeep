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
}
