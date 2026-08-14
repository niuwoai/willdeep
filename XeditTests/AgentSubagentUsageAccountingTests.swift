//
//  AgentSubagentUsageAccountingTests.swift
//  WillDeepTests
//
//  Worker accounting (skill-workers.v1 Phase 0): tokens spent inside a
//  `spawn_agent` child loop must reach the stats dashboard billed to the
//  model the child ran on. Before this, worker tokens were recorded only in
//  the transcript sidecar, so a cheap trade looked free.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSubagentUsageAccountingTests {
    private func session(
        modelID: String?,
        providerID: String?,
        messages: [AgentMessage]
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            title: "worker accounting",
            workspaceRootPath: nil,
            modelID: modelID,
            providerID: providerID,
            providerDisplayName: nil,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_100),
            messages: messages
        )
    }

    private func spawnMessage(
        usage: AgentSubagentRunUsage?,
        parentPrompt: Int = 1_000,
        parentCompletion: Int = 200
    ) -> AgentMessage {
        let runID = UUID()
        var call = AgentMessageToolCall(
            externalID: "call_1",
            toolName: "spawn_agent",
            argumentsJSON: #"{"prompt":"go","profile":"scout"}"#,
            subagentRunID: runID
        )
        call.subagentUsage = usage
        var message = AgentMessage(role: .assistant, content: "spawning", toolCalls: [call])
        message.promptTokens = parentPrompt
        message.completionTokens = parentCompletion
        message.usageTokens = parentPrompt + parentCompletion
        message.requestModelID = "claude-opus-5"
        message.requestProviderID = "claude"
        return message
    }

    // MARK: Attribution

    @Test("worker tokens bill to the worker's model, not the parent's")
    func workerTokensBillToWorkerModel() {
        let usage = AgentSubagentRunUsage(
            profileID: "scout",
            model: "glm-5",
            providerID: "some-im",
            usageTokens: 42_000,
            promptTokens: 40_000,
            completionTokens: 2_000,
            roundCount: 6,
            toolInvocationCount: 9
        )
        let rows = AgentUsageStats.modelUsage(for: [
            session(modelID: "claude-opus-5", providerID: "claude", messages: [spawnMessage(usage: usage)])
        ])

        let worker = rows.first { $0.modelID == "glm-5" }
        let parent = rows.first { $0.modelID == "claude-opus-5" }

        // Two distinct rows: the cheap tier only proves its worth if its
        // tokens are visible somewhere other than the expensive model's row.
        #expect(worker?.promptTokens == 40_000)
        #expect(worker?.completionTokens == 2_000)
        #expect(worker?.totalTokens == 42_000)
        #expect(worker?.providerID == "some-im")
        #expect(parent?.promptTokens == 1_000)
        #expect(parent?.completionTokens == 200)
    }

    @Test("a worker on the parent's model merges into that one row")
    func workerOnSameModelMergesRows() {
        let usage = AgentSubagentRunUsage(
            profileID: "deep",
            model: "claude-opus-5",
            providerID: "claude",
            usageTokens: 5_500,
            promptTokens: 5_000,
            completionTokens: 500
        )
        let rows = AgentUsageStats.modelUsage(for: [
            session(modelID: "claude-opus-5", providerID: "claude", messages: [spawnMessage(usage: usage)])
        ])

        #expect(rows.count == 1)
        #expect(rows.first?.promptTokens == 6_000)
        #expect(rows.first?.completionTokens == 700)
    }

    @Test("a run reporting only a total is counted and flagged as estimated")
    func totalOnlyRunIsFlaggedEstimated() throws {
        let usage = AgentSubagentRunUsage(
            profileID: "reader",
            model: "glm-5",
            providerID: "some-im",
            usageTokens: 3_000
        )
        let rows = AgentUsageStats.modelUsage(for: [
            session(modelID: "claude-opus-5", providerID: "claude", messages: [spawnMessage(usage: usage)])
        ])

        let worker = try #require(rows.first { $0.modelID == "glm-5" })
        #expect(worker.totalTokens == 3_000)
        #expect(worker.hasEstimatedUsage)
        #expect(worker.estimatedTokens == 3_000)
    }

    @Test("sessions recorded before worker accounting report only parent usage")
    func legacySessionsCountOnlyTheParent() {
        let rows = AgentUsageStats.modelUsage(for: [
            session(modelID: "claude-opus-5", providerID: "claude", messages: [spawnMessage(usage: nil)])
        ])

        #expect(rows.count == 1)
        #expect(rows.first?.modelID == "claude-opus-5")
        #expect(rows.first?.totalTokens == 1_200)
    }

    // MARK: Snapshot plumbing

    @Test("the usage snapshot carries run summaries off the tool call")
    func snapshotCarriesRunSummaries() {
        let usage = AgentSubagentRunUsage(
            profileID: "test_fixer",
            model: "glm-5",
            providerID: "some-im",
            usageTokens: 12_000,
            promptTokens: 11_000,
            completionTokens: 1_000,
            escalatedFromModel: "glm-5-air",
            verifierPassed: true
        )
        let snapshot = AgentUsageSessionSnapshot(
            session: session(
                modelID: "claude-opus-5",
                providerID: "claude",
                messages: [spawnMessage(usage: usage)]
            )
        )

        let runs = snapshot.messages.flatMap(\.subagentRuns)
        #expect(runs.count == 1)
        #expect(runs.first?.profileID == "test_fixer")
        #expect(runs.first?.verifierPassed == true)
        #expect(runs.first?.escalatedFromModel == "glm-5-air")
    }

    // MARK: Phase 0 KPIs

    private func run(
        profileID: String,
        verifierPassed: Bool? = nil,
        escalatedFrom: String? = nil
    ) -> AgentSubagentRunUsage {
        AgentSubagentRunUsage(
            profileID: profileID,
            model: "glm-5",
            providerID: "some-im",
            usageTokens: 1_000,
            promptTokens: 900,
            completionTokens: 100,
            escalatedFromModel: escalatedFrom,
            verifierPassed: verifierPassed
        )
    }

    private func kpis(runs: [AgentSubagentRunUsage], parentTurns: Int) -> AgentSkillWorkerKPIs {
        var messages: [AgentMessage] = (0..<parentTurns).map { index in
            AgentMessage(role: .assistant, content: "turn \(index)")
        }
        if !runs.isEmpty {
            let calls = runs.enumerated().map { offset, usage -> AgentMessageToolCall in
                var call = AgentMessageToolCall(
                    externalID: "call_\(offset)",
                    toolName: "spawn_agent",
                    argumentsJSON: "{}",
                    subagentRunID: UUID()
                )
                call.subagentUsage = usage
                return call
            }
            messages.append(AgentMessage(role: .assistant, content: "spawning", toolCalls: calls))
        }
        let snapshot = AgentUsageSessionSnapshot(
            session: session(modelID: "claude-opus-5", providerID: "claude", messages: messages)
        )
        return AgentUsageStats.skillWorkerKPIs(for: [snapshot])
    }

    @Test("skill coverage counts narrow trades against all model invocations")
    func skillCoverageCountsNarrowTradesOnly() throws {
        // 2 narrow runs; the deep run inherits the parent's model, so it
        // moves nothing off the expensive tier and must not count as coverage.
        let result = kpis(
            runs: [run(profileID: "scout"), run(profileID: "test_fixer"), run(profileID: "deep")],
            parentTurns: 2 // plus the one assistant message carrying the calls
        )

        #expect(result.narrowRunCount == 2)
        #expect(result.deepRunCount == 1)
        #expect(result.parentTurnCount == 3)
        let coverage = try #require(result.skillCoverage)
        #expect(abs(coverage - 2.0 / 6.0) < 0.0001)
    }

    @Test("unverified runs stay out of the success rate entirely")
    func unverifiedRunsAreNotFailures() throws {
        let result = kpis(
            runs: [
                run(profileID: "test_fixer", verifierPassed: true),
                run(profileID: "test_fixer", verifierPassed: false),
                run(profileID: "scout"), // no verifier at all
            ],
            parentTurns: 0
        )

        #expect(result.verifiedRunCount == 2)
        #expect(result.verifiedPassCount == 1)
        let rate = try #require(result.verifiedSuccessRate)
        #expect(abs(rate - 0.5) < 0.0001)
    }

    @Test("escalation rate measures narrow runs that fell back to the parent")
    func escalationRateOverNarrowRuns() throws {
        let result = kpis(
            runs: [
                run(profileID: "scout", escalatedFrom: "glm-5"),
                run(profileID: "scout"),
                run(profileID: "reader"),
                run(profileID: "deep"),
            ],
            parentTurns: 0
        )

        #expect(result.escalatedRunCount == 1)
        let rate = try #require(result.escalationRate)
        #expect(abs(rate - 1.0 / 3.0) < 0.0001)
    }

    @Test("an empty denominator reports no data instead of zero percent")
    func emptyDenominatorsReportNil() {
        let result = kpis(runs: [], parentTurns: 0)

        // Rendering 0% here would read as "workers failed", not "no runs yet".
        #expect(result.skillCoverage == nil)
        #expect(result.verifiedSuccessRate == nil)
        #expect(result.escalationRate == nil)
    }

    @Test("tool calls persisted before worker accounting still decode")
    func legacyToolCallDecodesWithoutUsage() throws {
        let legacyJSON = #"{"externalID":"call_1","toolName":"spawn_agent","argumentsJSON":"{}"}"#

        let decoded = try JSONDecoder().decode(
            AgentMessageToolCall.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.subagentUsage == nil)
    }
}
