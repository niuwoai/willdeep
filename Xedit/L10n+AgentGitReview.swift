import Foundation

// Kept outside the generated façade so L10n.swift remains below the
// repository's 3,000-line hard limit.
extension L10n {
    nonisolated enum AgentGitReview {
        static let uncommitted = String(localized: "agent-git-review.scope.uncommitted", defaultValue: "Uncommitted")
        static let unstaged = String(localized: "agent-git-review.scope.unstaged", defaultValue: "Unstaged")
        static let staged = String(localized: "agent-git-review.scope.staged", defaultValue: "Staged")
        static let lastCommit = String(localized: "agent-git-review.scope.last-commit", defaultValue: "Last commit")
        static let detached = String(localized: "agent-git-review.detached", defaultValue: "detached")
        static let jumpToFile = String(localized: "agent-git-review.jump-to-file", defaultValue: "Jump to file")
        static let showCombinedDiff = String(localized: "agent-git-review.show-combined-diff", defaultValue: "Show file review")
        static let showFileList = String(localized: "agent-git-review.show-file-list", defaultValue: "Show changed files")
        static let collapseAllFiles = String(localized: "agent-git-review.collapse-all-files", defaultValue: "Collapse all files")
        static let expandAllFiles = String(localized: "agent-git-review.expand-all-files", defaultValue: "Expand all files")
        static let openFileDiff = String(localized: "agent-git-review.open-file-diff", defaultValue: "Open file diff")
        static let unstagedEmpty = String(localized: "agent-git-review.empty.unstaged", defaultValue: "No unstaged changes.")
        static let stagedEmpty = String(localized: "agent-git-review.empty.staged", defaultValue: "No staged changes.")
        static let lastCommitEmpty = String(localized: "agent-git-review.empty.last-commit", defaultValue: "No commit is available to review.")
        static let overviewTooLarge = String(localized: "agent-git-review.overview-too-large", defaultValue: "The combined diff is above the review panel display budget.")
        static let commit = String(localized: "agent-git-review.commit", defaultValue: "Commit")
        static let commitAndPush = String(localized: "agent-git-review.commit-and-push", defaultValue: "Commit and Push")
        static let commitMessagePlaceholder = String(localized: "agent-git-review.commit-message-placeholder", defaultValue: "Commit message…")
        static let commitMessageRequired = String(localized: "agent-git-review.commit-message-required", defaultValue: "Enter a commit message.")
        static let includeUnstaged = String(localized: "agent-git-review.include-unstaged", defaultValue: "Include unstaged changes")
        static let commitSucceeded = String(localized: "agent-git-review.commit-succeeded", defaultValue: "Commit created.")
        static let commitAndPushSucceeded = String(localized: "agent-git-review.commit-and-push-succeeded", defaultValue: "Commit created and pushed.")

        static func unmodifiedLines(_ a1: String) -> String {
            let template = String(
                localized: "agent-git-review.unmodified-lines",
                defaultValue: "%@ unmodified lines"
            )
            return String(format: template, a1)
        }

        static func showMoreLines(_ a1: String) -> String {
            let template = String(
                localized: "agent-git-review.show-more-lines",
                defaultValue: "Show more (%@ lines remaining)"
            )
            return String(format: template, a1)
        }

        static func commitSucceededPushFailed(_ a1: String) -> String {
            let template = String(
                localized: "agent-git-review.commit-succeeded-push-failed",
                defaultValue: "Commit created, but push failed: %@"
            )
            return String(format: template, a1)
        }
    }
}
