//
//  AgentLearningReviewStore.swift
//  WillDeep
//
//  Persistent review queue for automatic Agent learning events.
//

import Combine
import Foundation

enum AgentLearningReviewDecision: String, Codable, Equatable, CaseIterable {
    case pending
    case reviewed
    case dismissed
}

struct AgentLearningReviewItem: Identifiable, Codable, Equatable {
    var id: UUID
    var event: AgentLearningEvent
    var decision: AgentLearningReviewDecision
    var sessionID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var reviewedAt: Date?

    init(
        id: UUID? = nil,
        event: AgentLearningEvent,
        decision: AgentLearningReviewDecision = .pending,
        sessionID: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        reviewedAt: Date? = nil
    ) {
        self.id = id ?? event.id
        self.event = event
        self.decision = decision
        self.sessionID = sessionID
        self.createdAt = createdAt ?? event.createdAt
        self.updatedAt = updatedAt ?? event.createdAt
        self.reviewedAt = reviewedAt
    }
}

enum AgentLearningReviewStore {
    private static let itemsKey = "com.willdeep.agentLearningReview.items.v1"
    private static let maxItems = 200

    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?

    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    private static var defaults: UserDefaults {
        testDefaultsOverride ?? .standard
    }

    static func load() -> [AgentLearningReviewItem] {
        guard let data = defaults.data(forKey: itemsKey),
              let items = try? JSONDecoder().decode([AgentLearningReviewItem].self, from: data) else {
            return []
        }
        return clean(items)
    }

    static func save(_ items: [AgentLearningReviewItem]) {
        guard let data = try? JSONEncoder().encode(clean(items)) else { return }
        defaults.set(data, forKey: itemsKey)
    }

    static func enqueue(events: [AgentLearningEvent], sessionID: UUID?) {
        let meaningfulEvents = events.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !meaningfulEvents.isEmpty else { return }

        var items = load()
        var seenIDs = Set(items.map(\.id))
        var seenFingerprints = Set(items.map(fingerprint))
        let now = Date()

        for event in meaningfulEvents {
            let item = AgentLearningReviewItem(
                event: event,
                sessionID: sessionID,
                updatedAt: now
            )
            let eventFingerprint = fingerprint(item)
            guard seenIDs.insert(item.id).inserted,
                  seenFingerprints.insert(eventFingerprint).inserted else {
                continue
            }
            items.insert(item, at: 0)
        }

        save(items)
    }

    static func mark(id: UUID, decision: AgentLearningReviewDecision) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        items[index].decision = decision
        items[index].updatedAt = now
        items[index].reviewedAt = decision == .pending ? nil : now
        save(items)
    }

    static func clearReviewed() {
        save(load().filter { $0.decision == .pending })
    }

    private static func clean(_ items: [AgentLearningReviewItem]) -> [AgentLearningReviewItem] {
        var seenIDs = Set<UUID>()
        var seenFingerprints = Set<String>()
        return items
            .filter { !$0.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { item in
                seenIDs.insert(item.id).inserted && seenFingerprints.insert(fingerprint(item)).inserted
            }
            .sorted { lhs, rhs in
                if lhs.decision == .pending, rhs.decision != .pending { return true }
                if lhs.decision != .pending, rhs.decision == .pending { return false }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(maxItems)
            .map { $0 }
    }

    nonisolated private static func fingerprint(_ item: AgentLearningReviewItem) -> String {
        [
            item.event.kind.rawValue,
            item.event.status.rawValue,
            normalized(item.event.title),
            normalized(item.event.detail)
        ].joined(separator: "|")
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
    }
}

@MainActor
final class AgentLearningReviewState: ObservableObject {
    @Published private(set) var items: [AgentLearningReviewItem]

    init(items: [AgentLearningReviewItem]? = nil) {
        self.items = items ?? AgentLearningReviewStore.load()
    }

    var pendingItems: [AgentLearningReviewItem] {
        items.filter { $0.decision == .pending }
    }

    var reviewedItems: [AgentLearningReviewItem] {
        items.filter { $0.decision != .pending }
    }

    func refresh() {
        items = AgentLearningReviewStore.load()
    }

    func markReviewed(id: UUID) {
        AgentLearningReviewStore.mark(id: id, decision: .reviewed)
        refresh()
    }

    func dismiss(id: UUID) {
        AgentLearningReviewStore.mark(id: id, decision: .dismissed)
        refresh()
    }

    func clearReviewed() {
        AgentLearningReviewStore.clearReviewed()
        refresh()
    }
}
