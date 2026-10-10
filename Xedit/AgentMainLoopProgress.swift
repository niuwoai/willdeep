import Foundation

/// Liveness evidence for a root execution, never evidence of task completion.
@MainActor
final class AgentMainLoopProgress {
    enum Decision { case run, handoff, pause }
    static let stagnantRoundLimit = 16
    static let repeatedFailureLimit = 5

    private var seenResults: Set<String> = []
    private var failures: [String: Int] = [:]
    private var seenObservations: Set<String> = []
    private var advanced = false
    private var segmentAdvanced = false
    private(set) var stagnantRounds = 0

    func observe(toolName: String, argumentsJSON: String, payload: String, succeeded: Bool,
                 observationID: String? = nil) {
        if let observationID, !seenObservations.insert(observationID).inserted { return }
        let signature = AgentRepeatedCallGuard.signature(toolName: toolName, argumentsJSON: argumentsJSON)
        guard succeeded else {
            failures[signature, default: 0] += 1
            return
        }
        failures[signature] = nil
        // Poll receipts and plan declarations are not proof of new work.
        guard !AgentRepeatedCallGuard.isExempt(toolName: toolName) else { return }
        let result = signature + AgentRepeatedCallGuard.digest(payload)
        if seenResults.insert(result).inserted {
            advanced = true
            segmentAdvanced = true
        }
    }

    func admitNextRound(completedRounds: Int, segmentLength: Int, isGoalMode: Bool,
                        hasActiveJobs: Bool) -> Decision {
        if completedRounds > 0 {
            if advanced { stagnantRounds = 0 }
            else if !hasActiveJobs { stagnantRounds += 1 }
        }
        advanced = false
        if failures.values.contains(where: { $0 >= Self.repeatedFailureLimit })
            || stagnantRounds >= Self.stagnantRoundLimit { return .pause }
        guard completedRounds > 0, completedRounds.isMultiple(of: max(1, segmentLength)) else { return .run }
        guard segmentAdvanced || hasActiveJobs else { return .pause }
        segmentAdvanced = false
        // Goal retains its durable time/admission/continuation accounting.
        return isGoalMode ? .handoff : .run
    }
}
