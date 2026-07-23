//
//  AgentMemoryStoreTests.swift
//  WillDeepTests
//
//  Covers local Agent memory settings and record helpers.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentMemoryStoreTests {
    @Test
    func settingsNormalizeClampsUserTunableValues() {
        let settings = AgentMemorySettings(
            isMemoryEnabled: true,
            autoRetrievalEnabled: true,
            queryRewriteEnabled: true,
            maxRetrievedMemories: 99,
            similarityThreshold: -0.4,
            autoSummaryEnabled: true,
            dailyMaintenanceEnabled: true,
            maintenanceHour: 77,
            maintenanceMinute: -8,
            transientTTLDays: 0,
            archiveRetentionDays: 0,
            toolModelID: "  deepseek-v4-pro  ",
            embeddingModelID: "  text-embedding-3-small  ",
            lastMaintenanceRun: nil
        ).normalized

        #expect(settings.maxRetrievedMemories == 20)
        #expect(settings.similarityThreshold == 0)
        #expect(settings.maintenanceHour == 23)
        #expect(settings.maintenanceMinute == 0)
        #expect(settings.transientTTLDays == 1)
        #expect(settings.archiveRetentionDays == 1)
        #expect(settings.toolModelID == "deepseek-v4-pro")
        #expect(settings.embeddingModelID == "text-embedding-3-small")
    }

    @Test
    func nextMaintenanceDateUsesConfiguredLocalTime() throws {
        var settings = AgentMemorySettings.default
        settings.maintenanceHour = 3
        settings.maintenanceMinute = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 4, minute: 0)))
        let next = try #require(settings.nextMaintenanceDate(after: start, calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)

        #expect(components.year == 2026)
        #expect(components.month == 6)
        #expect(components.day == 4)
        #expect(components.hour == 3)
        #expect(components.minute == 15)
    }

    @Test
    func memoryRecordNormalizesAndMatchesCaseInsensitively() {
        let record = AgentMemoryRecord(
            content: "  QuickDBM manages schema design sessions.  ",
            source: .manual,
            lifetime: .longTerm,
            accessCount: -3
        ).normalized

        #expect(record.content == "QuickDBM manages schema design sessions.")
        #expect(record.accessCount == 0)
        #expect(record.scope == .global)
        #expect(record.confidence == 1)
        #expect(record.topics.contains("quickdbm"))
        #expect(record.matches("quickdbm"))
        #expect(record.matches("SCHEMA"))
        #expect(!record.matches("unrelated"))
    }

    @Test
    func sanitizerRedactsSecretShapedMemoryContent() {
        let record = AgentMemoryRecord(
            content: "Use Authorization=Bearer abcdefghijklmnopqrstuvwxyz for the private proxy.",
            source: .manual
        ).normalized

        #expect(record.containsSensitiveContent)
        #expect(record.content.contains("[REDACTED_SECRET]"))
        #expect(!record.content.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    @Test
    func retrievalRespectsProjectScopeAndRanksRelevantMemories() throws {
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let other = URL(fileURLWithPath: "/tmp/OtherProject")
        let projectID = try #require(AgentMemoryEngine.projectFingerprint(for: root))
        let otherID = try #require(AgentMemoryEngine.projectFingerprint(for: other))
        let settings = AgentMemorySettings.default
        let records = [
            AgentMemoryRecord(
                content: "This project must use yarn for package scripts and release checks.",
                source: .manual,
                scope: .project,
                projectFingerprint: projectID
            ),
            AgentMemoryRecord(
                content: "Other project uses npm and pnpm interchangeably.",
                source: .manual,
                scope: .project,
                projectFingerprint: otherID
            ),
            AgentMemoryRecord(
                content: "User prefers concise Simplified Chinese responses.",
                source: .manual,
                scope: .global
            )
        ]

        let results = AgentMemoryEngine.retrieve(
            query: "run yarn test for this release",
            records: records,
            settings: settings,
            rootDirectory: root,
            openedFileURL: root.appendingPathComponent("package.json")
        )

        #expect(results.map(\.record.content).contains("This project must use yarn for package scripts and release checks."))
        #expect(!results.map(\.record.content).contains("Other project uses npm and pnpm interchangeably."))
        #expect(results.first?.record.projectFingerprint == projectID)
    }

    @Test
    func contextBlockIncludesCompactMetadata() {
        let record = AgentMemoryRecord(
            content: "Always update CHANGELOG when version changes.",
            source: .manual,
            scope: .project,
            projectFingerprint: "abc",
            topics: ["changelog", "version"],
            containsSensitiveContent: true
        )
        let block = AgentMemoryEngine.contextBlock(for: [
            AgentMemoryRetrievalResult(record: record.normalized, score: 0.42, reasons: ["manual"])
        ])

        #expect(block?.contains("Relevant long-term Agent memories") == true)
        #expect(block?.contains("score=0.42") == true)
        #expect(block?.contains("topics=") == true)
        #expect(block?.contains("changelog") == true)
        #expect(block?.contains("version") == true)
        #expect(block?.contains("sensitive=redacted") == true)
    }

    @Test
    func automaticCandidatesExtractDurableRules() throws {
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let projectID = try #require(AgentMemoryEngine.projectFingerprint(for: root))
        let records = AgentMemoryEngine.candidates(
            fromUser: "记住：这个项目每次改代码必须同步更新 CHANGELOG 和版本号。",
            rootDirectory: root
        )

        #expect(records.contains { $0.content.contains("CHANGELOG") })
        let projectRecord = try #require(records.first { $0.content.contains("CHANGELOG") })
        #expect(projectRecord.scope == .project)
        #expect(projectRecord.projectFingerprint == projectID)
        #expect(projectRecord.confidence >= 0.8)
    }

    @Test @MainActor
    func manualProjectScopedMemoryStoresFingerprintAndAccessStats() throws {
        let root = URL(fileURLWithPath: "/tmp/WillDeepProject")
        let projectID = try #require(AgentMemoryEngine.projectFingerprint(for: root))
        let state = AgentMemoryState(settings: .default, memories: [])

        state.addMemory(
            content: "This project must use yarn for all package scripts.",
            lifetime: .longTerm,
            scope: .project,
            rootDirectory: root
        )

        let memory = try #require(state.memories.first)
        #expect(memory.scope == .project)
        #expect(memory.projectFingerprint == projectID)

        let results = state.retrieveMemories(
            query: "run yarn build",
            rootDirectory: root,
            openedFileURL: root.appendingPathComponent("package.json")
        )

        #expect(results.count == 1)
        #expect(state.memories.first?.accessCount == 1)
        #expect(state.memories.first?.lastAccessedAt != nil)
    }

    @Test @MainActor
    func maintenanceMergesDuplicateMemories() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AgentMemoryState(
            settings: .default,
            memories: [
                AgentMemoryRecord(
                    content: "Always update changelog when bumping version.",
                    source: .manual,
                    createdAt: now.addingTimeInterval(-20),
                    updatedAt: now.addingTimeInterval(-20)
                ),
                AgentMemoryRecord(
                    content: "Always update changelog when bumping version.",
                    source: .automatic,
                    createdAt: now.addingTimeInterval(-10),
                    updatedAt: now.addingTimeInterval(-10)
                )
            ]
        )

        state.runMaintenance(now: now)

        #expect(state.memories.count == 1)
        #expect(state.settings.lastMaintenanceRun?.mergedCount == 1)
    }

    @Test
    func mergingDuplicateMemoriesKeepsActiveCopyActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = AgentMemoryRecord(
            content: "Always use yarn for this project.",
            source: .manual,
            updatedAt: now
        )
        let archived = AgentMemoryRecord(
            content: "Always use yarn for this project.",
            source: .automatic,
            updatedAt: now.addingTimeInterval(-10),
            archivedAt: now.addingTimeInterval(-5)
        )

        let merged = AgentMemoryEngine.mergedRecords([archived, active], now: now)

        #expect(merged.records.count == 1)
        #expect(merged.records.first?.archivedAt == nil)
    }
}
