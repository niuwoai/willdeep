import Foundation

nonisolated extension L10n {
    enum CloseTab {
        static let unsavedTitle = String(localized: "close-tab.unsaved-title", defaultValue: "Unsaved Changes")
        static func unsavedMessage(_ a1: String) -> String {
            let template = String(localized: "close-tab.unsaved-message", defaultValue: "Do you want to save the changes made to \"%@\"?")
            return String(format: template, a1)
        }
        static let save = String(localized: "close-tab.save", defaultValue: "Save")
        static let discard = String(localized: "close-tab.discard", defaultValue: "Discard")
        static let cancel = String(localized: "close-tab.cancel", defaultValue: "Cancel")
        static let saveFailedTitle = String(localized: "close-tab.save-failed-title", defaultValue: "Save Failed")
        static func saveFailedMessage(_ a1: String, _ a2: String) -> String {
            let template = String(localized: "close-tab.save-failed-message", defaultValue: "Could not save \"%1$@\": %2$@")
            return String(format: template, a1, a2)
        }
        static let ok = String(localized: "close-tab.ok", defaultValue: "OK")
    }

    enum ContextCompression {
        static let compress = String(localized: "context-compression.compress", defaultValue: "Compress")
        static let compressing = String(localized: "context-compression.compressing", defaultValue: "Compressing…")
        static let compressHelp = String(localized: "context-compression.compress-help", defaultValue: "Summarize older messages to free context budget")
    }

    enum AgentWorktreeSummary {
        static func filesChanged(_ n: Int) -> String {
            String(format: String(localized: "agent-worktree-summary.files-changed", defaultValue: "%d files changed"), n)
        }
        static let review = String(localized: "agent-worktree-summary.review", defaultValue: "Review")
        static let preparingReview = String(localized: "agent-worktree-summary.preparing-review", defaultValue: "Preparing…")
        static let reviewHelp = String(localized: "agent-worktree-summary.review-help", defaultValue: "View the current uncommitted diff")
        static func moreFiles(_ n: Int) -> String {
            String(format: String(localized: "agent-worktree-summary.more-files", defaultValue: "%d more files"), n)
        }
    }

    enum AgentWorkspaceCollision {
        static func warning(_ n: Int) -> String {
            String(
                format: String(
                    localized: "agent-workspace-collision.warning",
                    defaultValue: "Another %d session(s) are working in this same folder — edits may overwrite each other."
                ),
                n
            )
        }
        static let isolate = String(
            localized: "agent-workspace-collision.isolate",
            defaultValue: "Isolate in worktree"
        )
        static let isolateHelp = String(
            localized: "agent-workspace-collision.isolate.help",
            defaultValue: "Create a separate Git worktree and move this conversation there so it no longer shares the checkout"
        )
    }

    enum AgentWorkspaceGoalAwareness {
        static let open = String(
            localized: "agent-workspace-goal-awareness.open",
            defaultValue: "Open"
        )

        static func summary(
            _ title: String,
            _ completed: Int,
            _ total: Int,
            _ isRunning: Bool,
            _ isDispatchProject: Bool
        ) -> String {
            switch (isDispatchProject, isRunning) {
            case (true, true):
                return String(
                    format: String(
                        localized: "agent-workspace-goal-awareness.dispatch-running",
                        defaultValue: "Dispatch project “%@” is already running in this workspace · %lld/%lld"
                    ),
                    title,
                    completed,
                    total
                )
            case (true, false):
                return String(
                    format: String(
                        localized: "agent-workspace-goal-awareness.dispatch-unfinished",
                        defaultValue: "This workspace already has dispatch project “%@” · %lld/%lld"
                    ),
                    title,
                    completed,
                    total
                )
            case (false, true):
                return String(
                    format: String(
                        localized: "agent-workspace-goal-awareness.goal-running",
                        defaultValue: "Goal “%@” is already running in this workspace · %lld/%lld"
                    ),
                    title,
                    completed,
                    total
                )
            case (false, false):
                return String(
                    format: String(
                        localized: "agent-workspace-goal-awareness.goal-unfinished",
                        defaultValue: "This workspace already has unfinished Goal “%@” · %lld/%lld"
                    ),
                    title,
                    completed,
                    total
                )
            }
        }
    }
}
