//
//  AgentContextBuilder.swift
//  VeilWriter
//
//  Builds compact project context for first-phase agent chat.
//

import Foundation

enum AgentContextBuilder {
    private static let maxCurrentFileCharacters = 12_000
    private static let maxSelectionCharacters = 6_000
    private static let maxRulesCharacters = 6_000

    static func systemPrompt(
        rootDirectory: URL?,
        openedFileURL: URL?,
        fileContent: String,
        selectedText: String,
        language: Language?,
        toolsEnabled: Bool = false,
        interactionMode: AgentInteractionMode = .normal,
        currentPlan: AgentPlan? = nil,
        currentGoal: AgentGoal? = nil
    ) -> String {
        var sections: [String] = []
        sections.append("""
        You are VeilWriter Agent, a concise coding assistant embedded in a native macOS editor.
        Work with the currently opened project directory as the workspace.
        You cannot directly change files. When the user asks for code edits, provide a unified diff in a ```diff fenced block.
        Only generate diffs for existing files in the workspace, using paths relative to the workspace root.
        Avoid new files, deleted files, binary files, and paths outside the workspace unless the user explicitly asks and the app supports that workflow.
        Keep answers practical and scoped to the visible project context.
        """)

        // Plan mode: lock writes behind a numbered, user-approved plan.
        if interactionMode == .plan {
            if currentPlan == nil || currentPlan?.status == .proposed || currentPlan?.status == .rejected {
                sections.append("""
                === PLAN MODE — ACTIVE ===
                You are in plan-first mode. Before ANY tool call that writes, edits, or runs commands, you MUST first emit a numbered plan in a single fenced block tagged `plan`:

                ```plan
                1. <one-line step>
                2. <one-line step>
                ...
                ```

                Then STOP and wait for the user to click Approve. Do not call any tool yet. Read-only tools (search_files, grep_files, read_file, list_directory, git_status) are still allowed if you need them BEFORE drafting the plan — but once you've drafted, stop and wait.
                If the user revises and re-prompts after a Reject, emit a new ```plan block.
                """)
            } else if currentPlan?.status == .approved || currentPlan?.status == .executing {
                let plan = currentPlan!
                let stepsText = plan.steps.enumerated()
                    .map { "\($0.offset + 1). [\($0.element.status.rawValue)] \($0.element.text)" }
                    .joined(separator: "\n")
                sections.append("""
                === PLAN MODE — APPROVED ===
                The user approved this plan. Execute it step-by-step. Tool calls (including writes) are now unlocked.

                Approved plan (current statuses shown in brackets):
                \(stepsText)

                Progress reporting (REQUIRED):
                At the end of EVERY reply where you advanced or finished a step, include exactly one fenced block tagged `progress` listing each step number you touched this turn and its new status. Use these status tokens: `pending`, `in_progress`, `done`, `skipped`, `failed`. Example:

                ```progress
                1: done
                2: in_progress
                ```

                Steps you didn't touch this turn can be omitted. Mark a step `in_progress` before you start its tool calls; flip it to `done` (or `failed`) once finished. Once every step is `done`/`skipped`/`failed`, summarize what was accomplished.
                """)
            }
        }

        // Goal mode: pin the objective + checklist to every turn.
        if interactionMode == .goal, let goal = currentGoal, !goal.isEmpty {
            var goalBlock = "=== GOAL MODE — ACTIVE ===\n"
            if !goal.statement.isEmpty {
                goalBlock += "Goal: \(goal.statement)\n"
            }
            if !goal.checklist.isEmpty {
                goalBlock += "Acceptance checklist:\n"
                for item in goal.checklist {
                    goalBlock += "  - [\(item.done ? "x" : " ")] \(item.text)\n"
                }
            }
            goalBlock += "\nAt the end of every reply, briefly state which checklist items moved (use the exact item text) and what's still blocking."
            sections.append(goalBlock)
        }

        if toolsEnabled {
            sections.append("""
            Tools:
            - You can call tools to look around the workspace before answering: search_files, grep_files, read_file, list_directory, git_status, run_command.
            - You can discover Codex skills with list_skills and read a selected skill's SKILL.md with read_skill. Use skills when the user's task matches a specialized workflow.
            - You can inspect configured MCP servers with list_mcp_servers, inspect a server's tools with list_mcp_tools, and call a configured MCP tool with call_mcp_tool. MCP tool calls may require approval.
            - Prefer the read-only tools first. They run automatically. Simple read-only run_command calls such as `cd subdir && git diff`, `ls`, `cat`, `rg`, and `grep` can also run automatically after conservative parsing. Other run_command calls require user approval; destructive commands additionally need typed confirmation.
            - When something a user asked for is ambiguous or you're missing a required piece of information, call ask_user with a single concrete question instead of guessing. Do NOT call ask_user for things you can determine by reading files yourself. If the answer is one of a small known set, pass `options` so the user can click; set `multi_select` to true only when more than one option can legitimately apply at once.
            - Use workspace-relative paths in tool arguments.
            - After gathering enough context, stop calling tools and answer the user. For edits, still emit a ```diff block.
            """)
        }

        if let rootDirectory {
            sections.append("""
            Workspace:
            - Root: \(rootDirectory.path)
            - Name: \(rootDirectory.lastPathComponent)
            """)

            if let rules = projectRules(in: rootDirectory) {
                sections.append("""
                Project instructions:
                \(rules)
                """)
            }
        } else {
            sections.append("Workspace: no folder is currently open.")
        }

        if let openedFileURL {
            sections.append("""
            Active file:
            - Path: \(relativePath(for: openedFileURL, rootDirectory: rootDirectory))
            - Language: \(language?.displayName ?? "Plain Text")
            """)
        } else {
            sections.append("Active file: none.")
        }

        let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelection.isEmpty {
            sections.append("""
            Current selection:
            ```text
            \(limit(trimmedSelection, to: maxSelectionCharacters))
            ```
            """)
        }

        let trimmedContent = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            sections.append("""
            Current file content excerpt:
            ```text
            \(limit(trimmedContent, to: maxCurrentFileCharacters))
            ```
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func projectRules(in rootDirectory: URL) -> String? {
        let candidates = ["AGENTS.md", "CLAUDE.md", "README.md", "product-overview.md"]
        var collected: [String] = []

        for name in candidates {
            let url = rootDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let excerpt = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: maxRulesCharacters)
            guard !excerpt.isEmpty else { continue }
            collected.append("# \(name)\n\(excerpt)")
        }

        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "\n\n")
    }

    private static func relativePath(for url: URL, rootDirectory: URL?) -> String {
        guard let rootDirectory else { return url.path }
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        let relative = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}

// MARK: - Plan parser

/// Pulls a numbered plan out of an assistant message that contains a
/// ```plan fenced block. Lines starting with `N.` or `N)` count as steps;
/// everything inside the block before the first numbered line becomes
/// `summary`. Returns nil when no such block is present.
enum AgentPlanParser {
    static func extract(from content: String) -> AgentPlan? {
        guard let body = fencedBody(in: content, tag: "plan") else { return nil }
        var stepTexts: [String] = []
        var summaryLines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !stepTexts.isEmpty { continue }
                summaryLines.append("")
                continue
            }
            if let step = numberedStep(from: trimmed) {
                stepTexts.append(step)
            } else if stepTexts.isEmpty {
                summaryLines.append(trimmed)
            } else {
                // Continuation line under the previous step — append.
                let lastIdx = stepTexts.count - 1
                stepTexts[lastIdx] = "\(stepTexts[lastIdx]) \(trimmed)"
            }
        }
        guard !stepTexts.isEmpty else { return nil }
        let summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentPlan(status: .proposed, summary: summary, stepTexts: stepTexts)
    }

    /// Returns a copy of `plan` with step statuses updated from any
    /// ```progress fenced block in `content`. Block format:
    ///
    ///     ```progress
    ///     1: done
    ///     2: in_progress
    ///     3: skipped
    ///     ```
    ///
    /// `N` is the 1-based step index from the original plan. Unknown
    /// keys are ignored so a sloppy agent reply can't corrupt the
    /// whole plan. Returns nil when no progress block is present.
    static func applyProgress(to plan: AgentPlan, from content: String) -> AgentPlan? {
        guard let body = fencedBody(in: content, tag: "progress") else { return nil }
        var updates: [Int: AgentPlan.StepStatus] = [:]
        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Accept "1: done", "1) done", "step 1: done", "- 1. done"
            // Walk to the first run of digits, then to the separator.
            guard let (index, after) = leadingNumber(in: trimmed),
                  index >= 1, index <= plan.steps.count else { continue }
            // Skip a single separator char (: . ) -) after the number.
            let rest = trimmed[after...].drop { $0 == ":" || $0 == "." || $0 == ")" || $0 == "-" || $0 == " " || $0 == "\t" }
            let token = rest.split(separator: " ", maxSplits: 1).first.map(String.init)?
                .lowercased() ?? ""
            if let parsed = parseStepStatus(token) {
                updates[index - 1] = parsed
            }
        }
        guard !updates.isEmpty else { return nil }
        var next = plan
        for (i, newStatus) in updates {
            next.steps[i].status = newStatus
        }
        // Promote the whole plan to .executing the moment any step is
        // touched, and .done when every step is in a terminal state.
        if next.steps.allSatisfy({ [.done, .skipped, .failed].contains($0.status) }) {
            next.status = .done
        } else if next.status == .approved {
            next.status = .executing
        }
        return next
    }

    private static func fencedBody(in content: String, tag: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        let wanted = tag.lowercased()
        var inBlock = false
        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if trimmed.hasPrefix("```") {
                    let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    if info == wanted { inBlock = true }
                }
                continue
            }
            if trimmed.hasPrefix("```") { return body.joined(separator: "\n") }
            body.append(line)
        }
        // Streaming case: ``` not yet closed — still return what we have
        // so the plan card can render mid-stream.
        return inBlock && !body.isEmpty ? body.joined(separator: "\n") : nil
    }

    private static func numberedStep(from line: String) -> String? {
        var i = line.startIndex
        // Allow a leading "- " before the number for bulleted variants.
        if i < line.endIndex, line[i] == "-" {
            i = line.index(after: i)
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
        }
        let numStart = i
        while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
        guard i > numStart, i < line.endIndex else { return nil }
        let separator = line[i]
        guard separator == "." || separator == ")" else { return nil }
        let rest = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Returns the leading integer and the index right after it. Walks
    /// past any non-digit prefix (e.g. `"- "`, `"step "`) up to ~6 chars
    /// to forgive small formatting variations.
    private static func leadingNumber(in s: String) -> (Int, String.Index)? {
        var i = s.startIndex
        var skips = 0
        while i < s.endIndex, !s[i].isNumber, skips < 6 {
            i = s.index(after: i)
            skips += 1
        }
        guard i < s.endIndex, s[i].isNumber else { return nil }
        let numStart = i
        while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
        return (Int(s[numStart..<i]) ?? 0, i)
    }

    private static func parseStepStatus(_ token: String) -> AgentPlan.StepStatus? {
        switch token {
        case "done", "complete", "completed", "finished", "ok", "✓", "✔":
            return .done
        case "in_progress", "in-progress", "inprogress", "running", "active", "wip", "doing":
            return .inProgress
        case "pending", "todo", "queued", "waiting":
            return .pending
        case "skipped", "skip":
            return .skipped
        case "failed", "fail", "error", "blocked":
            return .failed
        default:
            return nil
        }
    }
}
