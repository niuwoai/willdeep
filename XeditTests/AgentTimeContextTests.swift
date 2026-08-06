import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentTimeContextTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-08-06 08:06:47 UTC == 16:06:47 in Shanghai — the exact skew from
    // the report, where the model told a UTC+8 user it was 08:06.
    private let moment = Date(timeIntervalSince1970: 1_786_003_607)

    // MARK: Local time

    @Test("the stamp is rendered in the user's zone, not UTC")
    func stampUsesLocalZone() {
        let block = AgentTimeContext.block(now: moment, timeZone: shanghai)

        #expect(block.contains("16:06:47"))
        #expect(!block.contains("08:06:47"))
    }

    @Test("the same instant renders differently per zone")
    func sameInstantDiffersByZone() {
        let local = AgentTimeContext.block(now: moment, timeZone: shanghai)
        let atUTC = AgentTimeContext.block(now: moment, timeZone: utc)

        #expect(local != atUTC)
        #expect(atUTC.contains("08:06:47"))
    }

    @Test("the zone is named and its offset spelled out")
    func zoneIsIdentified() {
        let block = AgentTimeContext.block(now: moment, timeZone: shanghai)

        #expect(block.contains("Asia/Shanghai"))
        #expect(block.contains("UTC+8"))
        // The numeric offset also rides on the stamp itself.
        #expect(block.contains("+08:00"))
    }

    // MARK: Offsets

    @Test("offsets cover whole hours, half hours, west of UTC, and UTC itself")
    func offsetFormatting() {
        #expect(AgentTimeContext.offsetDescription(for: utc, at: moment) == "UTC+0")
        #expect(AgentTimeContext.offsetDescription(for: shanghai, at: moment) == "UTC+8")

        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        #expect(AgentTimeContext.offsetDescription(for: kolkata, at: moment) == "UTC+5:30")

        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(AgentTimeContext.offsetDescription(for: newYork, at: moment).hasPrefix("UTC-"))

        // Half-hour offsets west of UTC keep both sign and minutes.
        let marquesas = TimeZone(identifier: "Pacific/Marquesas")!
        #expect(AgentTimeContext.offsetDescription(for: marquesas, at: moment) == "UTC-9:30")
    }

    @Test("daylight saving is resolved for the given instant, not assumed")
    func offsetFollowsDST() {
        let newYork = TimeZone(identifier: "America/New_York")!
        // 2026-01-15 (EST) vs 2026-07-15 (EDT).
        let winter = Date(timeIntervalSince1970: 1_768_478_400)
        let summer = Date(timeIntervalSince1970: 1_784_073_600)

        #expect(AgentTimeContext.offsetDescription(for: newYork, at: winter) == "UTC-5")
        #expect(AgentTimeContext.offsetDescription(for: newYork, at: summer) == "UTC-4")
    }

    // MARK: Instructions

    @Test("the block tells the model to convert rather than parrot UTC logs")
    func blockCarriesConversionRules() {
        let block = AgentTimeContext.block(now: moment, timeZone: shanghai)

        // The actual failure was a UTC server timestamp repeated verbatim.
        #expect(block.contains("UTC"))
        #expect(block.lowercased().contains("convert"))
        // And durations computed across mixed zones.
        #expect(block.lowercased().contains("same zone"))
        // The stamp is turn-start, not live — say so rather than let the
        // model extrapolate a countdown from a stale clock.
        #expect(block.lowercased().contains("start of the turn"))
    }

    @Test("the format is locale-independent")
    func formatIsStableAcrossLocales() {
        // A model reads this, so it must not shift shape with the host
        // locale (e.g. Arabic-Indic digits or a 12-hour clock).
        let block = AgentTimeContext.block(now: moment, timeZone: shanghai)

        #expect(block.contains("2026-08-06 16:06:47"))
        #expect(!block.contains("PM"))
        #expect(!block.contains("下午"))
    }

    // MARK: Cache safety

    @Test("the clock lands in per-turn context, never the cached prefix")
    func timeStaysOutOfStablePrefix() {
        let assembled = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true
        )
        let components = AgentContextBuilder.requestComponents(from: assembled)

        // Putting a per-second value in the stable prefix would invalidate
        // the provider prompt cache on every single request.
        #expect(!components.systemPrompt.contains("Current time and timezone"))
        #expect(components.turnContext.contains("Current time and timezone"))
    }
}
