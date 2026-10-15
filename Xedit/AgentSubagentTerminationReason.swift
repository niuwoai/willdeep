/// A host-observed Worker terminal, independent of model text or transcript
/// truncation. Passing a verifier does not turn an unfinished report into a
/// completed run when the Worker has exhausted its round budget.
nonisolated enum AgentSubagentTerminationReason: String, Sendable {
    case finalResponse = "final_response"
    case maxRounds = "max_rounds"

    func evidenceStatus(verifierPassed: Bool?) -> String {
        if self == .maxRounds { return "budget_exhausted" }
        return verifierPassed == false ? "failed" : "unverified"
    }
}
