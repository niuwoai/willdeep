//
//  CodeReviewWorkflow.swift
//  WillDeep
//
//  /code-review 入口。4 个 dimension 并发 review 当前 git diff。
//

import Foundation

struct CodeReviewWorkflow: WorkflowDefinition {
    var name: String { "code-review" }
    var displayTitle: String { "Code Review" }
    var slashCommand: String { "/code-review" }
    var shortDescription: String { "Review current git diff across 4 dimensions" }
    var argsPlaceholder: String { "(optional) focus hint, e.g. \"auth flow only\"" }
    var maxAgents: Int { 4 }
    var allowsEmptyArgs: Bool { true }

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
        let hint = args.trimmingCharacters(in: .whitespacesAndNewlines)

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

        let results = await engine.parallel(maxConcurrent: 4, prompts.enumerated().map { idx, prompt in
            { @Sendable in
                try await engine.agent(prompt, label: "review:\(self.dimensions[idx].label)")
            }
        })

        let parts = zip(dimensions, results).compactMap { dim, result -> String? in
            guard let result else { return nil }
            return "## \(dim.label.capitalized)\n\n\(result)"
        }
        if parts.isEmpty {
            return "All review dimensions failed. Check that there are uncommitted changes and the agent has read access."
        }

        return "# Code review — current diff\n\n" + parts.joined(separator: "\n\n---\n\n")
    }
}
