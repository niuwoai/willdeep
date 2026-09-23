//
//  AgentSessionApprovalBadge.swift
//  WillDeep
//
//  Compact sidebar badge for sessions that are blocked on user input:
//  tool approval, danger confirmation, ask_user answers, patch approval,
//  or a proposed Plan.
//

import SwiftUI
import AppKit
import Combine
import os

private let dockBadgeLog = Logger(subsystem: "com.willdeep.app", category: "dock-badge")

/// One session that is blocked on the user. Feeds the sidebar quick-jump
/// strip and the Dock icon menu; the process monitor merges approval records
/// and Runtime Event user actions into one count before publishing either UI.
struct AgentPendingApprovalEntry: Identifiable, Equatable {
    let sessionID: AgentSession.ID
    let title: String
    /// Turn start while a runtime is live, otherwise the session's last
    /// update. Sorting on it puts the most recently blocked session first.
    let waitingSince: Date

    var id: AgentSession.ID { sessionID }
}

enum AgentSessionApprovalBadgeLogic {
    /// The sidebar strip stays deliberately short — it sits above the account
    /// footer and must not grow into a second session list.
    static let quickJumpLimit = 3
    /// The Dock menu has room for a few more before it stops being a menu.
    static let dockMenuLimit = 5

    static func needsUserApproval(
        session: AgentSession,
        toolCallStatuses: [AgentToolCallStatus] = [],
        patchStatuses: [AgentPatchStatus] = [],
        planStatus: AgentPlan.Status? = nil
    ) -> Bool {
        if toolCallStatuses.contains(where: toolCallNeedsUserApproval(_:)) {
            return true
        }
        if patchStatuses.contains(.pending) {
            return true
        }
        return (planStatus ?? session.currentPlan?.status) == .proposed
    }

    /// Number shown on the Dock icon. Unlike the sidebar quick-jump list,
    /// this counts actionable requests rather than sessions: two parent tool
    /// approvals plus one delegated Worker approval must read as 3, not 1.
    /// Delegated approvals are ordinary tool-call records with a stable
    /// `subagent:` external id, so counting interactive records includes
    /// them without a second source of truth or double counting.
    static func pendingApprovalRequestCount(
        session: AgentSession,
        toolCallStatuses: [AgentToolCallStatus] = [],
        patchStatuses: [AgentPatchStatus] = [],
        planStatus: AgentPlan.Status? = nil
    ) -> Int {
        let toolRequests = toolCallStatuses.filter(toolCallNeedsUserApproval(_:)).count
        let patchRequests = patchStatuses.filter { $0 == .pending }.count
        let planRequests = (planStatus ?? session.currentPlan?.status) == .proposed ? 1 : 0
        return toolRequests + patchRequests + planRequests
    }

    @MainActor
    static func pendingAttentionRequestCount(
        session: AgentSession,
        runtime: AgentRuntime?,
        kernel: AgentRuntimeKernel
    ) -> Int {
        let approvalRequests: Int
        if let runtime {
            approvalRequests = pendingApprovalRequestCount(
                session: runtime.session,
                toolCallStatuses: runtime.toolCalls.map(\.status),
                patchStatuses: runtime.patchProposals.map(\.status),
                planStatus: runtime.currentPlan?.status
            )
        } else {
            approvalRequests = pendingApprovalRequestCount(session: session)
        }
        return approvalRequests
            + kernel.pendingUserActionCount(for: session.id, excluding: .approval)
    }

    nonisolated private static func toolCallNeedsUserApproval(_ status: AgentToolCallStatus) -> Bool {
        switch status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return false
        }
    }

    @MainActor
    static func pendingApprovalSessionCount(
        sessions: [AgentSession],
        runtimes: [AgentSession.ID: AgentRuntime] = [:]
    ) -> Int {
        sessions.reduce(into: 0) { count, session in
            guard session.archivedAt == nil else { return }
            if let runtime = runtimes[session.id] {
                if needsUserApproval(
                    session: runtime.session,
                    toolCallStatuses: runtime.toolCalls.map(\.status),
                    patchStatuses: runtime.patchProposals.map(\.status),
                    planStatus: runtime.currentPlan?.status
                ) {
                    count += 1
                }
                return
            }
            if needsUserApproval(session: session) {
                count += 1
            }
        }
    }

    /// Sessions blocked on the user, most recently blocked first. Same
    /// predicate as `pendingApprovalSessionCount`, so the strip, the Dock
    /// menu and the Dock badge can never disagree about what "waiting" means.
    @MainActor
    static func pendingApprovalEntries(
        sessions: [AgentSession],
        runtimes: [AgentSession.ID: AgentRuntime] = [:],
        limit: Int = quickJumpLimit
    ) -> [AgentPendingApprovalEntry] {
        var entries: [AgentPendingApprovalEntry] = []
        var seenSessionIDs: Set<AgentSession.ID> = []
        for session in sessions {
            guard session.archivedAt == nil, !seenSessionIDs.contains(session.id) else { continue }
            let runtime = runtimes[session.id]
            let isWaiting: Bool
            if let runtime {
                isWaiting = needsUserApproval(
                    session: runtime.session,
                    toolCallStatuses: runtime.toolCalls.map(\.status),
                    patchStatuses: runtime.patchProposals.map(\.status),
                    planStatus: runtime.currentPlan?.status
                )
            } else {
                isWaiting = needsUserApproval(session: session)
            }
            guard isWaiting else { continue }
            seenSessionIDs.insert(session.id)
            entries.append(
                AgentPendingApprovalEntry(
                    sessionID: session.id,
                    title: AgentUserInputPreview.latest(
                        in: runtime?.messages ?? session.messages
                    ) ?? "",
                    waitingSince: runtime?.turnStartedAt ?? session.updatedAt
                )
            )
        }
        return rankMostRecentFirst(entries, limit: limit)
    }

    /// Newest first, with the session id breaking ties so the strip has a
    /// stable order — Swift's sort is not stable, and a wobbling list under
    /// the account footer reads as a rendering bug.
    nonisolated static func rankMostRecentFirst(
        _ entries: [AgentPendingApprovalEntry],
        limit: Int = .max
    ) -> [AgentPendingApprovalEntry] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.waitingSince != rhs.waitingSince {
                return lhs.waitingSince > rhs.waitingSince
            }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        guard limit > 0 else { return [] }
        return Array(sorted.prefix(limit))
    }
}

@MainActor
final class AgentDockBadgeCoordinator: ObservableObject {
    static let shared = AgentDockBadgeCoordinator()

    /// Blocked sessions per window, newest first and *not* capped — the
    /// sidebar strip shows the first few but needs the full count to say how
    /// many are waiting. Keyed by `ObjectIdentifier(appState)`, so a window
    /// only ever surfaces its own sessions.
    @Published private(set) var pendingEntriesByAppState: [ObjectIdentifier: [AgentPendingApprovalEntry]] = [:]
    /// Every blocked session across all windows, newest first. Drives the
    /// Dock menu and the double-click jump, both of which are app-wide.
    @Published private(set) var allPendingEntries: [AgentPendingApprovalEntry] = []

    private var trackedAppStates: [ObjectIdentifier: AppState] = [:]
    private var appStateSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var kernelSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var runtimeListSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    /// Which runtime object each subscription above is attached to.
    private var watchedRuntimeObjects: [ObjectIdentifier: [AgentSession.ID: ObjectIdentifier]] = [:]
    private var runtimeSubscriptions: [ObjectIdentifier: [AgentSession.ID: AnyCancellable]] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastBadgeLabel: String?

    private init() {}

    /// Whether `appState` is in the tracked set. Every `track(appStates:)`
    /// call replaces the whole set, so tests use this to re-assert their
    /// tracking only after another registry actually replaced it.
    func isTracking(_ appState: AppState) -> Bool {
        trackedAppStates[ObjectIdentifier(appState)] != nil
    }

    func track(appStates: [AppState]) {
        let uniqueAppStates = Dictionary(
            appStates.map { (ObjectIdentifier($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for id in Array(appStateSubscriptions.keys) where uniqueAppStates[id] == nil {
            appStateSubscriptions[id]?.cancel()
            appStateSubscriptions.removeValue(forKey: id)
            kernelSubscriptions[id]?.cancel()
            kernelSubscriptions.removeValue(forKey: id)
            runtimeListSubscriptions[id]?.cancel()
            runtimeListSubscriptions.removeValue(forKey: id)
            runtimeSubscriptions[id]?.values.forEach { $0.cancel() }
            runtimeSubscriptions.removeValue(forKey: id)
            watchedRuntimeObjects.removeValue(forKey: id)
        }

        trackedAppStates = uniqueAppStates

        for (id, appState) in uniqueAppStates where appStateSubscriptions[id] == nil {
            appStateSubscriptions[id] = appState.$agentSessions
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRefresh()
                    }
                }
            // A runtime can appear or be swapped (evicted, then rebuilt on
            // demand; a routine run) without the session list changing.
            // Without this, its approvals were never subscribed to and the
            // Dock stayed blank while the sidebar showed the session waiting.
            runtimeListSubscriptions[id] = appState.$agentRuntimes
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRefresh()
                    }
                }
            kernelSubscriptions[id] = appState.agentRuntimeKernel.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRefresh()
                    }
                }
        }

        scheduleRefresh()
    }

    func clear() {
        appStateSubscriptions.values.forEach { $0.cancel() }
        kernelSubscriptions.values.forEach { $0.cancel() }
        runtimeListSubscriptions.values.forEach { $0.cancel() }
        runtimeListSubscriptions.removeAll()
        watchedRuntimeObjects.removeAll()
        runtimeSubscriptions.values.flatMap(\.values).forEach { $0.cancel() }
        appStateSubscriptions.removeAll()
        kernelSubscriptions.removeAll()
        runtimeSubscriptions.removeAll()
        trackedAppStates.removeAll()
        updateDockBadge(label: nil)
        publishPendingEntries(blockedByAppState: [:])
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        refreshRuntimeSubscriptions()
        var approvalRequestCountBySessionID: [AgentSession.ID: Int] = [:]
        var archivedBySessionID: [AgentSession.ID: Bool] = [:]
        // Uncapped per window; the strip and the Dock menu apply their own
        // (different) caps once the full picture is in.
        var blockedByAppState: [ObjectIdentifier: [AgentPendingApprovalEntry]] = [:]
        for (appStateID, appState) in trackedAppStates {
            var blocked: [AgentPendingApprovalEntry] = []
            for session in appState.agentSessions {
                let runtime = appState.agentRuntimes[session.id]
                let requestCount = AgentSessionApprovalBadgeLogic.pendingAttentionRequestCount(
                    session: session,
                    runtime: runtime,
                    kernel: appState.agentRuntimeKernel
                )
                approvalRequestCountBySessionID[session.id] = max(
                    approvalRequestCountBySessionID[session.id, default: 0],
                    requestCount
                )
                archivedBySessionID[session.id] = archivedBySessionID[session.id, default: true] && session.archivedAt != nil
                if requestCount > 0, session.archivedAt == nil {
                    let latestKernelAction = appState.agentRuntimeKernel.latestPendingUserAction(
                        for: session.id
                    )
                    blocked.append(
                        AgentPendingApprovalEntry(
                            sessionID: session.id,
                            title: latestKernelAction?.title
                                ?? AgentUserInputPreview.latest(
                                    in: runtime?.messages ?? session.messages
                                )
                                ?? "",
                            waitingSince: latestKernelAction?.updatedAt
                                ?? runtime?.turnStartedAt
                                ?? session.updatedAt
                        )
                    )
                }
            }
            blockedByAppState[appStateID] = blocked
        }
        let count = approvalRequestCountBySessionID.reduce(into: 0) { partial, entry in
            if archivedBySessionID[entry.key] != true {
                partial += entry.value
            }
        }
        updateDockBadge(
            label: count > 0 ? String(count) : nil,
            windows: trackedAppStates.count,
            runtimes: runtimeSubscriptions.values.reduce(0) { $0 + $1.count }
        )
        publishPendingEntries(blockedByAppState: blockedByAppState)
    }

    private func publishPendingEntries(blockedByAppState: [ObjectIdentifier: [AgentPendingApprovalEntry]]) {
        let perWindow = blockedByAppState.mapValues { AgentSessionApprovalBadgeLogic.rankMostRecentFirst($0) }
        // The same session can be open in two windows; the Dock lists it
        // once, keeping whichever copy has waited longest.
        var mergedBySessionID: [AgentSession.ID: AgentPendingApprovalEntry] = [:]
        for entry in blockedByAppState.values.flatMap({ $0 }) {
            if let existing = mergedBySessionID[entry.sessionID], existing.waitingSince >= entry.waitingSince {
                continue
            }
            mergedBySessionID[entry.sessionID] = entry
        }
        let merged = AgentSessionApprovalBadgeLogic.rankMostRecentFirst(Array(mergedBySessionID.values))

        // Every runtime event lands here. Publishing unchanged values would
        // redraw the sidebar footer on each one.
        if perWindow != pendingEntriesByAppState {
            pendingEntriesByAppState = perWindow
        }
        if merged != allPendingEntries {
            allPendingEntries = merged
        }
    }

    /// Blocked sessions belonging to one window's sidebar, newest first.
    func pendingEntries(for appState: AppState) -> [AgentPendingApprovalEntry] {
        pendingEntriesByAppState[ObjectIdentifier(appState)] ?? []
    }

    private func refreshRuntimeSubscriptions() {
        for (appStateID, appState) in trackedAppStates {
            var subscriptions = runtimeSubscriptions[appStateID] ?? [:]
            let liveRuntimeIDs = Set(appState.agentRuntimes.keys)

            for runtimeID in Array(subscriptions.keys) where !liveRuntimeIDs.contains(runtimeID) {
                subscriptions[runtimeID]?.cancel()
                subscriptions.removeValue(forKey: runtimeID)
            }

            var watched = watchedRuntimeObjects[appStateID] ?? [:]
            for runtimeID in Array(watched.keys) where subscriptions[runtimeID] == nil {
                watched.removeValue(forKey: runtimeID)
            }
            // Keyed by session id, but the object behind an id can be
            // replaced; a subscription to the evicted one would never fire.
            for (runtimeID, runtime) in appState.agentRuntimes
            where subscriptions[runtimeID] == nil || watched[runtimeID] != ObjectIdentifier(runtime) {
                subscriptions[runtimeID]?.cancel()
                subscriptions[runtimeID] = runtime.objectWillChange
                    .sink { [weak self] _ in
                        Task { @MainActor in
                            self?.scheduleRefresh()
                        }
                    }
                watched[runtimeID] = ObjectIdentifier(runtime)
            }
            watchedRuntimeObjects[appStateID] = watched

            runtimeSubscriptions[appStateID] = subscriptions
        }
    }

    private func updateDockBadge(label: String?, windows: Int = 0, runtimes: Int = 0) {
        guard label != lastBadgeLabel else { return }
        dockBadgeLog.info(
            "dock badge \(self.lastBadgeLabel ?? "-", privacy: .public) -> \(label ?? "-", privacy: .public) (app states: \(windows), runtimes watched: \(runtimes))"
        )
        lastBadgeLabel = label
        NSApp.dockTile.badgeLabel = label
    }
}

struct AgentSessionApprovalBadge: View {
    let session: AgentSession
    let runtime: AgentRuntime?
    var baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault

    var body: some View {
        if let runtime {
            ObservedApprovalBadge(
                session: session,
                runtime: runtime,
                baseFontSize: baseFontSize
            )
        } else if AgentSessionApprovalBadgeLogic.needsUserApproval(session: session) {
            Badge(baseFontSize: baseFontSize)
        }
    }
}

private struct ObservedApprovalBadge: View {
    let session: AgentSession
    @ObservedObject var runtime: AgentRuntime
    let baseFontSize: CGFloat

    var body: some View {
        if AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: runtime.toolCalls.map(\.status),
            patchStatuses: runtime.patchProposals.map(\.status),
            planStatus: runtime.currentPlan?.status
        ) {
            Badge(baseFontSize: baseFontSize)
        }
    }
}

private struct Badge: View {
    let baseFontSize: CGFloat

    var body: some View {
        Text(L10n.Sidebar.sessionRowWaitingApproval)
            .font(AgentDesign.chatSupportingFont(
                baseFontSize: baseFontSize,
                visualMinimum: 10,
                weight: .semibold
            ))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.black, in: Capsule())
            .help(L10n.Sidebar.sessionRowWaitingApprovalTooltip)
            .accessibilityLabel(Text(L10n.Sidebar.sessionRowWaitingApprovalTooltip))
    }
}
