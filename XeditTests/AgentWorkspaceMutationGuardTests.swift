//
//  AgentWorkspaceMutationGuardTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

private actor WorkspaceLeaseProbe {
    private(set) var acquired = false

    func markAcquired() {
        acquired = true
    }
}

@Suite(.serialized)
struct AgentWorkspaceMutationGuardTests {
    private enum TestError: Error {
        case gitFailed(String)
        case missingRevision
    }

    private func requireGit(_ arguments: [String], in directory: URL) throws {
        let result = AppState.runGitCommand(arguments: arguments, in: directory)
        guard result.succeeded else {
            throw TestError.gitFailed(result.userMessage)
        }
    }

    @Test("guard identifies mutating Git commands through wrappers and chains")
    func guardedCommandClassification() {
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git status") == nil)
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git diff --cached") == nil)
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git branch --show-current") == nil)
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git tag --points-at HEAD") == nil)
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git stash list") == nil)
        #expect(AgentWorkspaceMutationPolicy.guardedMutation(in: "git config user.email") == nil)

        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(in: "git add Sources/App.swift")?.actions
                == ["git add"]
        )
        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(in: "git -C /tmp/repo commit -m test")?.actions
                == ["git commit"]
        )
        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(
                in: #"/bin/zsh -lc "git status && git commit -m test""#
            )?.actions == ["git commit"]
        )
        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(in: "env LC_ALL=C git tag v1.2.3")?.actions
                == ["git tag"]
        )
        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(in: "git branch feature/revision-guard")?.actions
                == ["git branch"]
        )
        #expect(
            AgentWorkspaceMutationPolicy.guardedMutation(in: "git add . && git commit -m test")?.actions
                == ["git add", "git commit"]
        )
    }

    @Test("revision detects same-size file edits, staging, commits, and untracked drift")
    func revisionTracksRepositoryState() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_revision_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try requireGit(["init"], in: base)
        try requireGit(["config", "user.email", "tests@example.com"], in: base)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: base)
        let tracked = base.appendingPathComponent("README.md")
        try "alpha\n".write(to: tracked, atomically: true, encoding: .utf8)
        try requireGit(["add", "README.md"], in: base)
        try requireGit(["commit", "-m", "initial"], in: base)

        guard let clean = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }

        // Same byte count as "alpha\n": a size-only signature would miss
        // this if timestamp resolution were coarse. The revision hashes bytes.
        try "bravo\n".write(to: tracked, atomically: true, encoding: .utf8)
        guard let modified = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        let modifiedDifference = modified.difference(from: clean)
        #expect(modifiedDifference.changedPaths == ["README.md"])
        #expect(!modifiedDifference.headChanged)

        try requireGit(["add", "README.md"], in: base)
        guard let staged = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        #expect(staged.difference(from: modified).stagedChanged)

        try requireGit(["commit", "-m", "change readme"], in: base)
        guard let committed = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        #expect(committed.difference(from: staged).headChanged)

        let cacheDirectory = base.appendingPathComponent(".gocache/00", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try "transient\n".write(
            to: cacheDirectory.appendingPathComponent("build-cache"),
            atomically: true,
            encoding: .utf8
        )
        guard let cacheOnly = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        #expect(cacheOnly == committed)

        let untracked = base.appendingPathComponent("Notes.txt")
        try "first\n".write(to: untracked, atomically: true, encoding: .utf8)
        guard let untrackedFirst = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        #expect(untrackedFirst.difference(from: committed).changedPaths == ["Notes.txt"])

        try "other\n".write(to: untracked, atomically: true, encoding: .utf8)
        guard let untrackedOther = await AgentWorkspaceRevisionCapture.capture(for: base) else {
            throw TestError.missingRevision
        }
        #expect(untrackedOther.difference(from: untrackedFirst).changedPaths == ["Notes.txt"])
    }

    @Test("regular file hashing is batched without weakening content detection")
    func regularFileHashingUsesBoundedGitBatches() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_hash_batch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try requireGit(["init"], in: base)
        let paths = (0..<300).map { index in
            String(format: "Sources/File%03d.swift", index)
        }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        for path in paths {
            try "let value = 1\n".write(
                to: base.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }

        let first = AgentWorkspaceRevisionCapture.batchedFileDigests(
            relativePaths: paths,
            repositoryRoot: base
        )
        #expect(first.count == paths.count)

        let changedPath = paths[257]
        try "let value = 2\n".write(
            to: base.appendingPathComponent(changedPath),
            atomically: true,
            encoding: .utf8
        )
        let second = AgentWorkspaceRevisionCapture.batchedFileDigests(
            relativePaths: paths,
            repositoryRoot: base
        )
        #expect(second.count == paths.count)
        #expect(first[changedPath] != second[changedPath])
        #expect(first[paths[0]] == second[paths[0]])
    }

    @Test("repository lease serializes concurrent mutation attempts")
    func repositoryLeaseSerializesMutations() async throws {
        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_lease_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lockDirectory) }

        var firstLease: AgentWorkspaceMutationLease? = try await AgentWorkspaceMutationLease.acquire(
            repositoryIdentity: "shared-repository",
            lockDirectory: lockDirectory
        )
        let probe = WorkspaceLeaseProbe()
        let waiter = Task {
            let lease = try await AgentWorkspaceMutationLease.acquire(
                repositoryIdentity: "shared-repository",
                lockDirectory: lockDirectory
            )
            await probe.markAcquired()
            return lease
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(!(await probe.acquired))
        firstLease = nil

        let secondLease = try await waiter.value
        #expect(await probe.acquired)
        withExtendedLifetime(secondLease) {}
        withExtendedLifetime(firstLease) {}
    }

    @Test("conflict error tells the model to re-inspect and re-test")
    func conflictErrorIsActionable() {
        let error = AgentWorkspaceMutationGuardError.workspaceChanged(
            action: "git commit",
            details: ["HEAD changed", "changed paths: Sources/App.swift"],
            activeSessions: ["Fix sidebar"]
        )
        let message = error.localizedDescription
        #expect(message.contains("Blocked git commit"))
        #expect(message.contains("Sources/App.swift"))
        #expect(message.contains("Fix sidebar"))
        #expect(message.contains("Re-run affected tests"))
    }
}
