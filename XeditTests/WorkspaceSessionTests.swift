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
    @Test("selecting a local workspace session restores the window root")
    func testSelectingLocalWorkspaceSessionRestoresWindowRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_restore_\(UUID().uuidString)")
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

        let second = appState.startNewAgentSession(inWorkspaceAt: secondWorkspace.path)
        appState.agentMessages = [AgentMessage(role: .user, content: "second workspace task")]
        appState.persistActiveAgentSession()

        appState.selectAgentSession(id: first.id)
        #expect(appState.rootDirectory?.standardizedFileURL.path == firstWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceRootPath == firstWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceLocation == .local(path: firstWorkspace.standardizedFileURL.path))

        appState.selectAgentSession(id: second.id)
        #expect(appState.rootDirectory?.standardizedFileURL.path == secondWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceRootPath == secondWorkspace.standardizedFileURL.path)
        #expect(appState.activeRuntime?.workspaceLocation == .local(path: secondWorkspace.standardizedFileURL.path))
    }
}
