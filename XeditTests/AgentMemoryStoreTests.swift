//
//  AgentMemoryStoreTests.swift
//  VeilWriterTests
//
//  Covers local Agent memory settings and record helpers.
//

import Foundation
import Testing
@testable import VeilWriter

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
        #expect(record.matches("quickdbm"))
        #expect(record.matches("SCHEMA"))
        #expect(!record.matches("unrelated"))
    }
}
