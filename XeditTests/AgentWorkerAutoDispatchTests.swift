//
//  AgentWorkerAutoDispatchTests.swift
//  WillDeepTests
//
//  The decision half of auto-dispatch: when a failing command becomes a worker
//  run, which files that worker may touch, and every case where the loop must
//  keep its hands off.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentWorkerAutoDispatchTests {
    private func plan(
        toolName: String = "run_command",
        command: String? = "swift test",
        exitCode: Int32? = 1,
        output: String = "Xedit/Foo.swift:12:5: error: boom",
        policy: AgentDelegationPolicy = .automatic,
        dispatched: Set<String> = [],
        enabled: Bool = true,
        workspaceRootPath: String? = nil,
        exists: @escaping (String) -> Bool = { _ in true }
    ) -> Result<AgentWorkerAutoDispatch.Plan, AgentWorkerAutoDispatch.Refusal> {
        AgentWorkerAutoDispatch.plan(
            toolName: toolName,
            command: command,
            exitCode: exitCode,
            failureOutput: output,
            delegationPolicy: policy,
            alreadyDispatchedCommands: dispatched,
            isEnabled: enabled,
            workspaceRootPath: workspaceRootPath,
            existingWorkspacePaths: exists
        )
    }

    @Test("a failing test command becomes a test_fixer run verified by that command")
    func testFailingTestCommandDispatches() throws {
        let result = plan(command: "swift test --filter FooTests")
        let dispatch = try #require(try? result.get())

        #expect(dispatch.tradeID == AgentSubagentProfileCatalog.testFixerID)
        #expect(dispatch.verifierCommand == "swift test --filter FooTests")
        #expect(dispatch.targetRelativePaths == ["Xedit/Foo.swift"])
        // The child sees none of the parent conversation.
        #expect(dispatch.prompt.contains("swift test --filter FooTests"))
        #expect(dispatch.prompt.contains("`Xedit/Foo.swift`"))
        #expect(dispatch.prompt.contains("error: boom"))
    }

    @Test("a failing build command becomes a build_fixer run")
    func testFailingBuildCommandDispatches() throws {
        let dispatch = try #require(try? plan(
            command: "swift build",
            output: "Xedit/Bar.swift:3:1: error: no such module"
        ).get())
        #expect(dispatch.tradeID == AgentSubagentProfileCatalog.buildFixerID)
    }

    @Test("the prompt forbids the shortcuts that make a green verifier meaningless")
    func testPromptForbidsCheating() throws {
        let dispatch = try #require(try? plan().get())
        #expect(dispatch.prompt.contains("Do not weaken a test"))
        #expect(dispatch.prompt.contains("do not delete"))
        #expect(dispatch.prompt.contains("do not disable a lint rule"))
        #expect(dispatch.prompt.contains("stop and report"))
    }

    // MARK: - Refusals

    @Test("a release command is never auto-dispatched")
    func testReleaseCommandIsNotAutoDispatched() {
        // ops_runner exists, but deciding whether a deploy failure is transient
        // — or needs a rollback — is the parent's call, not a worker's.
        let result = plan(command: "make deploy", output: "deploy/x.sh:1: error: boom")
        #expect(result == .failure(.tradeNotAutoDispatchable(AgentSubagentProfileCatalog.opsRunnerID)))
    }

    @Test("/no-subagent is honoured by the automatic path too")
    func testForbiddenPolicyBlocksAutoDispatch() {
        #expect(plan(policy: .forbidden) == .failure(.delegationForbidden))
    }

    @Test("a command already delegated this turn is not delegated again")
    func testNoSecondDispatchForTheSameCommand() {
        let result = plan(command: "swift test", dispatched: ["swift test"])
        #expect(result == .failure(.alreadyDispatchedThisTurn))
        // And the model is told why, so a silent non-dispatch is impossible.
        #expect(AgentWorkerAutoDispatch.Refusal.alreadyDispatchedThisTurn.modelFacingNote != nil)
    }

    @Test("a failure with no exit code is a machine problem, not a repair job")
    func testNoExitCodeRefused() {
        #expect(plan(exitCode: nil) == .failure(.noExitCode))
        #expect(plan(exitCode: 0) == .failure(.noExitCode))
    }

    @Test("only run_command failures are considered")
    func testOnlyRunCommandConsidered() {
        #expect(plan(toolName: "edit_file") == .failure(.notACommandFailure))
    }

    @Test("the kill switch wins over everything")
    func testDisabledBySetting() {
        #expect(plan(enabled: false) == .failure(.disabledBySetting))
    }

    @Test("a failure naming no source file is left to the parent")
    func testNoDerivableWriteSet() {
        let result = plan(output: "error: linker command failed with exit code 1")
        #expect(result == .failure(.noDerivableWriteSet))
        #expect(AgentWorkerAutoDispatch.Refusal.noDerivableWriteSet.modelFacingNote != nil)
    }

    // MARK: - Write-set derivation

    @Test("write sets are derived from the toolchains people actually run")
    func testWriteSetAcrossToolchains() {
        let cases: [(String, [String])] = [
            ("Xedit/Foo.swift:12:5: error: boom", ["Xedit/Foo.swift"]),
            ("  --> crates/core/src/lib.rs:10:5", ["crates/core/src/lib.rs"]),
            ("./pkg/server.go:12:3: undefined: Foo", ["pkg/server.go"]),
            ("src/app.ts(12,3): error TS2304: Cannot find name", ["src/app.ts"]),
            ("File \"scripts/build.py\", line 3", ["scripts/build.py"]),
            ("FAIL src/components/Button.test.tsx", ["src/components/Button.test.tsx"]),
        ]
        for (output, expected) in cases {
            let derived = AgentWorkerAutoDispatch.deriveWriteSet(
                from: output,
                existingWorkspacePaths: { _ in true }
            )
            #expect(derived == expected, "output: \(output)")
        }
    }

    @Test("paths outside the workspace and non-source artifacts never enter the write set")
    func testWriteSetRejectsUnsafeAndIrrelevantPaths() {
        let output = """
        /Library/Developer/Toolchains/x.swift:1:1: note: from here
        ../outside/Escape.swift:2:2: error: nope
        build/Release/Foo.o: no such file
        Package.resolved: updated
        node_modules/dep/index.js:1:1: error: vendored
        Xedit/Real.swift:9:1: error: the actual defect
        """
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: output,
            // Everything is claimed to exist: the filter has to hold on its own.
            existingWorkspacePaths: { !$0.hasPrefix("node_modules/") }
        )
        #expect(derived == ["Xedit/Real.swift"])
    }

    // MARK: - Absolute paths (why build_fixer never received work)

    @Test("absolute paths inside the workspace are rebased instead of dropped")
    func testWriteSetRebasesAbsolutePathsOntoTheWorkspace() {
        // Swift, xcodebuild, clang and rustc all cite absolute paths. Write
        // access refuses those outright, so before this every compiler log
        // derived an empty write set and the dispatch refused itself.
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: "/Users/dev/proj/Xedit/AppState.swift:120:15: error: cannot find 'foo' in scope",
            workspaceRootPath: "/Users/dev/proj",
            existingWorkspacePaths: { _ in true }
        )

        #expect(derived == ["Xedit/AppState.swift"])
    }

    @Test("absolute paths outside the workspace are still refused")
    func testWriteSetStillRefusesPathsOutsideTheWorkspace() {
        let output = """
        /Applications/Xcode.app/Contents/Developer/SDK/Foo.swift:1:1: note: from here
        /Users/dev/other-repo/Escape.swift:2:2: error: nope
        /Users/dev/proj/Xedit/Real.swift:9:1: error: the actual defect
        """
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: output,
            workspaceRootPath: "/Users/dev/proj",
            existingWorkspacePaths: { _ in true }
        )

        #expect(derived == ["Xedit/Real.swift"])
    }

    @Test("with no workspace root every absolute path is dropped as before")
    func testWriteSetWithoutARootKeepsTheOldRefusal() {
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: "/Users/dev/proj/Xedit/AppState.swift:1:1: error: boom",
            workspaceRootPath: nil,
            existingWorkspacePaths: { _ in true }
        )

        #expect(derived.isEmpty)
    }

    @Test("a compiler failure with absolute paths now dispatches build_fixer end to end")
    func testCompilerFailureDispatchesBuildFixer() {
        // The whole chain that used to dead-end: a test-shaped command, a log
        // that shows the build never ran a test, and absolute paths.
        let result = plan(
            command: "ruby scripts/run_tests_fast.rb",
            output: "/Users/dev/proj/Xedit/AppState.swift:120:15: error: cannot find 'foo' in scope\n** BUILD FAILED **",
            workspaceRootPath: "/Users/dev/proj"
        )

        guard case .success(let dispatch) = result else {
            Issue.record("expected a dispatch, got \(result)")
            return
        }
        #expect(dispatch.tradeID == AgentSubagentProfileCatalog.buildFixerID)
        #expect(dispatch.targetRelativePaths == ["Xedit/AppState.swift"])
        #expect(dispatch.verifierCommand == "ruby scripts/run_tests_fast.rb")
    }

    @Test("a path the workspace does not have is dropped rather than authorized")
    func testWriteSetRequiresExistingPaths() {
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: "Xedit/Gone.swift:1:1: error: boom",
            existingWorkspacePaths: { _ in false }
        )
        #expect(derived.isEmpty)
    }

    @Test("the write set is capped below the write-access maximum")
    func testWriteSetIsCapped() {
        let output = (1...20)
            .map { "Xedit/File\($0).swift:1:1: error: boom" }
            .joined(separator: "\n")
        let derived = AgentWorkerAutoDispatch.deriveWriteSet(
            from: output,
            existingWorkspacePaths: { _ in true }
        )
        #expect(derived.count == AgentWorkerAutoDispatch.maxDerivedTargets)
        #expect(derived.count < AgentSubagentWriteAccess.maxTargetCount)
        // Sorted, so the approval card, the prompt and the lock agree.
        #expect(derived == derived.sorted())
    }

    // MARK: - What the parent is told afterwards

    @Test("a verified pass reports the verdict and still asks for review")
    func testResultNoteOnVerifiedPass() {
        let note = AppState.autoDispatchResultNote(
            profile: AgentSubagentProfileCatalog.testFixer,
            model: "someim-32b-test-fixer",
            outcome: AgentSubagentRunner.Outcome(
                report: "Fixed the off-by-one in the range check.",
                usageTokens: 1_200,
                roundCount: 3,
                toolInvocationCount: 5,
                verifierPassed: true,
                verifierAttempts: 2
            ),
            verifierCommand: "swift test",
            targets: ["Xedit/Foo.swift"]
        )

        // The model it actually ran on is named — this is the whole point of
        // the exercise, and it must be visible in the transcript.
        #expect(note.contains("someim-32b-test-fixer"))
        #expect(note.contains("`swift test` now exits 0"))
        #expect(note.contains("Fixed the off-by-one"))
        // A green verifier is evidence, not a review.
        #expect(note.contains("evidence, not a review"))
    }

    @Test("a worker that could not fix it hands the problem back and forbids a retry")
    func testResultNoteOnFailure() {
        let note = AppState.autoDispatchResultNote(
            profile: AgentSubagentProfileCatalog.buildFixer,
            model: "someim-32b-build-fixer",
            outcome: AgentSubagentRunner.Outcome(
                report: "The missing module is declared nowhere in the manifests.",
                usageTokens: 900,
                roundCount: 4,
                toolInvocationCount: 7,
                verifierPassed: false,
                verifierAttempts: 3
            ),
            verifierCommand: "swift build",
            targets: ["Xedit/Bar.swift"]
        )

        #expect(note.contains("still fails after 3 attempt(s)"))
        #expect(note.contains("do not re-delegate"))
    }

    @Test("a run with no verifier verdict is never reported as a pass")
    func testResultNoteWithoutVerdict() {
        let note = AppState.autoDispatchResultNote(
            profile: AgentSubagentProfileCatalog.testFixer,
            model: "someim-32b-test-fixer",
            outcome: AgentSubagentRunner.Outcome(
                report: "Report only.",
                usageTokens: 10,
                roundCount: 1,
                toolInvocationCount: 0
            ),
            verifierCommand: "swift test",
            targets: ["Xedit/Foo.swift"]
        )
        #expect(note.contains("no verdict"))
        #expect(!note.contains("now exits 0"))
    }

    @Test("automatic dispatch is on by default and can be switched off")
    func testKillSwitchDefault() {
        let key = AppState.autoDispatchWorkersDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppState.autoDispatchWorkersEnabled)
        UserDefaults.standard.set(false, forKey: key)
        #expect(!AppState.autoDispatchWorkersEnabled)
    }

    @Test("an enormous log is trimmed from the head so the verdict survives")
    func testOversizedOutputIsTrimmedFromTheHead() throws {
        let noise = String(repeating: "x", count: AgentWorkerAutoDispatch.maxOutputCharacters + 500)
        let dispatch = try #require(try? plan(
            output: "Xedit/Foo.swift:1:1: error: boom\n" + noise + "\nFINAL: 3 tests failed"
        ).get())
        #expect(dispatch.prompt.contains("FINAL: 3 tests failed"))
        #expect(dispatch.prompt.contains("earlier output trimmed"))
    }
}
