//
//  AgentTranscriptScrollBehavior.swift
//  WillDeep
//
//  Sticky-bottom tracking shared by the main Agent transcript and the
//  compact side-panel transcript.
//

import AppKit
import SwiftUI

nonisolated enum AgentTranscriptScrollPolicy {
    static func shouldShowScrollToLatest(
        hasVisibleContent: Bool,
        isFollowingBottom: Bool,
        isConversationSearchActive: Bool
    ) -> Bool {
        hasVisibleContent && !isFollowingBottom && !isConversationSearchActive
    }

    static func shouldScrollAfterAppending(
        _ message: AgentMessage?,
        isFollowingBottom: Bool
    ) -> Bool {
        isFollowingBottom || message?.isOperatorInput == true
    }

    /// A different conversation has its own reading context. Never inherit
    /// the previous conversation's off-bottom state into the newly selected
    /// transcript; the operator can scroll that conversation after it opens.
    static func followingBottomAfterSessionChange() -> Bool {
        true
    }

    /// Horizontal viewport changes are layout, not reading intent. Opening,
    /// closing, or resizing a side panel may briefly make AppKit report the
    /// top of the document while TextKit reflows; keep the existing follow
    /// decision until that transaction settles. A vertical-only bounds change
    /// is allowed to reflect an actual operator scroll.
    static func followingBottomAfterViewportChange(
        current: Bool,
        isNearBottom: Bool,
        viewportWidthChanged: Bool
    ) -> Bool {
        viewportWidthChanged ? current : isNearBottom
    }

    /// Whether arriving near the top should load an earlier history page.
    ///
    /// Reaching the top is only a reading intent when the operator actually
    /// scrolled there. The same "near top" reading also shows up as a
    /// transient layout artifact — session switches clamp the viewport to the
    /// document top while TextKit rebuilds the folded history, and restore
    /// passes move through top on their way back. Arming the prepend anchor
    /// on one of those blips is how a freshly selected long conversation
    /// ended up parked at its oldest page instead of at the latest message:
    /// the phantom "prepend" then restored a near-zero offset and switched
    /// follow-bottom off.
    static func shouldRequestEarlierHistory(
        nowNearTop: Bool,
        wasNearTop: Bool,
        isFollowingBottom: Bool,
        isRestorePending: Bool,
        isContentTransitionActive: Bool
    ) -> Bool {
        nowNearTop
            && !wasNearTop
            && !isFollowingBottom
            && !isRestorePending
            && !isContentTransitionActive
    }
}

/// Tracks one content-replacement transaction (a session switch swapping the
/// transcript's folded history string).
///
/// While the replacement is in flight, AppKit clamps the clip view through
/// arbitrary intermediate offsets — including the document top. Those bounds
/// changes carry no operator intent, so the observer must neither flip the
/// follow decision on them nor treat them as "reached the top". Generation
/// counting mirrors `AgentTranscriptViewportReflowState`: every geometry event
/// extends the transaction, and it settles only after the layout has gone
/// quiet.
nonisolated struct AgentTranscriptContentTransition {
    private(set) var generation = 0
    private(set) var isActive = false

    /// Starts (or restarts) the transaction. Returns the generation the
    /// settle callback must present to be accepted.
    mutating func begin() -> Int {
        isActive = true
        generation += 1
        return generation
    }

    /// Extends the transaction because another geometry event arrived. Nil
    /// when no transaction is active — callers must not resurrect one that
    /// already settled.
    mutating func extend() -> Int? {
        guard isActive else { return nil }
        generation += 1
        return generation
    }

    /// True when this settle attempt is the newest one; the transaction ends.
    /// Stale generations (an older timer firing after an extension) are
    /// refused and leave the transaction running.
    mutating func settle(generation: Int) -> Bool {
        guard isActive, generation == self.generation else { return false }
        isActive = false
        return true
    }

    mutating func cancel() {
        isActive = false
        generation += 1
    }
}

/// Maps a viewport to the same relative reading position after a horizontal
/// transcript reflow. Opening or closing the right side panel changes the
/// chat width, so a fixed vertical offset no longer points at the same part of
/// the conversation.
nonisolated enum AgentTranscriptViewportPolicy {
    static func widthChanged(
        from previousWidth: CGFloat?,
        to currentWidth: CGFloat,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard let previousWidth else { return false }
        return abs(previousWidth - currentWidth) > tolerance
    }

    static func relativeProgress(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        offsetFromTop: CGFloat
    ) -> CGFloat {
        let scrollableHeight = max(0, documentHeight - viewportHeight)
        guard scrollableHeight > 0 else { return 0 }
        return min(max(offsetFromTop / scrollableHeight, 0), 1)
    }

    static func restoredOffsetFromTop(
        progress: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let scrollableHeight = max(0, documentHeight - viewportHeight)
        return min(max(progress, 0), 1) * scrollableHeight
    }
}

/// Keeps the first stable reading anchor for the whole horizontal-reflow
/// transaction. A drag emits many viewport/document geometry notifications;
/// later notifications may briefly report a zero offset while TextKit is
/// rebuilding its layout. Those transient values must never replace the
/// anchor captured before the drag started.
nonisolated struct AgentTranscriptViewportReflowState<Anchor> {
    private(set) var preservedAnchor: Anchor?

    var isActive: Bool {
        preservedAnchor != nil
    }

    mutating func preserve(_ anchor: Anchor) -> Anchor {
        if let preservedAnchor {
            return preservedAnchor
        }
        preservedAnchor = anchor
        return anchor
    }

    mutating func finish() -> Anchor? {
        defer { preservedAnchor = nil }
        return preservedAnchor
    }

    mutating func cancel() {
        preservedAnchor = nil
    }
}

/// Observes the AppKit scroll view underneath a SwiftUI `ScrollView`.
///
/// Tracking user intent instead of recomputing "at bottom" after each layout
/// is important: when content grows, the old bottom immediately becomes an
/// off-bottom position. If that layout change were treated as a user scroll,
/// the transcript would stop following even though the operator never moved.
/// While following, document-height changes are pinned with a direct AppKit
/// clip-view adjustment; this avoids a token-by-token SwiftUI `scrollTo` and
/// its expensive relayout path.
struct AgentTranscriptScrollObserver: NSViewRepresentable {
    @Binding var isFollowingBottom: Bool
    var scrollToBottomRequestToken: Int? = nil
    var onReachTop: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.isFollowingBottom = isFollowingBottom
        context.coordinator.onChange = { isFollowingBottom = $0 }
        context.coordinator.onReachTop = onReachTop
        context.coordinator.requestScrollToBottom(token: scrollToBottomRequestToken)
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator else { return }
            coordinator.attachIfNeeded(from: nsView)
        }
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.attachIfNeeded(from: self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.attachIfNeeded(from: self)
            }
        }
    }

    final class Coordinator {
        private static let bottomTolerance: CGFloat = 56
        private static let topTolerance: CGFloat = 40
        private static let geometryTolerance: CGFloat = 0.5
        private static let reflowSettleDelay: TimeInterval = 0.08
        /// Longer than `reflowSettleDelay`: a session switch replaces the
        /// whole folded history string, and TextKit lays a large document out
        /// in several passes with real gaps between them.
        private static let contentTransitionSettleDelay: TimeInterval = 0.25

        private struct ViewportAnchor {
            let relativeProgress: CGFloat
            let followsBottom: Bool
        }

        weak var scrollView: NSScrollView?
        weak var documentView: NSView?
        var isFollowingBottom = true
        var onChange: ((Bool) -> Void)?
        var onReachTop: (() -> Bool)?
        private var notificationTokens: [NSObjectProtocol] = []
        private var lastDocumentSize: CGSize?
        private var lastViewportSize: CGSize?
        private var viewportAnchor: ViewportAnchor?
        private var viewportReflowState = AgentTranscriptViewportReflowState<ViewportAnchor>()
        private var viewportCaptureGeneration = 0
        private var viewportRestoreGeneration = 0
        private var viewportReflowSettleGeneration = 0
        private var isViewportRestorePending = false
        private var contentTransition = AgentTranscriptContentTransition()
        private var wasNearTop = false
        private var pendingPrependAnchor: (documentHeight: CGFloat, offsetFromTop: CGFloat)?
        private var handledScrollToBottomRequestToken: Int?

        deinit {
            removeObservers()
        }

        func attachIfNeeded(from view: NSView) {
            guard let candidate = enclosingScrollView(from: view) else { return }
            let candidateDocument = candidate.documentView
            guard scrollView !== candidate || documentView !== candidateDocument else { return }

            // SwiftUI occasionally rebuilds the underlying scroll or document
            // view when the surrounding structure changes (side panel mount /
            // unmount). The fresh view starts at the document top; without
            // carrying the anchor across the swap an off-bottom reader lands
            // at the top of the conversation with no restore path.
            let carriedAnchor = viewportAnchor
            let wasContentTransitionActive = contentTransition.isActive
            removeObservers()
            scrollView = candidate
            documentView = candidateDocument

            let clipView = candidate.contentView
            clipView.postsBoundsChangedNotifications = true
            if let candidateDocument {
                candidateDocument.postsFrameChangedNotifications = true
                candidateDocument.postsBoundsChangedNotifications = true
            }

            let center = NotificationCenter.default
            notificationTokens.append(
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleViewportChange()
                }
            )
            if let candidateDocument {
                notificationTokens.append(
                    center.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: candidateDocument,
                        queue: .main
                    ) { [weak self] _ in
                        self?.handleDocumentGeometryChange()
                    }
                )
                notificationTokens.append(
                    center.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: candidateDocument,
                        queue: .main
                    ) { [weak self] _ in
                        self?.handleDocumentGeometryChange()
                    }
                )
            }
            if isFollowingBottom {
                scrollToBottom(candidate)
                publish(true)
            } else if let carriedAnchor {
                // Reuse the reflow machinery: the rebuilt document reaches its
                // final height over several layout passes, and a one-shot
                // restore against the first (short) pass would land wrong.
                scheduleViewportReflowRestore(carriedAnchor, in: candidate)
            } else {
                publish(isNearBottom(in: candidate))
            }
            // A view rebuild mid-swap (session switch racing a structure
            // change) must not drop the clamp protection removeObservers just
            // cancelled — the new document's layout burst is still coming.
            if wasContentTransitionActive {
                beginContentTransition()
            }
            wasNearTop = isNearTop(in: candidate)
            lastDocumentSize = candidateDocument?.bounds.size
            lastViewportSize = clipView.bounds.size
            if !isViewportRestorePending {
                captureViewportAnchor(in: candidate)
            }
        }

        private func enclosingScrollView(from view: NSView) -> NSScrollView? {
            var candidate = view.superview
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                candidate = current.superview
            }
            return nil
        }

        private func handleViewportChange() {
            guard let scrollView else { return }
            let currentViewportSize = scrollView.contentView.bounds.size
            let viewportWidthChanged = AgentTranscriptViewportPolicy.widthChanged(
                from: lastViewportSize?.width,
                to: currentViewportSize.width,
                tolerance: Self.geometryTolerance
            )
            lastViewportSize = currentViewportSize

            // A content replacement is in flight (session switch). AppKit
            // clamps the clip view through arbitrary offsets — including the
            // document top — while TextKit rebuilds the history. None of that
            // is operator scrolling: reading a transient top here as "the
            // user scrolled away from the bottom" turned follow-bottom off
            // and left the freshly selected conversation parked at its start.
            // Ignore without extending the transaction — extending on
            // viewport changes would let an operator's own early wheel ticks
            // hold the window open indefinitely; only document geometry
            // (TextKit's side) keeps it alive.
            if contentTransition.isActive {
                return
            }

            // Opening/closing Files, Terminal, Preview, Plan, etc. first
            // resizes the chat viewport and only afterwards reflows the
            // document. That bounds notification is layout, not operator
            // scrolling. If it is allowed to run through the normal path,
            // the transient top/zero offset can overwrite viewportAnchor;
            // the following document resize then faithfully "restores" the
            // transcript to the top. Preserve the pre-resize anchor instead.
            if viewportWidthChanged {
                let followsBottom = AgentTranscriptScrollPolicy.followingBottomAfterViewportChange(
                    current: isFollowingBottom,
                    isNearBottom: isNearBottom(in: scrollView),
                    viewportWidthChanged: true
                )
                if followsBottom {
                    cancelPendingViewportRestore()
                    scrollToBottom(scrollView)
                    publish(true)
                    captureViewportAnchor(in: scrollView)
                } else if let viewportAnchor {
                    scheduleViewportReflowRestore(viewportAnchor, in: scrollView)
                }
                return
            }
            if viewportReflowState.isActive {
                return
            }
            // Publish before the top check so the arming decision sees this
            // very tick's follow state — a fast drag from bottom to top can
            // deliver "left the bottom" and "reached the top" in one bounds
            // notification, and that scroll IS a legitimate history request.
            publish(
                AgentTranscriptScrollPolicy.followingBottomAfterViewportChange(
                    current: isFollowingBottom,
                    isNearBottom: isNearBottom(in: scrollView),
                    viewportWidthChanged: false
                )
            )
            let nowNearTop = isNearTop(in: scrollView)
            if AgentTranscriptScrollPolicy.shouldRequestEarlierHistory(
                nowNearTop: nowNearTop,
                wasNearTop: wasNearTop,
                isFollowingBottom: isFollowingBottom,
                isRestorePending: isViewportRestorePending,
                isContentTransitionActive: contentTransition.isActive
            ),
               let metrics = viewportMetrics(in: scrollView),
               onReachTop?() == true {
                pendingPrependAnchor = (metrics.documentHeight, metrics.offsetFromTop)
            }
            wasNearTop = nowNearTop
            scheduleViewportAnchorCapture(in: scrollView)
        }

        /// Imperative navigation reset used when a different conversation is
        /// selected. The SwiftUI scroll proxy can run before TextKit finishes
        /// replacing the history string; this AppKit-side request updates the
        /// follow intent immediately and lets subsequent geometry changes keep
        /// pinning the final document height.
        func requestScrollToBottom(token: Int?) {
            guard let token else { return }
            guard handledScrollToBottomRequestToken != token else { return }
            handledScrollToBottomRequestToken = token
            isFollowingBottom = true
            cancelPendingViewportRestore()
            // A stale prepend anchor from the previous conversation must not
            // survive the switch: the next document growth (the new session's
            // history being laid out) would satisfy its height check, "restore"
            // a near-top offset, and switch follow-bottom off.
            pendingPrependAnchor = nil
            wasNearTop = false
            // The content swap that follows produces a burst of clamped
            // intermediate offsets; treat them as layout until it settles.
            beginContentTransition()
            guard let scrollView else { return }
            scrollToBottom(scrollView)
            captureViewportAnchor(in: scrollView)
        }

        private func handleDocumentGeometryChange() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let previousSize = lastDocumentSize
            let currentSize = documentView.bounds.size
            lastDocumentSize = currentSize

            // Session-switch content swap: keep pinning the growing document
            // to the bottom and keep the transaction open while geometry is
            // still churning. Document growth is TextKit's doing, never the
            // operator's, so pinning here cannot fight a real scroll.
            if contentTransition.isActive {
                if isFollowingBottom {
                    scrollToBottom(scrollView)
                }
                scheduleContentTransitionSettlement()
                return
            }

            if let pending = pendingPrependAnchor,
               currentSize.height > pending.documentHeight + Self.geometryTolerance {
                let insertedHeight = currentSize.height - pending.documentHeight
                restoreOffsetFromTop(pending.offsetFromTop + insertedHeight, in: scrollView)
                pendingPrependAnchor = nil
                publish(false)
                captureViewportAnchor(in: scrollView)
                return
            }

            if isFollowingBottom {
                cancelPendingViewportRestore()
                scrollToBottom(scrollView)
                publish(true)
                captureViewportAnchor(in: scrollView)
                return
            }

            let widthChanged = previousSize.map {
                abs($0.width - currentSize.width) > Self.geometryTolerance
            } ?? false
            if widthChanged, let viewportAnchor {
                scheduleViewportReflowRestore(viewportAnchor, in: scrollView)
            } else if let preservedAnchor = viewportReflowState.preservedAnchor {
                // Text wrapping can publish the new width and height in
                // separate notifications. Re-apply the original anchor after
                // every geometry step. Height-only changes do not extend the
                // settle window: a streaming reply may keep growing for many
                // seconds and must not leave the resize transaction open.
                scheduleViewportReflowRestore(
                    preservedAnchor,
                    in: scrollView,
                    extendsSettlement: false
                )
            } else if !isViewportRestorePending {
                if isNearBottom(in: scrollView) {
                    publish(true)
                }
                // Height-only growth (a streaming reply while the operator is
                // scrolled up) changes what the stored relative progress means,
                // but produces no clip-view bounds notification — the offset
                // is unchanged. Without a recapture here the anchor goes stale
                // against the new height, and the next side-panel toggle
                // "restores" a position from a document that no longer exists;
                // an anchor captured early in a long stream mapped back to the
                // top of the conversation.
                scheduleViewportAnchorCapture(in: scrollView)
            }
        }

        /// Bounds notifications can be emitted during the same layout pass
        /// that changes the document width. Defer the capture so a transient
        /// zero/top offset cannot overwrite the last operator-selected anchor
        /// before the width-change handler restores it.
        private func scheduleViewportAnchorCapture(in scrollView: NSScrollView) {
            viewportCaptureGeneration += 1
            let generation = viewportCaptureGeneration
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      let scrollView,
                      generation == self.viewportCaptureGeneration,
                      !self.isViewportRestorePending else {
                    return
                }
                self.captureViewportAnchor(in: scrollView)
            }
        }

        private func captureViewportAnchor(in scrollView: NSScrollView) {
            guard let metrics = viewportMetrics(in: scrollView) else {
                viewportAnchor = nil
                return
            }
            viewportAnchor = ViewportAnchor(
                relativeProgress: AgentTranscriptViewportPolicy.relativeProgress(
                    documentHeight: metrics.documentHeight,
                    viewportHeight: metrics.viewportHeight,
                    offsetFromTop: metrics.offsetFromTop
                ),
                followsBottom: isFollowingBottom
            )
        }

        private func scheduleViewportReflowRestore(
            _ anchor: ViewportAnchor,
            in scrollView: NSScrollView,
            extendsSettlement: Bool = true
        ) {
            let preservedAnchor = viewportReflowState.preserve(anchor)
            isViewportRestorePending = true
            viewportCaptureGeneration += 1
            viewportRestoreGeneration += 1
            let generation = viewportRestoreGeneration
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      let scrollView,
                      generation == self.viewportRestoreGeneration else {
                    return
                }
                self.restoreViewport(preservedAnchor, in: scrollView)
            }
            if extendsSettlement {
                scheduleViewportReflowSettlement(in: scrollView)
            }
        }

        /// A side-panel drag produces a burst of width and TextKit height
        /// changes. Finalize only after that burst has gone quiet, otherwise
        /// one intermediate frame can capture the temporary top position and
        /// make the next drag tick restore to zero.
        private func scheduleViewportReflowSettlement(in scrollView: NSScrollView) {
            viewportReflowSettleGeneration += 1
            let generation = viewportReflowSettleGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.reflowSettleDelay) { [weak self, weak scrollView] in
                guard let self,
                      let scrollView,
                      generation == self.viewportReflowSettleGeneration,
                      let preservedAnchor = self.viewportReflowState.finish() else {
                    return
                }
                self.restoreViewport(preservedAnchor, in: scrollView)
                self.isViewportRestorePending = false
                self.publish(self.isNearBottom(in: scrollView))
                self.captureViewportAnchor(in: scrollView)
            }
        }

        private func cancelPendingViewportRestore() {
            viewportRestoreGeneration += 1
            viewportReflowSettleGeneration += 1
            viewportReflowState.cancel()
            isViewportRestorePending = false
        }

        private func beginContentTransition() {
            scheduleContentTransitionSettlement(generation: contentTransition.begin())
        }

        /// Extends the open transaction (no-op when none is active) and arms
        /// the settle check for the newest generation.
        private func scheduleContentTransitionSettlement() {
            guard let generation = contentTransition.extend() else { return }
            scheduleContentTransitionSettlement(generation: generation)
        }

        private func scheduleContentTransitionSettlement(generation: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.contentTransitionSettleDelay) { [weak self] in
                guard let self, self.contentTransition.settle(generation: generation) else { return }
                guard let scrollView = self.scrollView else { return }
                // Converge the last frame: a clamp that arrived after the
                // final document change would otherwise become the resting
                // position with follow silently flipped off. A user who
                // scrolled up within the short window gets pulled back once —
                // consistent with "switching sessions opens at the latest
                // message".
                if self.isFollowingBottom, !self.isNearBottom(in: scrollView) {
                    self.scrollToBottom(scrollView)
                }
                self.publish(self.isNearBottom(in: scrollView))
                self.wasNearTop = self.isNearTop(in: scrollView)
                self.captureViewportAnchor(in: scrollView)
            }
        }

        private func restoreViewport(_ anchor: ViewportAnchor, in scrollView: NSScrollView) {
            if anchor.followsBottom {
                scrollToBottom(scrollView)
                return
            }
            guard let documentView = scrollView.documentView,
                  let metrics = viewportMetrics(in: scrollView) else {
                return
            }
            let offsetFromTop = AgentTranscriptViewportPolicy.restoredOffsetFromTop(
                progress: anchor.relativeProgress,
                documentHeight: metrics.documentHeight,
                viewportHeight: metrics.viewportHeight
            )
            let targetY: CGFloat
            if documentView.isFlipped {
                targetY = documentView.bounds.minY + offsetFromTop
            } else {
                targetY = documentView.bounds.maxY - metrics.viewportHeight - offsetFromTop
            }
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        private func viewportMetrics(
            in scrollView: NSScrollView
        ) -> (documentHeight: CGFloat, viewportHeight: CGFloat, offsetFromTop: CGFloat)? {
            guard let documentView = scrollView.documentView else { return nil }
            let visible = scrollView.contentView.documentVisibleRect
            let bounds = documentView.bounds
            let offsetFromTop: CGFloat
            if documentView.isFlipped {
                offsetFromTop = visible.minY - bounds.minY
            } else {
                offsetFromTop = bounds.maxY - visible.maxY
            }
            return (
                documentHeight: bounds.height,
                viewportHeight: visible.height,
                offsetFromTop: max(0, offsetFromTop)
            )
        }

        private func isNearBottom(in scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            let bounds = documentView.bounds
            guard bounds.height > visible.height else { return true }

            let distance: CGFloat
            if documentView.isFlipped {
                distance = bounds.maxY - visible.maxY
            } else {
                distance = visible.minY - bounds.minY
            }
            return distance <= Self.bottomTolerance
        }

        private func isNearTop(in scrollView: NSScrollView) -> Bool {
            guard let metrics = viewportMetrics(in: scrollView) else { return true }
            return metrics.offsetFromTop <= Self.topTolerance
        }

        private func restoreOffsetFromTop(_ offset: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let bounds = documentView.bounds
            let viewportHeight = clipView.documentVisibleRect.height
            let bounded = min(max(offset, 0), max(0, bounds.height - viewportHeight))
            let targetY = documentView.isFlipped
                ? bounds.minY + bounded
                : bounds.maxY - viewportHeight - bounded
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        private func scrollToBottom(_ scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let bounds = documentView.bounds
            let targetY: CGFloat
            if documentView.isFlipped {
                targetY = max(bounds.minY, bounds.maxY - clipView.bounds.height)
            } else {
                targetY = bounds.minY
            }
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        private func publish(_ value: Bool) {
            guard isFollowingBottom != value else { return }
            isFollowingBottom = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFollowingBottom == value else { return }
                self.onChange?(value)
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            notificationTokens.forEach(center.removeObserver)
            notificationTokens.removeAll()
            viewportCaptureGeneration += 1
            viewportRestoreGeneration += 1
            viewportReflowSettleGeneration += 1
            viewportReflowState.cancel()
            isViewportRestorePending = false
            contentTransition.cancel()
            lastDocumentSize = nil
            lastViewportSize = nil
            viewportAnchor = nil
            pendingPrependAnchor = nil
            wasNearTop = false
        }
    }
}
