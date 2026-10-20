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

struct AgentDockSessionEntry: Identifiable, Equatable {
    let sessionID: AgentSession.ID
    let title: String
    let lastActivityAt: Date

    var id: AgentSession.ID { sessionID }
}

struct AgentDockMenuSnapshot: Equatable {
    let attention: [AgentDockSessionEntry]
    let recent: [AgentDockSessionEntry]
    let more: [AgentDockSessionEntry]

    var isEmpty: Bool {
        attention.isEmpty && recent.isEmpty && more.isEmpty
    }
}

enum AgentDockMenuLogic {
    nonisolated static let attentionLimit = 5
    nonisolated static let recentLimit = 3
    nonisolated static let moreLimit = 20

    nonisolated static func snapshot(
        recentEntries: [AgentDockSessionEntry],
        pendingEntries: [AgentPendingApprovalEntry],
        unreadSessionIDs: Set<AgentSession.ID>,
        attentionLimit: Int = attentionLimit,
        recentLimit: Int = recentLimit,
        moreLimit: Int = moreLimit
    ) -> AgentDockMenuSnapshot {
        let recent = rankAndDeduplicate(recentEntries)
        let pending = pendingEntries.map {
            AgentDockSessionEntry(
                sessionID: $0.sessionID,
                title: $0.title,
                lastActivityAt: $0.waitingSince
            )
        }
        let unread = recent.filter { unreadSessionIDs.contains($0.sessionID) }
        let attention = rankAndDeduplicate(pending + unread)

        return AgentDockMenuSnapshot(
            attention: positivePrefix(attention, limit: attentionLimit),
            recent: positivePrefix(recent, limit: recentLimit),
            more: positivePrefix(Array(recent.dropFirst(max(0, recentLimit))), limit: moreLimit)
        )
    }

    nonisolated static func rankAndDeduplicate(
        _ entries: [AgentDockSessionEntry]
    ) -> [AgentDockSessionEntry] {
        var newestBySessionID: [AgentSession.ID: AgentDockSessionEntry] = [:]
        for entry in entries {
            guard let existing = newestBySessionID[entry.sessionID] else {
                newestBySessionID[entry.sessionID] = entry
                continue
            }
            if entry.lastActivityAt > existing.lastActivityAt {
                newestBySessionID[entry.sessionID] = entry
            }
        }
        return newestBySessionID.values.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    nonisolated private static func positivePrefix(
        _ entries: [AgentDockSessionEntry],
        limit: Int
    ) -> [AgentDockSessionEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }
}

enum AgentDockReopenGesture {
    /// Reopening a plugin or another dedicated page must preserve that page.
    /// Only an already visible conversation opts into the double-click jump.
    nonisolated static func canRevealPendingSession(from destination: AgentPrimaryDestination?) -> Bool {
        destination == .conversation
    }

    /// Matches the system double-click threshold closely enough without
    /// reading the user's mouse preferences on every Dock click. Anything
    /// slower is two separate "bring the app forward" clicks.
    nonisolated static let doubleClickInterval: TimeInterval = 0.6

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
        guard AgentDockReopenGesture.canRevealPendingSession(
            from: EditorAppStateRegistry.shared.current?.agentPrimaryDestination
        ) else {
            lastDockClickAt = nil
            return false
        }
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

    /// Native Dock menu sections mirror the task-oriented structure used by
    /// Codex: sessions needing attention first, then recent chats and a
    /// bounded More submenu. macOS appends its own Options / Show All Windows
    /// / Hide / Quit items below this custom menu.
    func makeDockMenu() -> NSMenu? {
        let snapshot = Self.menuSnapshot()
        guard !snapshot.isEmpty else { return nil }

        let menu = NSMenu()
        if !snapshot.attention.isEmpty {
            addHeader(L10n.Dock.pendingApprovalHeader, to: menu)
            snapshot.attention.forEach { addSessionItem($0, to: menu) }
        }
        if !snapshot.recent.isEmpty {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            addHeader(L10n.Dock.recentHeader, to: menu)
            snapshot.recent.forEach { addSessionItem($0, to: menu) }
        }
        if !snapshot.more.isEmpty {
            let moreMenu = NSMenu()
            snapshot.more.forEach { addSessionItem($0, to: moreMenu) }
            let moreItem = NSMenuItem(title: L10n.Dock.more, action: nil, keyEquivalent: "")
            moreItem.submenu = moreMenu
            menu.addItem(moreItem)
        }
        return menu
    }

    private static func menuSnapshot() -> AgentDockMenuSnapshot {
        var recentEntries: [AgentDockSessionEntry] = []
        for appState in EditorAppStateRegistry.shared.appStatesForTerminationCheck {
            let items = AgentRecentSessionEdgeRailLogic.recentItems(
                from: appState.agentSessions,
                hiddenWorkspaceKeys: appState.hiddenWorkspaceKeys,
                limit: .max,
                projects: appState.agentProjects,
                isMetadataOnly: appState.agentSessionIsMetadataOnly,
                metadataOnlyHasUserMessage: appState.agentSessionMetadataOnlyHasUserMessage
            )
            recentEntries.append(contentsOf: items.map { item in
                let session = appState.agentRuntimes[item.session.id]?.session ?? item.session
                return AgentDockSessionEntry(
                    sessionID: session.id,
                    title: session.title,
                    lastActivityAt: session.lastActivityAt
                )
            })
        }
        return AgentDockMenuLogic.snapshot(
            recentEntries: recentEntries,
            pendingEntries: AgentDockBadgeCoordinator.shared.allPendingEntries,
            unreadSessionIDs: AgentSessionUnreadStore.load()
        )
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    private func addSessionItem(_ entry: AgentDockSessionEntry, to menu: NSMenu) {
        let item = NSMenuItem(
            title: Self.menuTitle(for: entry),
            action: #selector(selectSession(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry.sessionID
        menu.addItem(item)
    }

    /// Dock menus are narrow and unscrollable; a long session title would
    /// stretch the menu across the screen.
    nonisolated static func menuTitle(
        for entry: AgentPendingApprovalEntry,
        maximumLength: Int = 44
    ) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? L10n.Sidebar.sessionRowWaitingApproval : trimmed
        return truncatedMenuTitle(title, maximumLength: maximumLength)
    }

    nonisolated static func menuTitle(
        for entry: AgentDockSessionEntry,
        maximumLength: Int = 44
    ) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? L10n.Sidebar.defaultSessionTitle : trimmed
        return truncatedMenuTitle(title, maximumLength: maximumLength)
    }

    nonisolated private static func truncatedMenuTitle(
        _ title: String,
        maximumLength: Int
    ) -> String {
        guard title.count > maximumLength else { return title }
        return title.prefix(maximumLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? UUID else { return }
        AgentSessionUnreadStore.setUnread(sessionID, unread: false)
        AgentNotificationResponder.reveal(runtimeID: sessionID)
    }
}
