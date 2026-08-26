//
//  AgentReadOnlyWorkerHandoffHint.swift
//  WillDeep
//
//  The deterministic entry point for the read-only trades.
//
//  `AgentWorkerAutoDispatch` gave `test_fixer` and `build_fixer` a real
//  trigger: a command that exits non-zero. The read-only trades —
//  `git_detective`, `log_inspector`, `scout`, `reader` — got nothing, and
//  measured over every session on this machine they were spawned zero times.
//  Nothing was broken; there was simply no moment at which the loop said
//  "this is theirs".
//
//  Truncation is that moment. A tool payload over the cap is cut off, and the
//  parent is then reasoning about a document it has only seen the front of —
//  the one situation where handing the whole thing to a worker with its own
//  window is strictly better than continuing. It is also an honest signal:
//  the loop knows exactly how much it dropped, so the hint can say so.
//
//  A hint, not a dispatch. The read-only trades report rather than change
//  anything, so the cost of a wrong call is a wasted worker run, not an
//  unreviewed edit — but the parent may also have already seen enough in the
//  first 24k to answer, and only it knows that.
//

import Foundation

nonisolated enum AgentReadOnlyWorkerHandoffHint {
    /// Below this there is no point naming a worker: a tail the parent can
    /// re-read with a narrower command costs less than a spawn.
    static let minimumOmittedCharacters = 4_000

    /// Pick the trade whose brief matches what produced the oversized payload.
    ///
    /// Returns nil for tools whose output is not a document to be read
    /// (`apply_patch`, `ask_user`), and for anything unrecognised — a hint
    /// naming the wrong trade is worse than none, because the worker then
    /// arrives with a job prompt aimed at the wrong kind of material.
    static func trade(toolName: String, command: String?) -> String? {
        switch toolName {
        case "read_file", "read_files":
            return AgentSubagentProfileCatalog.readerID
        case "grep_files", "search_files", "list_directory":
            return AgentSubagentProfileCatalog.scoutID
        case "run_command":
            guard let command = command?.lowercased() else { return nil }
            let head = command.split(separator: "|").first.map(String.init) ?? command
            if gitHistoryMarkers.contains(where: { head.contains($0) }) {
                return AgentSubagentProfileCatalog.gitDetectiveID
            }
            if logMarkers.contains(where: { head.contains($0) }) {
                return AgentSubagentProfileCatalog.logInspectorID
            }
            return nil
        default:
            return nil
        }
    }

    /// The note appended to a truncated payload, or nil when this truncation
    /// is not worth a worker.
    static func hint(
        toolName: String,
        command: String?,
        omittedCharacters: Int,
        alreadyHintedThisTurn: Bool
    ) -> String? {
        // Once per turn. The cap is hit repeatedly while grepping a large
        // tree, and repeating the same paragraph after every result trains
        // the model to skip it.
        guard !alreadyHintedThisTurn else { return nil }
        guard omittedCharacters >= minimumOmittedCharacters else { return nil }
        guard let tradeID = trade(toolName: toolName, command: command) else { return nil }
        return """


        (WillDeep: \(omittedCharacters) more characters were cut from this result — you are looking \
        at the front of it, not the whole thing. If the answer you need might be in the part you \
        cannot see, spawn `profile="\(tradeID)"` with a `task.goal` naming exactly what to extract \
        and the same target in `task.read_files` or the same command; the worker reads all of it in \
        its own window and reports back the part that matters, without spending yours. Continue here \
        instead when what you have already read answers the question.)
        """
    }

    /// Commands whose oversized output is repository history.
    private static let gitHistoryMarkers: [String] = [
        "git log", "git blame", "git show", "git diff", "git whatchanged",
        "git shortlog", "git reflog", "git bisect",
    ]

    /// Commands whose oversized output is a log or a diagnostic dump.
    private static let logMarkers: [String] = [
        ".log", "journalctl", "dmesg", "/usr/bin/log show", "log show",
        "docker logs", "kubectl logs", "tail -f", "xcrun simctl spawn",
    ]
}
