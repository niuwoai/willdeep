//
//  AgentToolRegistry.swift
//  WillDeep
//
//  Tool catalog + per-call risk classifier, split out of
//  AgentTools.swift in rc42. Two responsibilities:
//   - `static let all`: the descriptor list (name, description, risk
//     tier, parameter schema) the LLM sees as the available tool surface.
//   - `risk(for:arguments:rootDirectory:)`: per-call risk override. The
//     declared risk in `all` is the upper bound; this method downgrades
//     a `run_command` to .read when the classifier proves the shell
//     chain is read-only inside the workspace, or bumps to .danger on
//     destructive patterns. The classifier carries its own shell
//     tokenizer / chain splitter / per-executable allowlist (git
//     subcommands, sed without -i, find without -exec, etc.) — kept
//     private here because it's tightly coupled to the read-only
//     auto-allow decision and has no other consumers.
//

import Foundation

enum AgentToolRegistry {
    static let all: [AgentToolDescriptor] = [
        AgentToolDescriptor(
            name: "search_files",
            description: "Search workspace files for a literal text query and return matching lines with paths and line numbers. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Literal text to search for. Case-insensitive.", required: true),
                AgentToolParameter(name: "max_results", type: .integer, description: "Maximum matches to return. Defaults to 60.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "grep_files",
            description: "Search workspace files with a regular expression (ICU/NSRegularExpression syntax) and return matching lines with paths and line numbers. Prefer this over search_files when you need character classes, anchors, alternation, or backreferences. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "pattern", type: .string, description: "Regular expression pattern (ICU syntax, e.g. `func\\s+\\w+`).", required: true),
                AgentToolParameter(name: "path", type: .string, description: "Optional workspace-relative directory to limit the search to. Empty or omitted means the workspace root.", required: false),
                AgentToolParameter(name: "include", type: .string, description: "Optional filename glob to filter which files are searched (e.g. `*.swift`, `*.{ts,tsx}`). Matches just the filename.", required: false),
                AgentToolParameter(name: "case_sensitive", type: .boolean, description: "Match case-sensitively. Defaults to false.", required: false),
                AgentToolParameter(name: "max_results", type: .integer, description: "Maximum matches to return. Defaults to 60, capped at 200.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "read_file",
            description: "Read a UTF-8 text file inside the workspace. Returns the file content with line numbers.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative path to read.", required: true),
                AgentToolParameter(name: "max_bytes", type: .integer, description: "Maximum bytes to return. Defaults to 64KB.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_directory",
            description: "List the immediate entries of a workspace directory. Returns names and whether each entry is a directory.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative directory path. Empty string means workspace root.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "git_status",
            description: "Return the current git branch and porcelain status for the workspace. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "run_command",
            description: "Run a shell command in the workspace root. This is the DEFAULT way to execute any shell command — including ones that reach other machines (scp / rsync / ssh remote-host), file copies, builds, installs, and tests. Only use terminal_send_command instead when the user explicitly asks for the command to be run in the visible side-panel terminal. Requires user approval. Refuses commands that escape the workspace. Pass `run_in_background: true` for long-running tasks (dev servers, watchers, big builds, test suites that take minutes) — the call returns immediately with a job handle and you receive a system notification when the job finishes; meanwhile inspect partial output with `get_job_output` or stop it with `kill_job`.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Shell command line. Runs through /bin/sh -c.", required: true),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Hard timeout in seconds. Foreground default 20s (max 120). Background default unlimited (max 21600 = 6h).", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "When true, do not block on the command. Returns a job handle (job_xxxxxx); the host injects a system message when the job finishes. Use for tasks expected to take more than ~30 seconds. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_snapshot",
            description: "Read the visible text of the active Agent Terminal side-panel tab (a real terminal the user is watching — local shell by default, or SSH). Read-only; redacts common secrets. Use it to read back what your terminal_send_command produced, or to inspect prompts, banners, and command output.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_characters", type: .integer, description: "Maximum output-tail characters to return. Defaults to 16000, capped at 40000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_send_command",
            description: "Type one command line into the VISIBLE Agent Terminal side-panel tab and press Enter, so the user sees it run live in their own terminal. Use this ONLY when the user EXPLICITLY asks for the command to be run / typed into the side-panel terminal (e.g. \"在侧边栏终端里执行 du\", \"type df into the terminal\", \"run this in the terminal so I can watch it\"). For ALL other command execution — including copying a file to another machine (scp / rsync), SSH-ing to a remote host, builds, installs, tests, and any ordinary shell work — use run_command instead; do NOT route normal commands through the terminal just because they touch another host. Works with the default local shell — no SSH required; if no terminal tab is open yet, WillDeep opens a local shell automatically. Requires user approval. Does not read hidden/password input.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Command line to send, without a trailing newline. WillDeep appends Enter after approval.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_send_control",
            description: "Send a whitelisted control key to the active Agent Terminal side-panel tab. Requires user approval; use ctrl_c to interrupt a foreground command, enter to submit the current line, or escape to cancel terminal UI modes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "control", type: .string, description: "One of: ctrl_c, enter, escape.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "apply_patch",
            description: "Submit a conservative unified diff. CREATING a new file writes it to disk IMMEDIATELY — no review needed (use a creation diff: `--- /dev/null` + `+++ b/path` with a `new file mode` line and a `@@ -0,0 +1,N @@` hunk of all `+` lines; missing parent directories are created). EDITING an existing file shows a patch card INLINE IN THE CHAT, right below your message — there is NO separate right-side review panel — for the user to review and click Apply; in Goal mode or workspace-access approval mode the host applies the edit immediately. Validates the diff shape before queuing.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "diff", type: .string, description: "Unified diff. Use workspace-relative paths (`--- a/path`, `+++ b/path`) and standard @@ hunks. To create a new file, use `--- /dev/null` / `+++ b/path` with a `new file mode` line and a single all-added hunk.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional short title for the patch card. Defaults to Agent Patch.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_jobs",
            description: "List background shell jobs spawned via `run_command` with `run_in_background: true` in this session, including their status and short handles. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "only_alive", type: .boolean, description: "When true, only return jobs whose status is still `running`. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "get_job_output",
            description: "Read the captured stdout/stderr buffer for a background job. Pass the short handle (e.g. `job_ab12cd`) or full UUID. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "job_id", type: .string, description: "Job handle from `list_jobs` or the `run_command` response (e.g. `job_ab12cd`).", required: true),
                AgentToolParameter(name: "tail_lines", type: .integer, description: "Only return the last N lines of output. Omit to return the full buffer.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "kill_job",
            description: "Send SIGTERM (then SIGKILL after 2s) to a background job spawned via `run_command`. Returns immediately; the actual exit notice arrives via the usual completion system message.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "job_id", type: .string, description: "Job handle from `list_jobs` or the `run_command` response (e.g. `job_ab12cd`).", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "list_skills",
            description: "List installed Codex skills from CODEX_HOME so the agent can choose a specialized workflow before acting. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Optional case-insensitive text filter for skill name or description.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "read_skill",
            description: "Read one installed Codex skill's SKILL.md by skill name or identifier. Use after list_skills when a skill matches the task. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "Skill name or identifier returned by list_skills.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "add_memory",
            description: "Save a durable user or project memory when the conversation reveals a preference, rule, recurring fact, or reusable constraint that should influence future turns. Do not store secrets. Requires approval outside autonomous modes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "content", type: .string, description: "The concise memory to save. Prefer one durable fact or rule, not a transcript summary.", required: true),
                AgentToolParameter(name: "scope", type: .string, description: "`global` for user-wide preference, or `project` for workspace-specific conventions. Defaults to global.", required: false),
                AgentToolParameter(name: "lifetime", type: .string, description: "`longTerm` for durable rules or `transient` for short-lived context. Defaults to longTerm.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "create_user_skill",
            description: "Create a local user Codex skill under ~/.willdeep/skills when a reusable workflow has emerged and should be available via @skill/list_skills in future turns. Include when to use it, steps, verification, and safety notes. Requires approval outside autonomous modes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "Short skill name, e.g. `release-guardian` or `ppt-qc-workflow`.", required: true),
                AgentToolParameter(name: "description", type: .string, description: "One sentence describing when the Agent should use this skill.", required: true),
                AgentToolParameter(name: "body", type: .string, description: "Markdown skill instructions. Must avoid secrets and stale outputs.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "update_user_skill",
            description: "Update an existing user-created Codex skill by exact name or identifier. Only user skills under ~/.willdeep/skills or legacy ~/.codex/skills can be changed; bundled and plugin skills are refused. Pass a full replacement body when changing instructions. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "User skill name or identifier returned by list_skills.", required: true),
                AgentToolParameter(name: "description", type: .string, description: "Optional replacement one-sentence description. Omit to preserve the current description.", required: false),
                AgentToolParameter(name: "body", type: .string, description: "Optional replacement Markdown instructions. Omit to preserve the current body.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "delete_user_skill",
            description: "Delete a user-created Codex skill by exact name or identifier. Only user skills under ~/.willdeep/skills or legacy ~/.codex/skills can be deleted; bundled and plugin skills are refused. Destructive and requires typed confirmation.",
            risk: .danger,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "User skill name or identifier returned by list_skills.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "search_mcp_servers",
            description: "Search for MCP server candidates for a missing external capability, include currently configured MCP servers, and return next-step guidance. Use before suggest_mcp_server when the current server/package name is uncertain. Read-only; if web search is not configured it still returns a concrete query and fallback guidance.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "capability", type: .string, description: "The missing capability, e.g. `GitHub PR review threads`, `PostgreSQL readonly queries`, or `Figma assets`.", required: true),
                AgentToolParameter(name: "ecosystem", type: .string, description: "Optional ecosystem hint such as GitHub, Gmail, PostgreSQL, Figma, browser, ERP, or Slack.", required: false),
                AgentToolParameter(name: "count", type: .integer, description: "Number of search results to request, 1-10. Defaults to 5.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, only compose the search query and configured-server summary without contacting web search.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "suggest_mcp_server",
            description: "Record and return an MCP server suggestion when the user needs an external integration that is not currently configured. Use web_search first when a current server name or setup path is uncertain. This does not install anything or add credentials.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "capability", type: .string, description: "The missing capability, e.g. `GitHub PR review threads`, `PostgreSQL readonly queries`, or `Figma assets`.", required: true),
                AgentToolParameter(name: "server_name", type: .string, description: "Candidate MCP server/package name if known.", required: false),
                AgentToolParameter(name: "install_hint", type: .string, description: "Concise setup hint or URL/package reference. Do not include secrets.", required: false),
                AgentToolParameter(name: "reason", type: .string, description: "Why this MCP would help this or future tasks.", required: false),
                AgentToolParameter(name: "search_query", type: .string, description: "The query used or recommended to verify the MCP option.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "configure_mcp_server",
            description: "Add or update user MCP server configuration from pasted JSON. Accepts Cursor/Claude-style `{ \"mcpServers\": { ... } }` or a single server object with `name`/`server_name`; supports stdio `command`/`args`/`env` and streamable-http `url`/`headers`. Sensitive env/header values are stored through WillDeep's credential store. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "json", type: .string, description: "MCP server JSON pasted by the user. Do not invent credentials.", required: true),
                AgentToolParameter(name: "server_name", type: .string, description: "Optional server name to select when json contains several mcpServers, or to name a single-server object.", required: false),
                AgentToolParameter(name: "enabled", type: .boolean, description: "Optional override for whether the server is enabled after saving. Defaults to the JSON value or true.", required: false),
                AgentToolParameter(name: "trust_level", type: .string, description: "Optional trust level: standard, fullyTrusted, or untrusted. Defaults to standard unless JSON provides trust_level.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "web_search",
            description: "Search the web with the configured provider (Auto / Exa / Brave) and return result titles, URLs, snippets, and available metadata. Use for current events, library/API documentation, error messages, or anything not answerable from the workspace. Requires an Exa or Brave Search API key configured in Settings → Agent → Web tools. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Search query. Keep it keyword-style; quote exact phrases.", required: true),
                AgentToolParameter(name: "count", type: .integer, description: "Number of results to return, 1–20. Defaults to 8.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "web_fetch",
            description: "Fetch a public http(s) URL with GET and return its content as readable plain text (HTML is reduced to text; JSON/plain text passes through). Requires user approval; the user can Always-Allow a specific domain. Refuses private, loopback, and link-local hosts, including via redirects. Prefer web_search first when you don't already have an exact URL.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "url", type: .string, description: "Absolute http(s) URL to fetch.", required: true),
                AgentToolParameter(name: "max_chars", type: .integer, description: "Maximum characters of extracted text to return. Defaults to 20000, capped at 100000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "generate_image",
            description: "Generate an image through the configured some.im relay. Use this for image creation requests when Settings -> some.im is configured; it defaults to the user's image model preference, normally gpt-image-2. Returns a local file path in Downloads.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Detailed prompt for the image generator.", required: true),
                AgentToolParameter(name: "size", type: .string, description: "Optional output size such as 1024x1024. Defaults to 1024x1024.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im image model override. Leave empty to use Settings -> some.im priority, default gpt-image-2.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "visual_qa_screenshot",
            description: "Inspect a screenshot or UI image for on-demand visual QA. Use only when the user explicitly asks for screenshot/UI/color/theme/accessibility/layout review, or after a browser screenshot was captured with approval for visual verification. Returns local palette/OCR/theme signals and, by default, may send the image to the configured Image Understanding provider for visual review; pass `allow_vl: false` for local-only inspection. Requires approval because screenshots can contain private information and VL analysis may send image bytes to a provider.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Screenshot/image path. Prefer workspace-relative paths; absolute local paths are allowed for approved screenshots or user-provided images.", required: true),
                AgentToolParameter(name: "context", type: .string, description: "Optional short context such as page, route, expected state, or recent UI change being verified.", required: false),
                AgentToolParameter(name: "focus", type: .string, description: "Optional focus area such as `colors`, `dark-mode`, `layout`, `accessibility`, `regression`, or `general`.", required: false),
                AgentToolParameter(name: "allow_vl", type: .boolean, description: "When true (default), call the configured Image Understanding provider if available. Set false to restrict analysis to local palette/OCR/theme signals.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "chrome_status",
            description: "Check whether the WillDeep Browser Chrome extension native bridge is reachable on localhost and return protocol/version/capability details. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "chrome_read_page",
            description: "Read the active tab in the user's default Chrome profile through the WillDeep Browser extension. Returns URL, title, selected text, capped page text, link summaries, and form summaries. Does not read cookies or hidden form values. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_chars", type: .integer, description: "Maximum page text characters to return. Defaults to 20000, capped at 100000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "chrome_read_selection",
            description: "Read only the current text selection from the active Chrome tab through the WillDeep Browser extension. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "chrome_click",
            description: "Click an element in the active Chrome tab using a CSS selector through the WillDeep Browser extension. Requires approval because it changes browser state.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "selector", type: .string, description: "CSS selector for the element to click, e.g. `button[type=submit]`.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "chrome_type",
            description: "Focus an element in the active Chrome tab and replace its text/value through the WillDeep Browser extension. Requires approval because it can edit web apps.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "selector", type: .string, description: "CSS selector for the input, textarea, editable element, or text-like target.", required: true),
                AgentToolParameter(name: "text", type: .string, description: "Text to put into the target element.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "chrome_capture_tab",
            description: "Capture the visible area of the active Chrome tab through the WillDeep Browser extension and return the screenshot data URL. Requires approval because screenshots may expose private information.",
            risk: .write,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "chrome_debugger_command",
            description: "Run an explicit Chrome DevTools Protocol command against the active tab through chrome.debugger. This is high risk and should only be used when normal page tools are insufficient.",
            risk: .danger,
            parameters: [
                AgentToolParameter(name: "method", type: .string, description: "CDP method name, e.g. `Runtime.evaluate` or `Page.captureScreenshot`.", required: true),
                AgentToolParameter(name: "params_json", type: .string, description: "JSON object string for CDP params. Defaults to `{}`.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_mcp_servers",
            description: "List configured MCP servers from Codex config with sensitive environment values redacted. Does not start servers. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "list_mcp_tools",
            description: "Start a configured MCP server and list its available MCP tools via JSON-RPC. Read-only discovery.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "server", type: .string, description: "MCP server name from list_mcp_servers.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "call_mcp_tool",
            description: "Call a tool on a configured MCP server with JSON arguments. Read-style calls (get_/list_/search_… tool names, or calls an LLM judge certifies as read-only) auto-run on trusted servers; other calls require user approval because MCP tools may perform writes or network actions.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "server", type: .string, description: "MCP server name from list_mcp_servers.", required: true),
                AgentToolParameter(name: "tool", type: .string, description: "MCP tool name from list_mcp_tools.", required: true),
                AgentToolParameter(name: "arguments_json", type: .string, description: "JSON object string to pass as the MCP tool arguments. Defaults to {}.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "lark_cli",
            description: "Run the official Feishu/Lark CLI (`lark-cli`) with structured argument-array input. Use for Feishu/Lark docs, messages, calendar, sheets, Base, mail, tasks, meetings, wiki, and raw OpenAPI access after the connector has been configured. Pass only subcommand arguments, not `lark-cli` itself. Prefer read commands first; use `--dry-run` for write commands when supported. WillDeep classifies read/write/danger operations before execution.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "arguments", type: .stringArray, description: "Arguments after `lark-cli`, e.g. [`auth`, `status`] or [`docs`, `+create`, `--api-version`, `v2`, `--doc-format`, `markdown`, `--content`, `...`]. Do not include shell syntax.", required: true),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Hard timeout in seconds. Defaults to 120, capped at 600.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "claude_code",
            description: "Delegate a complex coding task to the locally installed Claude Code CLI (headless `claude -p`). Unlike spawn_agent, Claude Code CAN edit files, run builds/tests, and work multi-step inside the workspace — use it for self-contained implementation tasks you want done end-to-end. Requires user approval. The prompt must be fully self-contained: Claude Code sees the workspace files but not this conversation. Prefer `permission_mode: \"plan\"` when you only want an implementation plan without any file changes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description. Include relevant file paths, acceptance criteria, and constraints — Claude Code cannot ask follow-up questions in headless mode.", required: true),
                AgentToolParameter(name: "permission_mode", type: .string, description: "One of `plan` (read-only, returns a plan), `acceptEdits` (may create/edit files in the workspace), `default` (permission-needing actions are auto-denied). Defaults to acceptEdits.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional Claude model alias forwarded as `--model` (e.g. `sonnet`, `opus`, `haiku`).", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "Defaults to true: returns a job handle (job_xxxxxx) and the result arrives as a background-task notification; inspect progress with get_job_output. Set false when the caller needs to wait for the final CLI response inline.", required: false),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Optional hard timeout. Local/SSH background default has no hard timeout; delegated foreground default/cap is 21600 seconds.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "codex_cli",
            description: "Delegate a complex coding task to the locally installed Codex CLI (`codex -a never exec`). Codex can inspect and edit the workspace, run commands, and work multi-step; use it for self-contained implementation or review tasks. Requires user approval in WillDeep, then runs headless with Codex's internal approval prompts disabled while keeping Codex sandbox mode enabled. Use `permission_mode: \"plan\"` for a read-only plan. The prompt must be fully self-contained: Codex sees the workspace files but not this conversation.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description. Include relevant file paths, acceptance criteria, and constraints — the delegated Codex CLI session cannot ask follow-up questions here.", required: true),
                AgentToolParameter(name: "permission_mode", type: .string, description: "One of `plan` (read-only), `workspaceWrite` (may edit files inside the workspace), or `default` (alias for workspaceWrite). Defaults to workspaceWrite.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional Codex model id forwarded with `--model`.", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "Defaults to true: returns a job handle (job_xxxxxx) and the result arrives as a background-task notification; inspect progress with get_job_output. Set false when the caller needs to wait for the final CLI response inline.", required: false),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Optional hard timeout. Local/SSH background default has no hard timeout; delegated foreground default/cap is 21600 seconds.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "cursor_agent",
            description: "Delegate a complex coding task to the locally installed Cursor Agent CLI (`cursor agent --print`). Cursor Agent can inspect and edit the workspace, run shell commands, and work multi-step; use it for self-contained implementation tasks. Requires user approval. Use `permission_mode: \"plan\"` or `\"ask\"` for read-only modes. The prompt must be fully self-contained: Cursor Agent sees the workspace files but not this conversation.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description. Include relevant file paths, acceptance criteria, and constraints — the delegated Cursor Agent session cannot ask follow-up questions here.", required: true),
                AgentToolParameter(name: "permission_mode", type: .string, description: "One of `plan` (read-only planning), `ask` (read-only Q&A), or `default` (may edit files in the workspace under Cursor's sandbox). Defaults to default.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional Cursor model id forwarded with `--model`.", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "Defaults to true: returns a job handle (job_xxxxxx) and the result arrives as a background-task notification; inspect progress with get_job_output. Set false when the caller needs to wait for the final CLI response inline.", required: false),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Optional hard timeout. Local/SSH background default has no hard timeout; delegated foreground default/cap is 21600 seconds.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "cline_cli",
            description: "Delegate a complex coding task to the locally installed Cline CLI (`cline`). Cline can inspect and edit the workspace, run shell commands, and work multi-step; use it for self-contained implementation tasks. Requires user approval. Use `permission_mode: \"plan\"` for plan mode. The prompt must be fully self-contained: Cline sees the workspace files but not this conversation.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description. Include relevant file paths, acceptance criteria, and constraints — the delegated Cline CLI session cannot ask follow-up questions here.", required: true),
                AgentToolParameter(name: "permission_mode", type: .string, description: "One of `plan` (Cline plan mode), `act`, or `default` (alias for act). Defaults to act.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional Cline model id forwarded with `--model`.", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "Defaults to true: returns a job handle (job_xxxxxx) and the result arrives as a background-task notification; inspect progress with get_job_output. Set false when the caller needs to wait for the final CLI response inline.", required: false),
                AgentToolParameter(name: "timeout_seconds", type: .integer, description: "Optional hard timeout. Local/SSH background default has no hard timeout; delegated foreground default/cap is 21600 seconds.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "spawn_agent",
            description: "Spawn a read-only subagent to work on a self-contained task (codebase exploration, research, summarizing many files) and return its findings. The subagent runs its own tool loop against the same workspace but can only read — search/grep/read/list plus read-only shell commands; it cannot write files, ask the user, or spawn further agents. Use it to keep large exploration out of your own context. The prompt must be self-contained: the subagent does not see this conversation.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Self-contained task description for the subagent. Include all needed context — it cannot see the parent conversation or ask questions.", required: true),
                AgentToolParameter(name: "label", type: .string, description: "Short display label for the UI (e.g. `explore-auth-flow`). Defaults to a prompt prefix.", required: false),
                AgentToolParameter(name: "run_in_background", type: .boolean, description: "When true, return immediately with an agent handle (agent_xxxxxx); the report is injected as a system message when the subagent finishes. Up to 3 subagents may run in parallel per session. Defaults to false (wait for the report inline).", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model id override for the subagent (same provider). Use a cheaper/faster model for broad exploration.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "ask_user",
            description: "Ask the user a clarifying question and wait for their answer before continuing. Use this whenever a required piece of information is missing or ambiguous; do not guess. Returns the user's answer as the tool result. When the question has a small, well-defined set of valid answers, pass them as `options` so the user can click instead of type.",
            risk: .userInput,
            parameters: [
                AgentToolParameter(name: "question", type: .string, description: "The clarifying question to show the user.", required: true),
                AgentToolParameter(name: "options", type: .stringArray, description: "Optional list of preset answers. When provided, the UI renders them as buttons (single-choice) or checkboxes (multi-choice). The user can still type a free-form answer.", required: false),
                AgentToolParameter(name: "multi_select", type: .boolean, description: "When true, the user can pick multiple options; the tool result is a comma-separated list. Defaults to false (single choice).", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "run_workflow",
            description: "Start one of the built-in workflows (deep-research / code-review / bug-hunt / competitor-analysis / pr-review / release-notes / issue-triage / csv-ask / db-explore / db-schema-doc / transcribe / video-summary / meeting-notes) without making the user type a slash command. Use this when the user's request is clearly served by a workflow (e.g. user says \"review this PR\" → `pr-review`; \"summarize this video\" → `video-summary`; \"how many users signed up last week?\" against an open CSV/DB → `csv-ask` / `db-explore`). The workflow card appears in the transcript and runs in the background; this tool returns immediately with a one-liner so you can keep talking. Pass the same args you'd type after the slash command.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "workflow_name", type: .string, description: "Internal slug, e.g. `deep-research`, `code-review`, `pr-review`, `db-explore`, `video-summary`. NOT the slash command — drop the leading `/`.", required: true),
                AgentToolParameter(name: "args", type: .string, description: "Arguments to pass to the workflow, same shape as what comes after the slash command. For `/research how do mac apps update` pass `\"how do mac apps update\"`. For `/code-review --pr 123` pass `\"--pr 123\"`. Optional for workflows that allow empty args (e.g. /code-review on working tree, /issue-triage). Leave empty string when omitting.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "show_widget",
            description: "Render an interactive HTML/SVG visualization inline in the transcript. Use for dashboards, calculators with sliders/inputs, comparison tables that benefit from a live UI, charts, mockups, or any time a static markdown table or image would lose interactivity. The HTML runs in a strict WKWebView sandbox: NO network requests (connect-src 'none'), NO navigation, NO file access, NO popups. You must inline all styles and scripts — external <script src=...> or <link href=...> are blocked by CSP. CSS variables `--bg`, `--fg`, `--secondary`, `--accent` are pre-set to match the host theme; use `var(--fg)` etc. for colors so light/dark looks right. Returns immediately with a short ack; the rendered card appears in the transcript next turn.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "title", type: .string, description: "Short title shown on the widget card (1-5 words). Also used as the file name when the user exports the widget.", required: true),
                AgentToolParameter(name: "html", type: .string, description: "The full HTML/SVG to render. Inline <style> and <script> are allowed; external `src`/`href` are blocked. Keep under ~200 KB for snappy load.", required: true)
            ]
        )
    ]

    static func descriptor(for name: String) -> AgentToolDescriptor? {
        all.first { $0.name == name }
    }

    /// Classify a `run_command` invocation: bumps to .danger when the command
    /// matches a destructive pattern. Pure read-only shell chains can be
    /// auto-run when every directory hop stays inside the current workspace.
    static func risk(
        for name: String,
        arguments: [String: AgentJSONValue],
        rootDirectory: URL? = nil
    ) -> AgentToolRisk {
        // `glob` isn't an advertised tool, but some models hallucinate it
        // (they've seen `Glob` elsewhere). Treat it as the read-only
        // workspace scan it routes to — never the `.danger` default below,
        // which would pop a bogus "destructive command" confirm for a plain
        // file listing. See AgentFileTools.glob / AgentTools.run.
        if name == "glob" { return .read }
        guard let descriptor = descriptor(for: name) else { return .danger }
        if descriptor.name == "run_command", let command = arguments["command"]?.stringValue() {
            let sandboxDecision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: rootDirectory)
            if sandboxDecision.requiresTypedConfirmation {
                return .danger
            }
            if sandboxDecision.requiresUserApproval {
                return .write
            }
            return .read
        }
        if descriptor.name == "lark_cli" {
            return AgentLarkCLI.risk(arguments: arguments["arguments"]?.stringArrayValue() ?? [])
        }
        return descriptor.risk
    }

    private static let dangerousPatterns: [String] = [
        "rm -rf", "rm -fr", "rm -r ", "sudo ",
        ":(){:|:&};:",
        "git push --force", "git push -f", "git reset --hard",
        "git clean -f", "git checkout -- .",
        "mkfs", "dd if=", "shutdown", "reboot", "halt",
        "chmod -R 777", "chown -R",
        "> /dev/sda", "curl ", "wget "
    ]

    private static func looksDangerous(command: String) -> Bool {
        let lower = command.lowercased()
        return dangerousPatterns.contains { lower.contains($0) }
    }

    /// 1.79.0 plan 自动执行 banner 用。复用 shell 危险词黑名单扫
    /// 整段 plan markdown（步骤描述里可能有 `rm -rf /tmp` 这类的反引
    /// 号片段或自然语言描述）。**会假阳性**（例如 plan 里写"小心
    /// `rm` 时…"也会命中），但 banner 的处理是"只 dim 倒计时、不
    /// 拦截手动确认"，假阳性的代价只是用户多点一下，可以接受。
    static func planTextLooksDestructive(_ text: String) -> Bool {
        looksDangerous(command: text)
    }

    private static func isReadOnlyShellCommand(_ command: String, rootDirectory: URL?) -> Bool {
        guard let segments = splitSimpleShellChain(command), !segments.isEmpty else {
            return false
        }
        let normalizedRoot = rootDirectory?.standardizedFileURL
        var workingDirectory = normalizedRoot

        for segment in segments {
            guard let tokens = shellTokens(from: segment), let executable = tokens.first?.lowercased() else {
                return false
            }
            if executable == "cd" {
                guard let resolved = resolvedSafeCD(tokens, workingDirectory: workingDirectory, rootDirectory: normalizedRoot) else {
                    return false
                }
                workingDirectory = resolved
                continue
            }
            guard isReadOnlyCommand(tokens, workingDirectory: workingDirectory, rootDirectory: normalizedRoot) else {
                return false
            }
        }
        return true
    }

    private static func splitSimpleShellChain(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false
        var index = command.startIndex

        while index < command.endIndex {
            let character = command[index]
            if isEscaped {
                current.append(character)
                isEscaped = false
                index = command.index(after: index)
                continue
            }
            if character == "\\" {
                isEscaped = true
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                }
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }
            if character == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                segments.append(trimmed)
                current = ""
                index = command.index(after: index)
                continue
            }
            if character == "&" {
                let next = command.index(after: index)
                guard next < command.endIndex, command[next] == "&" else { return nil }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                segments.append(trimmed)
                current = ""
                index = command.index(after: next)
                continue
            }
            if "|<>`$(){}".contains(character) {
                return nil
            }
            current.append(character)
            index = command.index(after: index)
        }

        guard activeQuote == nil, !isEscaped else { return nil }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(trimmed)
        }
        return segments
    }

    private static func shellTokens(from command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            if "&;|<>`$(){}".contains(character) {
                return nil
            }
            current.append(character)
        }
        guard activeQuote == nil, !isEscaped else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func resolvedSafeCD(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        guard tokens.count <= 2 else { return nil }
        guard let path = tokens.dropFirst().first else {
            return rootDirectory == nil ? workingDirectory : nil
        }
        return resolvedSafePath(path, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
    }

    private static func isReadOnlyCommand(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> Bool {
        guard let rawExecutable = tokens.first else { return false }
        let executable = URL(fileURLWithPath: rawExecutable).lastPathComponent.lowercased()

        switch executable {
        case "git":
            return isReadOnlyGitCommand(tokens, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "pwd", "ls", "cat", "head", "tail", "wc", "grep", "rg", "tree", "du", "df", "file", "sort", "uniq":
            return !containsUnsafePathToken(tokens.dropFirst(), workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "sed":
            let args = Array(tokens.dropFirst())
            guard !args.contains(where: { $0 == "-i" || $0.hasPrefix("-i.") || $0.hasPrefix("-i") }) else {
                return false
            }
            return !containsUnsafePathToken(args, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        case "find":
            let args = Array(tokens.dropFirst())
            guard !args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }) else {
                return false
            }
            return !containsUnsafePathToken(args, workingDirectory: workingDirectory, rootDirectory: rootDirectory)
        default:
            return false
        }
    }

    private static func isReadOnlyGitCommand(_ tokens: [String], workingDirectory: URL?, rootDirectory: URL?) -> Bool {
        var index = 1
        var commandDirectory = workingDirectory
        while index < tokens.count {
            let token = tokens[index]
            if token == "-C" {
                guard index + 1 < tokens.count,
                      let resolved = resolvedSafePath(
                        tokens[index + 1],
                        workingDirectory: commandDirectory,
                        rootDirectory: rootDirectory
                      ) else {
                    return false
                }
                commandDirectory = resolved
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                return false
            }
            break
        }
        guard index < tokens.count else { return false }

        let subcommand = tokens[index].lowercased()
        let args = Array(tokens.dropFirst(index + 1))
        let readOnlySubcommands: Set<String> = [
            "status", "diff", "log", "show", "rev-parse",
            "ls-files", "grep", "describe", "blame"
        ]
        guard readOnlySubcommands.contains(subcommand) else { return false }

        if subcommand == "diff" {
            guard !args.contains(where: { $0 == "--output" || $0.hasPrefix("--output=") }) else {
                return false
            }
        }

        return !containsUnsafePathToken(args, workingDirectory: commandDirectory, rootDirectory: rootDirectory)
    }

    private static func containsUnsafePathToken<S: Sequence>(
        _ tokens: S,
        workingDirectory: URL?,
        rootDirectory: URL?
    ) -> Bool where S.Element == String {
        tokens.contains { token in
            guard !token.hasPrefix("-"), token != "--" else { return false }
            if rootDirectory != nil {
                return resolvedSafePath(token, workingDirectory: workingDirectory, rootDirectory: rootDirectory) == nil
            }
            return !isSafeRelativePathToken(token)
        }
    }

    private static func resolvedSafePath(_ token: String, workingDirectory: URL?, rootDirectory: URL?) -> URL? {
        guard isSafePathTokenSyntax(token, allowAbsolute: rootDirectory != nil) else {
            return nil
        }

        guard let rootDirectory else {
            guard isSafeRelativePathToken(token) else { return nil }
            return workingDirectory?.appendingPathComponent(token).standardizedFileURL
                ?? URL(fileURLWithPath: token).standardizedFileURL
        }

        let candidate: URL
        if token.hasPrefix("/") {
            candidate = URL(fileURLWithPath: token)
        } else {
            candidate = (workingDirectory ?? rootDirectory).appendingPathComponent(token)
        }
        let standardized = candidate.standardizedFileURL
        return isPath(standardized, inside: rootDirectory) ? standardized : nil
    }

    private static func isSafePathTokenSyntax(_ token: String, allowAbsolute: Bool) -> Bool {
        guard !token.isEmpty,
              !token.hasPrefix("~"),
              token != "-",
              !token.contains("*"),
              !token.contains("?") else {
            return false
        }
        if token.hasPrefix("/") {
            guard allowAbsolute else { return false }
        }
        return token
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != ".."
            }
    }

    private static func isPath(_ url: URL, inside rootDirectory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootDirectory.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func isSafeRelativePathToken(_ token: String) -> Bool {
        guard !token.isEmpty,
              !token.hasPrefix("/"),
              !token.hasPrefix("~"),
              token != "-",
              !token.contains("*"),
              !token.contains("?") else {
            return false
        }
        return token
            .split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != ".."
            }
    }
}
