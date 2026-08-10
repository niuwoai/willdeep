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
    static func shouldScrollAfterAppending(
        _ message: AgentMessage?,
        isFollowingBottom: Bool
    ) -> Bool {
        isFollowingBottom || message?.isOperatorInput == true
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
        private static let geometryTolerance: CGFloat = 0.5

        private struct ViewportAnchor {
            let relativeProgress: CGFloat
            let followsBottom: Bool
        }

        weak var scrollView: NSScrollView?
        weak var documentView: NSView?
        var isFollowingBottom = true
        var onChange: ((Bool) -> Void)?
        private var notificationTokens: [NSObjectProtocol] = []
        private var lastDocumentSize: CGSize?
        private var lastViewportSize: CGSize?
        private var viewportAnchor: ViewportAnchor?
        private var viewportCaptureGeneration = 0
        private var viewportRestoreGeneration = 0
        private var isViewportRestorePending = false

        deinit {
            removeObservers()
        }

        func attachIfNeeded(from view: NSView) {
            guard let candidate = enclosingScrollView(from: view) else { return }
            let candidateDocument = candidate.documentView
            guard scrollView !== candidate || documentView !== candidateDocument else { return }

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
            publish(isNearBottom(in: candidate))
            lastDocumentSize = candidateDocument?.bounds.size
            lastViewportSize = clipView.bounds.size
            captureViewportAnchor(in: candidate)
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

            // Opening/closing Files, Terminal, Preview, Plan, etc. first
            // resizes the chat viewport and only afterwards reflows the
            // document. That bounds notification is layout, not operator
            // scrolling. If it is allowed to run through the normal path,
            // the transient top/zero offset can overwrite viewportAnchor;
            // the following document resize then faithfully "restores" the
            // transcript to the top. Preserve the pre-resize anchor instead.
            if viewportWidthChanged,
               !isFollowingBottom,
               let viewportAnchor {
                scheduleViewportRestore(viewportAnchor, in: scrollView)
                return
            }
            publish(isNearBottom(in: scrollView))
            scheduleViewportAnchorCapture(in: scrollView)
        }

        private func handleDocumentGeometryChange() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let previousSize = lastDocumentSize
            let currentSize = documentView.bounds.size
            lastDocumentSize = currentSize

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
                scheduleViewportRestore(viewportAnchor, in: scrollView)
            } else if !isViewportRestorePending, isNearBottom(in: scrollView) {
                publish(true)
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

        private func scheduleViewportRestore(
            _ anchor: ViewportAnchor,
            in scrollView: NSScrollView
        ) {
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
                self.restoreViewport(anchor, in: scrollView)
                self.isViewportRestorePending = false
                self.publish(self.isNearBottom(in: scrollView))
                self.captureViewportAnchor(in: scrollView)
            }
        }

        private func cancelPendingViewportRestore() {
            viewportRestoreGeneration += 1
            isViewportRestorePending = false
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
            isViewportRestorePending = false
            lastDocumentSize = nil
            lastViewportSize = nil
            viewportAnchor = nil
        }
    }
}
