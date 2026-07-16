//
//  AgentScheduledTaskRegistry.swift
//  WillDeep
//
//  In-session scheduled tasks: the `schedule_task` tool creates an
//  AgentRoutine bound to the current session and enqueues a snapshot card
//  here. AppStateAgentLoop drains the queue at the top of the next turn and
//  appends a `.scheduledTask` message so a card shows up inline in the
//  transcript — the same pending → consume pipeline as show_widget. The card
//  is NOT sent to the LLM (all AgentClient adapters skip `.scheduledTask`),
//  but unlike widgets it IS persisted with the session.
//

import Foundation
import Combine

/// Immutable snapshot of a scheduled task, rendered as an inline transcript
/// card. `id` equals the backing `AgentRoutine.id` so the card can open the
/// routine's detail on tap and reflect deletion when the task auto-completes.
nonisolated struct AgentScheduledTaskCard: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var title: String
    var scheduleSummary: String
    var goal: String?
    var prompt: String
    var createdAt: Date

    init(
        id: UUID,
        title: String,
        scheduleSummary: String,
        goal: String? = nil,
        prompt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.scheduleSummary = scheduleSummary
        self.goal = goal
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

@MainActor
final class AgentScheduledTaskRegistry: ObservableObject {
    static let shared = AgentScheduledTaskRegistry()

    private var pending: [UUID: [AgentScheduledTaskCard]] = [:]

    private init() {}

    /// Called by the `schedule_task` tool handler. runtimeID comes from
    /// AgentToolContext.
    func add(_ card: AgentScheduledTaskCard, forRuntime runtimeID: UUID) {
        pending[runtimeID, default: []].append(card)
    }

    /// Drained by AppStateAgentLoop at the top of each turn, same injection
    /// pipeline as show_widget / spawn_agent / background jobs.
    func consumePending(forRuntime runtimeID: UUID) -> [AgentScheduledTaskCard] {
        guard let queued = pending.removeValue(forKey: runtimeID), !queued.isEmpty else {
            return []
        }
        return queued
    }
}
