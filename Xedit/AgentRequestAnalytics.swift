import Foundation

nonisolated enum AgentAuxiliaryRequestPurpose: String, Codable, Equatable, Sendable {
    case title
    case contextCompression
    case imageDescription
    case workerRouting
}

/// Compact, prompt-free telemetry for helper model calls associated with a
/// conversation. Keeping this on the session gives deletion/retention the same
/// lifecycle as the chat and avoids a second cross-window analytics database.
nonisolated struct AgentAuxiliaryModelRequestRecord: Codable, Equatable, Sendable {
    let id: UUID
    let purpose: AgentAuxiliaryRequestPurpose
    let providerID: String
    let providerName: String
    let modelID: String
    let isLocal: Bool
    let createdAt: Date
    let promptTokens: Int?
    let completionTokens: Int?
    let elapsedSeconds: Double
    let firstResponseSeconds: Double?
    let succeeded: Bool

    init(
        id: UUID = UUID(),
        purpose: AgentAuxiliaryRequestPurpose,
        providerID: String,
        providerName: String? = nil,
        modelID: String,
        isLocal: Bool,
        createdAt: Date = Date(),
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        elapsedSeconds: Double,
        firstResponseSeconds: Double? = nil,
        succeeded: Bool
    ) {
        self.id = id
        self.purpose = purpose
        self.providerID = providerID
        let cleanedProviderName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.providerName = cleanedProviderName.isEmpty ? providerID : cleanedProviderName
        self.modelID = modelID
        self.isLocal = isLocal
        self.createdAt = createdAt
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.elapsedSeconds = elapsedSeconds
        self.firstResponseSeconds = firstResponseSeconds
        self.succeeded = succeeded
    }
}

/// Measures one physical provider attempt without retaining request or output
/// content. A failed call is still a request and therefore still produces a
/// record; token fields remain nil if the provider never reported usage.
actor AgentAuxiliaryRequestMeasurement {
    private let startedAt = Date()
    private var firstResponseAt: Date?
    private var promptTokens: Int?
    private var completionTokens: Int?

    func consume(_ event: AgentClientEvent) {
        switch event {
        case .textDelta(let delta), .reasoningDelta(let delta):
            if !delta.isEmpty, firstResponseAt == nil { firstResponseAt = Date() }
        case .usageReported(let prompt, let completion, _, _, _, _):
            promptTokens = prompt > 0 ? prompt : nil
            completionTokens = completion > 0 ? completion : nil
        default:
            break
        }
    }

    func record(
        purpose: AgentAuxiliaryRequestPurpose,
        providerID: String,
        providerName: String? = nil,
        modelID: String,
        isLocal: Bool,
        succeeded: Bool
    ) -> AgentAuxiliaryModelRequestRecord {
        let finishedAt = Date()
        return AgentAuxiliaryModelRequestRecord(
            purpose: purpose,
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            isLocal: isLocal,
            createdAt: startedAt,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            elapsedSeconds: finishedAt.timeIntervalSince(startedAt),
            firstResponseSeconds: firstResponseAt?.timeIntervalSince(startedAt),
            succeeded: succeeded
        )
    }
}

/// One drill-down row for real model-request traffic. Request counts use
/// provider rounds, not user messages: a tool loop with three model calls is
/// three requests, which is also what an API gateway and a local endpoint see.
nonisolated struct AgentRequestModelUsageRow: Identifiable, Equatable {
    var id: String { "\(providerID)|\(modelID)" }
    let providerID: String
    let providerName: String
    let modelID: String
    let requestCount: Int
    let sessionCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let averageLatencySeconds: Double?
    let averageFirstResponseSeconds: Double?
    let averageTokensPerSecond: Double?
    let averagePromptTokens: Double?
    let averageCompletionTokens: Double?
}

/// Summary shared by the local-model and recent-API detail pages.
nonisolated struct AgentRequestUsageSummary: Equatable {
    let requestCount: Int
    let sessionCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let averageLatencySeconds: Double?
    let averageFirstResponseSeconds: Double?
    let averageTokensPerSecond: Double?
    let averagePromptTokens: Double?
    let averageCompletionTokens: Double?
    let measuredLatencyRequestCount: Int
    let measuredFirstResponseRequestCount: Int
    let measuredPromptRequestCount: Int
    let measuredCompletionRequestCount: Int
}

nonisolated struct AgentRequestAnalyticsSnapshot: Equatable {
    let localAllTime: AgentRequestUsageSummary
    let localModels: [AgentRequestModelUsageRow]
    let recentAPI: AgentRequestUsageSummary
    let recentAPIModels: [AgentRequestModelUsageRow]
}

nonisolated enum AgentRequestAnalytics {
    private static let localProviderID = "ollama"

    private struct Sample {
        let sessionID: UUID
        let providerID: String
        let providerName: String
        let modelID: String
        let isLocal: Bool
        let createdAt: Date
        let requestCount: Int
        let promptTokens: Int?
        let completionTokens: Int?
        let elapsedSeconds: Double?
        let firstResponseSeconds: Double?
    }

    private struct Accumulator {
        var sessionIDs: Set<UUID> = []
        var requestCount = 0
        var promptTokens = 0
        var completionTokens = 0
        var elapsedSeconds = 0.0
        var latencySamples = 0
        var firstResponseSeconds = 0.0
        var firstResponseSamples = 0
        var generationSeconds = 0.0
        var generatedTokens = 0
        var promptSamples = 0
        var completionSamples = 0

        mutating func add(_ sample: Sample) {
            sessionIDs.insert(sample.sessionID)
            requestCount += sample.requestCount
            if let prompt = sample.promptTokens {
                promptTokens += prompt
                promptSamples += sample.requestCount
            }
            if let completion = sample.completionTokens {
                completionTokens += completion
                completionSamples += sample.requestCount
            }
            if let elapsed = sample.elapsedSeconds, elapsed > 0 {
                elapsedSeconds += elapsed
                latencySamples += 1
                let generation = max(0, elapsed - max(0, sample.firstResponseSeconds ?? 0))
                if generation > 0, let completion = sample.completionTokens, completion > 0 {
                    generationSeconds += generation
                    generatedTokens += completion
                }
            }
            if let first = sample.firstResponseSeconds, first >= 0 {
                firstResponseSeconds += first
                firstResponseSamples += 1
            }
        }

        var summary: AgentRequestUsageSummary {
            AgentRequestUsageSummary(
                requestCount: requestCount,
                sessionCount: sessionIDs.count,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                averageLatencySeconds: latencySamples > 0
                    ? elapsedSeconds / Double(latencySamples)
                    : nil,
                averageFirstResponseSeconds: firstResponseSamples > 0
                    ? firstResponseSeconds / Double(firstResponseSamples)
                    : nil,
                averageTokensPerSecond: generationSeconds > 0
                    ? Double(generatedTokens) / generationSeconds
                    : nil,
                averagePromptTokens: promptSamples > 0
                    ? Double(promptTokens) / Double(promptSamples)
                    : nil,
                averageCompletionTokens: completionSamples > 0
                    ? Double(completionTokens) / Double(completionSamples)
                    : nil,
                measuredLatencyRequestCount: latencySamples,
                measuredFirstResponseRequestCount: firstResponseSamples,
                measuredPromptRequestCount: promptSamples,
                measuredCompletionRequestCount: completionSamples
            )
        }
    }

    static func snapshot(
        for sessions: [AgentUsageSessionSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AgentRequestAnalyticsSnapshot {
        let samples = sessions.flatMap(samples(for:))
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let recent = samples.filter { $0.createdAt >= recentStart && $0.createdAt <= now }
        let local = samples.filter(\.isLocal)
        return AgentRequestAnalyticsSnapshot(
            localAllTime: aggregate(local),
            localModels: modelRows(local),
            recentAPI: aggregate(recent),
            recentAPIModels: modelRows(recent)
        )
    }

    private static func samples(for session: AgentUsageSessionSnapshot) -> [Sample] {
        var result = session.messages.compactMap { message -> Sample? in
            guard message.role == .assistant, message.origin != .delegatedExternal else { return nil }
            let model = normalized(message.requestModelID ?? session.modelID, fallback: "unknown-model")
            let provider = normalized(message.requestProviderID ?? session.providerID, fallback: "unknown-provider")
            let hasRequestEvidence = message.requestModelID != nil
                || message.requestProviderID != nil
                || message.elapsedSeconds != nil
                || message.usageTokens != nil
            guard hasRequestEvidence else { return nil }
            return Sample(
                sessionID: session.id,
                providerID: provider,
                providerName: providerName(provider, stored: message.requestProviderDisplayName ?? session.providerDisplayName),
                modelID: model,
                isLocal: message.requestIsLocal ?? (provider.lowercased() == localProviderID),
                createdAt: message.createdAt,
                requestCount: 1,
                promptTokens: message.promptTokens.map { max(0, $0) },
                completionTokens: message.completionTokens.map { max(0, $0) },
                elapsedSeconds: positive(message.elapsedSeconds),
                firstResponseSeconds: nonnegative(message.firstResponseSeconds)
            )
        }

        for message in session.messages where !message.subagentRuns.isEmpty {
            result.append(contentsOf: workerSamples(
                message.subagentRuns,
                sessionID: session.id,
                createdAt: message.createdAt
            ))
        }
        let sessionLevelWorkerRuns = (session.hostWorkerRuns ?? []).compactMap(\.usage)
            + (session.coordinatorWorkerRuns ?? [])
        result.append(contentsOf: workerSamples(
            sessionLevelWorkerRuns,
            sessionID: session.id,
            createdAt: session.updatedAt
        ))
        result.append(contentsOf: session.auxiliaryModelRequests.map { record in
            Sample(
                sessionID: session.id,
                providerID: normalized(record.providerID, fallback: "unknown-provider"),
                providerName: providerName(record.providerID, stored: record.providerName),
                modelID: normalized(record.modelID, fallback: "unknown-model"),
                isLocal: record.isLocal,
                createdAt: record.createdAt,
                requestCount: 1,
                promptTokens: record.promptTokens.map { max(0, $0) },
                completionTokens: record.completionTokens.map { max(0, $0) },
                elapsedSeconds: positive(record.elapsedSeconds),
                firstResponseSeconds: nonnegative(record.firstResponseSeconds)
            )
        })
        return result
    }

    private static func workerSamples(
        _ runs: [AgentSubagentRunUsage],
        sessionID: UUID,
        createdAt: Date
    ) -> [Sample] {
        runs.compactMap { run in
            let requests = max(0, run.roundCount)
            guard requests > 0 else { return nil }
            let provider = normalized(run.providerID, fallback: "unknown-provider")
            return Sample(
                sessionID: sessionID,
                providerID: provider,
                providerName: providerName(provider, stored: nil),
                modelID: normalized(run.model, fallback: "unknown-model"),
                isLocal: provider.lowercased() == localProviderID,
                createdAt: createdAt,
                requestCount: requests,
                promptTokens: run.promptTokens > 0 ? run.promptTokens : nil,
                completionTokens: run.completionTokens > 0 ? run.completionTokens : nil,
                elapsedSeconds: nil,
                firstResponseSeconds: nil
            )
        }
    }

    private static func aggregate(_ samples: [Sample]) -> AgentRequestUsageSummary {
        var accumulator = Accumulator()
        samples.forEach { accumulator.add($0) }
        return accumulator.summary
    }

    private static func modelRows(_ samples: [Sample]) -> [AgentRequestModelUsageRow] {
        let groups = Dictionary(grouping: samples) { "\($0.providerID)|\($0.modelID)" }
        return groups.values.compactMap { group in
            guard let first = group.first else { return nil }
            let summary = aggregate(group)
            return AgentRequestModelUsageRow(
                providerID: first.providerID,
                providerName: first.providerName,
                modelID: first.modelID,
                requestCount: summary.requestCount,
                sessionCount: summary.sessionCount,
                promptTokens: summary.promptTokens,
                completionTokens: summary.completionTokens,
                averageLatencySeconds: summary.averageLatencySeconds,
                averageFirstResponseSeconds: summary.averageFirstResponseSeconds,
                averageTokensPerSecond: summary.averageTokensPerSecond,
                averagePromptTokens: summary.averagePromptTokens,
                averageCompletionTokens: summary.averageCompletionTokens
            )
        }
        .sorted {
            if $0.requestCount != $1.requestCount { return $0.requestCount > $1.requestCount }
            if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
            return $0.modelID < $1.modelID
        }
    }

    private static func normalized(_ value: String?, fallback: String) -> String {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? fallback : result
    }

    private static func providerName(_ providerID: String, stored: String?) -> String {
        let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? providerID : stored
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
