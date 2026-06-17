//
//  WorkspaceSessionTests.swift
//  WillDeepTests
//
//  Regression tests for session/workspace switching behavior.
//

import Foundation
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("agent 切 workspace / 切会话都不动 editor 窗口的 rootDirectory(1.85.0-rc11)")
    func testAgentWorkspaceSwitchDoesNotMoveEditorRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_decouple_\(UUID().uuidString)")
        let firstWorkspace = base.appendingPathComponent("first")
        let secondWorkspace = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let appState = AppState(rootDirectory: firstWorkspace)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }

        let first = appState.startNewAgentSession()
        appState.agentMessages = [AgentMessage(role: .user, content: "first workspace task")]
        appState.persistActiveAgentSession()

        // 在 secondWorkspace 起一个新会话:agent runtime 必须绑到
        // second,但 editor 的 rootDirectory 必须仍指向 first。
        let second = appState.startNewAgentSession(inWorkspaceAt: secondWorkspace.path)
        appState.agentMessages = [AgentMessage(role: .user, content: "second workspace task")]
        appState.persistActiveAgentSession()

        #expect(appState.rootDirectory?.standardizedFileURL.path == firstWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceRootPath == secondWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceLocation == .local(path: secondWorkspace.standardizedFileURL.path))

        // 切回 first 会话:runtime 跟着切,editor 仍然不动。
        appState.selectAgentSession(id: first.id)
        #expect(appState.rootDirectory?.standardizedFileURL.path == firstWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceRootPath == firstWorkspace.standardizedFileURL.path)

        // 再切到 second 会话:runtime 切回 second,editor 仍然不动。
        appState.selectAgentSession(id: second.id)
        #expect(appState.rootDirectory?.standardizedFileURL.path == firstWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceRootPath == secondWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceLocation == .local(path: secondWorkspace.standardizedFileURL.path))
    }
}
