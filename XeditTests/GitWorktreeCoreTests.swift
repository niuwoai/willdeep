//
//  GitWorktreeCoreTests.swift
//  WillDeepTests
//
//  Git status parsing and worktree lifecycle tests split from
//  XeditTests.swift so the main regression suite stays easier to scan.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct GitWorktreeCoreTests {
    private enum TestError: Error {
        case gitFailed(String)
    }

    private func requireGit(_ arguments: [String], in directory: URL) throws {
        let result = AppState.runGitCommand(arguments: arguments, in: directory)
        guard result.succeeded else {
            throw TestError.gitFailed(result.userMessage)
        }
    }

    @Test("git porcelain status maps common file states")
    func testGitPorcelainStatusMapping() {
        let entries = AppState.parseGitStatusPorcelain(
            """
             M Sources/App.swift
            ?? Notes/todo.md
            A  Sources/NewFile.swift
             D Sources/Removed.swift
            R  Old.swift -> Sources/Renamed.swift
            ?? Assets/
            """
        )

        #expect(entries["Sources/App.swift"] == .modified)
        #expect(entries["Notes/todo.md"] == .untracked)
        #expect(entries["Sources/NewFile.swift"] == .added)
        #expect(entries["Sources/Removed.swift"] == .deleted)
        #expect(entries["Sources/Renamed.swift"] == .renamed)
        #expect(entries["Assets"] == .untracked)
    }

    @Test("git repository status returns folder marker when child changed")
    func testGitRepositoryStatusFolderMarker() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: ["Sources/App.swift": .modified]
        )

        #expect(status.kind(for: root.appendingPathComponent("Sources")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("Sources/App.swift")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("README.md")) == nil)
    }

    @Test("git repository status aggregates folder markers deterministically")
    func testGitRepositoryStatusFolderMarkerPriority() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: [
                "icons/new.svg": .untracked,
                "icons/removed.svg": .deleted,
                "icons/changed.svg": .modified,
            ]
        )

        #expect(status.kind(for: root.appendingPathComponent("icons")) == .deleted)
    }

    @Test("git numstat parser returns per-file line deltas")
    func testGitNumstatParser() {
        let stats = AppState.parseGitNumstat(
            """
            25\t13\tXedit/AgentClient.swift
            -\t-\tAssets/icon.png
            2\t0\tDocs/Name With Spaces.md
            """
        )

        #expect(stats["Xedit/AgentClient.swift"]?.added == 25)
        #expect(stats["Xedit/AgentClient.swift"]?.deleted == 13)
        #expect(stats["Assets/icon.png"]?.added == nil)
        #expect(stats["Assets/icon.png"]?.deleted == nil)
        #expect(stats["Docs/Name With Spaces.md"]?.added == 2)
        #expect(stats["Docs/Name With Spaces.md"]?.deleted == 0)
    }

    @Test("git C-quoted path with octal-escaped CJK bytes decodes to UTF-8")
    func testUnquoteGitPathDecodesCJK() {
        // git 默认 core.quotePath=true 把「重启.md」输出成
        // "docs/\351\207\215\345\220\257.md"(重=E9 87 8D,启=E5 90 AF)。
        #expect(AppState.unquoteGitPath(#""docs/\351\207\215\345\220\257.md""#) == "docs/重启.md")
        // 含转义字符的常规情况
        #expect(AppState.unquoteGitPath(#""a\tb\\c\"d.md""#) == "a\tb\\c\"d.md")
        // 未加引号的路径原样返回(加了 core.quotePath=false 后的常态)
        #expect(AppState.unquoteGitPath("docs/重启.md") == "docs/重启.md")
        #expect(AppState.unquoteGitPath("Xedit/AppState.swift") == "Xedit/AppState.swift")
    }

    @Test("porcelain + numstat parsers decode octal-escaped CJK paths")
    func testParsersDecodeQuotedCJKPaths() {
        let entries = AppState.parseGitStatusPorcelain(
            #" M "docs/\351\207\215\345\220\257.md""# + "\n" +
            #"R  "old.md" -> "docs/\345\220\257\345\212\250.md""#
        )
        #expect(entries["docs/重启.md"] == .modified)
        #expect(entries["docs/启动.md"] == .renamed)

        // numstat 字段用真实 tab 分隔;路径里的反斜杠用 \\ 写成字面量。
        let stats = AppState.parseGitNumstat(
            "3\t1\t\"docs/\\351\\207\\215\\345\\220\\257.md\""
        )
        #expect(stats["docs/重启.md"]?.added == 3)
        #expect(stats["docs/重启.md"]?.deleted == 1)
    }

    @Test("worktree change summary combines porcelain entries and numstat")
    func testWorktreeChangeSummaryTotals() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "B.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 10, deleted: 2)
                ),
                AgentFileChangeSummary(
                    path: "A.swift",
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        #expect(summary.fileCount == 2)
        #expect(summary.totalAddedLines == 10)
        #expect(summary.totalDeletedLines == 2)
        #expect(summary.files.map(\.path) == ["A.swift", "B.swift"])
        #expect(summary.change(for: "B.swift")?.fileName == "B.swift")
    }

    @Test("agent worktree summary skips modified files without real diff")
    func testAgentWorktreeSummarySkipsModifiedFilesWithoutDiff() {
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 0, deleted: 0),
            hasNumstatEntry: true
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 2, deleted: 0),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .untracked,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == true)
    }

    @Test("git worktree porcelain parser captures branches and prunable rows")
    func testGitWorktreePorcelainParser() {
        let worktrees = AppState.parseGitWorktreeListPorcelain(
            """
            worktree /tmp/repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /tmp/repo-feature
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature/demo

            worktree /tmp/repo-old
            HEAD 3333333333333333333333333333333333333333
            detached
            prunable gitdir file points to non-existent location
            """
        )

        #expect(worktrees.count == 3)
        #expect(worktrees[0].isPrimary == true)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[1].branch == "feature/demo")
        #expect(worktrees[2].isDetached == true)
        #expect(worktrees[2].isPrunable == true)
        #expect(worktrees[2].pruneReason == "gitdir file points to non-existent location")
    }

    @Test("git worktree names are sanitized and default paths avoid collisions")
    func testGitWorktreeDefaultNaming() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_worktree_name_\(UUID().uuidString)")
            .appendingPathComponent("Repo")
        let existing = root.deletingLastPathComponent().appendingPathComponent("Repo-feature-name")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        #expect(AppState.sanitizedGitWorktreeName(" feature/name ! ") == "feature-name")
        let next = AppState.defaultGitWorktreeURL(repositoryRoot: root, branchName: "feature/name !")
        #expect(next.lastPathComponent == "Repo-feature-name-2")
    }

    @Test("git worktree creation lists and detects worktree git-file roots")
    func testGitWorktreeCreateListAndFindRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_worktree_create_\(UUID().uuidString)")
        let repository = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try requireGit(["init"], in: repository)
        try requireGit(["config", "user.email", "tests@example.com"], in: repository)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: repository)
        try "hello\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try requireGit(["add", "README.md"], in: repository)
        try requireGit(["commit", "-m", "initial"], in: repository)

        let created = AppState.createGitWorktree(from: repository, branchName: "feature test")
        guard case .success(let result) = created else {
            Issue.record("Expected worktree creation to succeed")
            return
        }

        #expect(result.worktree.branch == "feature-test")
        #expect(FileManager.default.fileExists(atPath: result.worktree.url.appendingPathComponent(".git").path))

        let detectedRoot = AppState.findGitRepositoryRoot(startingAt: result.worktree.url)
        #expect(detectedRoot?.standardizedFileURL.path == result.worktree.url.path)

        let worktrees = AppState.listGitWorktrees(for: result.worktree.url)
        #expect(worktrees.contains { $0.url == repository.standardizedFileURL && $0.isPrimary })
        #expect(worktrees.contains { $0.url == result.worktree.url && $0.branch == "feature-test" })
    }
}
