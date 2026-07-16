//
//  CodeReviewWorkflow.swift
//  WillDeep
//
//  /code-review 入口。默认审 working tree diff；带 `--pr <#>` /
//  `pr=<#>` 时改审指定 GitHub PR 的 diff（1.81.0-rc2 引入）。4 个
//  dimension 并发跑。
//

import Foundation

struct CodeReviewWorkflow: WorkflowDefinition {
    var name: String { "code-review" }
    var displayTitle: String { "Code Review" }
    var slashCommand: String { "/code-review" }
    var shortDescription: String { "Review current git diff (or `--pr <#>`) across 4 dimensions" }
    var argsPlaceholder: String { "(optional) --pr <#> or focus hint" }
    var maxAgents: Int { 4 }
    var allowsEmptyArgs: Bool { true }
    var managedDomain: SomeIMManagedDomain { .coding }

    private let dimensions: [(label: String, lens: String, detail: String)] = [
        ("correctness", "correctness & logic bugs",
         "Look for off-by-one, null deref, race conditions, wrong control flow, swapped args, missing early-return."),
        ("security", "security & input validation",
         "Look for injection (SQL/shell/regex), unsafe deserialization, missing auth checks, secret leaks, path traversal, OWASP top-10 patterns."),
        ("performance", "performance & scaling",
         "Look for N+1 queries, O(n²) on potentially large inputs, sync I/O on main thread, missing pagination, unbounded buffers, unnecessary re-renders."),
        ("tests", "test coverage & error handling",
         "Look for untested edge cases, swallowed errors, missing fallbacks, hard-to-test code, regressions a test would catch."),
    ]

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = parseArgs(args)

        // PR mode → preflight gh + 替换 diff 来源。
        if let prNumber = parsed.prNumber {
            do {
                try await GitHubCLIPreflight.check(workspaceURL: engine.workspaceURL)
            } catch let failure as GitHubCLIPreflight.Failure {
                return failure.errorDescription ?? "GitHub CLI preflight failed."
            }
            return try await runPRMode(engine: engine, prNumber: prNumber, hint: parsed.hint)
        }

        // Default: working tree diff.
        return try await runWorkingTreeMode(engine: engine, hint: parsed.hint)
    }

    // MARK: - Working tree mode (unchanged behavior from 1.81.0-rc1)

    private func runWorkingTreeMode(engine: WorkflowEngine, hint: String) async throws -> String {
        let prompts = dimensions.map { dim in
            var lines: [String] = []
            lines.append("You are reviewing the current uncommitted git diff for **\(dim.lens)**.")
            lines.append("")
            lines.append("1. Run `git_status` and `run_command \"git diff\"` to see what changed.")
            lines.append("2. \(dim.detail)")
            lines.append("3. For each finding, output:")
            lines.append("   - **file:line** — what you saw")
            lines.append("   - **risk** — concrete failure mode (not vague \"could be problematic\")")
            lines.append("   - **fix** — the smallest correct change")
            lines.append("4. If you find nothing, say so plainly — no padding.")
            if !hint.isEmpty {
                lines.append("")
                lines.append("Focus hint from the user: \(hint)")
            }
            return lines.joined(separator: "\n")
        }

        let results = try await engine.parallel(maxConcurrent: 4, prompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "review:\(self.dimensions[idx].label)")
            }
        })

        let parts = zip(dimensions, results).compactMap { dim, result -> String? in
            guard let result else { return nil }
            return "## \(dim.label.capitalized)\n\n\(result)"
        }
        if parts.isEmpty {
            // rc40:全维度失败别再返回成功字符串(会让卡片变绿勾伪装完成)。抛错 →
            // 卡片 .failed,用户能看到确实出问题了。
            throw WorkflowError.allTasksFailed(reason: "All review dimensions failed. The model/provider likely didn't respond — check the provider connection, and that there are uncommitted changes the agent can read.")
        }

        return "# Code review — working tree diff\n\n" + parts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - PR mode (1.81.0-rc2+)

    private func runPRMode(engine: WorkflowEngine, prNumber: Int, hint: String) async throws -> String {
        let prompts = dimensions.map { dim in
            var lines: [String] = []
            lines.append("You are reviewing **GitHub PR #\(prNumber)** of this repository for **\(dim.lens)**.")
            lines.append("")
            lines.append("1. Run `run_command \"gh pr view \(prNumber)\"` once to read the PR title, description, and base branch.")
            lines.append("2. Run `run_command \"gh pr diff \(prNumber)\"` to see the full diff.")
            lines.append("3. \(dim.detail)")
            lines.append("4. For each finding, output:")
            lines.append("   - **file:line** (in the PR diff) — what you saw")
            lines.append("   - **risk** — concrete failure mode")
            lines.append("   - **fix** — the smallest correct change")
            lines.append("5. If you find nothing in this dimension, say so plainly in one sentence.")
            if !hint.isEmpty {
                lines.append("")
                lines.append("Focus hint from the user: \(hint)")
            }
            return lines.joined(separator: "\n")
        }

        let results = try await engine.parallel(maxConcurrent: 4, prompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "review:\(self.dimensions[idx].label)")
            }
        })

        let parts = zip(dimensions, results).compactMap { dim, result -> String? in
            guard let result else { return nil }
            return "## \(dim.label.capitalized)\n\n\(result)"
        }
        if parts.isEmpty {
            throw WorkflowError.allTasksFailed(reason: "All review dimensions failed. Check that PR #\(prNumber) exists, `gh` is authenticated, and the provider responded.")
        }

        return "# Code review — PR #\(prNumber)\n\n" + parts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Arg parsing

    /// 解析 args：`--pr 123`、`--pr=123`、`pr=123` 都接受。剩下的
    /// non-flag 内容视作 free-form focus hint。
    private func parseArgs(_ raw: String) -> (prNumber: Int?, hint: String) {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var prNumber: Int? = nil
        var hintTokens: [String] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--pr", i + 1 < tokens.count, let n = Int(tokens[i + 1]) {
                prNumber = n
                i += 2
                continue
            }
            if let n = extractPRNumber(from: token) {
                prNumber = n
                i += 1
                continue
            }
            hintTokens.append(token)
            i += 1
        }
        return (prNumber, hintTokens.joined(separator: " "))
    }

    /// 匹配 `--pr=N` / `pr=N` / 单独的 `#N` 形式。
    private func extractPRNumber(from token: String) -> Int? {
        if token.hasPrefix("--pr=") {
            return Int(token.dropFirst("--pr=".count))
        }
        if token.hasPrefix("pr=") {
            return Int(token.dropFirst("pr=".count))
        }
        if token.hasPrefix("#") {
            return Int(token.dropFirst())
        }
        return nil
    }
}
