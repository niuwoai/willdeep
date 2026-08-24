//
//  AgentDockAttention.swift
//  WillDeep
//
//  Turns the Dock badge into something you can act on. macOS gives no click
//  event for the badge itself — the only signal is "the user clicked the Dock
//  icon" — so a double-click on the icon is what jumps to the session that is
//  waiting. The Dock icon's right-click menu lists the waiting sessions
//  outright, which is the discoverable path to the same place.
//

import AppKit
import Foundation

enum AgentDockReopenGesture {
    /// Matches the system double-click threshold closely enough without
    /// reading the user's mouse preferences on every Dock click. Anything
    /// slower is two separate "bring the app forward" clicks.
    static let doubleClickInterval: TimeInterval = 0.6

    /// Two Dock clicks inside the window count as a double-click. The first
    /// click keeps its normal meaning (activate / restore windows); only the
    /// second one navigates.
    nonisolated static func isDoubleClick(
        previousClick: Date?,
        currentClick: Date,
        interval: TimeInterval = doubleClickInterval
    ) -> Bool {
        guard let previousClick else { return false }
        let elapsed = currentClick.timeIntervalSince(previousClick)
        return elapsed >= 0 && elapsed <= interval
    }
}

@MainActor
final class AgentDockAttentionController: NSObject {
    static let shared = AgentDockAttentionController()

    private var lastDockClickAt: Date?

    private override init() {
        super.init()
    }

    /// Called from `applicationShouldHandleReopen`. Returns true when the
    /// click was consumed as a double-click and navigation happened.
    @discardableResult
    func handleDockIconClick(at now: Date = Date()) -> Bool {
        let isDoubleClick = AgentDockReopenGesture.isDoubleClick(
            previousClick: lastDockClickAt,
            currentClick: now
        )
        // Reset rather than extend, so a triple-click is not read as two
        // consecutive jumps.
        lastDockClickAt = isDoubleClick ? nil : now
        guard isDoubleClick else { return false }
        guard let entry = AgentDockBadgeCoordinator.shared.allPendingEntries.first else { return false }
        AgentNotificationResponder.reveal(runtimeID: entry.sessionID)
        return true
    }

    /// The Dock icon's right-click menu. Nil when nothing is waiting, so the
    /// menu stays empty instead of showing a dead header.
    func makeDockMenu() -> NSMenu? {
        let entries = AgentDockBadgeCoordinator.shared.allPendingEntries
        guard !entries.isEmpty else { return nil }

        let menu = NSMenu()
        let header = NSMenuItem(title: L10n.Dock.pendingApprovalHeader, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for entry in entries.prefix(AgentSessionApprovalBadgeLogic.dockMenuLimit) {
            let item = NSMenuItem(
                title: Self.menuTitle(for: entry),
                action: #selector(selectPendingSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.sessionID
            item.indentationLevel = 1
            menu.addItem(item)
        }
        return menu
    }

    /// Dock menus are narrow and unscrollable; a long session title would
    /// stretch the menu across the screen.
    nonisolated static func menuTitle(
        for entry: AgentPendingApprovalEntry,
        maximumLength: Int = 44
    ) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? L10n.Sidebar.sessionRowWaitingApproval : trimmed
        guard title.count > maximumLength else { return title }
        return title.prefix(maximumLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func selectPendingSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        AgentNotificationResponder.reveal(runtimeID: sessionID)
    }
}
