//
//  PRReviewWorkflow.swift
//  WillDeep
//
//  /pr-review <#> — 深度 PR 审查，比 /code-review --pr <#> 多看 PR
//  描述、已存在的 review comments、CI 状态、相关 issue；synthesize
//  出 GitHub 风格的 review 建议（approve / request changes / comment）
//  并给出可粘贴的 inline comment 提示。1.81.0-rc2 引入。
//

import Foundation

struct PRReviewWorkflow: WorkflowDefinition {
    var name: String { "pr-review" }
    var displayTitle: String { "PR Review" }
    var slashCommand: String { "/pr-review" }
    var shortDescription: String { "Deep review of a GitHub PR with review verdict" }
    var argsPlaceholder: String { "PR number, e.g. 123" }
    var maxAgents: Int { 6 }
    var allowsEmptyArgs: Bool { false }
    var managedDomain: SomeIMManagedDomain { .coding }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard let prNumber = Int(token) else {
            return "Usage: `/pr-review <number>`, e.g. `/pr-review 123` or `/pr-review #123`."
        }

        do {
            try GitHubCLIPreflight.check(workspaceURL: engine.workspaceURL)
        } catch let failure as GitHubCLIPreflight.Failure {
            return failure.errorDescription ?? "GitHub CLI preflight failed."
        }

        // Phase 1: 1 个 context agent 拉 PR 元数据 + diff + 已有 comments
        // + CI status，输出一段 markdown 摘要供后续 4 个 dim agent 共用。
        let contextPrompt = """
        Build context for reviewing GitHub PR #\(prNumber).

        Run these gh commands (one per `run_command` call):
        - `gh pr view \(prNumber) --json title,body,baseRefName,headRefName,author,additions,deletions,changedFiles,labels,state` (use the JSON output as the source of truth)
        - `gh pr view \(prNumber) --comments` (collect the existing review thread; quote 3-5 of the most actionable)
        - `gh pr checks \(prNumber)` (note any failing checks)

        Produce a self-contained context document with sections:
        ## PR overview
        Title, author, base ← head, change size (additions/deletions, file count), labels, current state.
        ## What the PR says it does
        2-4 sentence paraphrase of the description.
        ## Existing review threads
        Up to 5 quoted comments + who said them, focused on outstanding concerns.
        ## CI status
        Pass/fail list. Note which checks failed and any error excerpt if reachable.

        DO NOT review the code yet — that's the next phase.
        """
        let contextDoc = try await engine.agent(contextPrompt, label: "context")

        // Phase 2: 4 个 dim agent 并发审 diff，每个都有 contextDoc 当 prefix。
        let dimensions: [(label: String, lens: String, detail: String)] = [
            ("correctness", "correctness & logic bugs",
             "Off-by-one, null deref, race conditions, wrong control flow, swapped args, missing early-return."),
            ("security", "security & input validation",
             "Injection, unsafe deserialization, missing auth checks, secret leaks, path traversal, OWASP top-10."),
            ("performance", "performance & scaling",
             "N+1 queries, O(n²) on large inputs, sync I/O on hot paths, missing pagination, unbounded buffers."),
            ("tests", "test coverage & error handling",
             "Untested edge cases, swallowed errors, missing fallbacks, hard-to-test code, regressions a test would catch."),
        ]

        let reviewPrompts = dimensions.map { dim in
            """
            You are reviewing GitHub PR #\(prNumber) along the **\(dim.lens)** axis.

            Context (collected by another agent — trust it, don't re-fetch):

            \(contextDoc)

            Now run `gh pr diff \(prNumber)` to read the actual diff, then look for:
            \(dim.detail)

            For each finding, output a structured block:
            - **file:line** (in the PR diff)
            - **risk** — concrete failure mode
            - **suggested inline comment** — what you'd write in GitHub's review UI (≤120 chars, actionable)

            If you find nothing in this dimension, say so plainly in one sentence.
            """
        }

        let reviewResults = await engine.parallel(maxConcurrent: 4, reviewPrompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "review:\(dimensions[idx].label)")
            }
        })

        let reviewParts = zip(dimensions, reviewResults).compactMap { dim, result -> String? in
            guard let result else { return nil }
            return "## \(dim.label.capitalized)\n\n\(result)"
        }
        if reviewParts.isEmpty {
            return "All 4 review dimensions failed. Check `gh auth status` and that PR #\(prNumber) is accessible."
        }

        // Phase 3: synthesize → GitHub-style verdict.
        let synthesisPrompt = """
        You are giving the final verdict on GitHub PR #\(prNumber). Below are
        the per-dimension review reports. Synthesize into a single review.

        Output structure (markdown):
        # PR #\(prNumber) — review

        ## Verdict
        One of: ✅ **Approve** / 🔄 **Request changes** / 💬 **Comment only**.
        Then one sentence explaining why.

        ## Must-fix (blocking)
        Bullet list of findings that block merge. file:line + reason + fix.
        If none, write "(none)".

        ## Should-fix (non-blocking but recommended)
        Same shape, but the PR could merge first.

        ## Nits / discussion
        Style, naming, suggestions. Anything you'd leave a comment on but
        wouldn't block on.

        ## Suggested inline comments
        Bulleted list of file:line — short comment text, copy-paste ready.

        Context:

        \(contextDoc)

        Per-dimension reports:

        \(reviewParts.joined(separator: "\n\n---\n\n"))
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }
}
