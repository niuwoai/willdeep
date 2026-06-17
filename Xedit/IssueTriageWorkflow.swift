//
//  IssueTriageWorkflow.swift
//  WillDeep
//
//  /issue-triage — 拉当前 repo 的 open issues，分批让 sub-agent 分类
//  （bug / feature-request / question / duplicate / stale），synthesize
//  出 triage 看板和优先级建议。1.81.0-rc2 引入。
//

import Foundation

struct IssueTriageWorkflow: WorkflowDefinition {
    var name: String { "issue-triage" }
    var displayTitle: String { "Issue Triage" }
    var slashCommand: String { "/issue-triage" }
    var shortDescription: String { "Categorize and prioritize open GitHub issues" }
    var argsPlaceholder: String { "(optional) label filter, e.g. \"needs-triage\"" }
    var maxAgents: Int { 6 }
    var allowsEmptyArgs: Bool { true }

    /// 最多取多少 issue 进 triage。再多 LLM 也消化不过来，先聚焦 head 部分。
    private let issueCap = 40

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        do {
            try GitHubCLIPreflight.check(workspaceURL: engine.workspaceURL)
        } catch let failure as GitHubCLIPreflight.Failure {
            return failure.errorDescription ?? "GitHub CLI preflight failed."
        }

        let labelFilter = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // Phase 1: 1 个 scout 拉 open issues 列表（带 title + label + age）。
        let labelClause = labelFilter.isEmpty ? "" : " --label \"\(labelFilter)\""
        let scoutPrompt = """
        Collect open issues from this GitHub repo for triage.

        Run:
        - `gh issue list --state open --limit \(issueCap)\(labelClause) --json number,title,labels,createdAt,updatedAt,author,comments,body`

        Output ONE markdown block with the issues, each as:

        ### #N — title
        - author: @login, created: YYYY-MM-DD, updated: YYYY-MM-DD, comments: K, labels: a,b,c
        - body (first ~300 chars):
        > <first ~3 lines of body, quoted>

        Up to \(issueCap) issues. If fewer exist, list them all. Do NOT categorize yet.
        """
        let issueList = try await engine.agent(scoutPrompt, label: "scout")

        // Phase 2: 3 个并发分类 agent 共看同一个清单，但聚焦不同维度。
        let analysisPrompts: [(label: String, prompt: String)] = [
            ("classify", """
            Classify each open issue from the list below into one of these buckets:
            - **bug** — clear reproducible defect
            - **feature** — feature request / enhancement
            - **question** — user asking for help, may not need a code change
            - **docs** — documentation only
            - **stale** — no activity in 90+ days AND nobody is waiting on it
            - **duplicate** — appears to duplicate another # in the list (cite which)
            - **unclear** — title/body too vague to bucket

            Output a markdown table:
            | # | Title (short) | Bucket | Notes |

            Issue list:

            \(issueList)
            """),
            ("severity", """
            For each open issue from the list below, judge its **user-impact severity**:
            - **P0** — breaks core functionality / data loss / security
            - **P1** — significantly impairs a common workflow
            - **P2** — annoying or affects an uncommon path
            - **P3** — polish, edge case
            - **N/A** — feature requests, questions, docs

            Output a markdown table:
            | # | Title (short) | Severity | Reasoning (≤ 25 words) |

            Issue list:

            \(issueList)
            """),
            ("duplicates", """
            Scan the open issues list below for likely **duplicates and related-issue clusters**.

            Output:
            ## Probable duplicates
            For each suspected duplicate pair / triplet, list the # involved + a 1-sentence reason
            and a recommendation (close which one, link them, or merge into a tracker).

            ## Related clusters
            Groups of issues that aren't duplicates but share a root cause — bundling fixes
            could close many at once.

            If you find no duplicates or clusters, write "No obvious duplicates" / "No obvious clusters".

            Issue list:

            \(issueList)
            """),
        ]

        let analysisResults = await engine.parallel(maxConcurrent: 3, analysisPrompts.map { item in
            { @Sendable in
                try await engine.agent(item.prompt, label: "analyze:\(item.label)")
            }
        })

        let classification = analysisResults[0] ?? "(classify agent failed)"
        let severity = analysisResults[1] ?? "(severity agent failed)"
        let duplicates = analysisResults[2] ?? "(duplicates agent failed)"

        // Phase 3: synthesize → triage board.
        let synthesisPrompt = """
        Produce a triage report from the three analyses below.

        Output structure (markdown):
        # Issue triage
        \(labelFilter.isEmpty ? "(open issues, up to \(issueCap))" : "(label: \(labelFilter))")

        ## At-a-glance
        - Total open issues: N
        - Bugs: N (P0: N, P1: N)
        - Feature requests: N
        - Questions: N
        - Likely duplicates: N
        - Stale candidates: N

        ## Top priorities to look at next
        Ordered list of #N — title (severity, bucket) — one-sentence why. Cap at 10.

        ## Probable duplicates
        Recap from the duplicates analysis. Concrete action per pair.

        ## Stale / closable
        Issues that look ready to be auto-closed with a polite "stale" comment.
        Each: #N — title — why (e.g., "no reply from author in 6 months, P3 severity").

        ## Full table
        Merge classify + severity into a single table:
        | # | Title | Bucket | Severity | Notes |

        Analyses:

        ### Classification

        \(classification)

        ### Severity

        \(severity)

        ### Duplicates

        \(duplicates)

        Source issue list (for cross-reference):

        \(issueList)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }
}
