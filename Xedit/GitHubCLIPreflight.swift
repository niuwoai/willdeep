//
//  GitHubCLIPreflight.swift
//  WillDeep
//
//  1.81.0-rc2：GitHub 系 workflow（/pr-review, /release-notes,
//  /issue-triage 及带 `--pr <#>` 的 /code-review）开跑前的预检。
//  没装 `gh` / 没登录 / cwd 不是 git repo / repo 没 GitHub remote 时
//  直接退出并报错给用户 —— 比让一堆 sub-agent 跑到 LLM 调用层才发
//  现 401 / not found 省 token 也省时间。
//
//  全部预检都通过 `/usr/bin/env -S gh ...` 同步走 Process 跑，单次
//  调用 ≤2s。
//

import Foundation

nonisolated enum GitHubCLIPreflight {
    enum Failure: Error, LocalizedError {
        case ghNotInstalled
        case notLoggedIn(stderr: String)
        case notAGitRepo(cwd: String)
        case noGitHubRemote
        case unknownError(String)

        var errorDescription: String? {
            switch self {
            case .ghNotInstalled:
                return "GitHub CLI (`gh`) is not installed or not on PATH. Install it via Homebrew (`brew install gh`) and re-run the workflow."
            case .notLoggedIn(let stderr):
                return "GitHub CLI is installed but not logged in. Run `gh auth login` in a terminal, then retry. (\(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
            case .notAGitRepo(let cwd):
                return "Workspace `\(cwd)` is not a git repository — GitHub-based workflows need a repo to run against."
            case .noGitHubRemote:
                return "Repository has no GitHub remote. Add one (`git remote add origin git@github.com:owner/repo.git`) or run the workflow from a repo with a GitHub remote."
            case .unknownError(let message):
                return "GitHub CLI preflight failed: \(message)"
            }
        }
    }

    /// 在 workspace 根目录跑一次预检。所有 GitHub 系 workflow 的
    /// `run(...)` 开头都调一次。失败抛 Failure，调用方 catch 后把
    /// errorDescription 当成 workflow summary 显示给用户。
    ///
    /// Detached：每个探测都是 10s 超时的同步子进程，`gh auth status`
    /// 还要打网络（走代理时单次可达数秒），调用方在 MainActor 上。
    static func check(workspaceURL: URL?) async throws {
        try await Task.detached(priority: .userInitiated) {
            try checkGhAvailable()
            try checkGhAuthenticated()
            if let workspaceURL {
                try checkGitRepo(at: workspaceURL)
                try checkGitHubRemote(at: workspaceURL)
            }
            // 没传 workspaceURL（agent 不绑 workspace 的场景）就跳过最后
            // 两步 —— /issue-triage 等其实也能跑（gh 命令自己挑默认 repo
            // 或要用户在 args 里显式指定），不强求。
        }.value
    }

    private static func checkGhAvailable() throws {
        let result = run("/usr/bin/env", ["-S", "gh", "--version"])
        guard result.exitCode == 0 else {
            throw Failure.ghNotInstalled
        }
    }

    private static func checkGhAuthenticated() throws {
        // `gh auth status` 把状态打到 stderr，未登录 exit code != 0。
        let result = run("/usr/bin/env", ["-S", "gh", "auth", "status"])
        guard result.exitCode == 0 else {
            throw Failure.notLoggedIn(stderr: result.stderr)
        }
    }

    private static func checkGitRepo(at url: URL) throws {
        let result = run(
            "/usr/bin/env",
            ["-S", "git", "rev-parse", "--is-inside-work-tree"],
            cwd: url
        )
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, trimmed == "true" else {
            throw Failure.notAGitRepo(cwd: url.path)
        }
    }

    private static func checkGitHubRemote(at url: URL) throws {
        let result = run("/usr/bin/env", ["-S", "git", "remote", "-v"], cwd: url)
        guard result.exitCode == 0 else {
            throw Failure.unknownError("git remote -v failed: \(result.stderr)")
        }
        let lower = result.stdout.lowercased()
        guard lower.contains("github.com") else {
            throw Failure.noGitHubRemote
        }
    }

    // MARK: - Sync Process runner

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) -> RunResult {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        do {
            let output = try AgentSubprocess.runSynchronously(process, timeout: 10)
            return RunResult(exitCode: output.exitStatus, stdout: output.stdoutText, stderr: output.stderrText)
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: "Failed to launch: \(error.localizedDescription)")
        }
    }
}
