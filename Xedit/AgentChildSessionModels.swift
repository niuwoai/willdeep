//
//  AgentChildSessionModels.swift
//  WillDeep
//
//  One durable assignment attached to its own child conversation.
//

import Foundation

nonisolated struct AgentChildSessionAssignment: Codable, Equatable {
    nonisolated enum Status: String, Codable, Equatable {
        case queued
        case running
        case waiting
        case completed
        case failed
        case cancelled
        case interrupted
    }

    /// The assignment's identity is independent of the child session id.
    let id: UUID
    let prompt: String
    var status: Status
    let createdAt: Date
    var completedAt: Date?
    var resultNotificationID: UUID?
    var resultExcerpt: String?

    init(
        id: UUID = UUID(),
        prompt: String,
        status: Status = .queued,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        resultNotificationID: UUID? = nil,
        resultExcerpt: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.resultNotificationID = resultNotificationID
        self.resultExcerpt = resultExcerpt
    }

    /// A sidebar catalog is an index, not a copy of the task or its reply.
    /// Keep the full text in the child session JSON; bound both text fields
    /// before writing the lightweight catalog sidecar.
    static let catalogTextLimit = 512

    func forCatalog() -> Self {
        Self(
            id: id,
            prompt: String(prompt.prefix(Self.catalogTextLimit)),
            status: status,
            createdAt: createdAt,
            completedAt: completedAt,
            resultNotificationID: resultNotificationID,
            resultExcerpt: resultExcerpt.map { String($0.prefix(Self.catalogTextLimit)) }
        )
    }
}
