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

        weak var scrollView: NSScrollView?
        weak var documentView: NSView?
        var isFollowingBottom = true
        var onChange: ((Bool) -> Void)?
        private var notificationTokens: [NSObjectProtocol] = []

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
            publish(isNearBottom(in: scrollView))
        }

        private func handleDocumentGeometryChange() {
            guard let scrollView else { return }
            if isFollowingBottom {
                scrollToBottom(scrollView)
                publish(true)
            } else if isNearBottom(in: scrollView) {
                publish(true)
            }
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
        }
    }
}
