import Foundation

nonisolated enum AgentOpsConvergencePolicy {
    static func shouldFinishSnapshotLoop(profileID: String, recentTools: [String]) -> Bool {
        profileID == AgentSubagentProfileCatalog.opsRunnerID
            && recentTools.suffix(3).count == 3
            && recentTools.suffix(3).allSatisfy { $0 == "terminal_snapshot" }
    }
    static let handoff = "The synchronous operations inspection has returned. Use its evidence and continue the remaining task directly in the parent session under the existing tool approvals. Do not start another synchronous ops_runner inspection in this automatic turn. Keep visible-terminal commands in that same verified terminal. If evidence is missing, run a narrow query directly; do not repeat completed checks or claim deployment is complete before rollout verification."

    static func shouldReturnToParent(profileID: String, background: Bool,
                                    delegation: AgentDelegationPolicy, completed: Bool) -> Bool {
        completed && !background && (delegation == .automatic || delegation == .agentPreferred)
            && profileID == AgentSubagentProfileCatalog.opsRunnerID
    }
}
