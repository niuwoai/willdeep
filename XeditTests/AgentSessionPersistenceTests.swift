//
//  AgentSessionPersistenceTests.swift
//  WillDeepTests
//
//  Covers JSON round-tripping for AgentSession's newer fields
//  (interactionMode / currentPlan / currentGoal) plus the decodeIfPresent
//  fallbacks that keep older sessions loadable.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentSessionPersistenceTests {
    /// Older session JSON written before plan/goal persistence existed
    /// must still decode — fields default to normal/nil/false.
    @Test
    func legacySessionJSONLoadsWithDefaults() throws {
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "title": "Old chat",
          "createdAt": 750000000,
          "updatedAt": 750000050,
          "messages": []
        }
        """
        let data = Data(legacy.utf8)
        let session = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(session.interactionMode == .normal)
        #expect(session.currentPlan == nil)
        #expect(session.currentGoal == nil)
        #expect(session.didEditFiles == false)
        #expect(session.workspaceRootPath == nil)
    }

    /// Round-trip a session carrying every new field — values should
    /// survive encode → decode unchanged, including per-step status.
    @Test
    func planAndGoalSurviveJSONRoundTrip() throws {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "Inspect AppState", status: .done),
                AgentPlan.Step(text: "Add persistence", status: .inProgress),
                AgentPlan.Step(text: "Write tests", status: .pending)
            ],
            summary: "Wire plan/goal into the session JSON."
        )
        let goal = AgentGoal(
            statement: "Plan/Goal must persist across session switches",
            checklist: [
                AgentGoal.Item(text: "Decoder accepts old JSON", done: true),
                AgentGoal.Item(text: "Mutators persist", done: false)
            ]
        )
        let original = AgentSession(
            title: "Persistence work",
            workspaceRootPath: "/Users/test/proj",
            modelID: "gpt-4.6",
            messages: [],
            didEditFiles: true,
            interactionMode: .plan,
            currentPlan: plan,
            currentGoal: goal
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        #expect(decoded.interactionMode == .plan)
        #expect(decoded.currentPlan?.status == .executing)
        #expect(decoded.currentPlan?.steps.map(\.text) == plan.steps.map(\.text))
        #expect(decoded.currentPlan?.steps.map(\.status) == plan.steps.map(\.status))
        #expect(decoded.currentPlan?.summary == plan.summary)
        #expect(decoded.currentGoal?.statement == goal.statement)
        #expect(decoded.currentGoal?.checklist.count == 2)
        #expect(decoded.currentGoal?.checklist.first?.done == true)
        #expect(decoded.currentGoal?.checklist.last?.done == false)
        #expect(decoded.didEditFiles == true)
    }

    /// A goal-mode session with the goal field missing decodes fine —
    /// caller is expected to handle the nil (mode + nil-goal means the
    /// editor sheet pops on next entry).
    @Test
    func goalModeWithoutGoalLoadsAsNilGoal() throws {
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "title": "Goal pending",
          "createdAt": 750000000,
          "updatedAt": 750000050,
          "messages": [],
          "interactionMode": "goal"
        }
        """
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
        #expect(session.interactionMode == .goal)
        #expect(session.currentGoal == nil)
    }

    /// Bad interactionMode strings shouldn't blow up the whole decode —
    /// AgentInteractionMode is plain Codable, so an unknown value WILL
    /// throw. Documenting the contract: callers should treat decode
    /// errors as "this session is corrupt" rather than silently
    /// downgrade. If we ever need lenient handling we'll add a custom
    /// init then; for now, assert the throw so regressions are loud.
    @Test
    func unknownInteractionModeThrows() {
        let bad = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "title": "x",
          "createdAt": 0,
          "updatedAt": 0,
          "messages": [],
          "interactionMode": "warp-speed"
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AgentSession.self, from: Data(bad.utf8))
        }
    }
}
