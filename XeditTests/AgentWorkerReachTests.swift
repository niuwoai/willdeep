//
//  AgentWorkerReachTests.swift
//  WillDeepTests
//
//  Guards for the three gaps that kept the worker tier at zero runs on real
//  sessions: a failure whose command shape says nothing, a test that timed out
//  instead of failing, a read-only trade with no trigger at all — plus the
//  hosted-chain fallback that turns a stale `hostedTradeIDs` entry into a
//  retry rather than a dead spawn.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentWorkerReachTests {

    // MARK: - Log-shaped classification

    /// The measured miss: `gofmt -w …` exits non-zero with nothing but Go
    /// compiler output. Shape says "not a build command", so before this the
    /// failure named no trade at all.
    @Test("a compiler log classifies as build_fixer even when the command does not look like a build")
    func compilerLogClassifiesWithoutBuildShapedCommand() {
        let command = "gofmt -w internal/perftest/loadgen/config.go"
        let log = """
        FAIL	tokenhub/internal/perftest/loadgen [build failed]
        internal/perftest/loadgen/config.go:41:2: declared and not used: cfg
        """
        #expect(AgentWorkerDispatchHint.classify(command: command) == nil)
        #expect(AgentWorkerDispatchHint.classify(
            command: command,
            failureOutput: log
        ) == .buildFixer)
    }

    @Test("a log that shows tests actually ran classifies as test_fixer")
    func testExecutionLogClassifies() {
        let log = "--- FAIL: TestLogin (0.02s)\n    login_test.go:22: expected 200, got 500"
        #expect(AgentWorkerDispatchHint.classify(
            command: "./scripts/ci-entry",
            failureOutput: log
        ) == .testFixer)
    }

    /// The log channel must not fire on prose. A script whose shape names no
    /// trade, failing while printing ordinary words, still names no trade —
    /// the word "build" inside a sentence is not a compiler diagnostic.
    @Test("an ordinary failure log still classifies as nothing")
    func plainFailureLogClassifiesAsNil() {
        #expect(AgentWorkerDispatchHint.classify(command: "./notes.sh") == nil)
        #expect(AgentWorkerDispatchHint.classify(
            command: "./notes.sh",
            failureOutput: "could not reach the build server, please retry later"
        ) == nil)
    }

    /// The shape rule survives: a test command whose log proves the build
    /// never ran still lands on build_fixer, not on the trade allowed to edit
    /// test files.
    @Test("a test command that failed to compile stays with build_fixer")
    func testShapedCompileFailureStaysBuildFixer() {
        #expect(AgentWorkerDispatchHint.classify(
            command: "swift test",
            failureOutput: "error: no such module 'Foo'\ncompilation failed"
        ) == .buildFixer)
    }

    // MARK: - Timeouts

    @Test("a timed-out test suite gets a narrowed-verifier hint")
    func timedOutTestSuiteHints() throws {
        let note = try #require(AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: ["command": .string("yarn test:e2e")],
            exitCode: nil,
            failureOutput: "Command timed out before completing."
        ))
        #expect(note.contains(AgentSubagentProfileCatalog.testFixerID))
        // The whole point: the worker must not be handed the command that
        // just blew the deadline as its verifier.
        #expect(note.contains("NARROWED"))
    }

    @Test("a launch failure with no exit code still names no trade")
    func launchFailureStaysQuiet() {
        #expect(AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: ["command": .string("swift test")],
            exitCode: nil,
            failureOutput: "No such file or directory"
        ) == nil)
    }

    @Test("a timed-out release command is not pushed at ops_runner")
    func timedOutReleaseStaysQuiet() {
        #expect(AgentWorkerDispatchHint.hint(
            toolName: "run_command",
            arguments: ["command": .string("ruby scripts/release.rb run veilwriter")],
            exitCode: nil,
            failureOutput: "Command timed out before completing."
        ) == nil)
    }

    // MARK: - Read-only handoff on truncation

    @Test("an oversized git history payload points at git_detective")
    func truncatedGitHistoryPointsAtGitDetective() throws {
        let note = try #require(AgentReadOnlyWorkerHandoffHint.hint(
            toolName: "run_command",
            command: "git log --stat -n 400",
            omittedCharacters: 90_000,
            alreadyHintedThisTurn: false
        ))
        #expect(note.contains(AgentSubagentProfileCatalog.gitDetectiveID))
        #expect(note.contains("90000"))
    }

    @Test("an oversized log dump points at log_inspector")
    func truncatedLogPointsAtLogInspector() throws {
        let note = try #require(AgentReadOnlyWorkerHandoffHint.hint(
            toolName: "run_command",
            command: "/usr/bin/log show --last 2h",
            omittedCharacters: 50_000,
            alreadyHintedThisTurn: false
        ))
        #expect(note.contains(AgentSubagentProfileCatalog.logInspectorID))
    }

    @Test("search and read tools point at scout and reader")
    func truncatedSearchAndReadPointAtTheirTrades() throws {
        let search = try #require(AgentReadOnlyWorkerHandoffHint.trade(
            toolName: "grep_files",
            command: nil
        ))
        #expect(search == AgentSubagentProfileCatalog.scoutID)
        let read = try #require(AgentReadOnlyWorkerHandoffHint.trade(
            toolName: "read_file",
            command: nil
        ))
        #expect(read == AgentSubagentProfileCatalog.readerID)
    }

    @Test("the handoff hint fires at most once per turn")
    func handoffHintIsOncePerTurn() {
        #expect(AgentReadOnlyWorkerHandoffHint.hint(
            toolName: "grep_files",
            command: nil,
            omittedCharacters: 90_000,
            alreadyHintedThisTurn: true
        ) == nil)
    }

    @Test("a barely-truncated payload is not worth a worker")
    func smallTruncationStaysQuiet() {
        #expect(AgentReadOnlyWorkerHandoffHint.hint(
            toolName: "grep_files",
            command: nil,
            omittedCharacters: 100,
            alreadyHintedThisTurn: false
        ) == nil)
    }

    @Test("a write tool's oversized output names no read-only trade")
    func writeToolNamesNoTrade() {
        #expect(AgentReadOnlyWorkerHandoffHint.trade(
            toolName: "apply_patch",
            command: nil
        ) == nil)
    }

    // MARK: - Hosted chain fallback

    private struct StubError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Test("a missing hosted chain retries on the concrete flash model")
    func missingHostedChainRetries() {
        let error = StubError(text: #"HTTP 400: {"error":{"code":"model_not_configured"}}"#)
        #expect(AgentSubagentHostedModelFallback.retryModel(
            afterError: error,
            attemptedModel: "someim-32b-git-detective",
            hostedModel: "someim-32b-git-detective"
        ) == AgentSubagentHostedModelFallback.fallbackModel)
        #expect(AgentSubagentHostedModelFallback.fallbackModel == "deepseek-v4-flash")
    }

    @Test("an ordinary worker failure is not silently re-run on another model")
    func ordinaryFailureDoesNotSwapModels() {
        #expect(AgentSubagentHostedModelFallback.retryModel(
            afterError: StubError(text: "HTTP 500: upstream timeout"),
            attemptedModel: "someim-32b-scout",
            hostedModel: "someim-32b-scout"
        ) == nil)
    }

    /// A user-chosen model that happens to fail this way is theirs, not ours
    /// to replace: the retry only covers the model the roster picked.
    @Test("a model the trade did not declare as hosted is left alone")
    func nonHostedModelIsLeftAlone() {
        #expect(AgentSubagentHostedModelFallback.retryModel(
            afterError: StubError(text: "model_not_configured"),
            attemptedModel: "glm-5",
            hostedModel: nil
        ) == nil)
        #expect(AgentSubagentHostedModelFallback.retryModel(
            afterError: StubError(text: "model_not_configured"),
            attemptedModel: "glm-5",
            hostedModel: "someim-32b-scout"
        ) == nil)
    }

    @Test("the fallback model failing the same way does not loop")
    func fallbackModelDoesNotRetryItself() {
        #expect(AgentSubagentHostedModelFallback.retryModel(
            afterError: StubError(text: "model_not_configured"),
            attemptedModel: AgentSubagentHostedModelFallback.fallbackModel,
            hostedModel: AgentSubagentHostedModelFallback.fallbackModel
        ) == nil)
    }

    @Test("the fallback note names both the stale chain and what ran instead")
    func fallbackNoteNamesBothModels() {
        let note = AgentSubagentHostedModelFallback.fallbackNote(
            hostedModel: "someim-32b-git-detective",
            ranOn: "deepseek-v4-flash"
        )
        #expect(note.contains("someim-32b-git-detective"))
        #expect(note.contains("deepseek-v4-flash"))
        #expect(note.contains("hostedTradeIDs"))
    }
}
