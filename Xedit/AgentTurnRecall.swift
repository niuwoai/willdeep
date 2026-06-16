//
//  AgentTurnRecall.swift
//  WillDeep
//
//  Structured evidence for memory / skill context that influenced a turn.
//

import Foundation

enum AgentTurnRecallKind: String, Codable, Equatable {
    case memory
    case skill
}

struct AgentTurnRecallItem: Identifiable, Codable, Equatable {
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

struct AgentTurnRecallSnapshot: Codable, Equatable {
    var createdAt: Date
    var query: String
    var items: [AgentTurnRecallItem]

    var hasUsefulContent: Bool {
        !items.isEmpty
    }
}
