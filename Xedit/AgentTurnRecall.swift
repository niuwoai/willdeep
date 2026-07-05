//
//  AgentTurnRecall.swift
//  WillDeep
//
//  Structured evidence for memory / skill context that influenced a turn.
//

import Foundation

nonisolated enum AgentTurnRecallKind: String, Codable, Equatable {
    case memory
    case skill
}

nonisolated struct AgentTurnRecallItem: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: AgentTurnRecallKind
    var title: String
    var detail: String
    var score: Double?
    var reasons: [String]

    init(
        id: UUID = UUID(),
        kind: AgentTurnRecallKind,
        title: String,
        detail: String,
        score: Double? = nil,
        reasons: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.score = score
        self.reasons = reasons
    }
}

nonisolated struct AgentTurnRecallSnapshot: Codable, Equatable {
    var createdAt: Date
    var query: String
    var items: [AgentTurnRecallItem]

    var hasUsefulContent: Bool {
        !items.isEmpty
    }
}
