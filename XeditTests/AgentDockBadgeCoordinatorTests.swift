//
//  AgentDockBadgeCoordinatorTests.swift
//  XeditTests
//
//  End-to-end checks of the Dock badge: a real AppState tracked by the
//  coordinator, a runtime that starts waiting on the user, and the number
//  that actually lands on `NSApp.dockTile`. The counting helpers had tests;
//  the coordinator that wires them to runtime changes had none.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentDockBadgeCoordinatorTests {
    @Test("导航徽标沿用 Dock 的请求数，跨窗口不重复，归档和清理后归零")
    func publishedAttentionCountMatchesDockRequests() async throws {
        let coordinator = AgentDockBadgeCoordinator()
        defer { coordinator.clear() }
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let first = AppState(runtimeKernel: kernel, loadSessionCatalog: false)
        let second = AppState(runtimeKernel: kernel, loadSessionCatalog: false)
        var session = AgentSession(title: "Badge fixture")
        session.currentPlan = AgentPlan(status: .proposed, steps: [], summary: "Review")
        first.agentSessions = [session]
        second.agentSessions = [session]
        kernel.publish(AgentKernelEvent(
            runtimeID: session.id, source: .system, kind: .hostNotice,
            audience: .user, title: "Attention", payload: "fixture", requiresUserAction: true
        ))
        coordinator.track(appStates: [first, second])
        try await waitForRefresh(coordinator, count: 1)
        #expect(coordinator.pendingRequestCount == 2)
        #expect(coordinator.allPendingEntries.count == 1)
        let nextRefresh = coordinator.refreshCount + 1
        session.archivedAt = Date()
        first.agentSessions = [session]
        second.agentSessions = [session]
        try await waitForRefresh(coordinator, count: nextRefresh)
        #expect(coordinator.pendingRequestCount == 0)
        session.archivedAt = nil
        first.agentSessions = [session]
        try await waitForRefresh(coordinator, count: coordinator.refreshCount + 1)
        #expect(coordinator.pendingRequestCount == 2)
        coordinator.clear()
        #expect(coordinator.pendingRequestCount == 0)
    }

    private func waitForRefresh(_ coordinator: AgentDockBadgeCoordinator, count: Int) async throws {
        // Other suites can occupy the main actor before the refresh task even
        // starts sleeping. Wait for its result instead of assuming wall time
        // gives this task a turn on the executor.
        for _ in 0..<250 {
            if coordinator.refreshCount >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("突发刷新合并为一次执行，后续请求仍会触发新一轮刷新")
    func refreshBurstsAreCoalesced() async throws {
        let coordinator = AgentDockBadgeCoordinator()
        defer { coordinator.clear() }
        for _ in 0..<200 {
            coordinator.track(appStates: [])
        }
        try await waitForRefresh(coordinator, count: 1)
        #expect(coordinator.refreshCount == 1)
        for _ in 0..<100 {
            coordinator.track(appStates: [])
        }
        try await waitForRefresh(coordinator, count: 2)
        #expect(coordinator.refreshCount == 2)
    }

    @Test("清理取消尚未执行的刷新，取消任务不会影响新一轮刷新")
    func clearCancelsScheduledRefresh() async throws {
        let coordinator = AgentDockBadgeCoordinator()
        defer { coordinator.clear() }
        coordinator.track(appStates: [])
        coordinator.clear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.refreshCount == 0)
        coordinator.track(appStates: [])
        try await waitForRefresh(coordinator, count: 1)
        #expect(coordinator.refreshCount == 1)
    }

    private func pendingCall() -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(), externalID: "dock-badge-fixture-\(UUID())",
            toolName: "run_command", arguments: ["command": .string("true")], risk: .write, status: .pendingApproval
        )
    }

    /// Lets the coordinator's hop-to-main refresh run.
    ///
    /// `AgentDockBadgeCoordinator.shared` is process-wide. In a full run other
    /// suites' main-actor tests interleave at every `await`, and any of them
    /// that registers an AppState with an `EditorAppStateRegistry` re-tracks
    /// the coordinator with *its* set, silently dropping ours — the release
    /// gate saw 0 pending after 79s while the case passed alone. Re-assert
    /// our tracking only once it has actually been dropped, and give a loaded
    /// main actor a real window. (Re-tracking on every poll made the whole
    /// full run ~40s slower and pushed an unrelated near-deadline Goal case
    /// past its 120s wait.)
    private func settle(
        retracking tracked: @autoclosure () -> [AppState] = [],
        until condition: (() -> Bool)? = nil
    ) async {
        // A bare settle only lets pending refreshes land; the long window is
        // for waiting on evidence.
        for _ in 0..<(condition == nil ? 50 : 250) {
            if condition?() == true { return }
            let appStates = tracked()
            if !appStates.isEmpty, !appStates.allSatisfy(AgentDockBadgeCoordinator.shared.isTracking) {
                AgentDockBadgeCoordinator.shared.track(appStates: appStates)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func badgeShown(for session: AgentSession) -> Bool {
        pendingCount(for: session) == 1 && NSApp.dockTile.badgeLabel != nil
    }

    private func pendingCount(for session: AgentSession) -> Int {
        AgentDockBadgeCoordinator.shared.allPendingEntries.filter { $0.sessionID == session.id }.count
    }

    @Test("基线：已登记会话的运行态出现待审批，Dock 出数字")
    func baseline() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer {
            AgentDockBadgeCoordinator.shared.track(appStates: [])
            AgentSessionStore.delete(id: session.id)
        }
        AgentDockBadgeCoordinator.shared.track(appStates: [appState])
        await settle(retracking: [appState])
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.toolCalls = [pendingCall()]
        await settle(retracking: [appState]) { badgeShown(for: session) }
        #expect(pendingCount(for: session) == 1)
        #expect(NSApp.dockTile.badgeLabel != nil)
    }

    @Test("运行态被换成新对象（淘汰后按需重建）后出现待审批，Dock 仍出数字")
    func replacedRuntime() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer {
            AgentDockBadgeCoordinator.shared.track(appStates: [])
            AgentSessionStore.delete(id: session.id)
        }
        AgentDockBadgeCoordinator.shared.track(appStates: [appState])
        await settle(retracking: [appState])
        let replacement = AgentRuntime(session: session)
        appState.agentRuntimes[session.id] = replacement
        await settle(retracking: [appState])
        replacement.toolCalls = [pendingCall()]
        await settle(retracking: [appState]) { badgeShown(for: session) }
        #expect(pendingCount(for: session) == 1)
        #expect(NSApp.dockTile.badgeLabel != nil)
    }

    @Test("会话列表不变、只新增运行态后出现待审批，Dock 仍出数字")
    func runtimeAddedWithoutSessionListChange() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer {
            AgentDockBadgeCoordinator.shared.track(appStates: [])
            AgentSessionStore.delete(id: session.id)
        }
        appState.agentRuntimes.removeValue(forKey: session.id)
        AgentDockBadgeCoordinator.shared.track(appStates: [appState])
        await settle(retracking: [appState])
        let runtime = AgentRuntime(session: session)
        appState.agentRuntimes[session.id] = runtime
        await settle(retracking: [appState])
        runtime.toolCalls = [pendingCall()]
        await settle(retracking: [appState]) { badgeShown(for: session) }
        #expect(pendingCount(for: session) == 1)
        #expect(NSApp.dockTile.badgeLabel != nil)
    }

    @Test("编辑器窗口接管 current 后，Agent 窗口背后的 headless AppState 的待审批仍计入 Dock")
    func headlessFallbackStaysTracked() async throws {
        let registry = EditorAppStateRegistry()
        registry.ensureHeadlessFallback()
        let headless = try #require(registry.current)
        let session = headless.startNewAgentSession()
        let editor = AppState()
        defer {
            AgentDockBadgeCoordinator.shared.track(appStates: [])
            AgentSessionStore.delete(id: session.id)
        }
        registry.register(editor)
        #expect(registry.current === editor)
        await settle(retracking: registry.appStatesForTerminationCheck)
        let runtime = try #require(headless.agentRuntimes[session.id])
        runtime.toolCalls = [pendingCall()]
        await settle(retracking: registry.appStatesForTerminationCheck) { badgeShown(for: session) }
        #expect(pendingCount(for: session) == 1)
        #expect(NSApp.dockTile.badgeLabel != nil)
    }
}
