//
//  AgentGitCommitAttribution.swift
//  WillDeep
//
//  Splitting a worktree review into "this session wrote it" and "this was
//  already here".
//
//  The Git Review panel lists the whole worktree, and its commit button ran
//  `git add -A -- .`. That is self-consistent — it commits what it shows — but
//  it means a change the user made by hand, or another session made, gets
//  swept into the Agent's commit with no mention of it anywhere. The Agent
//  already keeps a write set (`AgentRuntime.agentEditedPaths`); nothing on the
//  commit path consulted it.
//
//  Attribution here is path-level, which is all the write set can support. A
//  file both the Agent and the user edited reads as attributed, so this
//  narrows what gets committed without claiming to prove authorship. The
//  honest framing in the UI is "not from this session" for the rest, not "not
//  touched by the Agent".
//

import Foundation

nonisolated struct AgentGitCommitAttribution: Equatable {
    /// Paths the session's write set claims.
    let attributed: [String]
    /// Paths present in the worktree that the write set does not claim.
    let unattributed: [String]

    var hasUnattributed: Bool { !unattributed.isEmpty }
    var isEmpty: Bool { attributed.isEmpty && unattributed.isEmpty }

    /// Split a review snapshot's file list against a write set.
    ///
    /// An empty write set yields no attribution at all rather than declaring
    /// every change unattributed: a session that has not written anything yet
    /// (or one restored without its write set) knows nothing about these
    /// files, and "I did not write any of this" is a claim it cannot make.
    /// `nil` means the same thing for a caller with no runtime at hand.
    nonisolated static func split(
        changePaths: [String],
        editedPaths: Set<String>?
    ) -> AgentGitCommitAttribution? {
        guard let editedPaths, !editedPaths.isEmpty else { return nil }
        let claimed = Set(editedPaths.map(normalize))
        var attributed: [String] = []
        var unattributed: [String] = []
        for path in changePaths {
            let key = normalize(path)
            guard !key.isEmpty else { continue }
            if claimed.contains(key) {
                attributed.append(path)
            } else {
                unattributed.append(path)
            }
        }
        return AgentGitCommitAttribution(attributed: attributed, unattributed: unattributed)
    }

    /// Git reports paths relative to the repository root; the write set is
    /// filled from patch application, which has used a leading `./` in the
    /// past. Compare on a single shape so one stray prefix does not read as a
    /// different file and quietly drop it out of the commit.
    private nonisolated static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }
}
