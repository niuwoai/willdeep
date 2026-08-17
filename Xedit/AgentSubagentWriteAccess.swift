//
//  AgentSubagentWriteAccess.swift
//  WillDeep
//
//  The writing trades' door: one declared file set, one holder at a time.
//
//  Most subagents are read-only by construction. A few built-in coding
//  trades receive a bounded workspace capability, guarded on three sides:
//
//   1. Workspace policy — Smart / Workspace Access inherit the parent's
//      workspace write grant; Strict still shows the whole set on one card.
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
/// declared at spawn time, because a real test fix usually moves the
/// implementation and its test together and a one-file door would force the
/// trade to report "cannot finish" on the common case. The guarantees are the
/// same either way: the parent declared every path in the set, and anything
/// outside it is denied on the execution path.
nonisolated struct AgentSubagentWriteAccess: Sendable, Equatable {
    static let maxTargetCount = 16

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
        guard !normalized.isEmpty, normalized.count <= Self.maxTargetCount else { return nil }
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

    private enum DiffHeaderPath: Equatable {
        case path(String)
        case devNull
        case invalid
    }

    private struct DiffOperation: Equatable {
        let old: DiffHeaderPath
        let new: DiffHeaderPath
    }

    private static func diffHeaderPath(_ line: String) -> DiffHeaderPath {
        var payload = String(line.dropFirst(4))
        if let tabIndex = payload.firstIndex(of: "\t") {
            payload = String(payload[..<tabIndex])
        }
        payload = payload.trimmingCharacters(in: .whitespaces)
        if payload == "/dev/null" { return .devNull }
        if payload.hasPrefix("a/") || payload.hasPrefix("b/") {
            payload = String(payload.dropFirst(2))
        }
        guard let normalized = normalizedTargetPath(payload) else { return .invalid }
        return .path(normalized)
    }

    /// Parse old/new header pairs rather than flattening paths: `/dev/null`
    /// on the old side means creation and is allowed for a declared target;
    /// on the new side it means deletion and remains forbidden.
    private static func patchOperations(inDiff diff: String) -> [DiffOperation]? {
        var previousOldPath: DiffHeaderPath?
        var operations: [DiffOperation] = []
        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("--- ") {
                guard previousOldPath == nil else { return nil }
                previousOldPath = diffHeaderPath(line)
            } else if line.hasPrefix("+++ ") {
                guard let old = previousOldPath else { return nil }
                operations.append(DiffOperation(old: old, new: diffHeaderPath(line)))
                previousOldPath = nil
            }
        }
        guard previousOldPath == nil, !operations.isEmpty else { return nil }
        return operations
    }

    /// Nil when the call may proceed; otherwise the denial text handed back
    /// to the child model as its tool result.
    func violationMessage(
        forToolName toolName: String,
        argumentsJSON: String,
        workspaceURL: URL?
    ) -> String? {
        if toolName == "create_file" {
            guard case .object(let arguments) = AgentJSONValue.decode(from: argumentsJSON),
                  let rawPath = arguments["path"]?.stringValue(),
                  let path = Self.normalizedTargetPath(rawPath) else {
                return "Denied: create_file needs one valid workspace-relative `path` from \(displayList)."
            }
            return allows(path)
                ? nil
                : "Denied: you may only create or edit \(displayList), but this call targets `\(path)`."
        }

        guard toolName == "apply_patch" else {
            return "Denied: `\(toolName)` is not an approved write tool for this subagent."
        }
        guard case .object(let arguments) = AgentJSONValue.decode(from: argumentsJSON),
              let diff = arguments["diff"]?.stringValue(),
              !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Denied: the patch had no readable `diff` argument. Re-emit the call with a unified diff for one of: \(displayList)."
        }

        guard let operations = Self.patchOperations(inDiff: diff) else {
            return "Denied: no `--- a/… / +++ b/…` header found in the diff. Emit a standard unified diff for one of: \(displayList)."
        }
        for operation in operations {
            let path: String
            switch (operation.old, operation.new) {
            case (.devNull, .path(let created)):
                path = created
            case (.path, .devNull):
                return "Denied: writing subagents may create or edit declared paths but cannot delete files."
            case (.path(let old), .path(let new)) where old == new:
                path = new
            case (.path(let old), .path(let new)):
                return "Denied: renaming `\(old)` to `\(new)` is outside the bounded write contract."
            case (.invalid, _), (_, .invalid), (.devNull, .devNull):
                return "Denied: the diff contains an invalid or unusable file header."
            }
            guard allows(path) else {
                return "Denied: you may only create or edit \(displayList), but this patch touches `\(path)`. Report the change needed elsewhere in your final message instead of patching it."
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
