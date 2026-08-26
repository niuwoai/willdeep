//
//  AgentSkillWorkerKPITests.swift
//  WillDeepTests
//
//  Deliberately its own @Suite rather than an extension on the aggregate
//  WillDeepTests: a function-level -only-testing against that aggregate has
//  silently matched zero tests and still reported TEST SUCCEEDED, which is
//  the worst possible outcome for a metric whose whole job is to be trusted.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
nonisolated struct AgentSkillWorkerKPITests {
    @Test("deep share counts against delegated runs, not parent turns")
    func deepShareDenominatorIsChildRunsOnly() {
        var kpis = AgentSkillWorkerKPIs()
        kpis.narrowRunCount = 19
        kpis.deepRunCount = 1
        // A busy session with many inline parent turns must not dilute the
        // number into looking healthy: the question is "of the work that was
        // delegated, how much needed the expensive tier", and a parent turn
        // was never a candidate for the 1M tier at all.
        kpis.parentTurnCount = 500

        #expect(kpis.deepShare == 0.05)
        // Same inputs, different question — skillCoverage does count parent
        // turns, because it asks how much work went somewhere cheaper.
        #expect(kpis.skillCoverage != kpis.deepShare)
    }

    @Test("deep share matches the willdeep-rs agent-metrics denominator")
    func deepShareIsComparableWithTheCLI() {
        // rs computes `deep / children.len()`. In WillDeep every child run is
        // either deep or narrow, so narrow + deep is the same denominator and
        // the two clients' numbers can be put side by side.
        var kpis = AgentSkillWorkerKPIs()
        kpis.narrowRunCount = 3
        kpis.deepRunCount = 1

        #expect(kpis.deepShare == 0.25)
    }

    @Test("no delegated runs reports no data rather than a healthy zero")
    func deepShareIsNilWithoutRuns() {
        var kpis = AgentSkillWorkerKPIs()
        kpis.parentTurnCount = 40

        // 0% here would read as "the scarce tier is under control" when in
        // fact nothing was delegated at all.
        #expect(kpis.deepShare == nil)
    }

    @Test("a session that only used deep reports 100%")
    func deepShareSaturates() {
        var kpis = AgentSkillWorkerKPIs()
        kpis.deepRunCount = 4

        #expect(kpis.deepShare == 1.0)
    }

    @Test("automatic coding separates straight-through delivery from parent rework")
    func codingQualityRatesUseAutomaticRuns() {
        var kpis = AgentSkillWorkerKPIs()
        kpis.automaticCodingRunCount = 10
        kpis.straightThroughDeliveryCount = 7
        kpis.parentRepairCodingRunCount = 2

        #expect(kpis.straightThroughRate == 0.7)
        #expect(kpis.codingReworkRate == 0.2)
    }

    @Test("coding quality rates show no data before the lane runs")
    func codingQualityRatesAreNilWithoutRuns() {
        let kpis = AgentSkillWorkerKPIs()

        #expect(kpis.straightThroughRate == nil)
        #expect(kpis.codingReworkRate == nil)
    }
}
