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
    var scope: AgentMemoryScope
    var projectFingerprint: String?
    var topics: [String]
    var confidence: Double
    var containsSensitiveContent: Bool
    var provenance: String?
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
        scope: AgentMemoryScope = .global,
        projectFingerprint: String? = nil,
        topics: [String] = [],
        confidence: Double = 1.0,
        containsSensitiveContent: Bool = false,
        provenance: String? = nil,
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
        self.scope = scope
        self.projectFingerprint = projectFingerprint
        self.topics = topics
        self.confidence = confidence
        self.containsSensitiveContent = containsSensitiveContent
        self.provenance = provenance
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
        let sanitized = AgentMemorySanitizer.sanitize(copy.content)
        copy.content = sanitized.text.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.containsSensitiveContent = copy.containsSensitiveContent || sanitized.redacted
        copy.projectFingerprint = copy.projectFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.projectFingerprint?.isEmpty == true {
            copy.projectFingerprint = nil
        }
        copy.topics = AgentMemoryKeywordExtractor.keywords(from: copy.topics.joined(separator: " ") + " " + copy.content, limit: 8)
        copy.confidence = max(0, min(1, copy.confidence))
        copy.provenance = copy.provenance?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.provenance?.isEmpty == true {
            copy.provenance = nil
        }
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
            || topics.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            || scope.displayName.localizedCaseInsensitiveContains(trimmed)
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, source, lifetime, scope, projectFingerprint, topics, confidence
        case containsSensitiveContent, provenance, createdAt, updatedAt, lastAccessedAt, accessCount, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try c.decode(String.self, forKey: .content)
        source = try c.decodeIfPresent(AgentMemorySource.self, forKey: .source) ?? .manual
        lifetime = try c.decodeIfPresent(AgentMemoryLifetime.self, forKey: .lifetime) ?? .longTerm
        scope = try c.decodeIfPresent(AgentMemoryScope.self, forKey: .scope) ?? .global
        projectFingerprint = try c.decodeIfPresent(String.self, forKey: .projectFingerprint)
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        containsSensitiveContent = try c.decodeIfPresent(Bool.self, forKey: .containsSensitiveContent) ?? false
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastAccessedAt = try c.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        accessCount = try c.decodeIfPresent(Int.self, forKey: .accessCount) ?? 0
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
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

enum AgentMemoryScope: String, CaseIterable, Codable, Identifiable {
    case global
    case project

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global:
            return "Global"
        case .project:
            return "Project"
        }
    }
}

struct AgentMemoryRetrievalResult: Equatable {
    var record: AgentMemoryRecord
    var score: Double
    var reasons: [String]
}

enum AgentMemoryKeywordExtractor {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "your", "you",
        "are", "was", "were", "will", "can", "should", "must", "not", "but", "about",
        "agent", "memory", "project", "willdeep", "使用", "需要", "这个", "那个", "我们",
        "你要", "不要", "必须", "可以", "如果", "时候", "项目", "记住"
    ]

    static func keywords(from text: String, limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        for token in tokens(from: text) {
            guard token.count >= 2, !stopWords.contains(token) else { continue }
            counts[token, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }

    static func tokens(from text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted
        return folded
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "_-")) }
            .filter { !$0.isEmpty }
    }
}

enum AgentMemorySanitizer {
    private static let patterns: [String] = [
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
        #"(?i)\b(sk|ak|pk|rk)-[A-Za-z0-9_\-]{16,}"#,
        #"(?i)\b(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{8,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    ]

    static func sanitize(_ text: String) -> (text: String, redacted: Bool) {
        var output = text
        var redacted = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            if regex.firstMatch(in: output, range: range) != nil {
                redacted = true
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: range,
                    withTemplate: "[REDACTED_SECRET]"
                )
            }
        }
        return (output, redacted)
    }
}

enum AgentMemoryEngine {
    static func projectFingerprint(for rootDirectory: URL?) -> String? {
        guard let path = rootDirectory?.standardizedFileURL.path, !path.isEmpty else { return nil }
        return fnv1a64(path)
    }

    static func retrieve(
        query: String,
        records: [AgentMemoryRecord],
        settings: AgentMemorySettings,
        rootDirectory: URL?,
        openedFileURL: URL?,
        selectedText: String = "",
        now: Date = Date()
    ) -> [AgentMemoryRetrievalResult] {
        guard settings.isMemoryEnabled, settings.autoRetrievalEnabled else { return [] }
        let projectID = projectFingerprint(for: rootDirectory)
        let queryText = [
            query,
            openedFileURL?.lastPathComponent ?? "",
            openedFileURL?.pathComponents.suffix(3).joined(separator: " ") ?? "",
            selectedText
        ].joined(separator: " ")
        let queryTokens = Set(AgentMemoryKeywordExtractor.tokens(from: queryText))
        guard !queryTokens.isEmpty else { return [] }

        return records
            .map(\.normalized)
            .filter { !$0.isArchived }
            .filter { applies($0, projectID: projectID) }
            .compactMap { record -> AgentMemoryRetrievalResult? in
                let result = score(record, queryTokens: queryTokens, queryText: queryText, now: now)
                guard result.score >= settings.similarityThreshold else { return nil }
                return AgentMemoryRetrievalResult(record: record, score: result.score, reasons: result.reasons)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.record.updatedAt > rhs.record.updatedAt
            }
            .prefix(settings.maxRetrievedMemories)
            .map { $0 }
    }

    static func contextBlock(for results: [AgentMemoryRetrievalResult]) -> String? {
        guard !results.isEmpty else { return nil }
        var lines = [
            "Relevant long-term Agent memories:",
            "Use these as durable user/project context. They may be stale; prefer current files and explicit user instructions when they conflict."
        ]
        for (index, result) in results.enumerated() {
            let record = result.record
            let topics = record.topics.isEmpty ? "" : " topics=\(record.topics.prefix(5).joined(separator: ","))"
            let sensitive = record.containsSensitiveContent ? " sensitive=redacted" : ""
            lines.append(
                "\(index + 1). [\(record.scope.rawValue) score=\(String(format: "%.2f", result.score))\(topics)\(sensitive)] \(record.content)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func candidates(
        fromUser userText: String,
        assistantText: String,
        rootDirectory: URL?,
        now: Date = Date()
    ) -> [AgentMemoryRecord] {
        let projectID = projectFingerprint(for: rootDirectory)
        let chunks = candidateSentences(from: userText) + candidateSentences(from: assistantText)
        var seen = Set<String>()
        return chunks.compactMap { raw in
            let sanitized = AgentMemorySanitizer.sanitize(raw)
            let content = sanitized.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.count >= 18 else { return nil }
            let key = normalizedKey(content)
            guard seen.insert(key).inserted else { return nil }
            let isProjectScoped = projectID != nil && looksProjectScoped(content)
            return AgentMemoryRecord(
                content: content,
                source: .automatic,
                lifetime: .longTerm,
                scope: isProjectScoped ? .project : .global,
                projectFingerprint: isProjectScoped ? projectID : nil,
                topics: AgentMemoryKeywordExtractor.keywords(from: content, limit: 8),
                confidence: confidence(for: content),
                containsSensitiveContent: sanitized.redacted,
                provenance: "auto-extracted",
                createdAt: now,
                updatedAt: now
            ).normalized
        }
    }

    static func mergedRecords(_ records: [AgentMemoryRecord], now: Date = Date()) -> (records: [AgentMemoryRecord], mergedCount: Int) {
        var buckets: [String: AgentMemoryRecord] = [:]
        var mergedCount = 0
        for record in records.map(\.normalized) {
            let key = mergeKey(for: record)
            guard var existing = buckets[key] else {
                buckets[key] = record
                continue
            }
            mergedCount += 1
            if record.updatedAt > existing.updatedAt || record.confidence > existing.confidence {
                existing.content = record.content
            }
            existing.updatedAt = max(existing.updatedAt, record.updatedAt)
            existing.createdAt = min(existing.createdAt, record.createdAt)
            existing.accessCount += record.accessCount
            existing.lastAccessedAt = [existing.lastAccessedAt, record.lastAccessedAt].compactMap { $0 }.max()
            existing.confidence = max(existing.confidence, record.confidence)
            existing.containsSensitiveContent = existing.containsSensitiveContent || record.containsSensitiveContent
            existing.topics = AgentMemoryKeywordExtractor.keywords(
                from: (existing.topics + record.topics).joined(separator: " ") + " " + existing.content,
                limit: 8
            )
            if existing.archivedAt != nil || record.archivedAt != nil {
                existing.archivedAt = existing.archivedAt == nil || record.archivedAt == nil
                    ? nil
                    : max(existing.archivedAt!, record.archivedAt!)
            }
            existing.updatedAt = max(existing.updatedAt, now)
            buckets[key] = existing.normalized
        }
        let sorted = buckets.values.sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
            return lhs.updatedAt > rhs.updatedAt
        }
        return (sorted, mergedCount)
    }

    private static func applies(_ record: AgentMemoryRecord, projectID: String?) -> Bool {
        switch record.scope {
        case .global:
            return true
        case .project:
            return record.projectFingerprint != nil && record.projectFingerprint == projectID
        }
    }

    private static func score(
        _ record: AgentMemoryRecord,
        queryTokens: Set<String>,
        queryText: String,
        now: Date
    ) -> (score: Double, reasons: [String]) {
        let recordTokens = Set(AgentMemoryKeywordExtractor.tokens(from: record.content + " " + record.topics.joined(separator: " ")))
        guard !recordTokens.isEmpty else { return (0, []) }
        let overlap = queryTokens.intersection(recordTokens)
        let union = queryTokens.union(recordTokens)
        var score = Double(overlap.count) / Double(max(1, union.count))
        var reasons: [String] = []
        if !overlap.isEmpty {
            reasons.append("matched \(overlap.prefix(4).joined(separator: ","))")
        }
        if queryText.localizedCaseInsensitiveContains(record.content) || record.content.localizedCaseInsensitiveContains(queryText) {
            score += 0.25
            reasons.append("phrase")
        }
        if record.scope == .project {
            score += 0.08
            reasons.append("project")
        }
        if record.lifetime == .longTerm {
            score += 0.04
        }
        if record.source == .manual {
            score += 0.06
            reasons.append("manual")
        }
        if record.accessCount > 0 {
            score += min(0.08, Double(record.accessCount) * 0.01)
        }
        let ageDays = max(0, now.timeIntervalSince(record.updatedAt) / 86_400)
        score += max(0, 0.06 - min(0.06, ageDays / 365.0 * 0.06))
        score *= max(0.2, record.confidence)
        return (min(1, score), reasons.isEmpty ? ["semantic"] : reasons)
    }

    private static func candidateSentences(from text: String) -> [String] {
        let markers = [
            "remember", "记住", "以后", "always", "never", "must", "should",
            "prefer", "use ", "don't", "不要", "必须", "统一", "规则", "约定",
            "希望", "默认", "优先", "每次", "下次", "遇到", "自动", "自主",
            "workflow", "skill", "mcp", "whenever", "next time", "by default"
        ]
        return text
            .components(separatedBy: CharacterSet(charactersIn: "\n。.!?；;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { sentence in
                let lower = sentence.lowercased()
                return markers.contains { lower.contains($0) }
            }
            .map { sentence in
                sentence.count > 260 ? String(sentence.prefix(260)) : sentence
            }
    }

    private static func looksProjectScoped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("repo")
            || lower.contains("project")
            || lower.contains("workspace")
            || lower.contains("仓库")
            || lower.contains("项目")
            || lower.contains("版本")
            || lower.contains("changelog")
            || lower.contains("测试")
    }

    private static func confidence(for text: String) -> Double {
        let lower = text.lowercased()
        if lower.contains("记住") || lower.contains("remember") { return 0.95 }
        if lower.contains("must") || lower.contains("必须") || lower.contains("永远") { return 0.88 }
        if lower.contains("should") || lower.contains("prefer") || lower.contains("尽量") { return 0.74 }
        return 0.62
    }

    private static func mergeKey(for record: AgentMemoryRecord) -> String {
        "\(record.scope.rawValue):\(record.projectFingerprint ?? "_"):\(normalizedKey(record.content))"
    }

    private static func normalizedKey(_ text: String) -> String {
        AgentMemoryKeywordExtractor
            .tokens(from: text)
            .prefix(16)
            .joined(separator: " ")
    }

    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
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

    func addMemory(
        content: String,
        source: AgentMemorySource = .manual,
        lifetime: AgentMemoryLifetime = .longTerm,
        scope: AgentMemoryScope = .global,
        rootDirectory: URL? = nil
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        let projectID = scope == .project ? AgentMemoryEngine.projectFingerprint(for: rootDirectory) : nil
        memories.insert(
            AgentMemoryRecord(
                content: trimmed,
                source: source,
                lifetime: lifetime,
                scope: projectID == nil && scope == .project ? .global : scope,
                projectFingerprint: projectID,
                topics: AgentMemoryKeywordExtractor.keywords(from: trimmed, limit: 8),
                confidence: source == .manual ? 1.0 : 0.7,
                createdAt: now,
                updatedAt: now
            ).normalized,
            at: 0
        )
    }

    func addMemory(_ record: AgentMemoryRecord) {
        let normalized = record.normalized
        guard !normalized.content.isEmpty else { return }
        memories.insert(normalized, at: 0)
        mergeDuplicateMemories()
    }

    func addAutomaticMemories(
        fromUser userText: String,
        assistantText: String,
        rootDirectory: URL?,
        now: Date = Date()
    ) {
        guard settings.normalized.isMemoryEnabled, settings.normalized.autoSummaryEnabled else { return }
        let candidates = AgentMemoryEngine.candidates(
            fromUser: userText,
            assistantText: assistantText,
            rootDirectory: rootDirectory,
            now: now
        )
        guard !candidates.isEmpty else { return }
        memories = (candidates + memories).deduplicatedByMemoryID()
        mergeDuplicateMemories(now: now)
    }

    func updateMemory(
        id: AgentMemoryRecord.ID,
        content: String,
        lifetime: AgentMemoryLifetime,
        scope: AgentMemoryScope? = nil,
        rootDirectory: URL? = nil
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].content = trimmed
        memories[index].lifetime = lifetime
        if let scope {
            memories[index].scope = scope
            switch scope {
            case .global:
                memories[index].projectFingerprint = nil
            case .project:
                memories[index].projectFingerprint = AgentMemoryEngine.projectFingerprint(for: rootDirectory)
                    ?? memories[index].projectFingerprint
                if memories[index].projectFingerprint == nil {
                    memories[index].scope = .global
                }
            }
        }
        memories[index].updatedAt = Date()
        memories[index] = memories[index].normalized
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

    func retrieveMemories(
        query: String,
        rootDirectory: URL?,
        openedFileURL: URL?,
        selectedText: String = "",
        now: Date = Date()
    ) -> [AgentMemoryRetrievalResult] {
        let results = AgentMemoryEngine.retrieve(
            query: query,
            records: memories,
            settings: settings.normalized,
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            selectedText: selectedText,
            now: now
        )
        markAccessed(ids: results.map(\.record.id), now: now)
        return results
    }

    func markAccessed(ids: [AgentMemoryRecord.ID], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var changed = false
        for index in memories.indices where idSet.contains(memories[index].id) {
            memories[index].lastAccessedAt = now
            memories[index].accessCount += 1
            changed = true
        }
        if changed {
            AgentMemorySettingsStore.saveRecords(memories)
            objectWillChange.send()
        }
    }

    func mergeDuplicateMemories(now: Date = Date()) {
        let merged = AgentMemoryEngine.mergedRecords(memories, now: now)
        memories = merged.records
    }

    func runMaintenance(preview: Bool = false, now: Date = Date(), calendar: Calendar = .current) {
        let normalizedSettings = settings.normalized
        var nextRecords = memories
        let transientCutoff = calendar.date(byAdding: .day, value: -normalizedSettings.transientTTLDays, to: now) ?? now
        let archiveCutoff = calendar.date(byAdding: .day, value: -normalizedSettings.archiveRetentionDays, to: now) ?? now
        var archivedCount = 0
        var removedExpiredCount = 0
        var mergedCount = 0

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
            let merged = AgentMemoryEngine.mergedRecords(nextRecords, now: now)
            nextRecords = merged.records
            mergedCount = merged.mergedCount
            memories = nextRecords
        } else {
            archivedCount = nextRecords.filter {
                $0.lifetime == .transient && $0.archivedAt == nil && $0.updatedAt < transientCutoff
            }.count
            removedExpiredCount = nextRecords.filter {
                guard let archivedAt = $0.archivedAt else { return false }
                return archivedAt < archiveCutoff
            }.count
            mergedCount = AgentMemoryEngine.mergedRecords(nextRecords, now: now).mergedCount
        }

        settings.lastMaintenanceRun = AgentMemoryMaintenanceRun(
            ranAt: now,
            status: preview ? .preview : .completed,
            inspectedCount: nextRecords.count,
            archivedCount: archivedCount,
            removedExpiredCount: removedExpiredCount,
            mergedCount: mergedCount,
            inputTokens: 0,
            outputTokens: 0
        )
    }
}

private extension Array where Element == AgentMemoryRecord {
    func deduplicatedByMemoryID() -> [AgentMemoryRecord] {
        var seen = Set<AgentMemoryRecord.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}
