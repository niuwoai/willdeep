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
        var createdSessionIDs: [AgentSession.ID] = []
        defer {
            for id in createdSessionIDs {
                AgentSessionStore.delete(id: id)
            }
        }

        let first = appState.startNewAgentSession()
        createdSessionIDs.append(first.id)
        appState.agentMessages = [AgentMessage(role: .user, content: "first workspace task")]
        appState.persistActiveAgentSession()

        // 在 secondWorkspace 起一个新会话:agent runtime 必须绑到
        // second,但 editor 的 rootDirectory 必须仍指向 first。
        let second = appState.startNewAgentSession(inWorkspaceAt: secondWorkspace.path)
        createdSessionIDs.append(second.id)
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

    @MainActor
    @Test("agent workspace rename/delete 后只在失败诊断时标记异常且不静默改路径")
    func testAgentWorkspaceAvailabilityDiagnosesMovedOrMissingWithoutSilentRebind() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_availability_\(UUID().uuidString)")
        let original = base.appendingPathComponent("project")
        let renamed = base.appendingPathComponent("project-renamed")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let session = AgentSession(workspaceRootPath: original.path)
        let runtime = AgentRuntime(session: session)
        #expect(try runtime.localWorkspaceURLForOptimisticUse()?.path == original.standardizedFileURL.path)

        try FileManager.default.moveItem(at: original, to: renamed)

        let availability = runtime.diagnoseLocalWorkspaceAfterFailure()
        #expect(runtime.workspaceRootPath == original.standardizedFileURL.path)
        #expect(runtime.workspaceLocation == .local(path: original.standardizedFileURL.path))
        #expect(availability?.blocksLocalWorkspaceUse == true)
        #expect(throws: AgentWorkspaceAvailabilityError.self) {
            _ = try runtime.localWorkspaceURLForOptimisticUse()
        }

        if case .moved(let originalPath, let resolvedPath, _) = availability {
            #expect(originalPath == original.standardizedFileURL.path)
            #expect(resolvedPath == renamed.standardizedFileURL.path)
        }
    }
}
