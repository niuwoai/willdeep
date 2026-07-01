//
//  AgentTurnReport.swift
//  WillDeep
//
//  Lightweight audit summary for the latest Agent turn.
//

import Foundation

struct AgentTurnReport: Identifiable, Equatable {
    struct ToolSummary: Equatable {
        var total: Int
        var succeeded: Int
        var failed: Int
        var denied: Int
        var pending: Int
        var readRisk: Int
        var writeRisk: Int
        var dangerRisk: Int
        var userInputRisk: Int
        var autoApproved: Int
        var userApproved: Int
        var escalated: Int
        var sandboxModes: [String]
    }

    let id: UUID
    var createdAt: Date
    var modelID: String
    var providerName: String
    var interactionMode: AgentInteractionMode
    var approvalMode: AgentApprovalMode
    var assistantMessageCount: Int
    var elapsedSeconds: Double?
    var totalTokens: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var recallSnapshot: AgentTurnRecallSnapshot?
    var toolSummary: ToolSummary
    var tools: [AgentToolCall]
    var sourceReferences: [AgentSourceReference]
    var learningEvents: [AgentLearningEvent]

    var hasUsefulContent: Bool {
        assistantMessageCount > 0 || toolSummary.total > 0 || !sourceReferences.isEmpty || !learningEvents.isEmpty || recallSnapshot?.hasUsefulContent == true
    }
}

extension AgentTurnReport {
    @MainActor
    static func latest(for runtime: AgentRuntime?) -> AgentTurnReport? {
        guard let runtime,
              let latestUser = runtime.messages.last(where: { $0.role == .user }) else {
            return nil
        }

        let assistantMessages = runtime.messages.filter {
            $0.role == .assistant && $0.createdAt >= latestUser.createdAt
        }
        let assistantIDs = Set(assistantMessages.map(\.id))
        let tools = runtime.toolCalls.filter { assistantIDs.contains($0.messageID) }
        let learningEvents = runtime.learningEvents.filter { $0.createdAt >= latestUser.createdAt }

        let report = AgentTurnReport(
            id: assistantMessages.last?.id ?? latestUser.id,
            createdAt: assistantMessages.last?.createdAt ?? latestUser.createdAt,
            modelID: reportModelID(for: runtime),
            providerName: reportProviderName(for: runtime),
            interactionMode: runtime.interactionMode,
            approvalMode: runtime.approvalMode,
            assistantMessageCount: assistantMessages.count,
            elapsedSeconds: summedElapsedSeconds(from: assistantMessages),
            totalTokens: sumOptional(assistantMessages.map(\.usageTokens)),
            promptTokens: sumOptional(assistantMessages.map(\.promptTokens)),
            completionTokens: sumOptional(assistantMessages.map(\.completionTokens)),
            recallSnapshot: runtime.latestTurnRecall?.createdAt ?? .distantPast >= latestUser.createdAt ? runtime.latestTurnRecall : nil,
            toolSummary: summarizeTools(tools),
            tools: Array(tools.prefix(8)),
            sourceReferences: summarizeSources(tools),
            learningEvents: Array(learningEvents.prefix(6))
        )
        return report.hasUsefulContent ? report : nil
    }

    private static func reportModelID(for runtime: AgentRuntime) -> String {
        let candidates = [
            runtime.sessionModelOverride,
            runtime.session.modelID
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "unknown"
    }

    private static func reportProviderName(for runtime: AgentRuntime) -> String {
        let provider = runtime.session.providerDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return provider?.isEmpty == false ? provider! : "default provider"
    }

    private static func summedElapsedSeconds(from messages: [AgentMessage]) -> Double? {
        let values = messages.compactMap(\.elapsedSeconds)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func sumOptional(_ values: [Int?]) -> Int? {
        let concrete = values.compactMap { $0 }
        guard !concrete.isEmpty else { return nil }
        return concrete.reduce(0, +)
    }

    private static func summarizeTools(_ tools: [AgentToolCall]) -> ToolSummary {
        let sandboxModes = tools
            .compactMap { $0.arguments["_sandbox"]?.stringValue() }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ToolSummary(
            total: tools.count,
            succeeded: tools.filter { $0.status == .succeeded }.count,
            failed: tools.filter { $0.status == .failed }.count,
            denied: tools.filter { $0.status == .denied }.count,
            pending: tools.filter {
                $0.status == .pendingApproval || $0.status == .awaitingConfirm || $0.status == .awaitingUserAnswer || $0.status == .running
            }.count,
            readRisk: tools.filter { $0.risk == .read }.count,
            writeRisk: tools.filter { $0.risk == .write }.count,
            dangerRisk: tools.filter { $0.risk == .danger }.count,
            userInputRisk: tools.filter { $0.risk == .userInput }.count,
            autoApproved: tools.filter { source in
                guard let approval = source.approvalSource else { return false }
                return approval != .user && approval != .escalated
            }.count,
            userApproved: tools.filter { $0.approvalSource == .user }.count,
            escalated: tools.filter { $0.approvalSource == .escalated }.count,
            sandboxModes: Array(Set(sandboxModes)).sorted()
        )
    }

    private static func summarizeSources(_ tools: [AgentToolCall]) -> [AgentSourceReference] {
        var seen = Set<String>()
        var result: [AgentSourceReference] = []
        for reference in tools.flatMap({ $0.result?.references ?? [] }) {
            let key = reference.url.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(reference)
        }
        return Array(result.prefix(24))
    }
}

extension AppState {
    var agentLatestTurnReport: AgentTurnReport? {
        AgentTurnReport.latest(for: activeRuntime)
    }
}
