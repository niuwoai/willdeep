//
//  AgentComputerUseFloatingPanel.swift
//  WillDeep
//
//  A compact, non-activating control strip that remains visible above the
//  target macOS application while a global Computer Use lease is active.
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

nonisolated enum AgentComputerUseFloatingPanelPolicy {
    static let preferredSize = CGSize(width: 660, height: 70)
    static let minimumHorizontalInset: CGFloat = 16
    static let bottomInset: CGFloat = 18

    static func shouldPresent(
        state: AgentComputerUseControlState
    ) -> Bool {
        state.phase != .idle && state.lease != nil
    }

    static func size(availableWidth: CGFloat) -> CGSize {
        CGSize(
            width: min(
                preferredSize.width,
                max(320, availableWidth - (minimumHorizontalInset * 2))
            ),
            height: preferredSize.height
        )
    }

    static func origin(
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.minY + bottomInset
        )
    }

    static func displayIndex(
        forWindowBounds windowBounds: CGRect,
        displayBounds: [CGRect]
    ) -> Int? {
        var bestIndex: Int?
        var bestIntersectionArea: CGFloat = 0
        for (index, bounds) in displayBounds.enumerated() {
            let intersection = bounds.intersection(windowBounds)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }
}

@MainActor
final class AgentComputerUseFloatingPanelController {
    static let shared = AgentComputerUseFloatingPanelController(
        coordinator: .shared
    )

    private let coordinator: AgentComputerUseCoordinator
    private let notificationCenter: NotificationCenter
    private var stateCancellable: AnyCancellable?
    private var controlIntentObserver: NSObjectProtocol?
    private var panel: NSPanel?
    private var isInstalled = false
    private var presentedLeaseID: AgentComputerUseLease.ID?
    private var positionedTargetPID: Int?

    init(
        coordinator: AgentComputerUseCoordinator,
        notificationCenter: NotificationCenter = .default
    ) {
        self.coordinator = coordinator
        self.notificationCenter = notificationCenter
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        controlIntentObserver = notificationCenter.addObserver(
            forName: .agentComputerUseControlIntent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let event = notification.object
                        as? AgentComputerUseControlIntentEvent else {
                    return
                }
                self.handleControlIntent(event)
            }
        }
        stateCancellable = coordinator.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    self?.updatePresentation(for: state)
                }
            }
    }

    func uninstall() {
        stateCancellable?.cancel()
        stateCancellable = nil
        if let controlIntentObserver {
            notificationCenter.removeObserver(controlIntentObserver)
        }
        controlIntentObserver = nil
        panel?.orderOut(nil)
        panel = nil
        presentedLeaseID = nil
        positionedTargetPID = nil
        isInstalled = false
    }

    deinit {
        stateCancellable?.cancel()
        if let controlIntentObserver {
            notificationCenter.removeObserver(controlIntentObserver)
        }
    }

    private func handleControlIntent(
        _ event: AgentComputerUseControlIntentEvent
    ) {
        guard let appState = EditorAppStateRegistry.shared.appState(
            forRuntime: event.lease.owner.runtimeID
        ) else {
            return
        }
        appState.handleComputerUseControlIntent(event)
    }

    private func updatePresentation(
        for state: AgentComputerUseControlState
    ) {
        guard AgentComputerUseFloatingPanelPolicy.shouldPresent(state: state),
              let lease = state.lease else {
            panel?.orderOut(nil)
            presentedLeaseID = nil
            positionedTargetPID = nil
            return
        }

        let activePanel = self.panel ?? makePanel()
        let shouldPosition = presentedLeaseID != lease.id
            || positionedTargetPID != lease.target.pid
            || !activePanel.isVisible
        if shouldPosition {
            position(activePanel, for: lease.target)
        }
        presentedLeaseID = lease.id
        positionedTargetPID = lease.target.pid
        if !activePanel.isVisible {
            activePanel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: AgentComputerUseFloatingPanelPolicy.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.title = L10n.ComputerUsePreview.statusAccessibility
        panel.contentView = NSHostingView(
            rootView: AgentComputerUseFloatingControlBar(
                coordinator: coordinator
            )
        )
        self.panel = panel
        return panel
    }

    private func position(
        _ panel: NSPanel,
        for target: AgentComputerUseTarget
    ) {
        guard let screen = relevantScreen(for: target) else { return }
        let panelSize = AgentComputerUseFloatingPanelPolicy.size(
            availableWidth: screen.visibleFrame.width
        )
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(
            AgentComputerUseFloatingPanelPolicy.origin(
                panelSize: panelSize,
                visibleFrame: screen.visibleFrame
            )
        )
    }

    private func relevantScreen(
        for target: AgentComputerUseTarget
    ) -> NSScreen? {
        if let pid = target.pid,
           let targetScreen = visibleWindowScreen(forPID: pid) {
            return targetScreen
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Resolves only public window metadata (owner pid, layer, and bounds).
    /// No window title, pixels, or Accessibility content is read here.
    private func visibleWindowScreen(forPID pid: Int) -> NSScreen? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let screens = NSScreen.screens
        let displayBounds = screens.map(quartzDisplayBounds)
        var bestScreenIndex: Int?
        var bestWindowArea: CGFloat = 0

        for info in windowInfo {
            guard let ownerPID = (
                info[kCGWindowOwnerPID as String] as? NSNumber
            )?.intValue,
            ownerPID == pid,
            let layer = (
                info[kCGWindowLayer as String] as? NSNumber
            )?.intValue,
            layer == 0,
            let boundsDictionary = info[kCGWindowBounds as String]
                as? [String: Any],
            let windowBounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
            ),
            windowBounds.width > 1,
            windowBounds.height > 1,
            let screenIndex = AgentComputerUseFloatingPanelPolicy.displayIndex(
                forWindowBounds: windowBounds,
                displayBounds: displayBounds
            ) else {
                continue
            }

            let intersection = displayBounds[screenIndex].intersection(
                windowBounds
            )
            let area = intersection.width * intersection.height
            if area > bestWindowArea {
                bestWindowArea = area
                bestScreenIndex = screenIndex
            }
        }

        guard let bestScreenIndex else { return nil }
        return screens[bestScreenIndex]
    }

    private func quartzDisplayBounds(for screen: NSScreen) -> CGRect {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[screenNumberKey]
            as? NSNumber else {
            return .null
        }
        return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
    }
}

private struct AgentComputerUseFloatingControlBar: View {
    @ObservedObject var coordinator: AgentComputerUseCoordinator

    var body: some View {
        Group {
            if let lease = coordinator.state.lease {
                controlBar(
                    state: coordinator.state,
                    lease: lease
                )
            } else {
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    private func controlBar(
        state: AgentComputerUseControlState,
        lease: AgentComputerUseLease
    ) -> some View {
        let actions = AgentComputerUsePresentationPolicy.actions(
            for: state.phase
        )

        return HStack(spacing: 10) {
            Image(systemName: phaseSymbol(for: state.phase))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phaseTint(for: state.phase))
                .frame(width: 28, height: 28)
                .background(
                    phaseTint(for: state.phase).opacity(0.13),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(phaseTitle(for: state.phase))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(phaseTint(for: state.phase))
                    .lineLimit(1)

                Text(displayName(for: lease.target))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 150, alignment: .leading)

            Divider()
                .frame(height: 30)

            Text(L10n.ComputerUsePreview.owningTask(lease.owner.sessionTitle))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)

            Spacer(minLength: 0)

            if state.phase == .stopping {
                ProgressView()
                    .controlSize(.small)
            }

            actionButtons(actions: actions, leaseID: lease.id)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.13), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("computer-use-floating-control-bar")
        .accessibilityLabel(L10n.ComputerUsePreview.statusAccessibility)
    }

    @ViewBuilder
    private func actionButtons(
        actions: AgentComputerUsePresentationActions,
        leaseID: AgentComputerUseLease.ID
    ) -> some View {
        HStack(spacing: 6) {
            if actions.showsPause {
                actionButton(
                    title: L10n.ComputerUsePreview.pause,
                    symbol: "pause.fill"
                ) {
                    coordinator.pause(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-floating-pause")
            }

            if actions.showsTakeover {
                actionButton(
                    title: L10n.ComputerUsePreview.takeOver,
                    symbol: "hand.raised.fill"
                ) {
                    coordinator.takeover(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-floating-takeover")
            }

            if actions.showsResume {
                actionButton(
                    title: L10n.ComputerUsePreview.resume,
                    symbol: "play.fill"
                ) {
                    coordinator.resume(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-floating-resume")
            }

            if actions.showsStop {
                actionButton(
                    title: L10n.ComputerUsePreview.stop,
                    symbol: "stop.fill",
                    tint: .red
                ) {
                    coordinator.stop(leaseID: leaseID)
                }
                .accessibilityIdentifier("computer-use-floating-stop")
            }
        }
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(tint)
    }

    private func displayName(
        for target: AgentComputerUseTarget
    ) -> String {
        let value = target.applicationName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? L10n.ComputerUsePreview.unknownTarget : value
    }

    private func phaseTitle(
        for phase: AgentComputerUseControlPhase
    ) -> String {
        switch phase {
        case .idle: return L10n.ComputerUsePreview.idle
        case .observing: return L10n.ComputerUsePreview.observing
        case .controlling: return L10n.ComputerUsePreview.controlling
        case .paused: return L10n.ComputerUsePreview.paused
        case .userTakeover: return L10n.ComputerUsePreview.userTakeover
        case .stopping: return L10n.ComputerUsePreview.stopping
        case .failed: return L10n.ComputerUsePreview.failed
        }
    }

    private func phaseSymbol(
        for phase: AgentComputerUseControlPhase
    ) -> String {
        switch phase {
        case .idle: return "circle"
        case .observing: return "eye.fill"
        case .controlling: return "cursorarrow.motionlines"
        case .paused: return "pause.fill"
        case .userTakeover: return "hand.raised.fill"
        case .stopping: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func phaseTint(
        for phase: AgentComputerUseControlPhase
    ) -> Color {
        switch phase {
        case .idle: return .secondary
        case .observing: return .blue
        case .controlling: return .accentColor
        case .paused: return .orange
        case .userTakeover: return .green
        case .stopping: return .secondary
        case .failed: return .red
        }
    }
}
