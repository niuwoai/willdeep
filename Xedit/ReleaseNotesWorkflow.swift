//
//  ReleaseNotesWorkflow.swift
//  WillDeep
//
//  /release-notes <since-tag> — 扫 since-tag..HEAD 区间内的 commits +
//  merged PRs，分类并合成 release note。1.81.0-rc2 引入。
//

import Foundation

struct ReleaseNotesWorkflow: WorkflowDefinition {
    var name: String { "release-notes" }
    var displayTitle: String { "Release Notes" }
    var slashCommand: String { "/release-notes" }
    var shortDescription: String { "Generate release notes between a tag and HEAD" }
    var argsPlaceholder: String { "since tag, e.g. v1.80.0-rc1" }
    var maxAgents: Int { 4 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let sinceTag = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sinceTag.isEmpty else {
            return "Usage: `/release-notes <tag>`, e.g. `/release-notes v1.80.0-rc1`."
        }

        do {
            try await GitHubCLIPreflight.check(workspaceURL: engine.workspaceURL)
        } catch let failure as GitHubCLIPreflight.Failure {
            return failure.errorDescription ?? "GitHub CLI preflight failed."
        }

        // Phase 1: 1 个 agent 拉提交清单 + PR 清单。
        let scoutPrompt = """
        Collect the raw material for release notes between tag `\(sinceTag)` and HEAD.

        Run (one per `run_command` call):
        - `git log \(sinceTag)..HEAD --oneline` (full commit list)
        - `git log \(sinceTag)..HEAD --format='%H %s'` (so PR numbers in subjects are visible)
        - `gh pr list --state merged --search "merged:>\(sinceTag)" --limit 50 --json number,title,labels,author,body` (merged PRs since the tag — may be approximate if the tag was created later than the PR merge)

        Output ONE markdown document with two sections:
        ## Commits (\(sinceTag)..HEAD)
        ```
        <verbatim git log output>
        ```
        ## Merged PRs
        Bulleted: #N — title — author — labels (comma-joined)

        Do not group or categorize yet — that's the next phase.
        """
        let rawMaterial = try await engine.agent(scoutPrompt, label: "scout")

        // Phase 2: 3 个并发分类 agent，各从一个角度切。
        let categoryPrompts: [(label: String, prompt: String)] = [
            ("features", """
            From the raw material below, list every **user-visible new feature** between \(sinceTag) and HEAD.
            For each: a 1-line description in past tense ("Added X", "Introduced Y") with the PR number or commit short hash in parens.
            If a change is unclear, run `run_command "git show <sha>"` or `run_command "gh pr view <#>"` to disambiguate.
            Skip refactors, internal cleanups, and bugfixes — those belong to other categories.

            Raw material:

            \(rawMaterial)
            """),
            ("fixes", """
            From the raw material below, list every **bug fix** between \(sinceTag) and HEAD.
            For each: a 1-line description ("Fixed X when Y") with PR # or commit hash in parens.
            Group related fixes if they share a root cause.

            Raw material:

            \(rawMaterial)
            """),
            ("breaking", """
            From the raw material below, identify any **breaking changes** between \(sinceTag) and HEAD —
            removed APIs, renamed config keys, behavior changes, dropped platform support, schema migrations.
            For each: clearly describe what changed, what the upgrade path is, with PR # in parens.

            If nothing is breaking, output a single line: "No breaking changes."

            Raw material:

            \(rawMaterial)
            """),
        ]

        let categoryResults = await engine.parallel(maxConcurrent: 3, categoryPrompts.map { item in
            { @Sendable in
                try await engine.agent(item.prompt, label: "cat:\(item.label)")
            }
        })

        let featuresSection = categoryResults[0] ?? "(features agent failed)"
        let fixesSection = categoryResults[1] ?? "(fixes agent failed)"
        let breakingSection = categoryResults[2] ?? "(breaking agent failed)"

        // Phase 3: synthesize → 最终 release note。
        let synthesisPrompt = """
        Polish these three category lists into a release note for the range `\(sinceTag)..HEAD`.

        Output structure (markdown):
        # Release notes (\(sinceTag) → HEAD)

        ## ⚠️ Breaking changes
        \(breakingSection)

        ## ✨ New features
        \(featuresSection)

        ## 🐛 Bug fixes
        \(fixesSection)

        ## Contributors
        Bulleted list of unique authors from the raw material. Deduplicate by username.

        Polish rules:
        - Past tense, terse, parallel sentence structure.
        - PR numbers as `#NNN` (no GitHub URL — markdown autolinks the rest).
        - If a section is empty, write "(none)" — don't pad.
        - Remove anything labeled "chore", "docs", "ci" from the visible output (mention briefly under "Other" if substantial).

        Raw material for cross-reference:

        \(rawMaterial)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }
}
