//
//  AgentContextBuilder.swift
//  WillDeep
//
//  Builds compact project context for first-phase agent chat.
//

import Foundation

enum AgentSystemPromptProfile: String, CaseIterable, Identifiable {
    case compact
    case standard
    case extended

    var id: String { rawValue }

    static func automatic(for configuration: AgentConfiguration) -> AgentSystemPromptProfile {
        automatic(modelID: configuration.model, providerID: configuration.providerID)
    }

    static func automatic(modelID: String, providerID: String) -> AgentSystemPromptProfile {
        let model = modelID.lowercased()
        let provider = providerID.lowercased()

        if containsAny(model, [
            "mini", "nano", "flash-lite", "lite", "haiku", "qwen-turbo",
            "deepseek-v4-flash", "deepseek-chat", "4o-mini", "4.1-mini",
            "4.1-nano", "glm-4-flash"
        ]) {
            return .compact
        }

        if containsAny(model, [
            "claude-opus-4.8", "claude-opus-4.7", "claude-opus-4.6",
            "claude-fable-5", "claude-mythos-5", "gpt-5.5",
            "gpt-5-codex", "gemini-3", "kimi-k2.7-code"
        ]) {
            return .extended
        }

        if provider.contains("claude"), model.contains("opus") {
            return .extended
        }

        return .standard
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

enum AgentContextBuilder {
    private static let maxCurrentFileCharacters = 12_000
    private static let maxSelectionCharacters = 6_000
    private static let maxRulesCharacters = 6_000
    static let stablePrefixVersion = "willdeep-agent-system-v5"

    static func systemPrompt(
        rootDirectory: URL?,
        openedFileURL: URL?,
        fileContent: String,
        selectedText: String,
        language: Language?,
        toolsEnabled: Bool = false,
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart,
        currentPlan: AgentPlan? = nil,
        currentGoal: AgentGoal? = nil,
        activeExperts: Set<AgentExpert> = [],
        globalRules: String? = AgentGlobalRulesStore.loadRules(),
        promptProfile: AgentSystemPromptProfile = .standard
    ) -> String {
        var sections: [String] = []
        sections.append(stableSystemPromptPrefix(toolsEnabled: toolsEnabled, promptProfile: promptProfile))

        if let rules = globalRules?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rules.isEmpty {
            sections.append("""
            Global user instructions:
            These instructions apply to every workspace. Project instructions below are more specific and may add stricter requirements.
            \(rules)
            """)
        }

        if let rootDirectory,
           let rules = projectRules(in: rootDirectory, openedFileURL: openedFileURL) {
            sections.append("""
            Project instructions:
            Deeper AGENTS.md/CLAUDE.md files appear later and override earlier instructions within their directory scope.
            \(rules)
            """)
        }

        sections.append("=== Dynamic Turn Context ===")

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

        // Goal mode: first collect/confirm a goal conversationally, then
        // pin the objective + checklist to every turn and require the
        // agent to self-evaluate at the end of every reply.
        if interactionMode == .goal, currentGoal == nil || currentGoal?.isEmpty == true {
            sections.append("""
            === GOAL MODE — SETUP ===
            The user turned on Goal mode. Do not show them a form. Collect the goal through normal conversation.
            If the latest user request already gives enough information, briefly restate the goal and emit exactly one fenced block tagged `goal`:

            ```goal
            Goal: <one sentence>
            Acceptance:
            - <observable completion item>
            - <observable completion item>
            ```

            If the goal or acceptance criteria are still unclear, ask one concise question instead of guessing. Do not run write-tier tools until the goal is defined.
            """)
        } else if interactionMode == .goal, let goal = currentGoal, !goal.isEmpty {
            var goalBlock = "=== GOAL MODE — ACTIVE ===\n"
            goalBlock += "Write-tier tool calls are auto-approved in this mode — work autonomously toward the goal without pausing to ask permission. Danger-tier commands (mass deletion, force push, privilege escalation) still require the user's typed confirmation, so prefer safer alternatives where possible.\n"
            if !goal.statement.isEmpty {
                goalBlock += "Goal: \(goal.statement)\n"
            }
            if !goal.checklist.isEmpty {
                goalBlock += "Acceptance checklist (current state shown — 1-based indexes):\n"
                for (idx, item) in goal.checklist.enumerated() {
                    goalBlock += "  \(idx + 1). [\(item.done ? "x" : " ")] \(item.text)\n"
                }
                goalBlock += """

                Turn-end self-check (REQUIRED on every Goal-mode assistant reply after the goal is defined):
                Before ending the reply, compare the evidence from this turn against the goal and state one concise "Goal self-check" sentence: `complete`, `in progress`, or `blocked`, with the reason.
                Then emit exactly one fenced block tagged `goal-check`. Each line lists a 1-based item index and its new state — only the items you're changing this turn. If no checklist status changed, emit the block with `# no changes`.

                ```goal-check
                1: done
                3: undone
                ```

                Use `done`/`complete` only when you have concrete evidence the item is satisfied (file edited, command exited 0, tests passed). Use `undone`/`incomplete`/`blocked` to flip a previously-ticked item back if you later discover it isn't actually satisfied. Items you didn't change this turn MUST be omitted. The user can override either direction at any time.
                """
            } else {
                goalBlock += "\nAt the end of every reply, include a concise Goal self-check sentence saying whether the goal is complete, in progress, or blocked, with the reason."
            }
            sections.append(goalBlock)
        }

        if toolsEnabled {
            sections.append("""
            - Current approval mode: \(approvalMode.displayName). \(approvalMode.conciseSystemPromptDescription)
            """)
        }

        if !activeExperts.isEmpty {
            sections.append(
                activeExperts
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    .map(\.systemPromptBlock)
                    .joined(separator: "\n\n")
            )
        }

        if let rootDirectory {
            sections.append("""
            Workspace:
            - Root: \(rootDirectory.path)
            - Name: \(rootDirectory.lastPathComponent)
            """)
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

    static func stableSystemPromptPrefix(
        toolsEnabled: Bool,
        promptProfile: AgentSystemPromptProfile = .standard
    ) -> String {
        var sections: [String] = [
            """
            === Stable WillDeep Agent Contract (\(stablePrefixVersion), \(promptProfile.rawValue)) ===
            You are WillDeep Agent, a concise coding assistant embedded in a native macOS editor.
            Work with the currently opened project directory as the workspace.
            You cannot directly change files from plain chat text. In tool-enabled turns, use create_file to make a NEW file (pass path + full content; it writes immediately), and apply_patch to EDIT an existing file via a unified diff (the edit appears as a patch card inline in the chat for the user to Apply); otherwise provide a unified diff in a ```diff fenced block.
            Only generate diffs for existing files in the workspace, using paths relative to the workspace root.
            Avoid new files, deleted files, binary files, and paths outside the workspace unless the user explicitly asks and the app supports that workflow.
            Keep answers practical and scoped to the visible project context.
            """,
            """
            Tone and response style:
            - Be concise and direct. Default to no more than 4 lines plus any required diff or tool result.
            - Do the work directly; avoid ceremonial preambles and postambles.
            - After producing a diff, stop unless the user asked for explanation.
            - No emojis unless the user asks.
            - Reference code as `path/to/file.swift:42` so the user can jump to it.
            """,
            """
            Coding conventions:
            - Don't add comments unless asked or the code would be hard to understand without a short note.
            - Don't assume a library is available; inspect the project's manifests first.
            - Look at neighboring files before inventing new patterns.
            - Never log, echo, persist, or expose secrets, tokens, credentials, personal data, or .env contents.
            """,
            """
            Project hard rules:
            - Reply in Simplified Chinese.
            - In React code, never hardcode user-visible JSX/TSX strings; use i18n resources.
            - Prefer yarn over npm or pnpm for package operations.
            - After code changes, bump the semantic version and keep frontend/backend versions in sync; for bugfixes only increment the rc number.
            - Do not generate or overwrite files via cat, echo, heredoc, or shell redirection; use the app's edit/write flow.
            - A single source file should stay under 3000 lines; consider splitting after 2000 lines.
            """,
            AppLocale.systemPromptDirective
        ]

        switch promptProfile {
        case .compact:
            sections.append("""
            Compact profile:
            - Prefer the shortest correct path. Use tools to verify facts, then answer tersely.
            - Keep plans implicit unless the user asks or Plan/Goal mode requires a visible plan.
            - Avoid broad refactors and optional explanations.
            """)
        case .standard:
            sections.append("""
            Standard profile:
            - Balance autonomy with concise progress updates.
            - For multi-file work, inspect conventions first, edit narrowly, and verify with the smallest meaningful command.
            """)
        case .extended:
            sections.append("""
            Extended profile for high-capability models:
            - Build a private task model before editing: goal, constraints, affected surfaces, verification evidence, and rollback risks.
            - Explore in parallel when independent reads are useful, then converge on a small implementation plan.
            - Treat repository instructions as scoped law: global rules < root project rules < deeper AGENTS.md/CLAUDE.md < latest user message.
            - For long tasks, keep the user oriented with concise status updates, but do not narrate routine mechanics.
            - Before the final answer, audit explicit requirements against evidence: edited files, command output, version consistency, and any known blocked checks.
            - Do not invent API fields, dependency names, environment values, or external state. Inspect sources or ask one concrete question.
            """)

            if toolsEnabled {
                sections.append("""
                Extended tool capability map:
                - Workspace exploration: search_files, grep_files, read_file, list_directory, git_status.
                - New files: create_file (path + full content) writes a brand-new file to disk immediately. Always use it for creation — never apply_patch.
                - Proposed edits: apply_patch validates a unified diff for an EXISTING file and shows a patch card inline in the chat (below your message) that the user clicks Apply on. Goal mode / workspace-access approval auto-apply edits too.
                - Shell and verification: run_command for build/test/render commands; use run_in_background with list_jobs/get_job_output/kill_job for long tasks.
                - Delegation: spawn_agent for read-only parallel exploration; claude_code/codex_cli/cursor_agent/cline_cli for approved end-to-end delegated coding tasks.
                - External context: web_search/web_fetch for current public information, list_mcp_servers/list_mcp_tools/call_mcp_tool for configured integrations, configure_mcp_server for approved pasted MCP JSON add/update, and lark_cli for configured Feishu/Lark work.
                - Browser and UI QA: chrome_* tools operate the active Chrome tab when configured; visual_qa_screenshot reviews approved screenshots or user-provided UI images.
                - Durable learning/configuration: add_memory, create_user_skill, update_user_skill, delete_user_skill, search_mcp_servers, suggest_mcp_server, and configure_mcp_server are auditable product-visible actions, not hidden thoughts.
                """)
            }
        }

        if toolsEnabled {
            sections.append("""
            Stable tool contract:
            - You can call tools to look around the workspace before answering: search_files, grep_files, read_file, list_directory, git_status, run_command.
            - Treat the visible side-panel terminal as a separate, stateful machine context. Before using terminal_send_command for anything that depends on local-vs-remote location, inspect or rely on terminal_snapshot and keep a session-level note of whether the active terminal tab is a local macOS shell, an SSH session, which host/user it is on, and what directory it shows. If the active terminal is SSH'd into a server, do not send commands that are meant to run locally on the Mac or in the workspace runtime; use run_command instead. If the user explicitly asks to run in the side-panel terminal but the current host is unclear, check terminal_snapshot or ask one concrete confirmation question.
            - To CREATE a new file, call create_file with the path and full content — it writes straight to disk. Do NOT craft a `/dev/null` apply_patch diff for new files. For code EDITS to an existing file, use apply_patch with a conservative unified diff; it shows a patch card inline in the chat for the user to Apply (Goal / workspace-access modes auto-apply). Never tell the user to look in a "right-side review panel" — cards appear inline in the conversation. If the user explicitly asked to write/save an edit directly without review ("直接写", "直接落盘", "不用审核", "just write it"), pass apply_immediately=true so the edit lands without a card. If apply_patch is unavailable or the edit requires unsupported deletion/binary changes, explain that limit and provide the diff or next step instead.
            - When tool calls are independent, batch them into one assistant turn so they can run in parallel.
            - You can discover Codex skills with list_skills and read a selected skill's SKILL.md with read_skill. Use skills when the user's task matches a specialized workflow. With approval, you can create_user_skill, update_user_skill, or delete_user_skill, but only user-created skills may be changed or deleted.
            - Learning checkpoint is REQUIRED before the final answer of any meaningful task. If the turn revealed a durable preference, rule, recurring fact, or project convention, call add_memory. If the turn produced a reusable multi-step workflow, call create_user_skill. If the task exposed a missing external integration, call list_mcp_servers first, then search_mcp_servers and suggest_mcp_server when no configured MCP covers it. These are auditable tool calls, not hidden changes.
            - You can inspect configured MCP servers with list_mcp_servers, inspect a server's tools with list_mcp_tools, and call a configured MCP tool with call_mcp_tool. MCP tool calls may require approval.
            - If the user pastes MCP JSON and asks to add or change it, call configure_mcp_server with the exact pasted JSON. It supports `{ "mcpServers": { ... } }` and single-server objects, stores sensitive env/header values through the existing credential store, and does not delete MCP servers.
            - For Feishu/Lark operations, prefer the dedicated lark_cli tool after the connector is configured. Do not call lark-cli through run_command unless the dedicated tool is unavailable.
            - For DingTalk operations, prefer a configured DingTalk MCP server via call_mcp_tool. Do not invent a dingtalk-cli; if no DingTalk MCP is configured, follow MCP discovery/suggestion first.
            - If a useful MCP is not configured, call search_mcp_servers when needed to verify current package/server candidates, then call suggest_mcp_server and explain the recommendation. Do not claim an MCP is installed unless list_mcp_servers proves it. Do not stop at "I cannot access that service" before this discovery path unless credentials, dangerous setup, or denied approval blocks you.
            - When a command or tool FAILS (non-zero exit code, thrown error, or clearly wrong output), treat it as a step to debug — not a reason to end the turn. Read the exit code and stderr, diagnose the likely cause, and try alternative approaches (fix the command, adjust flags/paths, install a missing dependency, switch tools) to accomplish the user's goal. Make several reasonable attempts before giving up. Stop and report back only when you are genuinely blocked — missing credentials, an unavailable program you cannot install, denied approval, a destructive action that needs the user's decision, or repeated attempts that all failed — and then say what you tried, why it failed, and what you need from the user. Never end the turn with only "the command failed" after a single attempt.
            - Prefer the read-only tools first. They run automatically. Simple read-only run_command calls such as `cd subdir && git diff`, `ls`, `cat`, `rg`, and `grep` can also run automatically after conservative parsing. Other run_command calls may be auto-approved by smart approval when the built-in policy or safety judge classifies them as normal, non-malicious work; destructive commands additionally need typed confirmation.
            - Work end-to-end with tools whenever the workspace makes that possible. If the task requires installing project dependencies, generating files, building, rendering, converting, or testing, run the appropriate command yourself with run_command after gathering context. Do not tell the user to run install/build/test/render commands when run_command can do it.
            - Protected secrets may appear as `${secret:...}` placeholders. Treat them as opaque values: include the placeholder exactly where the command/header/env var needs the secret. Do not ask the user to reveal plaintext, and do not try to transform it yourself; use `${secret:...|urlencode}` or `${secret:...|base64}` when a local transform is needed.
            - Project-local package dependency commands such as `npm install`, `npm ci`, `npm add`, `yarn install`, `yarn add`, `pnpm install`, and `pnpm add` may run in the workspace sandbox with network access when approved by policy. Avoid global installs, publish/release commands, sudo, credential changes, and paths outside the workspace unless the user explicitly asks and approval is granted.
            - For UI development, call visual_qa_screenshot when the user explicitly asks for screenshot, color, theme, layout, accessibility, visual regression, or "看一眼页面" style QA, or after an approved browser screenshot capture when visual verification is needed before finalizing. Do not call it on private/user screenshots unless the user provided the file or approved the screenshot capture. Use `allow_vl=false` when local palette/OCR/theme signals are enough; with `allow_vl=true`, the image may be sent to the configured Image Understanding provider.
            - Verify generated artifacts before your final answer when a practical verification command or file inspection exists. Only ask the user to run a command when you are blocked by missing credentials, an unavailable local program, denied approval, unsupported platform access, or a command that genuinely needs the user's interactive control.
            - For long-running shell work (dev servers, watchers, big test suites, full builds — anything you'd expect to take ≥30s), pass `run_in_background: true` to `run_command`. The call returns immediately with a job handle like `job_ab12cd`; the host will inject a `<background-task-notification>...</background-task-notification>` system message at the start of a later turn when the job finishes. Until then, you can call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop one. Do NOT busy-poll — if you've started a job and the user hasn't asked about it, just answer them; the completion notice will come on its own.
            - When something a user asked for is ambiguous or you're missing a required piece of information, call ask_user with a single concrete question instead of guessing. Do NOT call ask_user for things you can determine by reading files yourself. If the answer is one of a small known set, pass `options` so the user can click; set `multi_select` to true only when more than one option can legitimately apply at once.
            - For learning/configuration actions, store only compact rules or workflows: add_memory for explicit future preferences ("always", "never", "以后", "必须", "默认"), create/update/delete user skills only when the user asks or a genuinely reusable workflow is being maintained, and search_mcp_servers plus suggest_mcp_server/configure_mcp_server for repeat external-system gaps. Do not store secrets or one-off facts.
            - Use workspace-relative paths in tool arguments.
            - After gathering enough context and running the practical verification, stop calling tools and answer the user. For edits queued with apply_patch, summarize the patch card (shown inline in the chat) and verification; otherwise emit a ```diff block.
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    static func cacheDiagnostics(
        for systemPrompt: String,
        toolsEnabled: Bool,
        promptProfile: AgentSystemPromptProfile = .standard
    ) -> (hash: String, stableCharacters: Int) {
        let stable = stableSystemPromptPrefix(toolsEnabled: toolsEnabled, promptProfile: promptProfile)
        let dynamicMarker = "\n\n=== Dynamic Turn Context ==="
        let stableCharacterCount = systemPrompt.range(of: dynamicMarker).map {
            systemPrompt.distance(from: systemPrompt.startIndex, to: $0.lowerBound)
        } ?? stable.count
        let observedStablePrefix = String(systemPrompt.prefix(stableCharacterCount))
        return (stableHash(observedStablePrefix), stableCharacterCount)
    }

    private static func projectRules(in rootDirectory: URL, openedFileURL: URL?) -> String? {
        var collected: [String] = []

        for name in ["README.md", "product-overview.md"] {
            let url = rootDirectory.appendingPathComponent(name)
            appendRuleFile(url, label: name, to: &collected)
        }

        for directory in scopedInstructionDirectories(rootDirectory: rootDirectory, openedFileURL: openedFileURL) {
            for name in ["AGENTS.md", "CLAUDE.md"] {
                let url = directory.appendingPathComponent(name)
                let relative = relativePath(for: url, rootDirectory: rootDirectory)
                appendRuleFile(url, label: relative, to: &collected)
            }
        }

        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "\n\n")
    }

    private static func appendRuleFile(_ url: URL, label: String, to collected: inout [String]) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let excerpt = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: maxRulesCharacters)
        guard !excerpt.isEmpty else { return }
        collected.append("# \(label)\n\(excerpt)")
    }

    private static func scopedInstructionDirectories(rootDirectory: URL, openedFileURL: URL?) -> [URL] {
        let root = rootDirectory.standardizedFileURL
        guard let openedFileURL else { return [root] }

        let active = openedFileURL.standardizedFileURL
        let activePath = active.path
        let rootPath = root.path
        guard activePath == rootPath || activePath.hasPrefix(rootPath + "/") else {
            return [root]
        }

        var directories: [URL] = [root]
        var directory = active.deletingLastPathComponent()
        var stack: [URL] = []
        while directory.path != rootPath, directory.path.hasPrefix(rootPath + "/") {
            stack.append(directory)
            directory.deleteLastPathComponent()
        }
        directories.append(contentsOf: stack.reversed())
        return directories
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

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
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

    fileprivate static func fencedBody(in content: String, tag: String) -> String? {
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
    fileprivate static func leadingNumber(in s: String) -> (Int, String.Index)? {
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

// MARK: - Goal checklist evaluation parser

/// Parses the agent-emitted ```goal fenced block during conversational
/// Goal setup. The block keeps the surface intentionally simple so the
/// model can produce it after asking any needed clarifying questions.
enum AgentGoalParser {
    static func extract(from content: String) -> AgentGoal? {
        guard let body = AgentPlanParser.fencedBody(in: content, tag: "goal") else { return nil }
        var statement = ""
        var items: [String] = []
        var inAcceptance = false

        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("goal:") {
                statement = String(line.dropFirst("goal:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                inAcceptance = false
                continue
            }
            if lower == "acceptance:" || lower == "acceptance criteria:" || lower == "checklist:" {
                inAcceptance = true
                continue
            }
            if inAcceptance, let item = parseChecklistItem(line) {
                items.append(item)
            } else if statement.isEmpty {
                statement = line
            }
        }

        let checklist = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { AgentGoal.Item(text: $0) }
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStatement.isEmpty || !checklist.isEmpty else { return nil }
        return AgentGoal(statement: trimmedStatement, checklist: checklist)
    }

    private static func parseChecklistItem(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("- [ ] ") || text.hasPrefix("- [x] ") || text.hasPrefix("- [X] ") {
            text = String(text.dropFirst(6))
        } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
            text = String(text.dropFirst(2))
        } else if let (_, after) = AgentPlanParser.leadingNumber(in: text) {
            text = String(text[after...])
                .drop { $0 == "." || $0 == ")" || $0 == "-" || $0 == " " || $0 == "\t" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Parses the agent-emitted ```goal-check fenced block and applies its
/// done/undone flips to a goal's checklist. Mirrors AgentPlanParser's
/// progress-block design but uses a boolean lifecycle (the only two
/// states for a checklist item).
enum AgentGoalChecklistParser {
    /// Returns a copy of `goal` with checklist `done` flags updated from
    /// the goal-check block in `content`. Unknown tokens and indexes
    /// out of range are dropped silently — a sloppy reply can't corrupt
    /// the whole checklist. Returns nil when no goal-check block is
    /// present OR when nothing actually changes (so callers can avoid
    /// no-op persistence).
    static func applyEvaluation(to goal: AgentGoal, from content: String) -> AgentGoal? {
        guard let body = AgentPlanParser.fencedBody(in: content, tag: "goal-check") else { return nil }
        var updates: [Int: Bool] = [:]
        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let (index, after) = AgentPlanParser.leadingNumber(in: trimmed),
                  index >= 1, index <= goal.checklist.count else { continue }
            let rest = trimmed[after...]
                .drop { $0 == ":" || $0 == "." || $0 == ")" || $0 == "-" || $0 == " " || $0 == "\t" }
            let token = rest.split(separator: " ", maxSplits: 1).first.map(String.init)?
                .lowercased() ?? ""
            if let flag = parseDoneFlag(token) {
                updates[index - 1] = flag
            }
        }
        guard !updates.isEmpty else { return nil }
        var next = goal
        var changed = false
        for (i, newDone) in updates {
            if next.checklist[i].done != newDone {
                next.checklist[i].done = newDone
                changed = true
            }
        }
        return changed ? next : nil
    }

    private static func parseDoneFlag(_ token: String) -> Bool? {
        switch token {
        case "done", "x", "✓", "✔", "checked", "complete", "completed", "yes", "ok":
            return true
        case "undone", "uncheck", "unchecked", "todo", "pending", "incomplete", "blocked", "no":
            return false
        default:
            return nil
        }
    }
}
