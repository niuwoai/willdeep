//
//  AgentCreateFileToolTests.swift
//  WillDeepTests
//
//  Covers the create_file tool's diff synthesis. create_file hands the
//  model a clean (path, content) surface and internally builds a creation
//  diff that the existing apply_patch pipeline parses + writes. These tests
//  lock the round-trip: makeCreationDiff → parse → apply must reproduce the
//  original content byte-for-byte, so a new file lands exactly as given.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentCreateFileToolTests {
    /// Build → parse → apply and assert the file content round-trips and the
    /// change is recognized as a new file at the expected path.
    private func roundTrip(path: String, content: String) throws -> AgentPatchFileChange {
        let diff = AgentToolRunner.makeCreationDiff(path: path, content: content)
        let change = try #require(try AgentPatchApplier.parse(diff).first)
        #expect(change.isNewFile == true)
        #expect(change.path == path)
        #expect(try AgentPatchApplier.apply(change, to: "") == content)
        return change
    }

    @Test
    func multiLineContentRoundTrips() throws {
        _ = try roundTrip(path: "src/util/date.ts", content: "export const x = 1\nexport const y = 2")
    }

    @Test
    func contentWithTrailingNewlineRoundTrips() throws {
        _ = try roundTrip(path: "docs/readme.md", content: "# Title\n\nBody paragraph.\n")
    }

    @Test
    func singleLineNoNewlineRoundTrips() throws {
        _ = try roundTrip(path: "VERSION", content: "1.2.3")
    }

    @Test
    func emptyContentCreatesEmptyFile() throws {
        _ = try roundTrip(path: "empty.txt", content: "")
    }

    @Test
    func contentContainingDiffMarkersRoundTrips() throws {
        // Lines that themselves start with +/-/@@ must survive: every line is
        // emitted as an added (`+`) line, so the parser never mistakes file
        // content for diff control lines.
        let tricky = "+ not a hunk\n- also not\n@@ fake header @@\n normal"
        _ = try roundTrip(path: "tricky.txt", content: tricky)
    }

    @Test
    @MainActor
    func creationPatchUsesTargetRuntimeWorkspaceWhenAnotherSessionIsActive() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_create_file_runtime_root_\(UUID().uuidString)")
        let targetWorkspace = base.appendingPathComponent("target")
        let activeWorkspace = base.appendingPathComponent("active")
        try FileManager.default.createDirectory(at: targetWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let appState = AppState(rootDirectory: activeWorkspace)
        var createdSessionIDs: [AgentSession.ID] = []
        defer {
            for id in createdSessionIDs {
                AgentSessionStore.delete(id: id)
            }
        }

        let targetSession = appState.startNewAgentSession(inWorkspaceAt: targetWorkspace.path)
        createdSessionIDs.append(targetSession.id)
        let targetRuntime = try #require(appState.runtime(for: targetSession.id))
        // This test isolates runtime-to-workspace routing. Explicit workspace
        // access keeps the new Smart-without-Git approval gate from changing
        // the routing assertion into a pending-approval assertion.
        targetRuntime.approvalMode = .workspaceAccess
        let activeSession = appState.startNewAgentSession(inWorkspaceAt: activeWorkspace.path)
        createdSessionIDs.append(activeSession.id)
        let activeRuntime = try #require(appState.runtime(for: activeSession.id))

        let content = "services:\n  app:\n    image: tokenhub:beta\n"
        let diff = AgentToolRunner.makeCreationDiff(path: "deploy/compose.yml", content: content)
        let proposal = try appState.enqueueAgentPatchProposal(
            for: targetRuntime,
            messageID: UUID(),
            title: "创建文件: deploy/compose.yml",
            diff: diff,
            autoApplySource: .workspaceAccess
        )

        #expect(proposal.status == .applied)
        let targetFile = targetWorkspace.appendingPathComponent("deploy/compose.yml")
        let activeFile = activeWorkspace.appendingPathComponent("deploy/compose.yml")
        #expect(try String(contentsOf: targetFile, encoding: .utf8) == content)
        #expect(!FileManager.default.fileExists(atPath: activeFile.path))
        #expect(targetRuntime.didEditFiles)
        #expect(targetRuntime.agentEditedPaths == ["deploy/compose.yml"])
        #expect(!activeRuntime.didEditFiles)
        #expect(activeRuntime.agentEditedPaths.isEmpty)
    }
}
