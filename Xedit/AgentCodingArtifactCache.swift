//
//  AgentCodingArtifactCache.swift
//  WillDeep
//
//  Short-lived cache for scout task packets. The key includes the complete
//  captured Git/worktree revision, so a plan is never reused after any
//  tracked, staged, untracked, branch, HEAD, or operation-state drift.
//

import Foundation

actor AgentCodingArtifactCache {
    static let shared = AgentCodingArtifactCache()

    private struct Entry {
        let plan: AgentCodingTaskPlan
        let storedAt: Date
    }

    private let timeToLive: TimeInterval = 30 * 60
    private let maximumEntries = 128
    private var entries: [String: Entry] = [:]

    func plan(
        requestText: String,
        revision: AgentWorkspaceRevision,
        now: Date = Date()
    ) -> AgentCodingTaskPlan? {
        purgeExpired(now: now)
        return entries[Self.key(requestText: requestText, revision: revision)]?.plan
    }

    func store(
        _ plan: AgentCodingTaskPlan,
        requestText: String,
        revision: AgentWorkspaceRevision,
        now: Date = Date()
    ) {
        purgeExpired(now: now)
        if entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[Self.key(requestText: requestText, revision: revision)] = Entry(
            plan: plan,
            storedAt: now
        )
    }

    static func key(requestText: String, revision: AgentWorkspaceRevision) -> String {
        let fileState = revision.fileStates.keys.sorted().map {
            "\($0)=\(revision.fileStates[$0] ?? "")"
        }.joined(separator: "\n")
        return AgentWorkspaceRevisionCapture.sha256(
            [
                requestText.trimmingCharacters(in: .whitespacesAndNewlines),
                revision.repositoryRootPath,
                revision.repositoryCommonDirectoryPath,
                revision.headOID,
                revision.branchName,
                revision.stagedDigest,
                revision.operationDigest,
                fileState,
            ].joined(separator: "\n---\n")
        )
    }

    private func purgeExpired(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.storedAt) < timeToLive }
    }
}
