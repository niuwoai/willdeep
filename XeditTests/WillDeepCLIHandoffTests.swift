//
//  WillDeepCLIHandoffTests.swift
//  WillDeepTests
//
//  `/handoff`：会话转成 willdeep-cli Session v1、交接提交用临时索引构建并推到
//  远端分支，而本机的工作区、索引、当前分支一个字节都不动。用真实 git 跑一个
//  临时仓库 + 本地裸远端。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("WillDeep CLI handoff")
nonisolated struct WillDeepCLIHandoffTests {
    private struct Sandbox {
        let root: URL
        let repo: URL
        let remote: URL

        func git(_ arguments: [String], in directory: URL? = nil) -> GitCommandResult {
            AppState.runGitCommand(arguments: arguments, in: directory ?? repo, allowedExitStatuses: [0, 1], timeout: 60)
        }

        func runner() -> WillDeepCLIHandoff.GitRunner {
            { arguments, environment, timeout in
                AppState.runGitCommand(arguments: arguments, in: repo, allowedExitStatuses: [0, 1], timeout: timeout, extraEnvironment: environment)
            }
        }

        func write(_ path: String, _ content: String) throws {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func makeSandbox(withRemote: Bool = true) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-handoff-test-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let sandbox = Sandbox(root: root, repo: repo, remote: remote)
        #expect(sandbox.git(["init", "-q", "--bare"], in: remote).status == 0)
        #expect(sandbox.git(["init", "-q", "-b", "main"]).status == 0)
        _ = sandbox.git(["config", "user.name", "Handoff Test"])
        _ = sandbox.git(["config", "user.email", "handoff@example.invalid"])
        _ = sandbox.git(["config", "commit.gpgsign", "false"])
        if withRemote {
            _ = sandbox.git(["remote", "add", "origin", remote.path])
        }
        try sandbox.write("app.txt", "v1\n")
        try sandbox.write(".gitignore", "build/\n")
        #expect(sandbox.git(["add", "."]).status == 0)
        #expect(sandbox.git(["commit", "-q", "-m", "init"]).status == 0)
        return sandbox
    }

    private func session() -> WillDeepCLIHandoff.SessionInput {
        var host = AgentMessage(role: .user, content: "计划已批准")
        host.source = .hostInstruction
        var answer = AgentMessage(role: .assistant, content: "改完了 app.txt")
        answer.reasoningContent = "先看文件"
        return WillDeepCLIHandoff.SessionInput(
            title: "修复登录 Login flow",
            messages: [
                AgentMessage(role: .assistant, content: "开场白会被裁掉"),
                AgentMessage(role: .user, content: "把 app.txt 改成 v2"),
                AgentMessage(role: .system, content: "系统提示不进交接"),
                AgentMessage(role: .tool, content: "工具结果不进交接"),
                host,
                answer
            ],
            plan: AgentPlan(status: .executing, steps: [
                .init(text: "改 app.txt", status: .done),
                .init(text: "跑测试", status: .inProgress)
            ]),
            goal: AgentGoal(statement: "登录不再超时"),
            editedPaths: ["app.txt", "app.txt"]
        )
    }

    @Test("分支名只含 ASCII，中文标题退化成时间戳")
    func branchName() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WillDeepCLIHandoff.branchName(title: "Fix Login: timeout!", now: now) == "willdeep/handoff/20270115-080000-fix-login-timeout")
        #expect(WillDeepCLIHandoff.branchName(title: "修复登录", now: now) == "willdeep/handoff/20270115-080000")
    }

    @Test("Session v1 只带可读对话，保留思维链与宿主指令来源，计划状态沿用 snake_case")
    func cliSessionJSON() throws {
        let id = UUID()
        let data = try WillDeepCLIHandoff.cliSessionJSON(session: session(), id: id, now: Date(timeIntervalSince1970: 100))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["id"] as? String == id.uuidString.lowercased())
        #expect(object["workspace"] as? String == ".")
        #expect(object["goal"] as? String == "登录不再超时")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "user", "assistant"])
        #expect(messages[1]["source"] as? String == "hostInstruction")
        #expect(messages[2]["reasoning"] as? String == "先看文件")
        let plan = try #require(object["current_plan"] as? [String: Any])
        let steps = try #require(plan["steps"] as? [[String: Any]])
        #expect(steps.map { $0["status"] as? String } == ["done", "in_progress"])
    }

    @Test("恢复脚本里的值都单引号转义")
    func resumeScriptQuoting() throws {
        let package = WillDeepCLIHandoff.Package(cliSessionID: UUID(), branch: "willdeep/handoff/x", sessionJSON: Data(), brief: "")
        let script = WillDeepCLIHandoff.resumeScript(branch: "willdeep/handoff/x", package: package)
        #expect(script.contains("git switch -c 'willdeep/handoff/x' --track 'origin/willdeep/handoff/x'"))
        #expect(script.contains("willdeep -w \"$PWD\" run --session \(package.cliSessionID.uuidString.lowercased()) --input '\(package.briefPath)'"))
        #expect(WillDeepCLIHandoff.shellQuote("it's") == "'it'\\''s'")
    }

    @Test("交接提交带上未提交改动和传输文件，本机分支、索引、工作区不变")
    func performPushesWithoutTouchingTheWorkingTree() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.write("app.txt", "v2\n")
        try sandbox.write("staged.txt", "staged\n")
        #expect(sandbox.git(["add", "staged.txt"]).status == 0)
        try sandbox.write("new/untracked.txt", "new\n")
        try sandbox.write("build/ignored.txt", "ignored\n")

        let statusBefore = sandbox.git(["status", "--porcelain"]).stdout
        let headBefore = sandbox.git(["rev-parse", "HEAD"]).stdout
        let stagedBefore = sandbox.git(["diff", "--cached", "--name-only"]).stdout

        let result = try WillDeepCLIHandoff.perform(
            session: session(),
            instructions: "先跑测试",
            temporaryDirectory: sandbox.root.appendingPathComponent("scratch"),
            run: sandbox.runner()
        )

        #expect(result.includedUncommittedChanges)
        #expect(result.remoteName == "origin")
        #expect(sandbox.git(["status", "--porcelain"]).stdout == statusBefore)
        #expect(sandbox.git(["rev-parse", "HEAD"]).stdout == headBefore)
        #expect(sandbox.git(["diff", "--cached", "--name-only"]).stdout == stagedBefore)
        #expect(sandbox.git(["symbolic-ref", "--short", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "main")

        let remoteRef = sandbox.git(["rev-parse", "refs/heads/\(result.branch)"], in: sandbox.remote)
        #expect(remoteRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == result.commit)
        let files = sandbox.git(["ls-tree", "-r", "--name-only", result.commit], in: sandbox.remote).stdout
        #expect(files.contains("staged.txt"))
        #expect(files.contains("new/untracked.txt"))
        #expect(!files.contains("build/ignored.txt"))
        let id = result.cliSessionID.uuidString.lowercased()
        #expect(files.contains(".willdeep/handoff/\(id)/session.json"))
        #expect(files.contains(".willdeep/handoff/\(id)/brief.md"))
        #expect(sandbox.git(["show", "\(result.commit):app.txt"], in: sandbox.remote).stdout == "v2\n")
        let brief = sandbox.git(["show", "\(result.commit):.willdeep/handoff/\(id)/brief.md"], in: sandbox.remote).stdout
        #expect(brief.contains("先跑测试"))
        #expect(brief.contains("[in_progress] 跑测试"))
        #expect(sandbox.git(["rev-parse", "\(result.commit)^"], in: sandbox.remote).stdout == headBefore)
    }

    @Test("未跟踪的疑似密钥文件会拦下交接，什么都不推")
    func sensitiveUntrackedFilesStopTheHandoff() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try sandbox.write(".env", "TOKEN=x\n")
        #expect(throws: WillDeepCLIHandoff.Failure.sensitiveUntrackedFiles([".env"])) {
            try WillDeepCLIHandoff.perform(session: session(), instructions: "", temporaryDirectory: sandbox.root.appendingPathComponent("scratch"), run: sandbox.runner())
        }
        #expect(sandbox.git(["for-each-ref", "refs/heads"], in: sandbox.remote).stdout.isEmpty)
        #expect(WillDeepCLIHandoff.sensitivePaths(in: ["a/.env.local", ".env.example", "certs/server.pem", "src/key.swift"]) == ["a/.env.local", "certs/server.pem"])
    }

    @Test("没有远端时直接报错")
    func missingRemote() throws {
        let sandbox = try makeSandbox(withRemote: false)
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        #expect(throws: WillDeepCLIHandoff.Failure.noRemote) {
            try WillDeepCLIHandoff.perform(session: session(), instructions: "", temporaryDirectory: sandbox.root.appendingPathComponent("scratch"), run: sandbox.runner())
        }
    }
}
