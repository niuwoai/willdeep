//
//  AgentTranscriptScrollPolicyTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
nonisolated struct AgentTranscriptScrollPolicyTests {
    @Test
    func scrollToLatestButtonOnlyAppearsWhileReadingAboveTheBottom() {
        #expect(
            AgentTranscriptScrollPolicy.shouldShowScrollToLatest(
                hasVisibleContent: true,
                isFollowingBottom: false,
                isConversationSearchActive: false
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.shouldShowScrollToLatest(
                hasVisibleContent: true,
                isFollowingBottom: true,
                isConversationSearchActive: false
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.shouldShowScrollToLatest(
                hasVisibleContent: false,
                isFollowingBottom: false,
                isConversationSearchActive: false
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.shouldShowScrollToLatest(
                hasVisibleContent: true,
                isFollowingBottom: false,
                isConversationSearchActive: true
            )
        )
    }

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

    // MARK: - Earlier-history arming
    //
    // The reported path: switching to a long conversation (more messages than
    // the rendered cap) often opened parked at the TOP. TextKit's content
    // swap clamps the viewport through the document top; that blip armed the
    // prepend anchor via onReachTop, and the subsequent layout growth
    // "restored" a near-zero offset and switched follow-bottom off.

    @Test
    func operatorScrollingToTopStillLoadsEarlierHistory() {
        #expect(
            AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: true,
                wasNearTop: false,
                isFollowingBottom: false,
                isRestorePending: false,
                isContentTransitionActive: false
            )
        )
    }

    @Test
    func transientTopWhileFollowingBottomDoesNotArmPrepend() {
        // Following bottom + suddenly at the top is a layout artifact, not a
        // reading intent — nobody teleports from the newest message to the
        // oldest one without any scroll in between.
        #expect(
            !AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: true,
                wasNearTop: false,
                isFollowingBottom: true,
                isRestorePending: false,
                isContentTransitionActive: false
            )
        )
    }

    @Test
    func contentSwapAndRestorePassesNeverArmPrepend() {
        #expect(
            !AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: true,
                wasNearTop: false,
                isFollowingBottom: false,
                isRestorePending: false,
                isContentTransitionActive: true
            )
        )
        #expect(
            !AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: true,
                wasNearTop: false,
                isFollowingBottom: false,
                isRestorePending: true,
                isContentTransitionActive: false
            )
        )
    }

    @Test
    func stayingAtTheTopDoesNotRefireTheRequest() {
        // Arming is edge-triggered; a viewport that keeps reporting near-top
        // must not load page after page.
        #expect(
            !AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: true,
                wasNearTop: true,
                isFollowingBottom: false,
                isRestorePending: false,
                isContentTransitionActive: false
            )
        )
    }

    // MARK: - Content transition lifecycle

    @Test
    func contentTransitionSettlesOnlyOnTheNewestGeneration() {
        var transition = AgentTranscriptContentTransition()
        let first = transition.begin()
        #expect(transition.isActive)

        // Another geometry event arrives: the older settle timer must not
        // close the window early — that is exactly the "one intermediate
        // frame becomes the resting position" failure.
        let second = transition.extend()
        let staleSettled = transition.settle(generation: first)
        #expect(second != nil)
        #expect(!staleSettled)
        #expect(transition.isActive)

        let newestSettled = transition.settle(generation: second ?? -1)
        #expect(newestSettled)
        #expect(!transition.isActive)
    }

    @Test
    func settledTransitionCannotBeExtendedBackToLife() {
        var transition = AgentTranscriptContentTransition()
        let generation = transition.begin()
        let settled = transition.settle(generation: generation)
        #expect(settled)

        // A straggler notification after settlement is ordinary post-layout
        // noise; resurrecting the window would swallow real operator scrolls.
        let lateExtension = transition.extend()
        #expect(lateExtension == nil)
        #expect(!transition.isActive)
    }

    @Test
    func cancelledTransitionRefusesItsPendingSettle() {
        var transition = AgentTranscriptContentTransition()
        let generation = transition.begin()
        transition.cancel()

        let settledAfterCancel = transition.settle(generation: generation)
        #expect(!transition.isActive)
        #expect(!settledAfterCancel)
    }

    @Test
    func extendWithoutBeginStaysInert() {
        var transition = AgentTranscriptContentTransition()
        let extended = transition.extend()
        #expect(extended == nil)
        #expect(!transition.isActive)
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
