//
//  AgentLearningReviewStore.swift
//  WillDeep
//
//  Persistent review queue for automatic Agent learning events.
//

import Combine
import Foundation

nonisolated enum AgentLearningReviewDecision: String, Codable, Equatable, CaseIterable, Sendable {
    case pending
    case reviewed
    case dismissed
}

nonisolated struct AgentLearningReviewItem: Identifiable, Codable, Equatable, Sendable {
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

nonisolated enum AgentLearningReviewStore {
    private static let itemsKey = "com.willdeep.agentLearningReview.items.v1"
    private static let maxItems = 200
    static let pendingRetentionDays = 15
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
    static let pendingRetentionInterval = TimeInterval(pendingRetentionDays) * secondsPerDay

    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?

    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    private static var defaults: UserDefaults {
        testDefaultsOverride ?? .standard
    }

    static func load(now: Date = Date()) -> [AgentLearningReviewItem] {
        guard let data = defaults.data(forKey: itemsKey),
              let items = try? JSONDecoder().decode([AgentLearningReviewItem].self, from: data) else {
            return []
        }
        let cleanedItems = clean(items, now: now)
        if cleanedItems != items {
            persist(cleanedItems)
        }
        return cleanedItems
    }

    static func loadAsync(now: Date = Date()) async -> [AgentLearningReviewItem] {
        await Task.detached(priority: .userInitiated) {
            load(now: now)
        }.value
    }

    static func save(_ items: [AgentLearningReviewItem], now: Date = Date()) {
        persist(clean(items, now: now))
    }

    private static func persist(_ items: [AgentLearningReviewItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
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

    /// 以前已经提过的记忆建议正文，不论用户当时是保存、看过还是忽略。
    /// 回合末生成新建议前拿它去重：提过一次的事，不再让用户确认第二遍。
    static func previouslySuggestedMemoryContents(now: Date = Date()) -> [String] {
        load(now: now)
            .filter { $0.event.kind == .memory }
            .flatMap { $0.event.pendingMemoryDrafts.map(\.content) }
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

    /// Returns only events that still need the operator's attention. Events
    /// may briefly reach the transcript before their review-queue write lands,
    /// so a missing row is treated as pending rather than silently hidden.
    static func pendingEvents(from events: [AgentLearningEvent]) -> [AgentLearningEvent] {
        let decisions = Dictionary(uniqueKeysWithValues: load().map { ($0.id, $0.decision) })
        return events.filter { decisions[$0.id] == nil || decisions[$0.id] == .pending }
    }

    /// Opening the post-turn suggestion popover counts as reviewing every
    /// item it showed. Preserve explicit dismiss/approve decisions and create
    /// a reviewed row when rendering raced ahead of `enqueue`.
    static func markReviewed(events: [AgentLearningEvent]) {
        guard !events.isEmpty else { return }
        var items = load()
        let now = Date()
        for event in events {
            if let index = items.firstIndex(where: { $0.id == event.id }) {
                guard items[index].decision == .pending else { continue }
                items[index].decision = .reviewed
                items[index].updatedAt = now
                items[index].reviewedAt = now
            } else {
                items.append(AgentLearningReviewItem(
                    event: event,
                    decision: .reviewed,
                    updatedAt: now,
                    reviewedAt: now
                ))
            }
        }
        save(items)
    }

    static func updateSkillDraft(id: UUID, draft: AgentLearningSkillDraft) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].event.action?.skillDraft != nil else {
            return
        }

        let now = Date()
        items[index].event.action?.skillDraft = draft
        items[index].event.action?.target = draft.name
        items[index].event.detail = updatedSkillDraftDetail(from: items[index].event.detail, draftName: draft.name)
        items[index].updatedAt = now
        save(items)
    }

    static func clearReviewed() {
        save(load().filter { $0.decision == .pending })
    }

    private static func clean(_ items: [AgentLearningReviewItem], now: Date) -> [AgentLearningReviewItem] {
        var seenIDs = Set<UUID>()
        var seenFingerprints = Set<String>()
        return items
            .filter { !$0.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { item in
                item.decision != .pending
                    || now.timeIntervalSince(item.createdAt) < pendingRetentionInterval
            }
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

    nonisolated private static func updatedSkillDraftDetail(from detail: String, draftName: String) -> String {
        let lines = detail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var replaced = false
        let updatedLines = lines.map { line -> String in
            if line.hasPrefix("Draft skill: ") {
                replaced = true
                return "Draft skill: \(draftName)"
            }
            return line
        }

        if replaced {
            return updatedLines.joined(separator: "\n")
        }

        if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Draft skill: \(draftName)"
        }

        return detail + "\nDraft skill: \(draftName)"
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

    func reloadFromStore() async {
        let loadedItems = await AgentLearningReviewStore.loadAsync()
        guard !Task.isCancelled else { return }
        items = loadedItems
    }

    func markReviewed(id: UUID) {
        AgentLearningReviewStore.mark(id: id, decision: .reviewed)
        refresh()
    }

    func dismiss(id: UUID) {
        AgentLearningReviewStore.mark(id: id, decision: .dismissed)
        refresh()
    }

    func updateSkillDraft(id: UUID, draft: AgentLearningSkillDraft) {
        AgentLearningReviewStore.updateSkillDraft(id: id, draft: draft)
        refresh()
    }

    func clearReviewed() {
        AgentLearningReviewStore.clearReviewed()
        refresh()
    }
}
