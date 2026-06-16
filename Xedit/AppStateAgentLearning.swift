//
//  AppStateAgentLearning.swift
//  WillDeep
//
//  Agent turn-end memory and skill learning helpers.
//

import Foundation

extension AppState {
    static func memoryRetrievalQuery(
        messages: [AgentMessage],
        openedFileURL: URL?,
        selectedText: String
    ) -> String {
        let recentUserText = messages
            .reversed()
            .filter { $0.role == .user }
            .prefix(3)
            .map(\.modelContent)
            .reversed()
            .joined(separator: "\n\n")
        return [
            recentUserText,
            openedFileURL?.path ?? "",
            selectedText
        ]
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildTurnRecallSnapshot(
        query: String,
        retrievedMemories: [AgentMemoryRetrievalResult],
        attachedSkills: [AgentSkillEntry],
        createdAt: Date = Date()
    ) -> AgentTurnRecallSnapshot? {
        var items: [AgentTurnRecallItem] = retrievedMemories.map { result in
            AgentTurnRecallItem(
                kind: .memory,
                title: oneLine(result.record.content, limit: 140),
                detail: result.record.scope == .project ? "Project memory" : "Global memory",
                score: result.score,
                reasons: result.reasons
            )
        }
        items.append(contentsOf: attachedSkills.map { skill in
            AgentTurnRecallItem(
                kind: .skill,
                title: skill.identifier,
                detail: oneLine(skill.description, limit: 160),
                reasons: ["Attached via @skill for this turn."]
            )
        })
        guard !items.isEmpty else { return nil }
        return AgentTurnRecallSnapshot(
            createdAt: createdAt,
            query: query,
            items: items
        )
    }

    func captureTurnEndLearning(
        for runtime: AgentRuntime,
        memoryState: AgentMemoryState,
        workspaceURL: URL?
    ) {
        var events = captureAutomaticMemories(
            for: runtime,
            memoryState: memoryState,
            workspaceURL: workspaceURL
        )
        events.append(contentsOf: AgentSelfLearning.captureAutomaticMCPCapabilityGap(
            for: runtime,
            memoryState: memoryState,
            workspaceURL: workspaceURL
        ))
        events.append(contentsOf: AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: workspaceURL
        ))
        // Cross-link each learning event back to the recall hits that
        // influenced this turn, so the audit trail can say "this
        // suggestion relates to these recalled memories / attached skills"
        // — not just "it came from a tool sequence". Recall was captured
        // early in the turn (see runAgentLoop), so `latestTurnRecall` is
        // populated by the time this turn-end pass runs.
        let recall = runtime.latestTurnRecall
        events = events.map { event in
            var enriched = event
            let links = AgentSelfLearning.relatedRecallLinks(for: event, in: recall)
            enriched.relatedRecall = links.isEmpty ? nil : links
            return enriched
        }
        appendAgentLearningEvents(events, to: runtime)
    }

    private func captureAutomaticMemories(
        for runtime: AgentRuntime,
        memoryState: AgentMemoryState,
        workspaceURL: URL?
    ) -> [AgentLearningEvent] {
        guard memoryState.settings.normalized.isMemoryEnabled,
              memoryState.settings.normalized.autoSummaryEnabled,
              let latestUser = runtime.messages.last(where: { $0.role == .user }),
              let assistant = runtime.messages.last(where: {
                  $0.role == .assistant
                      && $0.createdAt >= latestUser.createdAt
                      && !$0.modelContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return []
        }
        let existingIDs = Set(memoryState.memories.map(\.id))
        memoryState.addAutomaticMemories(
            fromUser: latestUser.modelContent,
            assistantText: assistant.modelContent,
            rootDirectory: workspaceURL
        )
        let savedMemories = memoryState.memories.filter { !existingIDs.contains($0.id) }
        guard !savedMemories.isEmpty else { return [] }
        let preview = savedMemories
            .prefix(3)
            .map { "- \(Self.oneLine($0.content, limit: 180))" }
            .joined(separator: "\n")
        return [
            AgentLearningEvent(
                kind: .memory,
                status: .saved,
                title: "Saved \(savedMemories.count) conversation memor\(savedMemories.count == 1 ? "y" : "ies")",
                detail: preview,
                action: AgentLearningAction(
                    kind: .saveMemory,
                    commandName: "add_memory",
                    target: workspaceURL == nil ? "global memory" : "project memory",
                    reason: "The latest turn exposed durable conversation context.",
                    nextStep: "Use retrieved memories as context in future turns."
                )
            )
        ]
    }

    private func appendAgentLearningEvents(_ events: [AgentLearningEvent], to runtime: AgentRuntime) {
        let meaningfulEvents = events.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !meaningfulEvents.isEmpty else { return }
        runtime.learningEvents = Array((meaningfulEvents + runtime.learningEvents).prefix(24))
        AgentLearningReviewStore.enqueue(events: meaningfulEvents, sessionID: runtime.id)
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }
}
