//
//  AgentTranscriptUserMinimapTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite
struct AgentTranscriptUserMinimapTests {
    private func editCall(
        messageID: UUID,
        path: String,
        toolName: String = "apply_patch"
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: messageID,
            externalID: "call-\(path)",
            toolName: toolName,
            arguments: ["path": .string(path)],
            risk: .write,
            status: .succeeded
        )
    }

    @Test
    func foldsAssistantReplyAndEditedFilesIntoTheUserTurn() {
        let user = AgentMessage(role: .user, content: "Fix the parser", source: .operatorInput)
        let assistant = AgentMessage(role: .assistant, content: "  Patched it.  ")
        let calls = [
            editCall(messageID: assistant.id, path: "Sources/Parser.swift"),
            editCall(messageID: assistant.id, path: "Tests/ParserTests.swift")
        ]

        let turns = AgentTranscriptTurnSummary.build(
            from: [user, assistant],
            toolCalls: calls
        )

        #expect(turns.count == 1)
        #expect(turns[0].id == user.id)
        #expect(turns[0].userText == "Fix the parser")
        #expect(turns[0].assistantText == "Patched it.")
        #expect(turns[0].changedFiles == ["Sources/Parser.swift", "Tests/ParserTests.swift"])
    }

    /// The turn window stops at the next user message, so a later turn's
    /// edits must not leak backwards into an earlier summary.
    @Test
    func scopesEditedFilesToTheOwningTurn() {
        let firstUser = AgentMessage(role: .user, content: "One", source: .operatorInput)
        let firstAssistant = AgentMessage(role: .assistant, content: "Did one")
        let secondUser = AgentMessage(role: .user, content: "Two", source: .operatorInput)
        let secondAssistant = AgentMessage(role: .assistant, content: "Did two")
        let calls = [
            editCall(messageID: firstAssistant.id, path: "A.swift"),
            editCall(messageID: secondAssistant.id, path: "B.swift")
        ]

        let turns = AgentTranscriptTurnSummary.build(
            from: [firstUser, firstAssistant, secondUser, secondAssistant],
            toolCalls: calls
        )

        #expect(turns.count == 2)
        #expect(turns[0].changedFiles == ["A.swift"])
        #expect(turns[1].changedFiles == ["B.swift"])
    }

    @Test
    func deduplicatesRepeatedPathsKeepingFirstOrder() {
        let user = AgentMessage(role: .user, content: "Edit twice", source: .operatorInput)
        let assistant = AgentMessage(role: .assistant, content: "Done")
        let calls = [
            editCall(messageID: assistant.id, path: "A.swift"),
            editCall(messageID: assistant.id, path: "B.swift"),
            editCall(messageID: assistant.id, path: "A.swift")
        ]

        let turns = AgentTranscriptTurnSummary.build(
            from: [user, assistant],
            toolCalls: calls
        )

        #expect(turns[0].changedFiles == ["A.swift", "B.swift"])
    }

    @Test
    func ignoresNonEditToolsAndPathlessCalls() {
        let user = AgentMessage(role: .user, content: "Look around", source: .operatorInput)
        let assistant = AgentMessage(role: .assistant, content: "Looked")
        let calls = [
            editCall(messageID: assistant.id, path: "read.swift", toolName: "read_file"),
            editCall(messageID: assistant.id, path: "   "),
            AgentToolCall(
                messageID: assistant.id,
                externalID: "no-path",
                toolName: "apply_patch",
                arguments: [:],
                risk: .write,
                status: .succeeded
            )
        ]

        let turns = AgentTranscriptTurnSummary.build(
            from: [user, assistant],
            toolCalls: calls
        )

        #expect(turns[0].changedFiles.isEmpty)
    }

    /// Only the first non-empty assistant message of the turn is summarized.
    @Test
    func summarizesTheFirstNonEmptyAssistantReply() {
        let user = AgentMessage(role: .user, content: "Go", source: .operatorInput)
        let empty = AgentMessage(role: .assistant, content: "   ")
        let first = AgentMessage(role: .assistant, content: "First real reply")
        let second = AgentMessage(role: .assistant, content: "Second reply")

        let turns = AgentTranscriptTurnSummary.build(
            from: [user, empty, first, second],
            toolCalls: []
        )

        #expect(turns[0].assistantText == "First real reply")
    }

    @Test
    func skipsHostInstructionsSoOnlyRealUserTurnsGetTicks() {
        let hostInstruction = AgentMessage(
            role: .user,
            content: "Plan approved. Execute the complete plan step by step.",
            source: .hostInstruction
        )
        let user = AgentMessage(role: .user, content: "Real ask", source: .operatorInput)

        let turns = AgentTranscriptTurnSummary.build(
            from: [hostInstruction, user],
            toolCalls: []
        )

        #expect(turns.count == 1)
        #expect(turns[0].id == user.id)
    }

    // MARK: - Cache

    @Test
    func cacheReusesSummariesWhileTheFingerprintHolds() {
        let cache = AgentTranscriptMinimapCache()
        let summary = AgentTranscriptTurnSummary(
            id: UUID(),
            userText: "cached",
            assistantText: "",
            changedFiles: []
        )
        var rebuilds = 0

        for _ in 0..<5 {
            let turns = cache.turns(fingerprint: 42) {
                rebuilds += 1
                return [summary]
            }
            #expect(turns == [summary])
        }

        #expect(rebuilds == 1)
    }

    @Test
    func cacheRebuildsWhenTheFingerprintChanges() {
        let cache = AgentTranscriptMinimapCache()
        var rebuilds = 0
        let make: (String) -> [AgentTranscriptTurnSummary] = { text in
            [AgentTranscriptTurnSummary(id: UUID(), userText: text, assistantText: "", changedFiles: [])]
        }

        _ = cache.turns(fingerprint: 1) { rebuilds += 1; return make("first") }
        let second = cache.turns(fingerprint: 2) { rebuilds += 1; return make("second") }
        let third = cache.turns(fingerprint: 2) { rebuilds += 1; return make("third") }

        #expect(rebuilds == 2)
        #expect(second[0].userText == "second")
        #expect(third[0].userText == "second")
    }
}
