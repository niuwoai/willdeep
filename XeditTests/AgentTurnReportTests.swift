//
//  AgentTurnReportTests.swift
//  WillDeepTests
//
//  Covers latest-turn audit report generation.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentTurnReportTests {
    @Test
    func latestTurnReportSummarizesToolsApprovalsSandboxAndLearning() throws {
        let firstUser = AgentMessage(
            role: .user,
            content: "old turn",
            createdAt: Date(timeIntervalSince1970: 1_800_001_000)
        )
        let oldAssistant = AgentMessage(
            role: .assistant,
            content: "old answer",
            createdAt: Date(timeIntervalSince1970: 1_800_001_010)
        )
        let latestUser = AgentMessage(
            role: .user,
            content: "new turn",
            createdAt: Date(timeIntervalSince1970: 1_800_001_100)
        )
        var assistant = AgentMessage(
            role: .assistant,
            content: "new answer",
            createdAt: Date(timeIntervalSince1970: 1_800_001_120)
        )
        assistant.elapsedSeconds = 4.25
        assistant.usageTokens = 300
        assistant.promptTokens = 120
        assistant.completionTokens = 180

        let session = AgentSession(
            modelID: "deepseek-v4-flash",
            providerDisplayName: "DeepSeek",
            messages: [firstUser, oldAssistant, latestUser, assistant]
        )
        let runtime = AgentRuntime(session: session)
        runtime.toolCalls = [
            AgentToolCall(
                messageID: oldAssistant.id,
                externalID: "old-tool",
                toolName: "read_file",
                arguments: [:],
                risk: .read,
                status: .succeeded
            ),
            AgentToolCall(
                messageID: assistant.id,
                externalID: "new-tool",
                toolName: "run_command",
                arguments: [
                    "_sandbox": .string("workspace-write"),
                    "_approval_reason": .string("Allowed in workspace")
                ],
                risk: .write,
                status: .succeeded,
                result: AgentToolResult(summary: "ok", payload: "ok"),
                approvalSource: .workspaceAccess
            )
        ]
        runtime.learningEvents = [
            AgentLearningEvent(
                kind: .memory,
                status: .saved,
                title: "Old memory",
                detail: "",
                createdAt: Date(timeIntervalSince1970: 1_800_001_050)
            ),
            AgentLearningEvent(
                kind: .skill,
                status: .created,
                title: "Created user skill",
                detail: "",
                createdAt: Date(timeIntervalSince1970: 1_800_001_130)
            )
        ]
        runtime.latestTurnRecall = AgentTurnRecallSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_800_001_125),
            query: "new turn",
            items: [
                AgentTurnRecallItem(
                    kind: .memory,
                    title: "Agent should use yarn by default.",
                    detail: "Project memory",
                    score: 0.82,
                    reasons: ["keyword overlap"]
                ),
                AgentTurnRecallItem(
                    kind: .skill,
                    title: "release-guardian",
                    detail: "Use before shipping a release.",
                    reasons: ["Attached via @skill for this turn."]
                )
            ]
        )

        let report = try #require(AgentTurnReport.latest(for: runtime))

        #expect(report.modelID == "deepseek-v4-flash")
        #expect(report.providerName == "DeepSeek")
        #expect(report.assistantMessageCount == 1)
        #expect(report.elapsedSeconds == 4.25)
        #expect(report.totalTokens == 300)
        #expect(report.toolSummary.total == 1)
        #expect(report.toolSummary.writeRisk == 1)
        #expect(report.toolSummary.autoApproved == 1)
        #expect(report.toolSummary.sandboxModes == ["workspace-write"])
        #expect(report.tools.map(\.toolName) == ["run_command"])
        #expect(report.recallSnapshot?.items.count == 2)
        #expect(report.recallSnapshot?.items.map(\.kind) == [.memory, .skill])
        #expect(report.learningEvents.map(\.title) == ["Created user skill"])
    }
}
