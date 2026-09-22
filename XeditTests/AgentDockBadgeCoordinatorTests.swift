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
    private func pendingCall() -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(), externalID: "dock-badge-fixture-\(UUID())",
            toolName: "run_command", arguments: ["command": .string("true")], risk: .write, status: .pendingApproval
        )
    }

    /// Lets the coordinator's hop-to-main refresh run.
    private func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
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
        await settle()
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.toolCalls = [pendingCall()]
        await settle { pendingCount(for: session) == 1 }
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
        await settle()
        let replacement = AgentRuntime(session: session)
        appState.agentRuntimes[session.id] = replacement
        await settle()
        replacement.toolCalls = [pendingCall()]
        await settle { pendingCount(for: session) == 1 }
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
        await settle()
        let runtime = AgentRuntime(session: session)
        appState.agentRuntimes[session.id] = runtime
        await settle()
        runtime.toolCalls = [pendingCall()]
        await settle { pendingCount(for: session) == 1 }
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
        await settle()
        let runtime = try #require(headless.agentRuntimes[session.id])
        runtime.toolCalls = [pendingCall()]
        await settle { pendingCount(for: session) == 1 }
        #expect(pendingCount(for: session) == 1)
        #expect(NSApp.dockTile.badgeLabel != nil)
    }
}
