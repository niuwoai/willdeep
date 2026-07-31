//
//  AgentComputerUseFloatingPanel.swift
//  WillDeep
//
//  One global Computer Use presence surface: the conversation owns the
//  control card and window thumbnail, while this controller contributes only
//  a compact target-app + Computer Use menu-bar item and local preview feed.
//

import AppKit
import Combine
import Foundation

nonisolated enum AgentComputerUseStatusItemPolicy {
    static let previewRefreshInterval: TimeInterval = 1.5
    static let previewRetryInterval: TimeInterval = 5
    static let menuBarIconSize = CGSize(width: 30, height: 18)

    static func shouldPresent(
        state: AgentComputerUseControlState
    ) -> Bool {
        state.phase != .idle && state.lease != nil
    }

    static func shouldRefreshPreview(
        phase: AgentComputerUseControlPhase
    ) -> Bool {
        phase == .observing || phase == .controlling
    }

    static func shouldShowPreview(
        phase: AgentComputerUseControlPhase
    ) -> Bool {
        shouldRefreshPreview(phase: phase) || phase == .failed
    }
}

@MainActor
final class AgentComputerUseStatusController {
    static let shared = AgentComputerUseStatusController(
        coordinator: .shared
    )

    private let coordinator: AgentComputerUseCoordinator
    private let notificationCenter: NotificationCenter
    private let statusBar: NSStatusBar
    private var stateCancellable: AnyCancellable?
    private var controlIntentObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var previewTask: Task<Void, Never>?
    private var previewLeaseID: AgentComputerUseLease.ID?
    private var isInstalled = false

    init(
        coordinator: AgentComputerUseCoordinator,
        notificationCenter: NotificationCenter = .default,
        statusBar: NSStatusBar = .system
    ) {
        self.coordinator = coordinator
        self.notificationCenter = notificationCenter
        self.statusBar = statusBar
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
        stopPreviewLoop()
        removeStatusItem()
        isInstalled = false
    }

    deinit {
        stateCancellable?.cancel()
        previewTask?.cancel()
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
        guard AgentComputerUseStatusItemPolicy.shouldPresent(state: state),
              let lease = state.lease else {
            stopPreviewLoop()
            removeStatusItem()
            return
        }

        updateStatusItem(state: state, lease: lease)
        if AgentComputerUseStatusItemPolicy.shouldRefreshPreview(
            phase: state.phase
        ) {
            startPreviewLoop(for: lease)
        } else {
            stopPreviewLoop()
        }
    }

    private func updateStatusItem(
        state: AgentComputerUseControlState,
        lease: AgentComputerUseLease
    ) {
        let item = statusItem ?? statusBar.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem = item
        let targetName = displayName(for: lease.target)
        let accessibilityLabel = [
            L10n.ComputerUsePreview.statusAccessibility,
            targetName,
            phaseTitle(for: state.phase),
        ].joined(separator: ", ")
        if let button = item.button {
            button.image = menuBarImage(for: lease.target)
            button.imagePosition = .imageOnly
            button.toolTip = accessibilityLabel
            button.setAccessibilityLabel(accessibilityLabel)
        }
        item.menu = statusMenu(state: state, lease: lease)
    }

    private func statusMenu(
        state: AgentComputerUseControlState,
        lease: AgentComputerUseLease
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary = NSMenuItem(
            title: "\(phaseTitle(for: state.phase)) · \(displayName(for: lease.target))",
            action: nil,
            keyEquivalent: ""
        )
        summary.image = targetApplicationIcon(for: lease.target)
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let actions = AgentComputerUsePresentationPolicy.actions(
            for: state.phase
        )
        if actions.showsPause {
            addMenuItem(
                to: menu,
                title: L10n.ComputerUsePreview.pause,
                symbol: "pause.fill",
                action: #selector(pauseComputerUse)
            )
        }
        if actions.showsTakeover {
            addMenuItem(
                to: menu,
                title: L10n.ComputerUsePreview.takeOver,
                symbol: "hand.raised.fill",
                action: #selector(takeOverComputerUse)
            )
        }
        if actions.showsResume {
            addMenuItem(
                to: menu,
                title: L10n.ComputerUsePreview.resume,
                symbol: "play.fill",
                action: #selector(resumeComputerUse)
            )
        }
        if actions.showsStop {
            addMenuItem(
                to: menu,
                title: L10n.ComputerUsePreview.stop,
                symbol: "stop.fill",
                action: #selector(stopComputerUse)
            )
        }
        return menu
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        symbol: String,
        action: Selector
    ) {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func pauseComputerUse() {
        coordinator.pause(leaseID: coordinator.state.lease?.id)
    }

    @objc private func takeOverComputerUse() {
        coordinator.takeover(leaseID: coordinator.state.lease?.id)
    }

    @objc private func resumeComputerUse() {
        coordinator.resume(leaseID: coordinator.state.lease?.id)
    }

    @objc private func stopComputerUse() {
        coordinator.stop(leaseID: coordinator.state.lease?.id)
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        statusBar.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func startPreviewLoop(
        for lease: AgentComputerUseLease
    ) {
        guard previewLeaseID != lease.id || previewTask == nil else {
            return
        }
        stopPreviewLoop()
        previewLeaseID = lease.id
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let captured = await self.refreshPreview(
                    leaseID: lease.id
                )
                let delay = captured
                    ? AgentComputerUseStatusItemPolicy.previewRefreshInterval
                    : AgentComputerUseStatusItemPolicy.previewRetryInterval
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func stopPreviewLoop() {
        previewTask?.cancel()
        previewTask = nil
        previewLeaseID = nil
    }

    private func refreshPreview(
        leaseID: AgentComputerUseLease.ID
    ) async -> Bool {
        guard let lease = coordinator.state.lease,
              lease.id == leaseID,
              AgentComputerUseStatusItemPolicy.shouldRefreshPreview(
                phase: coordinator.state.phase
              ),
              let privacyEpoch = coordinator.beginLocalObservation() else {
            return false
        }

        var arguments: [String: AgentJSONValue] = [:]
        if let pid = lease.target.pid {
            arguments["pid"] = .number(Double(pid))
        } else if let bundleIdentifier = lease.target.bundleIdentifier {
            arguments["app"] = .string(bundleIdentifier)
        } else {
            arguments["app"] = .string(lease.target.applicationName)
        }

        do {
            let result = try await AgentComputerUseBridge.shared.invoke(
                action: "capture_control_preview",
                arguments: arguments,
                controlLeaseID: lease.id.uuidString.lowercased()
            )
            guard let screenshot = result["screenshot"] as? [String: Any],
                  let path = screenshot["path"] as? String,
                  !path.isEmpty else {
                return false
            }
            let capturedAt = Date()
            let activity = AgentComputerUseActivity(
                image: AgentImageAttachment(
                    mimeType: "image/jpeg",
                    filePath: path,
                    source: .capture,
                    createdAt: capturedAt
                ),
                toolName: "computer_use_preview",
                capturedAt: capturedAt
            )
            return coordinator.publishLocalPreview(
                activity,
                leaseID: lease.id,
                startedAtPrivacyEpoch: privacyEpoch
            )
        } catch {
            return false
        }
    }

    private func menuBarImage(
        for target: AgentComputerUseTarget
    ) -> NSImage {
        let size = AgentComputerUseStatusItemPolicy.menuBarIconSize
        let targetIcon = targetApplicationIcon(for: target)
        let marker = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: L10n.ComputerUsePreview.statusAccessibility
        ) ?? NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: L10n.ComputerUsePreview.statusAccessibility
        )
        let image = NSImage(size: size, flipped: false) { _ in
            targetIcon.draw(
                in: CGRect(x: 0, y: 1, width: 17, height: 17),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(
                roundedRect: CGRect(x: 14, y: 0, width: 16, height: 16),
                xRadius: 5,
                yRadius: 5
            ).fill()
            marker?.draw(
                in: CGRect(x: 16, y: 2, width: 12, height: 12),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private func targetApplicationIcon(
        for target: AgentComputerUseTarget
    ) -> NSImage {
        if let pid = target.pid,
           let processIdentifier = pid_t(exactly: pid),
           let app = NSRunningApplication(processIdentifier: processIdentifier),
           let icon = app.icon {
            return icon
        }
        if let bundleIdentifier = target.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
           ) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(
            systemSymbolName: "macwindow",
            accessibilityDescription: displayName(for: target)
        ) ?? NSImage(size: CGSize(width: 17, height: 17))
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
}
