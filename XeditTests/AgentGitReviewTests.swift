//
//  AgentGitReviewTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent Git 审阅与提交", .serialized)
struct AgentGitReviewTests {
    @Test("name-status 解析修改新增删除与重命名")
    func parsesNameStatus() {
        let parsed = AgentGitReviewLoader.parseNameStatus(
            """
            M\tSources/App.swift
            A\tSources/New.swift
            D\tSources/Old.swift
            R100\tSources/Before.swift\tSources/After.swift
            """
        )

        #expect(parsed["Sources/App.swift"] == .modified)
        #expect(parsed["Sources/New.swift"] == .added)
        #expect(parsed["Sources/Old.swift"] == .deleted)
        #expect(parsed["Sources/After.swift"] == .renamed)
        #expect(parsed["Sources/Before.swift"] == nil)
    }

    @Test("每种范围生成对应的单文件 Git 参数")
    func buildsDetailArguments() {
        let path = "Sources/App.swift"

        #expect(
            AgentGitReviewLoader.detailArguments(scope: .uncommitted, path: path)
                == ["diff", "--no-ext-diff", "HEAD", "--", path]
        )
        #expect(
            AgentGitReviewLoader.detailArguments(scope: .unstaged, path: path)
                == ["diff", "--no-ext-diff", "--", path]
        )
        #expect(
            AgentGitReviewLoader.detailArguments(scope: .staged, path: path)
                == ["diff", "--cached", "--no-ext-diff", "--", path]
        )
        #expect(
            AgentGitReviewLoader.detailArguments(scope: .lastCommit, path: path)
                == ["show", "--format=", "--no-ext-diff", "HEAD", "--", path]
        )
    }

    @Test("统一 Diff 解析为逐文件行号与未修改区块")
    func parsesFileFirstDiffDocument() throws {
        let changes = AgentWorktreeChangeSummary(
            repositoryRoot: URL(fileURLWithPath: "/tmp/review"),
            files: [
                AgentFileChangeSummary(
                    path: "Sources/App.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 2, deleted: 1)
                )
            ]
        )
        let document = AgentGitReviewDiffDocument.parse(
            """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1234567..7654321 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -3,3 +3,4 @@
             let first = true
            -let title = "Old"
            +let title = "New"
            +let enabled = true
             return title
            """,
            changes: changes
        )

        let file = try #require(document.files.first)
        #expect(file.path == "Sources/App.swift")
        #expect(file.rows == [
            .collapsed(count: 2),
            .context(oldLine: 3, newLine: 3, text: "let first = true"),
            .deletion(oldLine: 4, text: "let title = \"Old\""),
            .addition(newLine: 4, text: "let title = \"New\""),
            .addition(newLine: 5, text: "let enabled = true"),
            .context(oldLine: 5, newLine: 6, text: "return title"),
        ])
    }

    @Test("逐文件 Diff 初始只显示 100 行并按批次展开")
    func limitsInitialDiffRows() {
        #expect(AgentGitReviewFileCardsMetrics.visibleLineBatchSize == 100)
        #expect(
            AgentGitReviewFileCardsMetrics.nextVisibleLineCount(current: 100, total: 275)
                == 200
        )
        #expect(
            AgentGitReviewFileCardsMetrics.nextVisibleLineCount(current: 200, total: 275)
                == 275
        )
    }

    @Test("范围快照区分未暂存、已暂存与上一轮提交")
    func loadsScopedSnapshots() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        try write("base changed\n", to: repository.appendingPathComponent("unstaged.txt"))
        try write("staged changed\n", to: repository.appendingPathComponent("staged.txt"))
        try write("new\n", to: repository.appendingPathComponent("untracked.txt"))
        try runGit(["add", "--", "staged.txt"], in: repository)

        let uncommitted = try #require(
            AgentGitReviewLoader.load(workspaceRoot: repository, scope: .uncommitted)
        )
        let unstaged = try #require(
            AgentGitReviewLoader.load(workspaceRoot: repository, scope: .unstaged)
        )
        let staged = try #require(
            AgentGitReviewLoader.load(workspaceRoot: repository, scope: .staged)
        )
        let lastCommit = try #require(
            AgentGitReviewLoader.load(workspaceRoot: repository, scope: .lastCommit)
        )

        #expect(Set(uncommitted.changes.files.map(\.path)) == [
            "staged.txt", "unstaged.txt", "untracked.txt",
        ])
        #expect(Set(unstaged.changes.files.map(\.path)) == [
            "unstaged.txt", "untracked.txt",
        ])
        #expect(uncommitted.changes.change(for: "untracked.txt")?.addedLines == 1)
        #expect(uncommitted.changes.change(for: "untracked.txt")?.deletedLines == 0)
        #expect(unstaged.changes.change(for: "untracked.txt")?.addedLines == 1)
        #expect(unstaged.changes.change(for: "untracked.txt")?.deletedLines == 0)
        #expect(staged.changes.files.map(\.path) == ["staged.txt"])
        #expect(Set(lastCommit.changes.files.map(\.path)) == [
            "staged.txt", "unstaged.txt",
        ])
        #expect(!uncommitted.overviewDiff.isEmpty)
        #expect(!staged.overviewDiff.isEmpty)
    }

    @Test("提交服务可暂存并创建本地提交")
    func commitsUnstagedChanges() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("next\n", to: repository.appendingPathComponent("unstaged.txt"))

        let outcome = AgentGitCommitService.commit(
            repositoryRoot: repository,
            message: "test: commit from review panel",
            includeUnstaged: true,
            pushAfterCommit: false
        )

        #expect(outcome.commitCreated)
        #expect(!outcome.pushed)
        #expect(AppState.runGit(arguments: ["status", "--porcelain"], in: repository).isEmpty)
        #expect(
            AppState.runGit(arguments: ["log", "-1", "--pretty=%s"], in: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "test: commit from review panel"
        )
    }

    private func makeRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-git-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try runGit(["init"], in: repository)
        try runGit(["config", "user.name", "WillDeep Tests"], in: repository)
        try runGit(["config", "user.email", "willdeep-tests@example.invalid"], in: repository)
        try write("base\n", to: repository.appendingPathComponent("unstaged.txt"))
        try write("base\n", to: repository.appendingPathComponent("staged.txt"))
        try runGit(["add", "--", "."], in: repository)
        try runGit(["commit", "-m", "test: initial"], in: repository)
        return repository
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private func runGit(_ arguments: [String], in repository: URL) throws {
        let result = AppState.runGitCommand(
            arguments: arguments,
            in: repository,
            timeout: AgentGitCommitService.commandTimeout
        )
        guard result.succeeded else {
            throw AgentGitReviewTestError.commandFailed(result.userMessage)
        }
    }
}

private enum AgentGitReviewTestError: Error {
    case commandFailed(String)
}
