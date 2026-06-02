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
                let stepsText = (currentPlan?.steps ?? []).enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n")
                sections.append("""
                === PLAN MODE — APPROVED ===
                The user approved this plan. Execute it step-by-step. Tool calls (including writes) are now unlocked. After finishing the last step, summarize what was done.

                Approved plan:
                \(stepsText)
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
        guard let body = fencedPlanBody(in: content) else { return nil }
        var steps: [String] = []
        var summaryLines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !steps.isEmpty { continue }
                summaryLines.append("")
                continue
            }
            if let step = numberedStep(from: trimmed) {
                steps.append(step)
            } else if steps.isEmpty {
                summaryLines.append(trimmed)
            } else {
                // Continuation line under the previous step — append.
                let lastIdx = steps.count - 1
                steps[lastIdx] = "\(steps[lastIdx]) \(trimmed)"
            }
        }
        guard !steps.isEmpty else { return nil }
        let summary = summaryLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentPlan(status: .proposed, steps: steps, summary: summary)
    }

    private static func fencedPlanBody(in content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var inBlock = false
        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if trimmed.hasPrefix("```") {
                    let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    if info == "plan" { inBlock = true }
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
        while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
        guard i > line.startIndex, i < line.endIndex else { return nil }
        let separator = line[i]
        guard separator == "." || separator == ")" else { return nil }
        let rest = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}
