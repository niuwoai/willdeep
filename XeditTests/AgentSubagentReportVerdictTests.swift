//
//  AgentSubagentReportVerdictTests.swift
//  XeditTests
//
//  The gate and the parsing around `judge`'s first real job. The model call
//  itself is not exercised here — what these lock down is when it is allowed
//  to happen at all (an infinite regress lives one wrong condition away) and
//  what reaches the parent when it does.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentSubagentReportVerdictTests {

    private let report = String(repeating: "The retry path is set in AppState.swift. ", count: 6)

    // MARK: - When it may run

    @Test
    func judgesOnlyReportOnlyRuns() {
        #expect(AgentSubagentReportVerdict.shouldJudge(
            profileID: AgentSubagentProfileCatalog.scoutID,
            verifierPassed: nil,
            report: report,
            isEnabled: true
        ))

        // A verifier's exit code is a better judge than any model — both a
        // pass and a fail already decided the run.
        for verified in [true, false] {
            #expect(!AgentSubagentReportVerdict.shouldJudge(
                profileID: AgentSubagentProfileCatalog.testFixerID,
                verifierPassed: verified,
                report: report,
                isEnabled: true
            ))
        }
    }

    /// The condition an infinite regress hides behind: `judge` runs are
    /// report-only too, so judging them would call this forever.
    @Test
    func neverJudgesTheJudge() {
        #expect(!AgentSubagentReportVerdict.shouldJudge(
            profileID: AgentSubagentProfileCatalog.judgeID,
            verifierPassed: nil,
            report: report,
            isEnabled: true
        ))
    }

    @Test
    func skipsWhatIsNotWorthAModelCall() {
        // Disabled by the user.
        #expect(!AgentSubagentReportVerdict.shouldJudge(
            profileID: AgentSubagentProfileCatalog.scoutID,
            verifierPassed: nil,
            report: report,
            isEnabled: false
        ))
        // Too short to contain a claim.
        #expect(!AgentSubagentReportVerdict.shouldJudge(
            profileID: AgentSubagentProfileCatalog.scoutID,
            verifierPassed: nil,
            report: "Found it.",
            isEnabled: true
        ))
        #expect(!AgentSubagentReportVerdict.shouldJudge(
            profileID: AgentSubagentProfileCatalog.scoutID,
            verifierPassed: nil,
            report: "   ",
            isEnabled: true
        ))
    }

    // MARK: - What reaches the parent

    @Test
    func passingVerdictStaysOneLine() {
        let result = AgentSubagentReportVerdict.decode(
            #"{"verdict":"supported","reason":""}"#
        )

        #expect(result?.note == "<report-check verdict=\"supported\" />")
    }

    @Test
    func failingVerdictCarriesTheReasonAndItsOwnLimits() {
        let decoded = AgentSubagentReportVerdict.decode(
            #"{"verdict":"unsupported","reason":"The 30s timeout claim cites no location."}"#
        )
        let note = try! #require(decoded).note

        #expect(note.contains("verdict=\"unsupported\""))
        #expect(note.contains("The 30s timeout claim cites no location."))
        // The parent must not read this as a file-level finding.
        #expect(note.contains("no files were opened"))
    }

    @Test
    func rejectsVerdictsTheParentCouldNotActOn() {
        // An accusation with no reason is worse than silence.
        #expect(AgentSubagentReportVerdict.decode(#"{"verdict":"unsupported","reason":"  "}"#) == nil)
        #expect(AgentSubagentReportVerdict.decode(#"{"verdict":"off_topic","reason":""}"#) == nil)
        // Unknown verdicts, malformed payloads and prose are all dropped.
        #expect(AgentSubagentReportVerdict.decode(#"{"verdict":"maybe","reason":"hmm"}"#) == nil)
        #expect(AgentSubagentReportVerdict.decode("not json at all") == nil)
        #expect(AgentSubagentReportVerdict.decode("") == nil)
        // A passing verdict needs no reason.
        #expect(AgentSubagentReportVerdict.decode(#"{"verdict":"supported","reason":""}"#) != nil)
    }

    // MARK: - Prompt

    @Test
    func promptClampsBothHalvesAndStatesTheHonestBlockerRule() {
        let hugeTask = String(repeating: "t", count: 5_000)
        let hugeReport = String(repeating: "r", count: 20_000)
        let prompt = AgentSubagentReportVerdict.prompt(task: hugeTask, report: hugeReport)

        #expect(prompt.count < hugeTask.count + hugeReport.count)
        #expect(prompt.contains("…(trimmed)"))
        // A worker that reports a blocker honestly has answered the task;
        // without this the judge marks every honest "I could not" as a miss.
        #expect(prompt.lowercased().contains("blocker"))
        #expect(prompt.contains("off_topic"))
    }
}
