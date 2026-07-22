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
        #expect(session.goalTurnRecoveryCheckpoint == nil)
        #expect(session.latestTurnRecall == nil)
        #expect(session.contextSummary == nil)
        #expect(session.contextSummaryThroughMessageID == nil)
        #expect(session.didEditFiles == false)
        #expect(session.agentArtifactPaths.isEmpty)
        #expect(session.workspaceRootPath == nil)
        #expect(session.sidePanelState == .empty)
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
        let sidePanelLastViewedAt = Date(timeIntervalSince1970: 760_000_100)
        let recoveryCheckpoint = AgentGoalTurnRecoveryCheckpoint(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            startedAt: Date(timeIntervalSince1970: 760_000_050)
        )
        let original = AgentSession(
            title: "Persistence work",
            workspaceRootPath: "/Users/test/.willdeep/worktrees/proj/task",
            sidebarWorkspaceRootPath: "/Users/test/proj",
            modelID: "gpt-4.6",
            messages: [AgentMessage(role: .user, content: "keep the visible transcript")],
            contextSummary: "summary used only for model context",
            contextSummaryThroughMessageID: UUID(uuidString: "44444444-4444-4444-4444-444444444444"),
            didEditFiles: true,
            agentEditedPaths: ["Sources/App.swift", "reports/result.pdf"],
            agentArtifactPaths: ["reports/result.pdf"],
            interactionMode: .plan,
            currentPlan: plan,
            currentGoal: goal,
            goalTurnRecoveryCheckpoint: recoveryCheckpoint,
            latestTurnRecall: AgentTurnRecallSnapshot(
                createdAt: Date(timeIntervalSince1970: 760_000_000),
                query: "release workflow",
                items: [
                    AgentTurnRecallItem(
                        kind: .memory,
                        title: "Use yarn in this project.",
                        detail: "Project memory",
                        score: 0.76,
                        reasons: ["keyword overlap"]
                    )
                ]
            ),
            sidePanelState: AgentSidePanelState(
                kind: AgentSidePanelKind.imageEditor,
                selectedFilePath: "/Users/test/proj/README.md",
                mediaTaskScope: AgentMediaTaskScope(
                    label: "Shot 1",
                    projectID: "project-1",
                    episodeID: "episode-1",
                    shotID: "shot-1"
                ),
                imageEditorImagePath: "/Users/test/proj/frame.png",
                imageEditorMaskPath: "/Users/test/proj/mask.png",
                imageEditorPreferredOperation: AgentImageEditorOperationPreference.erase,
                imageEditorContext: AgentImageEditorContext(
                    projectID: "project-1",
                    episodeID: "episode-1",
                    shotID: "shot-1",
                    reviewItemID: "review-1"
                ),
                lastViewedAt: sidePanelLastViewedAt
            )
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
        #expect(decoded.goalTurnRecoveryCheckpoint == recoveryCheckpoint)
        #expect(decoded.messages.first?.content == "keep the visible transcript")
        #expect(decoded.contextSummary == "summary used only for model context")
        #expect(decoded.contextSummaryThroughMessageID == UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        #expect(decoded.sidebarWorkspaceRootPath == "/Users/test/proj")
        #expect(decoded.workspaceSidebarGroupKey == "/Users/test/proj")
        #expect(decoded.latestTurnRecall?.items.count == 1)
        #expect(decoded.latestTurnRecall?.items.first?.kind == .memory)
        #expect(decoded.didEditFiles == true)
        #expect(decoded.agentEditedPaths == ["Sources/App.swift", "reports/result.pdf"])
        #expect(decoded.agentArtifactPaths == ["reports/result.pdf"])
        #expect(decoded.sidePanelState.kind == AgentSidePanelKind.imageEditor)
        #expect(decoded.sidePanelState.selectedFilePath == "/Users/test/proj/README.md")
        #expect(decoded.sidePanelState.mediaTaskScope?.shotID == "shot-1")
        #expect(decoded.sidePanelState.imageEditorImagePath == "/Users/test/proj/frame.png")
        #expect(decoded.sidePanelState.imageEditorMaskPath == "/Users/test/proj/mask.png")
        #expect(decoded.sidePanelState.imageEditorPreferredOperation == AgentImageEditorOperationPreference.erase)
        #expect(decoded.sidePanelState.imageEditorContext?.reviewItemID == "review-1")
        #expect(decoded.sidePanelState.lastViewedAt == sidePanelLastViewedAt)
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
