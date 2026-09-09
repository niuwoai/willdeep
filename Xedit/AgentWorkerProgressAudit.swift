import Foundation

/// Metadata only: never write prompts, reasoning, command arguments or output.
@MainActor
final class AgentWorkerProgressAudit {
    struct Entry: Codable {
        let kind: String
        let recordedAt: Date
        let runID: UUID
        let sequence: Int
        let round: Int
        let completedTools: Int
        let phase: String
        let toolName: String?
        let durationSeconds: Double?
        let resultCharacters: Int?
    }
    private var sequence = 0
    private var lastPhase = ""
    private var seenTools: Set<String> = []

    func entries(runID: UUID, progress: AgentSubagentProgressUpdate) -> [Entry] {
        var events: [Entry] = []
        func add(_ kind: String, _ phase: String, tool: String? = nil,
                 duration: Double? = nil, characters: Int? = nil) {
            sequence += 1
            events.append(Entry(kind: kind, recordedAt: Date(), runID: runID,
                sequence: sequence, round: progress.round, completedTools: progress.completedToolInvocations,
                phase: phase, toolName: tool, durationSeconds: duration, resultCharacters: characters))
        }
        let phase: String
        var tool: String?
        switch progress.activity {
        case .thinking: phase = "model_wait"
        case .runningTool(let name): phase = "tool_started"; tool = name
        case .retryingEmptyResponse: phase = "retry"
        case .verifying: phase = "verification"
        case .preparingReport: phase = "report"
        case .finished: phase = "finished"
        }
        let fingerprint = "\(progress.round):\(progress.completedToolInvocations):\(phase):\(tool ?? "")"
        if fingerprint != lastPhase {
            add("worker_progress", phase, tool: tool)
            lastPhase = fingerprint
        }
        for round in progress.recordedRounds ?? [] {
            for call in round.toolCalls {
                guard seenTools.insert("\(round.index):\(call.externalID)").inserted else { continue }
                add("worker_tool", "tool_finished", tool: call.name,
                    duration: call.durationSeconds, characters: call.result.count)
            }
        }
        return events
    }
}
