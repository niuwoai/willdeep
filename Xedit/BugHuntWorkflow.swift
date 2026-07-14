//
//  BugHuntWorkflow.swift
//  WillDeep
//
//  /bug-hunt 入口。先 1 个 picker agent 挑出 K 个最值得审的文件，
//  K 个 hunter agent 并发各审一个文件，1 个 synthesize 把发现合并去重。
//

import Foundation

struct BugHuntWorkflow: WorkflowDefinition {
    var name: String { "bug-hunt" }
    var displayTitle: String { "Bug Hunt" }
    var slashCommand: String { "/bug-hunt" }
    var shortDescription: String { "Scan the workspace for likely bugs" }
    var argsPlaceholder: String { "(optional) area hint, e.g. \"auth and session handling\"" }
    var maxAgents: Int { 8 }
    var allowsEmptyArgs: Bool { true }
    var managedDomain: SomeIMManagedDomain { .coding }

    private let maxFilesToHunt = 6

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let hint = args.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Picker — let one agent pick K files worth auditing.
        var pickerPrompt = """
        You are a code-auditor scout. Pick the \(maxFilesToHunt) source files
        in this workspace that are MOST likely to harbor latent bugs.
        Heuristics:
        - Recent churn (look at git log)
        - High complexity (long, branchy)
        - Public API / boundary code (input handling, persistence, auth)
        - Code with known TODO/FIXME comments

        Use `git_status`, `run_command \"git log --pretty=%H -n 20\"`,
        `list_directory`, `grep_files`, `search_files` as needed.

        Output: exactly \(maxFilesToHunt) lines, each line a workspace-relative
        path. No commentary, no fences — just paths. If the workspace
        has fewer than \(maxFilesToHunt) source files, list however many it has.
        """
        if !hint.isEmpty {
            pickerPrompt += "\n\nFocus hint from the user: \(hint)"
        }

        let pickerOutput = try await engine.agent(pickerPrompt, label: "pick")
        let files = pickerOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }
            .prefix(maxFilesToHunt)

        guard !files.isEmpty else {
            return "Picker agent returned no files. Workspace empty or it misbehaved."
        }

        // 2. Hunters — one per file, in parallel.
        let hunterPrompts = files.map { path in
            """
            Audit a single file for latent bugs: `\(path)`.

            1. `read_file` the whole thing.
            2. Optionally `grep_files` for callers if their behavior changes
               the picture.
            3. List ONLY real, concrete bugs. For each:
               - **file:line** — what's wrong
               - **failure mode** — what breaks, under what input
               - **fix sketch** — the smallest correct change
            4. If you find nothing, say so plainly in one sentence.
            """
        }

        let hunterResults = await engine.parallel(
            maxConcurrent: Swift.min(self.maxAgents - 2, hunterPrompts.count),
            hunterPrompts.enumerated().map { idx, prompt in
                { @Sendable in
                    try await engine.agent(prompt, label: "hunt:\(files[files.index(files.startIndex, offsetBy: idx)].split(separator: "/").last ?? "?")")
                }
            }
        )

        let nonEmptyFindings = zip(files, hunterResults).compactMap { path, result -> String? in
            guard let result, !result.lowercased().contains("nothing found") else { return nil }
            return "## `\(path)`\n\n\(result)"
        }

        if nonEmptyFindings.isEmpty {
            return "Audited \(files.count) files, no concrete bugs surfaced. Either the codebase is clean in those spots or the hunters were too conservative — try `/bug-hunt` with a sharper hint."
        }

        // 3. Synthesize — dedup + prioritize.
        let synthesizePrompt = """
        Below are bug-hunt reports from \(nonEmptyFindings.count) parallel
        auditors, one per file. Merge them:
        - Group related findings (same root cause across files)
        - Drop duplicates and weak speculation
        - Rank by severity: data loss / security > correctness > UX > nit

        Output structure:
        # Bug hunt — \(files.count) files audited
        ## High-severity
        ## Medium-severity
        ## Low-severity / nits
        Each finding: file:line, failure mode, fix sketch.

        Reports:

        \(nonEmptyFindings.joined(separator: "\n\n---\n\n"))
        """

        return try await engine.agent(synthesizePrompt, label: "synthesize")
    }
}
