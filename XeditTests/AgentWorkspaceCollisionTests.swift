//
//  AgentWorkspaceCollisionTests.swift
//  WillDeepTests
//
//  Covers the pure counting rule behind the composer's "another session
//  is working in this same folder" soft warning. Only *other*,
//  *currently-responding* runtimes in the *same standardized checkout*
//  count — so the hint stays quiet for idle history and never counts the
//  active session itself.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentWorkspaceCollisionTests {
    private let active = UUID()
    private let repo = "/Users/dev/project"

    private func candidate(
        _ id: UUID,
        responding: Bool,
        path: String?
    ) -> AgentWorkspaceCollisionCandidate {
        AgentWorkspaceCollisionCandidate(id: id, isResponding: responding, localPath: path)
    }

    @Test("counts another responding session in the same directory")
    func testCountsConcurrentSameDir() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [
                candidate(active, responding: true, path: repo),
                candidate(other, responding: true, path: repo),
            ]
        )
        #expect(count == 1)
    }

    @Test("ignores the active session itself even when responding")
    func testIgnoresActiveSession() {
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [candidate(active, responding: true, path: repo)]
        )
        #expect(count == 0)
    }

    @Test("idle sessions in the same directory do not count")
    func testIgnoresIdleSessions() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [
                candidate(active, responding: false, path: repo),
                candidate(other, responding: false, path: repo),
            ]
        )
        #expect(count == 0)
    }

    @Test("responding sessions in a different directory do not count")
    func testIgnoresDifferentDirectory() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [candidate(other, responding: true, path: "/Users/dev/other")]
        )
        #expect(count == 0)
    }

    @Test("worktree isolation clears the original checkout collision")
    func testWorktreeIsolationClearsCollision() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: "/Users/dev/.willdeep/worktrees/project/task",
            among: [candidate(other, responding: true, path: repo)]
        )
        #expect(count == 0)
    }

    @Test("worktree execution keeps the conversation in its original workspace group")
    @MainActor
    func testWorktreeKeepsOriginalSidebarWorkspace() {
        let runtime = AgentRuntime(session: AgentSession(workspaceRootPath: repo))

        runtime.rebindGitWorktree(
            to: "/Users/dev/.willdeep/worktrees/project/task",
            sidebarWorkspaceRootPath: repo
        )

        #expect(runtime.localWorkspacePath == "/Users/dev/.willdeep/worktrees/project/task")
        #expect(runtime.session.workspaceSidebarGroupKey == repo)
        #expect(runtime.session.workspaceName == "project")
        #expect(AgentUsageSessionSnapshot(session: runtime.session).workspaceIdentifier == "local:\(repo)")
    }

    @Test("remote / unbound runtimes (nil path) do not count")
    func testIgnoresNilPath() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [candidate(other, responding: true, path: nil)]
        )
        #expect(count == 0)
    }

    @Test("path comparison is standardized (trailing slash collapses)")
    func testStandardizesPaths() {
        let other = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [candidate(other, responding: true, path: repo + "/")]
        )
        #expect(count == 1)
    }

    @Test("tallies multiple concurrent workers on the same checkout")
    func testCountsMultiple() {
        let a = UUID(), b = UUID(), c = UUID()
        let count = AppState.concurrentSessionCount(
            activeID: active,
            activePath: repo,
            among: [
                candidate(active, responding: true, path: repo),
                candidate(a, responding: true, path: repo),
                candidate(b, responding: true, path: repo),
                candidate(c, responding: false, path: repo), // idle → excluded
            ]
        )
        #expect(count == 2)
    }
}
