//
//  AgentSubagentTaskPacketTests.swift
//  WillDeepTests
//
//  Task packets and the verifier gate (skill-workers.v1 Phase 1).
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentSubagentTaskPacketTests {
    // MARK: Parsing

    @Test("a packet parses from the object form")
    func parsesObjectForm() throws {
        let value = AgentJSONValue.decode(from: """
        {"goal":"fix the OAuth test","relevant_files":["a.swift","b.swift"],
         "known_facts":["fails since abc123"],"constraints":["do not touch the schema"],
         "verifier":{"command":"swift test"},"max_attempts":3}
        """)

        let packet = try #require(AgentSubagentTaskPacket.parse(value))
        #expect(packet.goal == "fix the OAuth test")
        #expect(packet.relevantFiles == ["a.swift", "b.swift"])
        #expect(packet.knownFacts == ["fails since abc123"])
        #expect(packet.constraints == ["do not touch the schema"])
        #expect(packet.verifierCommand == "swift test")
        #expect(packet.maxAttempts == 3)
    }

    @Test("a packet sent as a JSON string parses the same way")
    func parsesStringForm() throws {
        // The tool schema declares `task` as a string because the parameter
        // vocabulary has no object type, but models send both shapes.
        let value = AgentJSONValue.string(#"{"goal":"tidy up","verifier":"swift build"}"#)

        let packet = try #require(AgentSubagentTaskPacket.parse(value))
        #expect(packet.goal == "tidy up")
        // A flattened one-key verifier is tolerated rather than costing a round.
        #expect(packet.verifierCommand == "swift build")
    }

    @Test("a packet without a goal is not a packet")
    func rejectsGoallessPacket() {
        #expect(AgentSubagentTaskPacket.parse(AgentJSONValue.decode(from: #"{"relevant_files":["a"]}"#)) == nil)
        #expect(AgentSubagentTaskPacket.parse(nil) == nil)
        #expect(AgentSubagentTaskPacket.parse(.string("   ")) == nil)
    }

    @Test("attempts are clamped so a packet cannot buy unlimited retries")
    func clampsAttempts() {
        #expect(AgentSubagentTaskPacket(goal: "g", maxAttempts: 99).maxAttempts
            == AgentSubagentTaskPacket.maxAttemptsCeiling)
        #expect(AgentSubagentTaskPacket(goal: "g", maxAttempts: 0).maxAttempts == 1)
    }

    // MARK: Opening message

    @Test("the opening message inlines file contents so the worker starts hot")
    func openingMessageInlinesFiles() {
        let packet = AgentSubagentTaskPacket(
            goal: "fix it",
            relevantFiles: ["Sources/Auth.swift"],
            knownFacts: ["password login is fine"],
            constraints: ["do not change the schema"],
            verifierCommand: "swift test"
        )

        let message = packet.openingMessage(fallbackPrompt: "fix it") { path in
            path == "Sources/Auth.swift" ? "func login() {}" : nil
        }

        #expect(message.contains("## Task"))
        #expect(message.contains("func login() {}"))
        #expect(message.contains("password login is fine"))
        #expect(message.contains("do not change the schema"))
        #expect(message.contains("swift test"))
    }

    @Test("an unreadable file is reported in place, not silently dropped")
    func missingFileIsReported() {
        let packet = AgentSubagentTaskPacket(goal: "g", relevantFiles: ["nope.swift"])

        let message = packet.openingMessage(fallbackPrompt: "g") { _ in nil }

        // Silently omitting it would leave the worker inventing a file that
        // the parent believed it had been handed.
        #expect(message.contains("nope.swift"))
        #expect(message.contains("could not be read"))
    }

    @Test("inlining stops at the budget instead of blowing the window")
    func inliningRespectsBudget() {
        let huge = String(repeating: "x", count: AgentSubagentTaskPacket.inlineCharacterBudget * 2)
        let packet = AgentSubagentTaskPacket(goal: "g", relevantFiles: ["big.swift"])

        let message = packet.openingMessage(fallbackPrompt: "g") { _ in huge }

        #expect(message.count < huge.count)
        #expect(message.contains("truncated at the inline budget"))
    }

    // MARK: Verifier retry text

    @Test("the retry message carries the failure and forbids weakening the check")
    func retryMessageStatesTheContract() {
        let text = AgentSubagentRunner.verifierRetryMessage(
            command: "swift test",
            output: "1 test failed",
            attempt: 2,
            maxAttempts: 4,
            payloadLimit: 4_000
        )

        #expect(text.contains("attempt 2 of 4"))
        #expect(text.contains("1 test failed"))
        #expect(text.contains("not done"))
        #expect(text.contains("weaken"))
    }

    @Test("verifier output is clamped to the trade's payload budget")
    func retryMessageClampsOutput() {
        let text = AgentSubagentRunner.verifierRetryMessage(
            command: "swift build",
            output: String(repeating: "e", count: 20_000),
            attempt: 1,
            maxAttempts: 3,
            payloadLimit: 500
        )

        #expect(text.contains("output truncated"))
        #expect(text.count < 5_000)
    }

    // MARK: Escalation

    @Test("a failed verifier escalates and a passed one never does")
    func verifierVerdictDrivesEscalation() {
        let profile = AgentSubagentProfileCatalog.testFixer
        func outcome(verifierPassed: Bool?, report: String) -> AgentSubagentRunner.Outcome {
            AgentSubagentRunner.Outcome(
                report: report,
                usageTokens: 10,
                roundCount: 1,
                toolInvocationCount: 1,
                verifierPassed: verifierPassed,
                verifierAttempts: verifierPassed == nil ? 0 : 1
            )
        }

        let longReport = String(repeating: "a detailed report. ", count: 5)
        #expect(AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(verifierPassed: false, report: longReport),
            profile: profile
        ))
        // A terse report is normally an escalation trigger, but a passing
        // verifier is proof the work is done — paying twice for it is waste.
        #expect(!AgentSubagentEscalation.shouldEscalate(
            outcome: outcome(verifierPassed: true, report: "done"),
            profile: profile
        ))
    }
}
