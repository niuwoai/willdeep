//
//  AgentGoalTranscriptPresentation.swift
//  WillDeep
//
//  Goal mode keeps the live execution trace visible while a turn is running,
//  then settles the transcript to the operator-facing outcome. The underlying
//  messages and tool records stay untouched for audit, retry, and model context.
//

import Foundation

nonisolated enum AgentGoalTranscriptPresentation {
    /// Coalesces each settled operator turn to its final substantive assistant
    /// result. Generated images and text artifacts remain visible even when
    /// they were emitted before the final summary.
    static func settledMessages(from messages: [AgentMessage]) -> [AgentMessage] {
        var result: [AgentMessage] = []
        var turn: [AgentMessage] = []

        func flushTurn() {
            guard !turn.isEmpty else { return }
            result.append(contentsOf: compactedTurn(turn))
            turn.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.isOperatorInput {
                flushTurn()
            }
            turn.append(message)
        }
        flushTurn()
        return result
    }

    private static func compactedTurn(_ messages: [AgentMessage]) -> [AgentMessage] {
        let assistantMessages = messages.filter { $0.role == .assistant && hasVisibleOutput($0) }
        guard !assistantMessages.isEmpty else { return messages }

        let summary = assistantMessages.reversed().first(where: isOutcomeSummary)
            ?? assistantMessages.last
        var retainedAssistantIDs = Set(
            assistantMessages
                .filter(hasUserFacingArtifact)
                .map(\.id)
        )
        if let summary {
            retainedAssistantIDs.insert(summary.id)
        }

        return messages.compactMap { message in
            guard message.role == .assistant else { return message }
            guard retainedAssistantIDs.contains(message.id) else { return nil }

            // Settled Goal history is an operator-facing delivery surface. Keep
            // the source message untouched, but remove internal progress/check
            // protocol from this presentation copy so it cannot grow a second
            // checklist beneath the final summary.
            var settledMessage = message
            settledMessage.content = AgentTurnProgressPresentation.extract(
                from: message.content,
                plan: nil
            ).visibleContent
            settledMessage.toolCalls = []
            return settledMessage
        }
    }

    private static func hasVisibleOutput(_ message: AgentMessage) -> Bool {
        !visibleProse(in: message).isEmpty || hasUserFacingArtifact(message)
    }

    private static func hasUserFacingArtifact(_ message: AgentMessage) -> Bool {
        !message.images.isEmpty || !message.textAttachments.isEmpty
    }

    private static func isOutcomeSummary(_ message: AgentMessage) -> Bool {
        let prose = visibleProse(in: message)
        guard !prose.isEmpty else { return false }
        return AgentActivityHeadlinePresentation.make(from: prose) == nil
    }

    private static func visibleProse(in message: AgentMessage) -> String {
        AgentTurnProgressPresentation.extract(from: message.content, plan: nil)
            .visibleContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
