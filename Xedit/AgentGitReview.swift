//
//  AgentGitReview.swift
//  WillDeep
//
//  Git review scopes and commit plumbing shared by the Agent review panel.
//  All process work stays off the main actor; the SwiftUI surface only owns
//  presentation and confirmation state.
//

import Foundation

nonisolated enum AgentGitReviewScope: String, CaseIterable, Identifiable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case lastCommit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommitted: return L10n.AgentGitReview.uncommitted
        case .unstaged: return L10n.AgentGitReview.unstaged
        case .staged: return L10n.AgentGitReview.staged
        case .lastCommit: return L10n.AgentGitReview.lastCommit
        }
    }
}

struct AgentGitReviewSnapshot {
    let repositoryRoot: URL
    let branchName: String
    let scope: AgentGitReviewScope
    let changes: AgentWorktreeChangeSummary
    let overviewDiff: String
    let loadedAt: Date
}

enum AgentGitReviewDetail: Equatable {
    case text(String)
    case unavailable(String)
}

enum AgentGitReviewLoader {
    nonisolated static func load(
        workspaceRoot: URL,
        scope: AgentGitReviewScope
    ) -> AgentGitReviewSnapshot? {
        let status = AppState.loadGitStatus(for: workspaceRoot)
        guard status.isRepository, let repositoryRoot = status.repositoryRoot else {
            return nil
        }

        let changes = loadChanges(
            scope: scope,
            status: status,
            repositoryRoot: repositoryRoot
        )
        let overviewDiff = loadOverviewDiff(
            scope: scope,
            changes: changes,
            repositoryRoot: repositoryRoot
        )
        return AgentGitReviewSnapshot(
            repositoryRoot: repositoryRoot,
            branchName: status.branchName ?? L10n.AgentGitReview.detached,
            scope: scope,
            changes: changes,
            overviewDiff: overviewDiff,
            loadedAt: Date()
        )
    }

    nonisolated static func loadDetail(
        scope: AgentGitReviewScope,
        change: AgentFileChangeSummary,
        repositoryRoot: URL
    ) -> AgentGitReviewDetail {
        if change.kind == .untracked {
            switch AppState.loadUntrackedDiffPreviewSection(
                change,
                repositoryRoot: repositoryRoot
            ) {
            case .diff(let diff):
                return .text(diff)
            case .summaryReason(let reason):
                return .unavailable(reason)
            }
        }

        let fileURL = repositoryRoot
            .appendingPathComponent(change.path)
            .standardizedFileURL
        if change.kind != .deleted,
           let fileSize = AppState.fileSize(at: fileURL),
           let reason = AgentSidePanelDiffLimiter.fileUnavailableReason(byteCount: fileSize) {
            return .unavailable(reason)
        }

        let rawDiff = AppState.runGit(
            arguments: detailArguments(scope: scope, path: change.path),
            in: repositoryRoot
        )
        guard !rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(L10n.AgentSidePanel.diffFileUnavailable)
        }
        if let reason = AgentSidePanelDiffLimiter.unavailableReason(for: rawDiff) {
            return .unavailable(reason)
        }
        return .text(rawDiff)
    }

    nonisolated static func parseNameStatus(_ output: String) -> [String: GitFileStatusKind] {
        var result: [String: GitFileStatusKind] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let token = fields[0]
            let rawPath = token.hasPrefix("R") && fields.count >= 3 ? fields[2] : fields[1]
            let path = AppState.unquoteGitPath(rawPath)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }
            result[path] = kind(for: token)
        }
        return result
    }

    nonisolated static func detailArguments(
        scope: AgentGitReviewScope,
        path: String
    ) -> [String] {
        switch scope {
        case .uncommitted:
            return ["diff", "--no-ext-diff", "HEAD", "--", path]
        case .unstaged:
            return ["diff", "--no-ext-diff", "--", path]
        case .staged:
            return ["diff", "--cached", "--no-ext-diff", "--", path]
        case .lastCommit:
            return ["show", "--format=", "--no-ext-diff", "HEAD", "--", path]
        }
    }

    private nonisolated static func loadChanges(
        scope: AgentGitReviewScope,
        status: GitRepositoryStatus,
        repositoryRoot: URL
    ) -> AgentWorktreeChangeSummary {
        if scope == .uncommitted {
            return AppState.loadAgentWorktreeChangeSummary(status: status)
        }

        let numstat = AppState.parseGitNumstat(
            AppState.runGit(
                arguments: numstatArguments(scope: scope),
                in: repositoryRoot
            )
        )
        var kinds = parseNameStatus(
            AppState.runGit(
                arguments: nameStatusArguments(scope: scope),
                in: repositoryRoot
            )
        )
        if scope == .unstaged {
            for (path, kind) in status.entries where kind == .untracked {
                kinds[path] = .untracked
            }
        }

        let paths = Set(kinds.keys).union(numstat.keys)
        let files = paths.map { path in
            let kind = kinds[path] ?? .modified
            let lineStats = numstat[path]
                ?? (kind == .untracked
                    ? AppState.untrackedTextLineStats(
                        path: path,
                        repositoryRoot: repositoryRoot
                    )
                    : nil)
                ?? AgentLineChangeStats(added: nil, deleted: nil)
            return AgentFileChangeSummary(
                path: path,
                kind: kind,
                lineStats: lineStats
            )
        }
        return AgentWorktreeChangeSummary(repositoryRoot: repositoryRoot, files: files)
    }

    private nonisolated static func loadOverviewDiff(
        scope: AgentGitReviewScope,
        changes: AgentWorktreeChangeSummary,
        repositoryRoot: URL
    ) -> String {
        guard !changes.isEmpty else { return "" }
        if scope == .uncommitted {
            return AppState.loadAgentWorktreeDiffPreview(
                changes: changes,
                repositoryRoot: repositoryRoot
            ).diff
        }

        var sections: [String] = []
        let tracked = AppState.runGit(
            arguments: overviewArguments(scope: scope),
            in: repositoryRoot
        )
        if !tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(tracked)
        }
        if scope == .unstaged {
            for change in changes.files where change.kind == .untracked {
                if case .diff(let diff) = AppState.loadUntrackedDiffPreviewSection(
                    change,
                    repositoryRoot: repositoryRoot
                ) {
                    sections.append(diff)
                }
            }
        }

        let diff = sections.joined(separator: "\n")
        guard diff.utf8.count <= AppState.worktreeDiffPreviewMaxUTF8Bytes else {
            return AppState.worktreeDiffPreviewSummaryText(
                changes: changes,
                reasons: [L10n.AgentGitReview.overviewTooLarge]
            )
        }
        return diff
    }

    private nonisolated static func numstatArguments(scope: AgentGitReviewScope) -> [String] {
        switch scope {
        case .uncommitted:
            return ["diff", "--numstat", "--no-renames", "HEAD", "--"]
        case .unstaged:
            return ["diff", "--numstat", "--no-renames", "--"]
        case .staged:
            return ["diff", "--cached", "--numstat", "--no-renames", "--"]
        case .lastCommit:
            return ["show", "--format=", "--numstat", "--no-renames", "HEAD", "--"]
        }
    }

    private nonisolated static func nameStatusArguments(scope: AgentGitReviewScope) -> [String] {
        switch scope {
        case .uncommitted:
            return ["diff", "--name-status", "--no-renames", "HEAD", "--"]
        case .unstaged:
            return ["diff", "--name-status", "--no-renames", "--"]
        case .staged:
            return ["diff", "--cached", "--name-status", "--no-renames", "--"]
        case .lastCommit:
            return ["show", "--format=", "--name-status", "--no-renames", "HEAD", "--"]
        }
    }

    private nonisolated static func overviewArguments(scope: AgentGitReviewScope) -> [String] {
        switch scope {
        case .uncommitted:
            return ["diff", "--no-ext-diff", "HEAD", "--"]
        case .unstaged:
            return ["diff", "--no-ext-diff", "--"]
        case .staged:
            return ["diff", "--cached", "--no-ext-diff", "--"]
        case .lastCommit:
            return ["show", "--format=", "--no-ext-diff", "HEAD", "--"]
        }
    }

    private nonisolated static func kind(for token: String) -> GitFileStatusKind {
        if token.hasPrefix("A") { return .added }
        if token.hasPrefix("D") { return .deleted }
        if token.hasPrefix("R") { return .renamed }
        return .modified
    }
}

struct AgentGitCommitOutcome: Equatable {
    let commitCreated: Bool
    let pushed: Bool
    let message: String
}

enum AgentGitCommitService {
    nonisolated static let commandTimeout: TimeInterval = 120

    nonisolated static func commit(
        repositoryRoot: URL,
        message: String,
        includeUnstaged: Bool,
        pushAfterCommit: Bool
    ) -> AgentGitCommitOutcome {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return AgentGitCommitOutcome(
                commitCreated: false,
                pushed: false,
                message: L10n.AgentGitReview.commitMessageRequired
            )
        }

        if includeUnstaged {
            let stage = AppState.runGitCommand(
                arguments: ["add", "-A", "--", "."],
                in: repositoryRoot,
                timeout: commandTimeout
            )
            guard stage.succeeded else {
                return AgentGitCommitOutcome(
                    commitCreated: false,
                    pushed: false,
                    message: stage.userMessage
                )
            }
        }

        let commit = AppState.runGitCommand(
            arguments: ["commit", "-m", trimmedMessage],
            in: repositoryRoot,
            timeout: commandTimeout
        )
        guard commit.succeeded else {
            return AgentGitCommitOutcome(
                commitCreated: false,
                pushed: false,
                message: commit.userMessage
            )
        }
        guard pushAfterCommit else {
            return AgentGitCommitOutcome(
                commitCreated: true,
                pushed: false,
                message: L10n.AgentGitReview.commitSucceeded
            )
        }

        let push = AppState.runGitCommand(
            arguments: ["push"],
            in: repositoryRoot,
            timeout: commandTimeout
        )
        if push.succeeded {
            return AgentGitCommitOutcome(
                commitCreated: true,
                pushed: true,
                message: L10n.AgentGitReview.commitAndPushSucceeded
            )
        }
        return AgentGitCommitOutcome(
            commitCreated: true,
            pushed: false,
            message: L10n.AgentGitReview.commitSucceededPushFailed(push.userMessage)
        )
    }
}
