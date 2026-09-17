//
//  L10n+SessionHandoff.swift
//  WillDeep
//
//  `/handoff` and `/sessions` strings. Table: SessionHandoff.xcstrings.
//

import Foundation

extension L10n {
    enum SessionHandoff {
        static let commandSubtitle = String(localized: "session-handoff.command.subtitle", defaultValue: "Hand this session off to willdeep-cli on another machine via a git branch", table: "SessionHandoff")
        static let commandPlaceholder = String(localized: "session-handoff.command.placeholder", defaultValue: "optional instructions for the receiving side", table: "SessionHandoff")
        static let sessionsCommandSubtitle = String(localized: "session-handoff.sessions-command.subtitle", defaultValue: "See what the other sessions in this workspace are doing", table: "SessionHandoff")
        static let sessionsPrompt = String(localized: "session-handoff.sessions-command.prompt", defaultValue: "What are the other sessions in this workspace doing right now? List each one's current step and latest request, and point out any work that overlaps with this session.", table: "SessionHandoff")

        static let started = String(localized: "session-handoff.started", defaultValue: "Preparing the handoff: packaging this session and pushing a handoff branch…", table: "SessionHandoff")
        static let alreadyRunning = String(localized: "session-handoff.already-running", defaultValue: "A handoff for this session is already in progress.", table: "SessionHandoff")
        static let remoteWorkspace = String(localized: "session-handoff.remote-workspace", defaultValue: "Handoff needs a local workspace folder. This session runs in a remote workspace.", table: "SessionHandoff")
        static let noWorkspace = String(localized: "session-handoff.no-workspace", defaultValue: "Handoff needs a workspace folder. Open a folder for this session first.", table: "SessionHandoff")
        static let notARepository = String(localized: "session-handoff.not-a-repository", defaultValue: "The workspace is not a git repository. Handoff carries the code through a git branch.", table: "SessionHandoff")
        static let noCommits = String(localized: "session-handoff.no-commits", defaultValue: "The repository has no commits yet. Make a first commit, then hand off.", table: "SessionHandoff")
        static let noRemote = String(localized: "session-handoff.no-remote", defaultValue: "The repository has no git remote. Add one that the receiving machine can also reach.", table: "SessionHandoff")

        static func sensitiveFiles(_ paths: String) -> String {
            String(format: String(localized: "session-handoff.sensitive-files", defaultValue: "Handoff stopped: these untracked files look like secrets and would be pushed: %@. Add them to .gitignore or remove them, then try again.", table: "SessionHandoff"), paths)
        }

        static func gitFailed(step: String, detail: String) -> String {
            String(format: String(localized: "session-handoff.git-failed", defaultValue: "Handoff failed at git %@: %@", table: "SessionHandoff"), step, detail)
        }

        static func pushFailed(_ detail: String) -> String {
            String(format: String(localized: "session-handoff.push-failed", defaultValue: "Could not push the handoff branch. Check that this Mac has git credentials for the remote (for example `gh auth login`). Details: %@", table: "SessionHandoff"), detail)
        }

        static func failed(_ reason: String) -> String {
            String(format: String(localized: "session-handoff.failed", defaultValue: "Handoff failed. %@", table: "SessionHandoff"), reason)
        }

        /// branch, remote, uncommitted note, script
        static func succeeded(branch: String, remote: String, uncommittedNote: String, script: String) -> String {
            String(format: String(localized: "session-handoff.succeeded", defaultValue: "Handed off to branch `%1$@` on %2$@.%3$@ Nothing on this Mac changed: same branch, same working tree.\n\nOn the receiving machine, run this inside its clone of the repository (it needs git credentials for the remote and willdeep-cli installed). The command was also copied to the clipboard:\n\n```bash\n%4$@\n```", table: "SessionHandoff"), branch, remote, uncommittedNote, script)
        }

        static let uncommittedIncluded = String(localized: "session-handoff.uncommitted-included", defaultValue: " Uncommitted changes are included.", table: "SessionHandoff")
    }
}
