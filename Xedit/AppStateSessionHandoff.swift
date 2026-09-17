//
//  AppStateSessionHandoff.swift
//  WillDeep
//
//  `/handoff` host side: gather the active session, run the git work off the
//  main actor, report back into the transcript. Package and git logic:
//  WillDeepCLIHandoff.swift.
//

import AppKit
import Foundation
import OSLog

private let sessionHandoffLog = Logger(subsystem: "com.willdeep.agent", category: "session-handoff")

@MainActor
enum SessionHandoffInFlight {
    static var sessionIDs: Set<AgentSession.ID> = []
}

extension AppState {
    func handoffActiveSessionToCLI(instructions: String) {
        guard let runtime = activeRuntime else { return }
        guard !SessionHandoffInFlight.sessionIDs.contains(runtime.id) else {
            appendSessionHandoffNotice(L10n.SessionHandoff.alreadyRunning, to: runtime)
            return
        }
        guard let location = runtime.workspaceLocation else {
            appendSessionHandoffNotice(L10n.SessionHandoff.noWorkspace, to: runtime)
            return
        }
        guard let workspacePath = location.localPath, !workspacePath.isEmpty else {
            appendSessionHandoffNotice(L10n.SessionHandoff.remoteWorkspace, to: runtime)
            return
        }

        let input = WillDeepCLIHandoff.SessionInput(
            title: runtime.session.title,
            messages: runtime.messages,
            plan: runtime.currentPlan,
            goal: runtime.currentGoal,
            editedPaths: runtime.session.agentEditedPaths
        )
        SessionHandoffInFlight.sessionIDs.insert(runtime.id)
        appendSessionHandoffNotice(L10n.SessionHandoff.started, to: runtime)
        let runtimeID = runtime.id
        let workspaceURL = URL(fileURLWithPath: workspacePath)

        Task.detached(priority: .userInitiated) {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-handoff-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let outcome: Swift.Result<WillDeepCLIHandoff.Result, Error>
            do {
                outcome = .success(try WillDeepCLIHandoff.perform(
                    session: input,
                    instructions: instructions,
                    temporaryDirectory: scratch
                ) { arguments, environment, timeout in
                    AppState.runGitCommand(
                        arguments: arguments,
                        in: workspaceURL,
                        allowedExitStatuses: [0, 1],
                        timeout: timeout,
                        extraEnvironment: environment
                    )
                })
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.finishSessionHandoff(runtimeID: runtimeID, outcome: outcome)
            }
        }
    }

    private func finishSessionHandoff(
        runtimeID: AgentSession.ID,
        outcome: Swift.Result<WillDeepCLIHandoff.Result, Error>
    ) {
        SessionHandoffInFlight.sessionIDs.remove(runtimeID)
        guard let runtime = runtime(for: runtimeID) else { return }
        switch outcome {
        case .success(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.resumeScript, forType: .string)
            sessionHandoffLog.info("handoff session=\(runtimeID.uuidString, privacy: .public) branch=\(result.branch, privacy: .public) commit=\(result.commit, privacy: .public)")
            appendSessionHandoffNotice(
                L10n.SessionHandoff.succeeded(
                    branch: result.branch,
                    remote: result.remoteName,
                    uncommittedNote: result.includedUncommittedChanges ? L10n.SessionHandoff.uncommittedIncluded : "",
                    script: result.resumeScript
                ),
                to: runtime
            )
        case .failure(let error):
            sessionHandoffLog.error("handoff session=\(runtimeID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            appendSessionHandoffNotice(L10n.SessionHandoff.failed(error.localizedDescription), to: runtime)
        }
    }

    private func appendSessionHandoffNotice(_ text: String, to runtime: AgentRuntime) {
        runtime.messages.append(AgentMessage(role: .system, content: text))
        persistAgentSession(runtime: runtime)
    }

    /// `/sessions`: ask the Agent to look at its peers. Goes through the
    /// ordinary send path so it queues behind a running turn.
    func askAgentAboutPeerSessions() {
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }
        runtime.input = L10n.SessionHandoff.sessionsPrompt
        sendAgentMessage()
    }
}
