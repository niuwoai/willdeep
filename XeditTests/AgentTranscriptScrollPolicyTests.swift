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
    func sidePanelWidthChangeIsRecognizedAsViewportReflow() {
        #expect(
            AgentTranscriptViewportPolicy.widthChanged(
                from: 820,
                to: 500
            )
        )
        #expect(
            !AgentTranscriptViewportPolicy.widthChanged(
                from: 500,
                to: 500.25
            )
        )
        #expect(
            !AgentTranscriptViewportPolicy.widthChanged(
                from: nil,
                to: 500
            )
        )
    }

    @Test
    func horizontalReflowKeepsRelativeReadingPosition() {
        let progress = AgentTranscriptViewportPolicy.relativeProgress(
            documentHeight: 2_400,
            viewportHeight: 600,
            offsetFromTop: 900
        )
        let restored = AgentTranscriptViewportPolicy.restoredOffsetFromTop(
            progress: progress,
            documentHeight: 1_500,
            viewportHeight: 600
        )

        #expect(progress == 0.5)
        #expect(restored == 450)
    }

    @Test
    func reflowAnchorClampsToScrollableRange() {
        #expect(
            AgentTranscriptViewportPolicy.relativeProgress(
                documentHeight: 1_000,
                viewportHeight: 400,
                offsetFromTop: 900
            ) == 1
        )
        #expect(
            AgentTranscriptViewportPolicy.restoredOffsetFromTop(
                progress: -0.5,
                documentHeight: 1_000,
                viewportHeight: 400
            ) == 0
        )
        #expect(
            AgentTranscriptViewportPolicy.restoredOffsetFromTop(
                progress: 0.75,
                documentHeight: 300,
                viewportHeight: 400
            ) == 0
        )
    }

    @Test
    func continuousSidebarDragKeepsThePreDragAnchorUntilLayoutSettles() {
        var state = AgentTranscriptViewportReflowState<CGFloat>()

        #expect(state.preserve(0.42) == 0.42)
        #expect(state.isActive)
        // A transient TextKit layout frame can report the top of the
        // transcript. It must not replace the anchor from before the drag.
        #expect(state.preserve(0) == 0.42)
        #expect(state.finish() == 0.42)
        #expect(!state.isActive)
    }

    @Test
    func sidePanelReflowDoesNotImpersonateAnOperatorScroll() {
        #expect(
            AgentTranscriptScrollPolicy.followingBottomAfterViewportChange(
                current: true,
                isNearBottom: false,
                viewportWidthChanged: true
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.followingBottomAfterViewportChange(
                current: false,
                isNearBottom: true,
                viewportWidthChanged: true
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.followingBottomAfterViewportChange(
                current: true,
                isNearBottom: false,
                viewportWidthChanged: false
            )
        )
    }

    @Test
    func selectingAnotherConversationStartsAtTheBottom() {
        #expect(AgentTranscriptScrollPolicy.followingBottomAfterSessionChange())
    }

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
