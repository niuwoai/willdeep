//
//  AgentSubagentWriteAccess.swift
//  WillDeep
//
//  The editor trade's write door: one approved file, one holder at a time.
//
//  Subagents are read-only by construction, and a lot rests on that: they
//  have no approval UI, cancelling one has no side effects, and three of
//  them can run in parallel without coordinating. The editor trade opens
//  exactly one hole in that, so the hole is guarded on three sides:
//
//   1. Approval — the `spawn_agent` call itself is write-tier and goes
//      through the parent's approval card. The user approves "let a
//      subagent edit <file>", not each individual patch: one file is a
//      claim a person can actually evaluate.
//   2. Path — every patch is parsed and rejected unless every path it
//      touches is the approved file. Enforced on the execution path, not
//      by asking the prompt nicely.
//   3. Lock — one editor per file per parent session, so two children
//      cannot interleave patches on the same file.
//

import Foundation

/// A granted, path-scoped write capability handed to one writing subagent.
///
/// The editor trade holds a set of one; the fixer trades hold the set the user
/// approved at spawn time, because a real test fix usually moves the
/// implementation and its test together and a one-file door would force the
/// trade to report "cannot finish" on the common case. The guarantees are the
/// same either way: the user saw every path in the set before approving, and
/// anything outside it is denied on the execution path.
nonisolated struct AgentSubagentWriteAccess: Sendable, Equatable {
    /// Workspace-relative, normalized, de-duplicated and sorted so the
    /// approval card, the prompt and the lock all name the same list in the
    /// same order.
    let targetRelativePaths: [String]

    init?(targetRelativePaths: [String]) {
        var seen = Set<String>()
        var normalized: [String] = []
        for raw in targetRelativePaths {
            guard let path = Self.normalizedTargetPath(raw) else { return nil }
            if seen.insert(path).inserted { normalized.append(path) }
        }
        guard !normalized.isEmpty else { return nil }
        self.targetRelativePaths = normalized.sorted()
    }

    /// Single-file convenience for the editor trade and its tests. The path is
    /// assumed already normalized by the caller.
    init(targetRelativePath: String) {
        self.targetRelativePaths = [targetRelativePath]
    }

    /// Backtick-quoted list for prompts and denial messages.
    var displayList: String {
        targetRelativePaths.map { "`\($0)`" }.joined(separator: ", ")
    }

    func allows(_ path: String) -> Bool {
        targetRelativePaths.contains(path)
    }

    /// Normalizes a user/model-supplied target path, rejecting anything that
    /// could escape the workspace. Returns nil when the path is unusable.
    static func normalizedTargetPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // Absolute paths and traversal are refused outright rather than
        // resolved: the approval card showed the user a relative path, and
        // resolution could quietly land somewhere else.
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    /// Paths a unified diff touches, normalized. `/dev/null` (file creation
    /// or deletion) is reported as nil so callers can refuse it — the editor
    /// trade edits an existing, named file and nothing else.
    static func patchedPaths(inDiff diff: String) -> [String?] {
        diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String?? in
                let text = String(line)
                guard text.hasPrefix("--- ") || text.hasPrefix("+++ ") else { return nil }
                var payload = String(text.dropFirst(4))
                // Strip a trailing timestamp column if the model emitted one.
                if let tabIndex = payload.firstIndex(of: "\t") {
                    payload = String(payload[..<tabIndex])
                }
                payload = payload.trimmingCharacters(in: .whitespaces)
                if payload == "/dev/null" { return .some(nil) }
                if payload.hasPrefix("a/") || payload.hasPrefix("b/") {
                    payload = String(payload.dropFirst(2))
                }
                return .some(normalizedTargetPath(payload))
            }
    }

    /// Nil when the call may proceed; otherwise the denial text handed back
    /// to the child model as its tool result.
    func violationMessage(forArgumentsJSON argumentsJSON: String, workspaceURL: URL?) -> String? {
        guard case .object(let arguments) = AgentJSONValue.decode(from: argumentsJSON),
              let diff = arguments["diff"]?.stringValue(),
              !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Denied: the patch had no readable `diff` argument. Re-emit the call with a unified diff for one of: \(displayList)."
        }

        let paths = Self.patchedPaths(inDiff: diff)
        guard !paths.isEmpty else {
            return "Denied: no `--- a/… / +++ b/…` header found in the diff. Emit a standard unified diff for one of: \(displayList)."
        }
        for path in paths {
            guard let path else {
                return "Denied: this trade edits existing files and cannot create or delete them. Patch one of \(displayList) in place, or report what should be created instead."
            }
            guard allows(path) else {
                // The denial names the escape route on purpose: the trade is
                // supposed to report out-of-scope work, not quietly give up.
                return "Denied: you may only edit \(displayList), but this patch touches `\(path)`. Report the change needed elsewhere in your final message instead of patching it."
            }
        }
        return nil
    }
}

/// Per-file exclusion for editor subagents, scoped to a parent session.
///
/// Two children patching one file would interleave hunks against a moving
/// base — the same class of collision the repo already sees from concurrent
/// sessions, but faster and invisible.
@MainActor
final class AgentSubagentEditorLock {
    static let shared = AgentSubagentEditorLock()

    private struct Key: Hashable {
        let parentRuntimeID: UUID
        let path: String
    }

    private var holders: [Key: UUID] = [:]

    /// Claims `path` for `runID`. Returns false when another live editor
    /// already holds it.
    func acquire(path: String, parentRuntimeID: UUID, runID: UUID) -> Bool {
        acquire(paths: [path], parentRuntimeID: parentRuntimeID, runID: runID)
    }

    /// Claims every path in the set for `runID`, all or nothing. A partial
    /// claim would let two children each hold half of an overlapping set and
    /// then deadlock or interleave — so a single conflict rejects the whole
    /// acquisition and leaves the existing holder untouched.
    func acquire(paths: [String], parentRuntimeID: UUID, runID: UUID) -> Bool {
        let keys = paths.map { Key(parentRuntimeID: parentRuntimeID, path: $0) }
        for key in keys {
            if let existing = holders[key], existing != runID { return false }
        }
        for key in keys { holders[key] = runID }
        return true
    }

    /// Paths in `paths` already held by a different run, for telling the
    /// caller exactly which file it is waiting on.
    func conflictingPaths(_ paths: [String], parentRuntimeID: UUID, runID: UUID) -> [String] {
        paths.filter { path in
            guard let existing = holders[Key(parentRuntimeID: parentRuntimeID, path: path)] else {
                return false
            }
            return existing != runID
        }
    }

    /// Releases every claim held by `runID`. Safe to call more than once —
    /// completion, cancellation and failure all funnel here.
    func release(runID: UUID) {
        holders = holders.filter { $0.value != runID }
    }

    func isLocked(path: String, parentRuntimeID: UUID) -> Bool {
        holders[Key(parentRuntimeID: parentRuntimeID, path: path)] != nil
    }
}
