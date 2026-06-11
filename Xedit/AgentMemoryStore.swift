//
//  AgentMemoryStore.swift
//  WillDeep
//
//  Local persistence for Agent memory settings and user-managed memories.
//

import Combine
import Foundation

struct AgentMemorySettings: Codable, Equatable {
    var isMemoryEnabled: Bool
    var autoRetrievalEnabled: Bool
    var queryRewriteEnabled: Bool
    var maxRetrievedMemories: Int
    var similarityThreshold: Double
    var autoSummaryEnabled: Bool
    var dailyMaintenanceEnabled: Bool
    var maintenanceHour: Int
    var maintenanceMinute: Int
    var transientTTLDays: Int
    var archiveRetentionDays: Int
    var toolModelID: String
    var embeddingModelID: String
    var lastMaintenanceRun: AgentMemoryMaintenanceRun?

    static let `default` = AgentMemorySettings(
        isMemoryEnabled: true,
        autoRetrievalEnabled: true,
        queryRewriteEnabled: true,
        maxRetrievedMemories: 5,
        similarityThreshold: 0.10,
        autoSummaryEnabled: true,
        dailyMaintenanceEnabled: true,
        maintenanceHour: 3,
        maintenanceMinute: 0,
        transientTTLDays: 30,
        archiveRetentionDays: 30,
        toolModelID: "",
        embeddingModelID: "text-embedding-3-small",
        lastMaintenanceRun: nil
    )

    var normalized: AgentMemorySettings {
        var copy = self
        copy.maxRetrievedMemories = max(1, min(20, copy.maxRetrievedMemories))
        copy.similarityThreshold = max(0, min(1, copy.similarityThreshold))
        copy.maintenanceHour = max(0, min(23, copy.maintenanceHour))
        copy.maintenanceMinute = max(0, min(59, copy.maintenanceMinute))
        copy.transientTTLDays = max(1, min(3650, copy.transientTTLDays))
        copy.archiveRetentionDays = max(1, min(3650, copy.archiveRetentionDays))
        copy.toolModelID = copy.toolModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.embeddingModelID = copy.embeddingModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    func nextMaintenanceDate(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        let components = DateComponents(hour: maintenanceHour, minute: maintenanceMinute)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}

struct AgentMemoryMaintenanceRun: Codable, Equatable {
    var ranAt: Date
    var status: AgentMemoryMaintenanceStatus
    var inspectedCount: Int
    var archivedCount: Int
    var removedExpiredCount: Int
    var mergedCount: Int
    var inputTokens: Int
    var outputTokens: Int
}

enum AgentMemoryMaintenanceStatus: String, Codable {
    case completed
    case preview
}

struct AgentMemoryRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var content: String
    var source: AgentMemorySource
    var lifetime: AgentMemoryLifetime
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var accessCount: Int
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        content: String,
        source: AgentMemorySource,
        lifetime: AgentMemoryLifetime = .longTerm,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        accessCount: Int = 0,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.lifetime = lifetime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.archivedAt = archivedAt
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    var normalized: AgentMemoryRecord {
        var copy = self
        copy.content = copy.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.updatedAt < copy.createdAt {
            copy.updatedAt = copy.createdAt
        }
        copy.accessCount = max(0, copy.accessCount)
        return copy
    }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return content.localizedCaseInsensitiveContains(trimmed)
    }
}

enum AgentMemorySource: String, CaseIterable, Codable, Identifiable {
    case automatic
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .manual:
            return "Manual"
        }
    }
}

enum AgentMemoryLifetime: String, CaseIterable, Codable, Identifiable {
    case transient
    case longTerm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transient:
            return "Transient"
        case .longTerm:
            return "Long-term"
        }
    }
}

enum AgentMemorySettingsStore {
    private static let settingsKey = "com.willdeep.agentMemory.settings.v1"
    private static let recordsKey = "com.willdeep.agentMemory.records.v1"

    static func loadSettings() -> AgentMemorySettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentMemorySettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func saveSettings(_ settings: AgentMemorySettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func loadRecords() -> [AgentMemoryRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([AgentMemoryRecord].self, from: data) else {
            return []
        }
        return clean(records)
    }

    static func saveRecords(_ records: [AgentMemoryRecord]) {
        guard let data = try? JSONEncoder().encode(clean(records)) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }

    private static func clean(_ records: [AgentMemoryRecord]) -> [AgentMemoryRecord] {
        var seen = Set<UUID>()
        return records
            .map(\.normalized)
            .filter { !$0.content.isEmpty }
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.isArchived != rhs.isArchived {
                    return !lhs.isArchived
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }
}

@MainActor
final class AgentMemoryState: ObservableObject {
    @Published var settings: AgentMemorySettings {
        didSet { AgentMemorySettingsStore.saveSettings(settings.normalized) }
    }

    @Published var memories: [AgentMemoryRecord] {
        didSet { AgentMemorySettingsStore.saveRecords(memories) }
    }

    init(
        settings: AgentMemorySettings? = nil,
        memories: [AgentMemoryRecord]? = nil
    ) {
        self.settings = (settings ?? AgentMemorySettingsStore.loadSettings()).normalized
        self.memories = memories ?? AgentMemorySettingsStore.loadRecords()
    }

    var activeMemories: [AgentMemoryRecord] {
        memories.filter { !$0.isArchived }
    }

    var archivedMemories: [AgentMemoryRecord] {
        memories.filter(\.isArchived)
    }

    func addMemory(content: String, source: AgentMemorySource = .manual, lifetime: AgentMemoryLifetime = .longTerm) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        memories.insert(
            AgentMemoryRecord(
                content: trimmed,
                source: source,
                lifetime: lifetime,
                createdAt: now,
                updatedAt: now
            ),
            at: 0
        )
    }

    func updateMemory(id: AgentMemoryRecord.ID, content: String, lifetime: AgentMemoryLifetime) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].content = trimmed
        memories[index].lifetime = lifetime
        memories[index].updatedAt = Date()
    }

    func archiveMemory(id: AgentMemoryRecord.ID) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].archivedAt = Date()
        memories[index].updatedAt = Date()
    }

    func restoreMemory(id: AgentMemoryRecord.ID) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].archivedAt = nil
        memories[index].updatedAt = Date()
    }

    func deleteMemory(id: AgentMemoryRecord.ID) {
        memories.removeAll { $0.id == id }
    }

    func clearMemories(includeArchived: Bool = true) {
        if includeArchived {
            memories.removeAll()
        } else {
            memories.removeAll { !$0.isArchived }
        }
    }

    func memories(matching query: String, includeArchived: Bool) -> [AgentMemoryRecord] {
        memories
            .filter { includeArchived || !$0.isArchived }
            .filter { $0.matches(query) }
    }

    func runMaintenance(preview: Bool = false, now: Date = Date(), calendar: Calendar = .current) {
        let normalizedSettings = settings.normalized
        var nextRecords = memories
        let transientCutoff = calendar.date(byAdding: .day, value: -normalizedSettings.transientTTLDays, to: now) ?? now
        let archiveCutoff = calendar.date(byAdding: .day, value: -normalizedSettings.archiveRetentionDays, to: now) ?? now
        var archivedCount = 0
        var removedExpiredCount = 0

        if !preview {
            nextRecords = nextRecords.compactMap { record in
                var copy = record
                if copy.lifetime == .transient,
                   copy.archivedAt == nil,
                   copy.updatedAt < transientCutoff {
                    copy.archivedAt = now
                    copy.updatedAt = now
                    archivedCount += 1
                }
                if let archivedAt = copy.archivedAt, archivedAt < archiveCutoff {
                    removedExpiredCount += 1
                    return nil
                }
                return copy
            }
            memories = nextRecords
        } else {
            archivedCount = nextRecords.filter {
                $0.lifetime == .transient && $0.archivedAt == nil && $0.updatedAt < transientCutoff
            }.count
            removedExpiredCount = nextRecords.filter {
                guard let archivedAt = $0.archivedAt else { return false }
                return archivedAt < archiveCutoff
            }.count
        }

        settings.lastMaintenanceRun = AgentMemoryMaintenanceRun(
            ranAt: now,
            status: preview ? .preview : .completed,
            inspectedCount: nextRecords.count,
            archivedCount: archivedCount,
            removedExpiredCount: removedExpiredCount,
            mergedCount: 0,
            inputTokens: 0,
            outputTokens: 0
        )
    }
}
