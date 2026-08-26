//
//  AgentWorkerRouteGuard.swift
//  WillDeep
//
//  Host enforcement for high-confidence mixed-model routes. A prompt can ask
//  the parent to delegate; only a tool boundary can ensure it actually does.
//

import Foundation

nonisolated enum AgentWorkerRouteGuard {
    private static let directFileWriteTools: Set<String> = [
        "create_file", "write_file", "edit_file", "apply_patch",
    ]

    /// Both command transports can mutate production state. The visible
    /// terminal used to escape the mixed-model route because only
    /// `run_command` crossed this guard.
    private static let directCommandTools: Set<String> = [
        "run_command", "terminal_send_command",
    ]

    static func refusal(
        toolName: String,
        risk: AgentToolRisk,
        decision: AgentRequestRouter.Decision?,
        delegationPolicy: AgentDelegationPolicy,
        attemptedProfiles: Set<String>
    ) -> String? {
        guard delegationPolicy != .forbidden,
              let decision,
              decision.requiresDelegatedExecution,
              let profileID = decision.profileID,
              !attemptedProfiles.contains(profileID) else { return nil }

        let profile = AgentSubagentProfileStore.resolvedProfile(id: profileID)
        if profile.requiresWriteAccess, directFileWriteTools.contains(toolName) {
            return message(profileID: profileID, toolName: toolName)
        }
        if profileID == AgentSubagentProfileCatalog.opsRunnerID,
           directCommandTools.contains(toolName),
           risk != .read {
            return message(profileID: profileID, toolName: toolName)
        }
        return nil
    }

    private static func message(profileID: String, toolName: String) -> String {
        if profileID == AgentSubagentProfileCatalog.opsRunnerID,
           toolName == "terminal_send_command" {
            return """
            Blocked by WillDeep's mixed-model route: this turn is delegate-first `ops_runner` work. \
            Call `spawn_agent` with `profile="ops_runner"`, `target_command` set to the EXACT terminal \
            command, and a bounded task packet before executing it directly. Tell the worker that the \
            command belongs in the visible terminal: it must snapshot/select the intended tab, verify \
            the host and `shell_ready` state, send only that approved command with \
            `terminal_send_command`, then snapshot the result. Do not silently move the raw command to \
            `run_command`; an active SSH terminal is a different execution context. Keep rollback and \
            every other mutating command in the parent session. If the operator explicitly wants no \
            worker, stop and ask them to send a new `/no-subagent` turn rather than bypassing the route.
            """
        }
        return """
        Blocked by WillDeep's mixed-model route: this turn is delegate-first `\(profileID)` work. \
        Call `spawn_agent` with `profile=\"\(profileID)\"` and a bounded task packet before \
        executing it directly. For writing trades, declare the exact `target_file` / \
        `target_files` or `task.write_files`; include a verifier when a command can decide \
        completion. If the operator explicitly wants no worker, stop and ask them to send a \
        new `/no-subagent` turn rather than bypassing the route.
        """
    }
}
