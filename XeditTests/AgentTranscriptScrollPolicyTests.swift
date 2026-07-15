//
//  AgentTranscriptScrollPolicyTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentTranscriptScrollPolicyTests {
    @Test
    func taskUpdateKeepsHistoryPositionWhenOperatorScrolledUp() {
        let assistant = AgentMessage(role: .assistant, content: "Task update")

        #expect(
            !AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                assistant,
                isFollowingBottom: false
            )
        )
    }

    @Test
    func anyUpdateKeepsFollowingWhenAlreadyAtBottom() {
        let assistant = AgentMessage(role: .assistant, content: "Task update")

        #expect(
            AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                assistant,
                isFollowingBottom: true
            )
        )
    }

    @Test
    func operatorInputForcesReturnToBottom() {
        let user = AgentMessage(
            role: .user,
            content: "Continue",
            source: .operatorInput
        )

        #expect(
            AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                user,
                isFollowingBottom: false
            )
        )
    }

    @Test
    func hostInstructionDoesNotImpersonateOperatorOrForceScroll() {
        let instruction = AgentMessage(
            role: .user,
            content: "Plan approved. Execute the complete plan step by step.",
            source: .hostInstruction
        )

        #expect(instruction.isHostInstruction)
        #expect(!instruction.isOperatorInput)
        #expect(
            !AgentTranscriptScrollPolicy.shouldScrollAfterAppending(
                instruction,
                isFollowingBottom: false
            )
        )
    }

    @Test
    func legacyPlanApprovalInstructionIsHidden() {
        let legacy = AgentMessage(
            role: .user,
            content: "Plan approved. Please proceed with executing the plan step by step."
        )

        #expect(legacy.isHostInstruction)
        #expect(!legacy.isOperatorInput)
    }

    @Test
    func messageSourceRoundTripsThroughSessionCoding() throws {
        let original = AgentMessage(
            role: .user,
            content: "Internal execution instruction",
            source: .hostInstruction
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: encoded)

        #expect(decoded.source == .hostInstruction)
        #expect(decoded.isHostInstruction)
    }
}
