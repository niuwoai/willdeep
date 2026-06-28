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

enum AgentSessionApprovalBadgeLogic {
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
}

@MainActor
final class AgentDockBadgeCoordinator {
    static let shared = AgentDockBadgeCoordinator()

    private var trackedAppStates: [ObjectIdentifier: AppState] = [:]
    private var appStateSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var runtimeSubscriptions: [ObjectIdentifier: [AgentSession.ID: AnyCancellable]] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastBadgeLabel: String?

    private init() {}

    func track(appStates: [AppState]) {
        let uniqueAppStates = Dictionary(
            appStates.map { (ObjectIdentifier($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for id in Array(appStateSubscriptions.keys) where uniqueAppStates[id] == nil {
            appStateSubscriptions[id]?.cancel()
            appStateSubscriptions.removeValue(forKey: id)
            runtimeSubscriptions[id]?.values.forEach { $0.cancel() }
            runtimeSubscriptions.removeValue(forKey: id)
        }

        trackedAppStates = uniqueAppStates

        for (id, appState) in uniqueAppStates where appStateSubscriptions[id] == nil {
            appStateSubscriptions[id] = appState.objectWillChange
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
        runtimeSubscriptions.values.flatMap(\.values).forEach { $0.cancel() }
        appStateSubscriptions.removeAll()
        runtimeSubscriptions.removeAll()
        trackedAppStates.removeAll()
        updateDockBadge(label: nil)
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
        var approvalBySessionID: [AgentSession.ID: Bool] = [:]
        var archivedBySessionID: [AgentSession.ID: Bool] = [:]
        for appState in trackedAppStates.values {
            for session in appState.agentSessions {
                let sessionNeedsApproval: Bool
                if let runtime = appState.agentRuntimes[session.id] {
                    sessionNeedsApproval = AgentSessionApprovalBadgeLogic.needsUserApproval(
                        session: runtime.session,
                        toolCallStatuses: runtime.toolCalls.map(\.status),
                        patchStatuses: runtime.patchProposals.map(\.status),
                        planStatus: runtime.currentPlan?.status
                    )
                } else {
                    sessionNeedsApproval = AgentSessionApprovalBadgeLogic.needsUserApproval(session: session)
                }
                approvalBySessionID[session.id, default: false] = approvalBySessionID[session.id, default: false] || sessionNeedsApproval
                archivedBySessionID[session.id] = archivedBySessionID[session.id, default: true] && session.archivedAt != nil
            }
        }
        let count = approvalBySessionID.reduce(into: 0) { partial, entry in
            if entry.value, archivedBySessionID[entry.key] != true {
                partial += 1
            }
        }
        updateDockBadge(label: count > 0 ? String(count) : nil)
    }

    private func refreshRuntimeSubscriptions() {
        for (appStateID, appState) in trackedAppStates {
            var subscriptions = runtimeSubscriptions[appStateID] ?? [:]
            let liveRuntimeIDs = Set(appState.agentRuntimes.keys)

            for runtimeID in Array(subscriptions.keys) where !liveRuntimeIDs.contains(runtimeID) {
                subscriptions[runtimeID]?.cancel()
                subscriptions.removeValue(forKey: runtimeID)
            }

            for (runtimeID, runtime) in appState.agentRuntimes where subscriptions[runtimeID] == nil {
                subscriptions[runtimeID] = runtime.objectWillChange
                    .sink { [weak self] _ in
                        Task { @MainActor in
                            self?.scheduleRefresh()
                        }
                    }
            }

            runtimeSubscriptions[appStateID] = subscriptions
        }
    }

    private func updateDockBadge(label: String?) {
        guard label != lastBadgeLabel else { return }
        lastBadgeLabel = label
        NSApp.dockTile.badgeLabel = label
    }
}

struct AgentSessionApprovalBadge: View {
    let session: AgentSession
    let runtime: AgentRuntime?

    var body: some View {
        if let runtime {
            ObservedApprovalBadge(session: session, runtime: runtime)
        } else if AgentSessionApprovalBadgeLogic.needsUserApproval(session: session) {
            Badge()
        }
    }
}

private struct ObservedApprovalBadge: View {
    let session: AgentSession
    @ObservedObject var runtime: AgentRuntime

    var body: some View {
        if AgentSessionApprovalBadgeLogic.needsUserApproval(
            session: session,
            toolCallStatuses: runtime.toolCalls.map(\.status),
            patchStatuses: runtime.patchProposals.map(\.status),
            planStatus: runtime.currentPlan?.status
        ) {
            Badge()
        }
    }
}

private struct Badge: View {
    var body: some View {
        Text(L10n.Sidebar.sessionRowWaitingApproval)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.green)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.14), in: Capsule())
            .help(L10n.Sidebar.sessionRowWaitingApprovalTooltip)
            .accessibilityLabel(Text(L10n.Sidebar.sessionRowWaitingApprovalTooltip))
    }
}
