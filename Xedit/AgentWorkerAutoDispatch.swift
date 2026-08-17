//
//  AgentWorkerAutoDispatch.swift
//  WillDeep
//
//  Turning a failing verification command into a worker run, without asking
//  the parent model's permission first.
//
//  `AgentWorkerDispatchHint` was the polite version of this: append a recipe
//  to the failure and hope the parent takes it. Measured over real sessions it
//  does not work — the hint fires, the parent reads it, and then fixes the
//  thing itself anyway, because it already has the file open and writing a
//  task packet feels like the long way round. The cheap tier only earns its
//  keep if work actually reaches it, so for the one case where the goal is
//  unambiguous — a test or build command that exited non-zero, with the
//  command itself available as the verifier — the loop stops suggesting and
//  dispatches.
//
//  Scope is deliberately narrow:
//
//  - Only `test_fixer` and `build_fixer`. A failing deploy also has a trade
//    (`ops_runner`), but its correct output is "retry and watch", and deciding
//    whether a release failure is transient is exactly the judgement that must
//    stay with the parent and the user.
//  - Only when the failure names files we can turn into a write set. A writing
//    worker with no declared paths cannot do anything, and guessing a wider
//    set than the failure justifies is how an auto-dispatch turns into an
//    unreviewed refactor.
//  - Once per command per turn. The worker re-runs the same command as its
//    verifier; if it comes back still failing, that is information for the
//    parent, not a reason to dispatch again.
//
//  Everything here is pure so the decision can be tested without a runtime:
//  the side-effecting half (approval card, editor lock, child loop) lives in
//  AppStateAgentWorkerAutoDispatch.swift.
//

import Foundation

nonisolated enum AgentWorkerAutoDispatch {
    /// Upper bound on the write set handed to the worker. Lower than
    /// `AgentSubagentWriteAccess.maxTargetCount` on purpose: a failure that
    /// implicates more than this many files is not the bounded repair this
    /// path is for, and shipping a 16-file auto-dispatch off a parsed build
    /// log is a bigger bet than the mechanism has earned.
    static let maxDerivedTargets = 8

    /// Source extensions worth treating as a repair target. Deliberately not
    /// "anything with a dot": a build log is full of `.o`, `.d`, `.json` and
    /// `.lock` paths that a fixer must not be handed.
    static let repairableExtensions: Set<String> = [
        "swift", "rs", "go", "ts", "tsx", "js", "jsx", "py", "rb", "java",
        "kt", "kts", "m", "mm", "c", "cc", "cpp", "h", "hpp", "cs", "php",
        "scala", "ex", "exs", "sh", "bash", "zsh",
    ]

    /// Why a failure was not auto-dispatched. Surfaced in the tool result so a
    /// silent non-dispatch is never indistinguishable from a broken feature.
    enum Refusal: Equatable, Error {
        case notACommandFailure
        case noExitCode
        case tradeNotAutoDispatchable(String)
        case delegationForbidden
        case alreadyDispatchedThisTurn
        case noDerivableWriteSet
        case disabledBySetting

        /// A short note for the tool result, or nil when the reason is not
        /// worth a line in front of the model (an ordinary non-matching
        /// failure is the common case and should stay quiet).
        var modelFacingNote: String? {
            switch self {
            case .notACommandFailure, .noExitCode, .tradeNotAutoDispatchable, .disabledBySetting:
                return nil
            case .delegationForbidden:
                return nil
            case .alreadyDispatchedThisTurn:
                return "(WillDeep: a worker already attempted this command in this turn and it still fails. Take it from here yourself — do not re-delegate the same command.)"
            case .noDerivableWriteSet:
                return "(WillDeep: this failure did not name any source file, so there was no write set to hand a worker. Diagnose it here, or spawn a worker yourself with an explicit `target_files`.)"
            }
        }
    }

    /// A dispatch the caller should perform.
    struct Plan: Equatable {
        /// `test_fixer` or `build_fixer`.
        let tradeID: String
        /// Workspace-relative paths the worker may edit, already normalized,
        /// de-duplicated, sorted and capped.
        let targetRelativePaths: [String]
        /// The command whose exit code ends the run.
        let verifierCommand: String
        /// Self-contained task text. The child sees none of the parent's
        /// conversation, so everything it needs is in here.
        let prompt: String
    }

    /// Decide whether a failed tool call should become a worker run.
    ///
    /// `existingWorkspacePaths` is the caller's answer to "does this path
    /// actually exist in the workspace" — passed in rather than hitting the
    /// filesystem here so the decision stays pure and testable.
    static func plan(
        toolName: String,
        command: String?,
        exitCode: Int32?,
        failureOutput: String,
        delegationPolicy: AgentDelegationPolicy,
        alreadyDispatchedCommands: Set<String>,
        isEnabled: Bool,
        existingWorkspacePaths: (String) -> Bool
    ) -> Result<Plan, Refusal> {
        guard isEnabled else { return .failure(.disabledBySetting) }
        guard toolName == "run_command" else { return .failure(.notACommandFailure) }
        // No exit code means the command never rendered a verdict — it failed
        // to launch, timed out, or was cancelled. There is nothing for a fixer
        // to repair in a machine problem.
        guard let exitCode, exitCode != 0 else { return .failure(.noExitCode) }
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return .failure(.notACommandFailure) }
        // `/no-subagent` is the user saying "do it yourself" for this turn.
        // An automatic spawn would be the one path that ignores them.
        guard delegationPolicy != .forbidden else { return .failure(.delegationForbidden) }
        guard !alreadyDispatchedCommands.contains(command) else {
            return .failure(.alreadyDispatchedThisTurn)
        }

        guard let kind = AgentWorkerDispatchHint.classify(command: command) else {
            return .failure(.notACommandFailure)
        }
        switch kind {
        case .testFixer, .buildFixer:
            break
        case .opsRunner:
            // A release failure's correct next step is a judgement call
            // (transient? roll back?) that belongs to the parent and the user.
            return .failure(.tradeNotAutoDispatchable(kind.tradeID))
        }

        let targets = deriveWriteSet(
            from: failureOutput,
            existingWorkspacePaths: existingWorkspacePaths
        )
        guard !targets.isEmpty else { return .failure(.noDerivableWriteSet) }

        return .success(Plan(
            tradeID: kind.tradeID,
            targetRelativePaths: targets,
            verifierCommand: command,
            prompt: prompt(
                kind: kind,
                command: command,
                targets: targets,
                failureOutput: failureOutput
            )
        ))
    }

    /// Pull candidate repair targets out of a compiler/test log.
    ///
    /// Only paths that survive `AgentSubagentWriteAccess` normalization *and*
    /// exist in the workspace are kept: a log mentions vendored sources,
    /// absolute toolchain paths and line/column noise, none of which a worker
    /// should be authorized to write.
    static func deriveWriteSet(
        from failureOutput: String,
        existingWorkspacePaths: (String) -> Bool
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for candidate in pathCandidates(in: failureOutput) {
            guard let normalized = AgentSubagentWriteAccess.normalizedTargetPath(candidate) else {
                continue
            }
            guard let ext = normalized.split(separator: ".").last.map(String.init)?.lowercased(),
                  repairableExtensions.contains(ext) else { continue }
            guard existingWorkspacePaths(normalized) else { continue }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
                if ordered.count == maxDerivedTargets { break }
            }
        }
        return ordered.sorted()
    }

    /// Path-shaped tokens, in the order the log mentions them.
    ///
    /// Kept as one scan over the text rather than a per-toolchain parser:
    /// Swift, Rust, Go, tsc, pytest and jest all put the path immediately
    /// before a `:line` or `(line,col)`, and the ones that do not (Python's
    /// `File "x.py", line 3`) still leave the path as a bare token.
    private static func pathCandidates(in output: String) -> [String] {
        var candidates: [String] = []
        let separators = CharacterSet(charactersIn: " \t\n\r\"'`()[]<>,;|")
        for rawToken in output.components(separatedBy: separators) {
            var token = rawToken
            // Trim a trailing `:12:5:` / `:12` locator and any punctuation.
            while let last = token.last, last == ":" || last == "." || last == "," {
                token.removeLast()
            }
            // `src/foo.ts(12,3)` already lost its parens to the separator set;
            // `src/foo.rs:10:5` still carries the locator.
            while let range = token.range(of: ":[0-9]+$", options: .regularExpression) {
                token.removeSubrange(range)
            }
            guard token.contains("/") || token.contains(".") else { continue }
            guard !token.isEmpty, token.count < 512 else { continue }
            candidates.append(token)
        }
        return candidates
    }

    /// The child's entire briefing. It cannot see the parent conversation, so
    /// the failing command, the log, and the boundary all travel with it.
    private static func prompt(
        kind: AgentWorkerDispatchHint.Kind,
        command: String,
        targets: [String],
        failureOutput: String
    ) -> String {
        let what = kind == .testFixer ? "failing test" : "build/lint failure"
        let list = targets.map { "`\($0)`" }.joined(separator: ", ")
        return """
        A verification command in this workspace is failing and you own fixing it.

        Failing command (this is also your verifier — it must exit 0 before you are done):
        \(command)

        Output from the failed run:
        \(clampedOutput(failureOutput))

        You may create or edit exactly these files: \(list). Anything outside that set is rejected.

        Fix the \(what) at its cause. Do not weaken a test to make it pass, do not delete
        assertions, and do not disable a lint rule to silence it — if the honest fix is outside
        your file set, stop and report that instead. Your report is the return value: say what
        you changed and what the verifier did.
        """
    }

    /// The log is the worker's main evidence, but it is also the one part of
    /// this prompt with no upper bound.
    static let maxOutputCharacters = 6_000

    private static func clampedOutput(_ output: String) -> String {
        guard output.count > maxOutputCharacters else { return output }
        // Keep the tail: compilers put the summary and the last error there,
        // and a truncated head loses the count of what actually failed.
        let tail = output.suffix(maxOutputCharacters)
        return "…(earlier output trimmed)\n\(tail)"
    }
}
