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
            name: "list_workspace_sessions",
            description: "List WillDeep Agent sessions that belong to the CURRENT workspace group, including title, mode, activity time, running/queued state, and whether the title is locked. Read-only. Use this when the user asks what sessions exist in this workspace, or before deciding whether a new user input belongs in the current session or should be renamed.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "include_archived", type: .boolean, description: "When true, include archived sessions in this workspace. Defaults to false.", required: false),
                AgentToolParameter(name: "limit", type: .integer, description: "Maximum sessions to return. Defaults to 20, capped at 100.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "suggest_session_title",
            description: "Use WillDeep's configured title-summary flash model to suggest a concise title for the CURRENT session from the latest conversation context. Read-only. On a new user input, call this when the current session title looks stale or too generic; then call rename_session with the suggestion when appropriate. In normal mode rename_session asks the user to approve; in Goal mode rename_session auto-applies.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "rename_session",
            description: "Propose a concise new title for the CURRENT conversation. Use sparingly: when the user asks for a rename, or when the existing title is clearly misleading after the task's scope changed. Prefer calling suggest_session_title first so the candidate comes from the configured flash title model. Never churn titles for cosmetic reasons. In normal mode this shows the user an approval card; in Goal mode it auto-applies without pausing the goal.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "title", type: .string, description: "Concise single-line conversation title, at most 120 characters.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "change_workspace",
            description: "Propose rebinding the CURRENT conversation to a different local workspace. Use only when the current workspace is missing or wrong and the task clearly targets a known absolute local directory. Always shows the user an approval card. After it succeeds, stop the current turn; workspace/file/command tools may resume after the user's next message with the new context.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Absolute path of an existing local directory.", required: true)
            ]
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
            name: "list_queued_tasks",
            description: "Inspect queued work for the CURRENT WillDeep agent session and workspace: queued user messages, provider-dispatch waits, running background jobs, active media tasks, and project_build_guard build queue entries. Read-only. Before starting expensive compile/test/archive/release/deploy work that the user did not explicitly request, call this tool; if it reports queued user messages or dispatch waits, prefer deferring heavy work and answer concisely.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "include_finished", type: .boolean, description: "When true, include recently finished background jobs and media tasks as context. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_list_shortcuts",
            description: "List saved visible Agent Terminal recording shortcuts and their editable event structure. Read-only. Protected echo-off/password input is never exposed; it is shown only as a protected event with metadata.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "shortcut_id", type: .string, description: "Optional shortcut UUID to inspect. Omit to list all terminal shortcuts.", required: false),
                AgentToolParameter(name: "max_text_characters", type: .integer, description: "Maximum visible text characters per event. Defaults to 400, capped at 4000. Protected input is never returned.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_create_shortcut",
            description: "Create a saved Agent Terminal recording shortcut from a user-described sequence after approval. Use this when the user dictates terminal steps and asks to turn them into a recording. Pass events_json as an array: {\"command\":\"cd app\"} sends the command plus Enter; {\"text\":\"raw visible text with escapes like \\\\n, \\\\t, \\\\e, \\\\b, \\\\x7f\"} sends exact visible input; {\"control\":\"enter|tab|escape|backspace|ctrl_c\"} sends a control key; {\"protected_placeholder\":\"密码 1\"} creates a local password placeholder that WillDeep asks the user to fill in the chat card after creation. Add delay_ms to an event to wait before sending it. Never include plaintext passwords/secrets; password, secret, protected_text, and requires_echo_off fields are rejected.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "title", type: .string, description: "Shortcut title derived from the dictated operation.", required: true),
                AgentToolParameter(name: "events_json", type: .string, description: "JSON array of events. Each event must include command, text, control, or protected_placeholder; optional delay_ms waits before the event.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_edit_shortcut",
            description: "Edit a saved Agent Terminal recording shortcut after user approval. Supports renaming, changing event delays, deleting events, and replacing or setting visible input text. set_visible_text accepts terminal escapes like \\\\n, \\\\t, \\\\e, \\\\b, and \\\\x7f. It cannot read or rewrite protected echo-off/password bytes; protected events can only be preserved or deleted. Pass operations_json as an array like [{\"op\":\"set_delay\",\"event_index\":1,\"delay_ms\":1200},{\"op\":\"replace_visible_text\",\"event_index\":0,\"find\":\"old\",\"replace\":\"new\"}].",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "shortcut_id", type: .string, description: "Shortcut UUID from terminal_list_shortcuts.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional new shortcut title.", required: false),
                AgentToolParameter(name: "operations_json", type: .string, description: "JSON array of edit operations. Supported op values: set_delay, delete_event, replace_visible_text, set_visible_text, delete_visible_text.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_snapshot",
            description: "Read the latest live visible screen of the current conversation's bound Agent Terminal tab, or the exact terminal_tab_id when supplied. Never guesses from the UI's active tab. Returns the tab id, cursor row/column, and exact current cursor line. The screen marks the cursor line with `=>`; lines above it may be prior output from before SSH or directory changes. Local tabs can contain nested manual SSH, so verify host/cwd before machine-specific claims. If no tab is bound to this conversation, the error lists every open side-panel tab: never claim the side panel is closed — confirm the intended tab with the user and retry with terminal_tab_id. Read-only; redacts common secrets.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_characters", type: .integer, description: "Maximum characters from the latest visible screen to return. Defaults to 6000, capped at 12000.", required: false),
                AgentToolParameter(name: "terminal_tab_id", type: .string, description: "Optional exact terminal tab UUID. Omit to use the tab bound to this conversation.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_send_command",
            description: "Type one command line into the VISIBLE Agent Terminal tab bound to this conversation (or the exact terminal_tab_id) and press Enter, so the user sees it run live. Never guesses from the active UI tab. Use this ONLY when the user EXPLICITLY asks for execution in the side-panel terminal. Before sending a machine-specific command, use terminal_snapshot to confirm whether the bound tab is local or SSH and which host/user it shows; never send a local-intended command into an SSH tab. Avoid heredoc, here-string, `cat > file`, `echo > file`, or similar pasted multi-line file writes by default; prefer create_file/edit_file/apply_patch, run_command, or explicit transfer tools. WillDeep supports rz/sz ZMODEM with zmodem_upload_paths and zmodem_download_directory. For all ordinary shell work not explicitly requested in the visible terminal, use run_command. If no tab is bound yet, WillDeep opens a local shell for this conversation. Requires user approval and does not read hidden/password input.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "command", type: .string, description: "Command line to send, without a trailing newline. WillDeep appends Enter after approval.", required: true),
                AgentToolParameter(name: "terminal_tab_id", type: .string, description: "Optional exact terminal tab UUID. Omit to use or create the tab bound to this conversation.", required: false),
                AgentToolParameter(name: "zmodem_upload_paths", type: .stringArray, description: "Optional local files to upload when this command starts remote rz. Relative paths resolve from the workspace root. The ZMODEM bridge uses them once instead of opening the macOS file picker.", required: false),
                AgentToolParameter(name: "zmodem_download_directory", type: .string, description: "Optional local directory for files received when this command starts remote sz. Relative paths resolve from the workspace root. The ZMODEM bridge uses it once instead of opening the macOS folder picker.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "terminal_send_control",
            description: "Send a whitelisted control key to the current conversation's bound Agent Terminal tab, or the exact terminal_tab_id when supplied. Never guesses from the UI's active tab. Requires user approval; use ctrl_c to interrupt a foreground command, enter to submit the current line, or escape to cancel terminal UI modes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "control", type: .string, description: "One of: ctrl_c, enter, escape.", required: true),
                AgentToolParameter(name: "terminal_tab_id", type: .string, description: "Optional exact terminal tab UUID. Omit to use or create the tab bound to this conversation.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "create_file",
            description: "Create a BRAND-NEW file and write it to disk IMMEDIATELY. This is the ONLY correct way to make a new file — do NOT use edit_file or apply_patch for creation. Pass the workspace-relative path and the full file content directly; no diff to hand-craft. Fails if the path already exists (to change an existing file, use edit_file instead). Missing parent directories are created. A file card showing the new file appears inline in the chat for auditability.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative path of the NEW file, e.g. `src/utils/date.ts` or `docs/README.md`. Must not already exist.", required: true),
                AgentToolParameter(name: "content", type: .string, description: "Full contents of the new file, written verbatim. Pass an empty string for an empty file.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional short title for the file card. Defaults to `创建文件: <path>`.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "edit_file",
            description: "EDIT an EXISTING file by EXACT STRING REPLACEMENT — the PREFERRED way to edit files. Pass the workspace-relative path, the exact current text to replace (old_string) and its replacement (new_string). old_string must match the file content EXACTLY — including whitespace and indentation, WITHOUT read_file line-number prefixes — and must appear exactly ONCE in the file unless replace_all=true; include a few surrounding lines to make it unique. The host locates the match and builds the diff itself. If every edited file is already tracked by git and clean against HEAD, the edit writes to disk immediately; otherwise it shows a patch card INLINE IN THE CHAT (below your message; there is NO separate right-side review panel) for the user to review and click Apply. Goal mode or workspace-access approval mode also applies immediately. To CREATE a new file, use `create_file` — NOT this tool.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "path", type: .string, description: "Workspace-relative path of the EXISTING file to edit, e.g. `src/utils/date.ts`.", required: true),
                AgentToolParameter(name: "old_string", type: .string, description: "Exact text currently in the file to replace, copied verbatim — same whitespace/indentation, no line-number prefixes. Must be unique in the file unless replace_all=true.", required: true),
                AgentToolParameter(name: "new_string", type: .string, description: "Replacement text. Pass an empty string to delete old_string. Must differ from old_string.", required: true),
                AgentToolParameter(name: "replace_all", type: .boolean, description: "Replace EVERY occurrence of old_string instead of requiring a unique match (e.g. renaming a symbol). Defaults to false.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional short title for the patch card. Defaults to `编辑文件: <path>`.", required: false),
                AgentToolParameter(name: "apply_immediately", type: .boolean, description: "Set true ONLY when the user explicitly asked to write / save directly without review (e.g. \"直接写\", \"直接落盘\", \"不用审核\", \"just write it\", \"save it directly\"). The edit then writes to disk immediately instead of waiting for the user to click Apply. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "apply_patch",
            description: "LEGACY fallback for editing an EXISTING file via a hand-written unified diff. PREFER `edit_file` (exact string replacement) — hand-crafted diffs frequently fail hunk matching. Use apply_patch only when edit_file cannot express the change (e.g. many scattered edits in one atomic patch). To CREATE a new file, use `create_file` instead — NOT this tool. If every edited file is already tracked by git and clean against HEAD, the edit writes to disk immediately; otherwise it shows a patch card INLINE IN THE CHAT, right below your message — there is NO separate right-side review panel — for the user to review and click Apply. Goal mode or workspace-access approval mode also applies immediately. Validates the diff shape before queuing.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "diff", type: .string, description: "Unified diff for an EXISTING file. Use workspace-relative paths (`--- a/path`, `+++ b/path`) and standard @@ hunks. (New files: use `create_file`, not a `/dev/null` diff here.)", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional short title for the patch card. Defaults to Agent Patch.", required: false),
                AgentToolParameter(name: "apply_immediately", type: .boolean, description: "Set true ONLY when the user explicitly asked to write / save directly without review (e.g. \"直接写\", \"直接落盘\", \"不用审核\", \"just write it\", \"save it directly\"). The edit then writes to disk immediately instead of waiting for the user to click Apply. Defaults to false.", required: false)
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
            description: "Read one installed Codex skill's SKILL.md or a referenced file inside that skill directory. Use after list_skills when a skill matches the task, and follow SKILL.md references with the optional resource path. Read-only; rejects paths outside the selected skill.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "name", type: .string, description: "Skill name or identifier returned by list_skills.", required: true),
                AgentToolParameter(name: "resource", type: .string, description: "Optional skill-relative file such as references/design-to-code.md. Defaults to SKILL.md.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "activate_expert",
            description: "Activate a specialist expert pack for the current Agent session after the user agrees. Use this when a task clearly matches an available expert but it is not active yet, for example web UI work that should use the Web Programming expert.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "expert_id", type: .string, description: "Expert raw id to activate. Supported values include: shortDrama, browserOps, webCoding.", required: true),
                AgentToolParameter(name: "reason", type: .string, description: "Brief user-facing reason for activating this expert.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "add_memory",
            description: "Save a durable user or project memory when the conversation reveals a preference, rule, recurring fact, or reusable constraint that should influence future turns. Do not store secrets. Requires approval outside autonomous modes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "content", type: .string, description: "The concise memory to save. Prefer one durable fact or rule, not a transcript summary.", required: true),
                AgentToolParameter(name: "scope", type: .string, description: "`global` for user-wide preferences, `project` for conventions tied to THIS workspace (repo rules, versioning, test commands — project memories are only recalled inside the same workspace). Omit to let the host infer from the content; prefer passing it explicitly.", required: false),
                AgentToolParameter(name: "lifetime", type: .string, description: "`longTerm` for durable rules or `transient` for short-lived context. Defaults to longTerm.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "create_user_skill",
            description: "Create a local user Codex skill under ~/.willdeep/skills when a reusable workflow has emerged and should be available via $skill/list_skills in future turns. Include when to use it, steps, verification, and safety notes. Requires approval outside autonomous modes.",
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
            description: "Search the web with the configured provider (Auto / Exa / Brave) and return result titles, URLs, snippets, and available metadata. Use for current events, library/API documentation, error messages, or anything not answerable from the workspace. Uses local Exa / Brave keys from Settings → Agent → Web tools first; when both are missing and the user is signed in to some.im, falls back to some.im managed search. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "query", type: .string, description: "Search query. Keep it keyword-style; quote exact phrases.", required: true),
                AgentToolParameter(name: "count", type: .integer, description: "Number of results to return, 1–20. Defaults to 8.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "web_fetch",
            description: "Fetch a public http(s) URL with GET and return its content as readable plain text (HTML is reduced to text; JSON/plain text passes through). Validated public URLs may run automatically while researching a Plan or Goal; normal mode requires user approval and can Always-Allow a specific domain. Refuses private, loopback, and link-local hosts, including via redirects. Prefer web_search first when you don't already have an exact URL.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "url", type: .string, description: "Absolute http(s) URL to fetch.", required: true),
                AgentToolParameter(name: "max_chars", type: .integer, description: "Maximum characters of extracted text to return. Defaults to 20000, capped at 100000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "create_media_task",
            description: "Register a remote AI media task in WillDeep's side-panel task tracker. Use when a skill or provider submits an async some.im/Replicate image/video/short-drama job and the user should see its status. This does not call the provider itself or expose credentials.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "provider", type: .string, description: "Provider: some_im, replicate, skill, local, or unknown.", required: true),
                AgentToolParameter(name: "kind", type: .string, description: "Kind: image_generation, image_edit, image_upscale, image_erase, image_inpaint, video_generation, short_drama, or unknown.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Short user-facing title for the task.", required: true),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional generation/edit prompt or concise task brief.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model or workflow id.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional provider task/prediction id.", required: false),
                AgentToolParameter(name: "status_url", type: .string, description: "Optional provider polling URL.", required: false),
                AgentToolParameter(name: "cancel_url", type: .string, description: "Optional provider cancel URL.", required: false),
                AgentToolParameter(name: "status_endpoint_suffix", type: .string, description: "Optional provider polling endpoint suffix for id-based tasks, e.g. custom/status. Persisted for automatic refresh after restart.", required: false),
                AgentToolParameter(name: "cancel_endpoint_suffix", type: .string, description: "Optional provider cancel endpoint suffix for id-based tasks. Persisted for automatic cancel/refresh workflows.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Optional local source image path for image edit/upscale tasks. Stored for recovery, retry planning, and chat handoff; do not put secrets here.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional local mask image path for erase/inpaint tasks. Stored for recovery, retry planning, and chat handoff.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this media task is intended to resolve. Completion handoff can then suggest short_drama_resolve_review_item.", required: false),
                AgentToolParameter(name: "status", type: .string, description: "Optional initial status: queued, submitted, starting, processing, succeeded, failed, or canceled. Defaults to submitted; defaults to succeeded when artifact_paths are provided.", required: false),
                AgentToolParameter(name: "artifact_paths", type: .stringArray, description: "Optional local output file paths already produced by a skill, Ruby script, or third-party API. When provided, the task is marked succeeded by default and artifacts are routed to any short-drama anchors.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID.", required: false),
                AgentToolParameter(name: "project_path", type: .string, description: "Optional short-drama project path.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode id.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot/storyboard id.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind: character or scene. Completed artifacts append to that asset's reference images.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID to receive completed reference images.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "open_image_editor",
            description: "Open a local image file in WillDeep's right-side image mask editor so the user can draw a rectangle or brush mask and submit Replicate/some.im inpaint or erase tasks. Optional short-drama shot or asset anchors are preserved on submitted media tasks.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "image_path", type: .string, description: "Local image file path to open. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional existing local PNG mask to load as the editor's base layer. Relative paths resolve from the workspace root when available.", required: false),
                AgentToolParameter(name: "operation", type: .string, description: "Preferred edit mode: inpaint/redraw or erase. Defaults to inpaint.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID for result routing.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID for shot result routing.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID for result routing.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind for reference-image routing: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID for reference-image routing.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID carried into submitted edit tasks.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "edit_image_with_mask",
            description: "Submit an image edit task directly from a local image_path and mask_path without opening the UI mask editor. Use when a Skill, Ruby script, or widget has already produced a PNG mask and wants Replicate or some.im to inpaint/redraw or erase immediately. Optional short-drama shot or asset anchors are preserved so completed artifacts route back to the storyboard or reference asset.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "image_path", type: .string, description: "Local source image path. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "mask_path", type: .string, description: "Local mask image path. White mask areas are edited by the provider. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "operation", type: .string, description: "inpaint/redraw or erase. Defaults to inpaint.", required: false),
                AgentToolParameter(name: "provider", type: .string, description: "replicate or some_im. Defaults to replicate.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Edit prompt. Required for inpaint; erase uses a default background reconstruction prompt when omitted.", required: false),
                AgentToolParameter(name: "version", type: .string, description: "Optional Replicate workflow version override. Defaults to Settings -> Integrations -> Replicate inpaint/erase version.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im model override. Defaults to Settings -> some.im preferred image model.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional some.im endpoint suffix. Defaults to images/edits.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional user-facing task title shown in the media task side panel.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID for result routing.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID for shot result routing.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID for result routing.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind for reference-image routing: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID for reference-image routing.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this edit is intended to resolve.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "upscale_image",
            description: "Submit a Replicate image upscale task for a local image path and track it in WillDeep's media task side panel. Optional short-drama shot or asset anchors are preserved so completed artifacts route back to the storyboard or reference asset.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "image_path", type: .string, description: "Local image file path to upscale. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "version", type: .string, description: "Optional Replicate workflow version override. Defaults to Settings -> Integrations -> Replicate image upscale version.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional note stored on the media task. Defaults to the image filename.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID for result routing.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID for shot result routing.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID for result routing.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind for reference-image routing: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID for reference-image routing.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this upscale is intended to resolve.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "show_image_choice_widget",
            description: "Show a set of local image paths as an interactive choice widget in chat and the right-side Web Widget panel. Use when a skill, Ruby script, or media workflow produced several candidate images and the user should pick one before continuing.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "image_paths", type: .stringArray, description: "Local image file paths to display. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional widget title. Defaults to 图片候选选择.", required: false),
                AgentToolParameter(name: "note", type: .string, description: "Optional short note shown under the title.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID copied into every choice action for result routing.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID copied into every choice action for shot result routing.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID copied into every choice action for shot result routing.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind copied into every choice action: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID copied into every choice action for asset reference routing.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID copied into every choice action.", required: false),
                AgentToolParameter(name: "source_label", type: .string, description: "Optional short label for the skill, Ruby script, or media workflow that produced these candidates. Included when the widget is sent back to chat.", required: false),
                AgentToolParameter(name: "source_path", type: .string, description: "Optional local source file or manifest path for the candidate set.", required: false),
                AgentToolParameter(name: "package_directory", type: .string, description: "Optional short-drama production package directory associated with the candidates.", required: false),
                AgentToolParameter(name: "widget_context", type: .string, description: "Optional compact structured context (<=2 KB) that should ride along with candidate widget handoff.", required: false),
                AgentToolParameter(name: "recommended_tool", type: .string, description: "Optional next tool name the agent should consider after the user chooses a candidate.", required: false),
                AgentToolParameter(name: "recommended_arguments", type: .string, description: "Optional concise arguments for recommended_tool.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "generate_video_from_image",
            description: "Submit or prepare an image-to-video task from a local image path. Defaults to Seedance 2.0 via some.im and tracks the task in WillDeep's media task side panel. If video_engine=kling/可灵, return a Kling MCP handoff instead of submitting to some.im.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "image_path", type: .string, description: "Local image file path to use as the video reference/first frame. Relative paths resolve from the workspace root when available.", required: true),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional video motion prompt. Defaults to a concise keyframe-to-video instruction.", required: false),
                AgentToolParameter(name: "video_engine", type: .string, description: "Optional video engine. \(AgentVideoGenerationEngine.allowedValuesDescription())", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional video model override. Defaults to seedance-2.0 for Seedance, or Kling's recommended image-to-video model for video_engine=kling.", required: false),
                AgentToolParameter(name: "duration", type: .string, description: "Optional Kling video duration when video_engine=kling. Defaults to 5.", required: false),
                AgentToolParameter(name: "aspect_ratio", type: .string, description: "Optional Kling aspect ratio when video_engine=kling. Defaults to 16:9.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional user-facing task title shown in the media task side panel.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional some.im endpoint suffix. Defaults to videos/generations.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID for result routing.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID for shot result routing.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID for result routing.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind for reference routing.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID for reference routing.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this video task is intended to resolve.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "import_media_directory",
            description: "Import local image/video files from a directory into WillDeep's media task tracker as a completed local or skill task. Use after Ruby skills or third-party API scripts download outputs to a folder; supports short-drama project, episode, shot, character, and scene anchors.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "directory_path", type: .string, description: "Local directory containing downloaded image/video outputs.", required: true),
                AgentToolParameter(name: "recursive", type: .boolean, description: "When true, scan subdirectories too. Defaults to false.", required: false),
                AgentToolParameter(name: "max_files", type: .integer, description: "Maximum files to import, 1-500. Defaults to 200.", required: false),
                AgentToolParameter(name: "provider", type: .string, description: "Optional provider label: local, skill, replicate, some_im, or unknown. Defaults to local.", required: false),
                AgentToolParameter(name: "kind", type: .string, description: "Optional media kind such as image_generation, image_edit, image_upscale, image_erase, image_inpaint, video_generation, short_drama, or unknown. Inferred from file types when omitted.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional user-facing task title shown in the media task side panel.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional generation/edit prompt or source script brief.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model, workflow, or script name.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional upstream provider task id for traceability.", required: false),
                AgentToolParameter(name: "status_url", type: .string, description: "Optional upstream provider polling URL for traceability.", required: false),
                AgentToolParameter(name: "cancel_url", type: .string, description: "Optional upstream provider cancel URL for traceability.", required: false),
                AgentToolParameter(name: "status_endpoint_suffix", type: .string, description: "Optional upstream provider polling endpoint suffix for id-based tasks, persisted for automatic refresh after restart.", required: false),
                AgentToolParameter(name: "cancel_endpoint_suffix", type: .string, description: "Optional upstream provider cancel endpoint suffix for id-based tasks, persisted for automatic cancel workflows.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Optional local source image path for imported image edit/upscale outputs.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional local mask image path for imported erase/inpaint outputs.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "project_path", type: .string, description: "Optional short-drama project path.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind: character or scene. Completed artifacts append to that asset's reference images.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID to receive completed reference images.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "import_media_manifest",
            description: "Import a JSON manifest produced by Ruby skills or third-party API scripts. Each manifest item points to a local image/video file and may carry short-drama project, episode, shot, character, or scene anchors; WillDeep groups matching anchors into completed media tasks and routes artifacts back to the side panel and short-drama store. When import_pending_tasks is true, missing files that already include remote_task_id or status_url are registered as active media tasks so the side panel can track external async jobs before outputs land.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "manifest_path", type: .string, description: "Local JSON manifest path. Supported top-level arrays: items or artifacts. Each item should include file_path or path. Required unless package_directory is provided.", required: false),
                AgentToolParameter(name: "package_directory", type: .string, description: "Optional short-drama production package directory. When manifest_path is omitted, WillDeep imports media-import-manifest-template.json from this directory.", required: false),
                AgentToolParameter(name: "base_directory", type: .string, description: "Optional base directory for relative file_path/path entries. Defaults to manifest base_directory, then the manifest folder.", required: false),
                AgentToolParameter(name: "max_items", type: .integer, description: "Maximum manifest items to import, 1-1000. Defaults to 500.", required: false),
                AgentToolParameter(name: "skip_missing", type: .boolean, description: "When true, missing files are skipped and reported instead of failing the whole import. Defaults to true so production-package templates can be imported incrementally.", required: false),
                AgentToolParameter(name: "import_pending_tasks", type: .boolean, description: "When true, missing manifest files that include remote_task_id or status_url create active media tasks instead of being skipped. Defaults to false to avoid registering untouched template placeholders.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, validate and group the manifest without creating media tasks or writing back to short-drama projects. Defaults to false.", required: false),
                AgentToolParameter(name: "provider", type: .string, description: "Optional provider override for all items: local, skill, replicate, some_im, or unknown. Defaults to item/provider, manifest/provider, then skill.", required: false),
                AgentToolParameter(name: "kind", type: .string, description: "Optional media kind override for all items, e.g. image_generation, image_edit, image_upscale, image_erase, image_inpaint, video_generation, short_drama, or unknown.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional prompt override when an item and manifest omit prompt.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model/script override when an item and manifest omit model.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional upstream provider task id fallback.", required: false),
                AgentToolParameter(name: "status_url", type: .string, description: "Optional upstream provider polling URL fallback.", required: false),
                AgentToolParameter(name: "cancel_url", type: .string, description: "Optional upstream provider cancel URL fallback.", required: false),
                AgentToolParameter(name: "status_endpoint_suffix", type: .string, description: "Optional upstream provider polling endpoint suffix fallback for id-based tasks. Manifest item value overrides this.", required: false),
                AgentToolParameter(name: "cancel_endpoint_suffix", type: .string, description: "Optional upstream provider cancel endpoint suffix fallback for id-based tasks. Manifest item value overrides this.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Optional local source image path fallback for image edit/upscale items. Manifest item value overrides this.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional local mask image path fallback for erase/inpaint items. Manifest item value overrides this.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional fallback short-drama project UUID.", required: false),
                AgentToolParameter(name: "project_path", type: .string, description: "Optional fallback short-drama project path.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional fallback short-drama episode UUID.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional fallback short-drama shot UUID.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional fallback short-drama asset kind: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional fallback short-drama character/scene UUID.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "update_media_task",
            description: "Update an existing remote AI media task's status, progress, provider ids, and output artifact paths. Use after polling some.im/Replicate or after a short-drama skill writes generated assets.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Task handle from create_media_task/list_media_tasks, e.g. media_ab12cd.", required: true),
                AgentToolParameter(name: "status", type: .string, description: "Optional status: queued, submitted, starting, processing, succeeded, failed, or canceled.", required: false),
                AgentToolParameter(name: "progress", type: .string, description: "Optional 0..1 progress value, e.g. 0.65.", required: false),
                AgentToolParameter(name: "status_message", type: .string, description: "Optional user-facing status/error message.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional provider task/prediction id.", required: false),
                AgentToolParameter(name: "status_url", type: .string, description: "Optional provider polling URL.", required: false),
                AgentToolParameter(name: "cancel_url", type: .string, description: "Optional provider cancel URL.", required: false),
                AgentToolParameter(name: "status_endpoint_suffix", type: .string, description: "Optional provider polling endpoint suffix for id-based tasks. Persisted for automatic refresh after restart.", required: false),
                AgentToolParameter(name: "cancel_endpoint_suffix", type: .string, description: "Optional provider cancel endpoint suffix for id-based tasks.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Optional local source image path for image edit/upscale tasks.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional local mask image path for erase/inpaint tasks.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this task is intended to resolve.", required: false),
                AgentToolParameter(name: "artifact_paths", type: .stringArray, description: "Optional local output file paths produced by the task.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "list_media_tasks",
            description: "List WillDeep remote AI media tasks for the current session, including some.im/Replicate/skill image and video jobs. Read-only.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "only_active", type: .boolean, description: "When true, only return tasks still running or queued. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "replicate_create_prediction",
            description: "Submit a Replicate async prediction for image/video editing workflows such as upscaling, erasing, inpainting, or generation. Registers the prediction in WillDeep's media task side panel and stores output artifacts locally when the prediction has already completed. Requires REPLICATE_API_TOKEN or a Replicate token saved in Keychain.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "version", type: .string, description: "Replicate model version hash required by the Predictions API.", required: true),
                AgentToolParameter(name: "input_json", type: .string, description: "JSON object string for the model input, e.g. {\"image\":\"https://...\",\"prompt\":\"...\"}.", required: true),
                AgentToolParameter(name: "kind", type: .string, description: "Optional media kind: image_upscale, image_erase, image_inpaint, image_edit, image_generation, video_generation, or unknown. Defaults to image_edit.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional user-facing task title shown in the media task side panel.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional display model/workflow name. Defaults to version.", required: false),
                AgentToolParameter(name: "webhook", type: .string, description: "Optional HTTPS webhook URL for Replicate callbacks.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Optional local source image path for image edit/upscale predictions. Stored on the media task for recovery and chat handoff.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional local mask image path for erase/inpaint predictions. Stored on the media task for recovery and chat handoff.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this prediction is intended to resolve.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind: character or scene. Completed artifacts append to that asset's reference images.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID to receive completed reference images.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "replicate_poll_prediction",
            description: "Poll a Replicate prediction by media task handle or prediction id. Updates the media task status and downloads output images/videos to Downloads when the prediction succeeds.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Optional media task handle, e.g. media_ab12cd. Preferred when the prediction was created in this session.", required: false),
                AgentToolParameter(name: "prediction_id", type: .string, description: "Optional Replicate prediction id or full get URL when task_id is not available.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional output title used for downloaded artifacts when polling by prediction_id only.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "replicate_cancel_prediction",
            description: "Cancel a running Replicate prediction by media task handle or prediction id, then update the media task tracker.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Optional media task handle, e.g. media_ab12cd. Preferred when the prediction was created in this session.", required: false),
                AgentToolParameter(name: "prediction_id", type: .string, description: "Optional Replicate prediction id or full cancel/get URL when task_id is not available.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "some_im_create_media_task",
            description: "Submit a some.im async media task and register it in WillDeep's media task side panel. Use for some.im image generation/editing/upscale/erase/inpaint/video workflows when the provider exposes an async or synchronous media endpoint. Defaults to images/async-generations for image generation, images/edits for image edits, and videos/generations for video; pass endpoint_suffix for custom some.im routes.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "kind", type: .string, description: "Optional media kind: image_generation, image_edit, image_upscale, image_erase, image_inpaint, video_generation, short_drama, or unknown. Defaults to image_generation.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Prompt or edit instruction. Required unless input_json is provided.", required: false),
                AgentToolParameter(name: "input_json", type: .string, description: "Optional full JSON object string for the some.im endpoint. If omitted, the tool builds a minimal request from model, prompt, and size.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im media model override. Defaults to Settings -> some.im preferred image/video model.", required: false),
                AgentToolParameter(name: "size", type: .string, description: "Optional image size such as 1024x1024 when not using input_json.", required: false),
                AgentToolParameter(name: "reference_image_path", type: .string, description: "Optional local image path to send as the `image` input, useful for image-to-video or image edit workflows. Relative paths resolve from the workspace root when available.", required: false),
                AgentToolParameter(name: "source_image_path", type: .string, description: "Alias for reference_image_path; persisted on the media task for recovery and chat handoff.", required: false),
                AgentToolParameter(name: "output_directory", type: .string, description: "Optional workspace-relative directory for downloaded output artifacts. Defaults to the workspace root when a workspace is open.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this media task is intended to resolve.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional user-facing task title shown in the media task side panel.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional endpoint suffix under the configured some.im base URL, e.g. images/async-generations, images/generations, videos/generations, or provider-specific async route.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID to receive completed artifacts.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind: character or scene. Completed artifacts append to that asset's reference images.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character/scene UUID to receive completed reference images.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "some_im_poll_media_task",
            description: "Poll a some.im media task by WillDeep media task handle or remote task id/status URL. Updates the media task status and downloads output images/videos to Downloads when the task succeeds. When task_id is used, any persisted status_endpoint_suffix is reused automatically.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Optional WillDeep media task handle, e.g. media_ab12cd. Preferred when the task was created in this session.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional some.im task id or full status URL when task_id is not available.", required: false),
                AgentToolParameter(name: "status_endpoint_suffix", type: .string, description: "Optional polling endpoint suffix when remote_task_id is an id rather than a full URL. Overrides the persisted suffix for this refresh.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Optional output title used for downloaded artifacts when polling by remote_task_id only.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "some_im_cancel_media_task",
            description: "Cancel a running some.im media task by WillDeep media task handle or remote task id/cancel URL, then update the media task tracker. When task_id is used, any persisted cancel_endpoint_suffix or status_endpoint_suffix is reused automatically.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Optional WillDeep media task handle, e.g. media_ab12cd. Preferred when the task was created in this session.", required: false),
                AgentToolParameter(name: "remote_task_id", type: .string, description: "Optional some.im task id or full cancel URL when task_id is not available.", required: false),
                AgentToolParameter(name: "cancel_endpoint_suffix", type: .string, description: "Optional cancel endpoint suffix when remote_task_id is an id rather than a full URL. Overrides the persisted suffix for this cancel request.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_create_project",
            description: "Create a short-drama project in WillDeep's side-panel manager. Use before planning episodes, shots, characters, scenes, or attaching generated media.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "title", type: .string, description: "Project title.", required: true),
                AgentToolParameter(name: "logline", type: .string, description: "Optional one-sentence premise or production brief.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_import_plan",
            description: "Import a complete short-drama plan JSON produced by a skill or Ruby script into WillDeep's side-panel manager. Accepts WillDeep production-package.json, a direct AgentShortDramaProject JSON, or a skill-friendly snake_case plan with project_id/title/logline/characters/scenes/episodes/shots.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "json", type: .string, description: "Inline short-drama plan JSON. Use this or file_path.", required: false),
                AgentToolParameter(name: "file_path", type: .string, description: "Local path to a JSON plan or exported production-package.json. Use this or json.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, parse and summarize the plan without creating or updating any short-drama project. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_export_plan_template",
            description: "Export a skill-friendly short-drama planning JSON template that can be filled by a skill or Ruby script, then imported with short_drama_import_plan or the Short Drama side-panel import button.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "output_path", type: .string, description: "Optional local output path. Defaults to WillDeep Application Support short-drama templates.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upsert_episode",
            description: "Create or update one episode in a short-drama project. Omit project_id to use the active project.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID to update; omit to create.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Episode title.", required: true),
                AgentToolParameter(name: "summary", type: .string, description: "Optional episode synopsis.", required: false),
                AgentToolParameter(name: "order", type: .integer, description: "Optional 1-based episode order.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upsert_character",
            description: "Create or update a reusable character profile for a short-drama project. Omit project_id to use the active project.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "character_id", type: .string, description: "Optional character UUID to update; omit to create.", required: false),
                AgentToolParameter(name: "name", type: .string, description: "Character name.", required: true),
                AgentToolParameter(name: "description", type: .string, description: "Optional story/personality description.", required: false),
                AgentToolParameter(name: "visual_prompt", type: .string, description: "Optional visual consistency prompt for image/video generation.", required: false),
                AgentToolParameter(name: "reference_image_paths", type: .stringArray, description: "Optional local reference image paths.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upsert_scene",
            description: "Create or update a reusable scene/location profile for a short-drama project. Omit project_id to use the active project.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "scene_id", type: .string, description: "Optional scene UUID to update; omit to create.", required: false),
                AgentToolParameter(name: "name", type: .string, description: "Scene or location name.", required: true),
                AgentToolParameter(name: "description", type: .string, description: "Optional scene description.", required: false),
                AgentToolParameter(name: "visual_prompt", type: .string, description: "Optional environment/style prompt for image/video generation.", required: false),
                AgentToolParameter(name: "reference_image_paths", type: .stringArray, description: "Optional local reference image paths.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_attach_asset_reference_image",
            description: "Append one or more local images to an existing short-drama character or scene asset's referenceImagePaths without rewriting the full asset profile. Use when the user chooses a candidate image as a character/scene reference.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "character or scene.", required: true),
                AgentToolParameter(name: "asset_id", type: .string, description: "Character or scene UUID to receive the reference image.", required: true),
                AgentToolParameter(name: "image_path", type: .string, description: "Optional local image path to append. Use this or image_paths.", required: false),
                AgentToolParameter(name: "image_paths", type: .stringArray, description: "Optional local image paths to append. Use this or image_path.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upsert_shot",
            description: "Create or update one storyboard shot under an episode, including prompt, status, character/scene links, and generated artifact paths. Omit project_id to use the active project.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional shot UUID to update; omit to create.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Shot title.", required: true),
                AgentToolParameter(name: "summary", type: .string, description: "Optional narrative beat or action summary.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional generation prompt for image/video tools.", required: false),
                AgentToolParameter(name: "status", type: .string, description: "Optional status: planned, scripting, generating, ready, needs_review.", required: false),
                AgentToolParameter(name: "order", type: .integer, description: "Optional 1-based shot order.", required: false),
                AgentToolParameter(name: "scene_id", type: .string, description: "Optional linked scene UUID.", required: false),
                AgentToolParameter(name: "character_ids", type: .stringArray, description: "Optional linked character UUIDs.", required: false),
                AgentToolParameter(name: "artifact_paths", type: .stringArray, description: "Optional local generated image/video paths for this shot.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_duplicate_shot",
            description: "Duplicate an existing short-drama shot inside the same episode, preserving scene and character anchors while allowing title, summary, prompt, and order overrides. Use this for reaction shots, close-ups, alternate angles, or reshoot variants. Generated artifacts and review items are not copied unless explicitly requested.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the source shot.", required: true),
                AgentToolParameter(name: "source_shot_id", type: .string, description: "Source shot UUID to duplicate. shot_id is also accepted as an alias.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Optional title for the duplicated shot. Defaults to '<source title> 副本'.", required: false),
                AgentToolParameter(name: "summary", type: .string, description: "Optional summary override. Defaults to the source summary.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional prompt override. Defaults to the source prompt.", required: false),
                AgentToolParameter(name: "order", type: .integer, description: "Optional 1-based order for the duplicated shot. Defaults to immediately after the source shot.", required: false),
                AgentToolParameter(name: "copy_artifacts", type: .boolean, description: "When true, copy artifact paths and selected artifact. Defaults to false so the new shot starts clean.", required: false),
                AgentToolParameter(name: "copy_review_items", type: .boolean, description: "When true, copy review items as new open items with fresh ids. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_move_shot",
            description: "Move an existing short-drama shot to another episode while preserving its id, prompt, artifacts, review items, and media task continuity. Use when a skill or editor split a shot into the wrong episode. Linked media tasks for the same project/shot are retargeted to the new episode.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID to move.", required: true),
                AgentToolParameter(name: "target_episode_id", type: .string, description: "Destination episode UUID.", required: true),
                AgentToolParameter(name: "source_episode_id", type: .string, description: "Optional current/source episode UUID. episode_id is also accepted as an alias.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Alias for source_episode_id when moving from a known episode.", required: false),
                AgentToolParameter(name: "order", type: .integer, description: "Optional 1-based order in the target episode. Defaults to the end.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_delete_structure_item",
            description: "Delete one short-drama structure item from the side-panel manager: episode, shot, character, or scene. Use dry_run first when a skill imported the wrong structure. Deleting a character or scene unlinks it from shots; deleting an episode removes its shots. Linked media tasks are reported but not deleted.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "item_type", type: .string, description: "episode, shot, character, or scene.", required: true),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID. Required when item_type is episode; optional context when deleting a shot.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID. Required when item_type is shot.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Character or scene UUID. Required when item_type is character or scene.", required: false),
                AgentToolParameter(name: "character_id", type: .string, description: "Alias for asset_id when deleting a character.", required: false),
                AgentToolParameter(name: "scene_id", type: .string, description: "Alias for asset_id when deleting a scene.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, preview affected shots and linked media task handles without writing changes. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_reorder_structure_items",
            description: "Reorder short-drama episodes in a project or shots inside one episode by passing the desired ordered_ids. Missing existing items are kept after the requested ids and all orders are normalized to 1..N. Use dry_run first when a skill or chat plan wants to reorganize the storyboard.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "item_type", type: .string, description: "episode or shot.", required: true),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID. Required when item_type is shot.", required: false),
                AgentToolParameter(name: "ordered_ids", type: .stringArray, description: "UUIDs in the desired leading order. Existing items omitted here remain after these ids in their current order.", required: true),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, preview current and new order without writing changes. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_generate_shot_media",
            description: "Submit image media, or submit/prepare video media, for an existing short-drama shot and anchor the media task to project_id, episode_id, and shot_id so completed artifacts return to that storyboard shot. Video defaults to Seedance 2.0 via some.im; pass video_engine=kling/可灵 to produce a Kling MCP handoff.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID to generate media for.", required: true),
                AgentToolParameter(name: "kind", type: .string, description: "image_generation or video_generation. Defaults to image_generation.", required: false),
                AgentToolParameter(name: "prompt_override", type: .string, description: "Optional prompt override. Defaults to the shot prompt, then summary, then title.", required: false),
                AgentToolParameter(name: "video_engine", type: .string, description: "Optional video engine for kind=video_generation. \(AgentVideoGenerationEngine.allowedValuesDescription())", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model override. Defaults to Settings -> some.im preferred image model for images, seedance-2.0 for Seedance video, or a recommended Kling video model for video_engine=kling.", required: false),
                AgentToolParameter(name: "duration", type: .string, description: "Optional Kling video duration for kind=video_generation and video_engine=kling. Defaults to 5.", required: false),
                AgentToolParameter(name: "aspect_ratio", type: .string, description: "Optional Kling aspect ratio for kind=video_generation and video_engine=kling. Defaults to 16:9.", required: false),
                AgentToolParameter(name: "size", type: .string, description: "Optional image size such as 1024x1024 for image generation.", required: false),
                AgentToolParameter(name: "use_selected_artifact", type: .boolean, description: "For video generation, whether to use the shot's selected artifact as reference/first-frame image. Defaults to true.", required: false),
                AgentToolParameter(name: "reference_image_path", type: .string, description: "Optional local image path to send as reference/first-frame image for video generation. Overrides selected_artifact_path.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this image or video generation task is intended to resolve.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional some.im endpoint suffix. Defaults to images/async-generations or videos/generations.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, validate the shot, prompt, model, endpoint, and optional video reference image without submitting a provider job. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_generate_batch_media",
            description: "Submit image or video generation tasks for every shot in a short-drama project or episode, in episode/shot order. Video defaults to Seedance 2.0 via some.im; pass video_engine=kling/可灵 to get per-shot Kling MCP handoffs instead of some.im submissions.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. When omitted, all episodes in the project are generated.", required: false),
                AgentToolParameter(name: "shot_ids", type: .stringArray, description: "Optional explicit shot UUIDs. When provided, only those shots are considered inside the project or episode scope.", required: false),
                AgentToolParameter(name: "kind", type: .string, description: "image_generation or video_generation. Defaults to image_generation.", required: false),
                AgentToolParameter(name: "video_engine", type: .string, description: "Optional video engine for kind=video_generation. \(AgentVideoGenerationEngine.allowedValuesDescription())", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional model override. Defaults to Settings -> some.im preferred image model for images, seedance-2.0 for Seedance video, or a recommended Kling video model for video_engine=kling.", required: false),
                AgentToolParameter(name: "duration", type: .string, description: "Optional Kling video duration for kind=video_generation and video_engine=kling. Defaults to 5.", required: false),
                AgentToolParameter(name: "aspect_ratio", type: .string, description: "Optional Kling aspect ratio for kind=video_generation and video_engine=kling. Defaults to 16:9.", required: false),
                AgentToolParameter(name: "size", type: .string, description: "Optional image size such as 1024x1024 for image generation.", required: false),
                AgentToolParameter(name: "use_selected_artifact", type: .boolean, description: "For video generation, whether each shot's selected artifact should be used as reference/first-frame image. Defaults to true.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional some.im endpoint suffix. Defaults to images/async-generations or videos/generations.", required: false),
                AgentToolParameter(name: "target_filter", type: .string, description: "Optional target filter: all or missing. When missing, image_generation only targets shots without a selected main image, and video_generation only targets shots without a video artifact. Defaults to all.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, only list the shots that would be submitted. Defaults to false.", required: false),
                AgentToolParameter(name: "max_shots", type: .integer, description: "Safety cap for how many shots to submit in one batch. Defaults to 200; maximum 200.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_generate_asset_media",
            description: "Submit a some.im image generation task for an existing short-drama character or scene asset, then automatically append completed artifacts to that asset's referenceImagePaths. Use this to generate character portraits, costume references, scene plates, or location mood boards before storyboard generation.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "character or scene.", required: true),
                AgentToolParameter(name: "asset_id", type: .string, description: "Character or scene UUID to generate reference media for.", required: true),
                AgentToolParameter(name: "prompt_override", type: .string, description: "Optional prompt override. Defaults to the asset visual prompt, then description, plus project logline.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im image model override. Defaults to Settings -> some.im preferred image model.", required: false),
                AgentToolParameter(name: "size", type: .string, description: "Optional image size such as 1024x1024. Defaults to 1024x1024.", required: false),
                AgentToolParameter(name: "endpoint_suffix", type: .string, description: "Optional some.im endpoint suffix. Defaults to images/async-generations.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, validate the character/scene asset and show the prompt/model/endpoint without submitting a provider job. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upsert_review_item",
            description: "Create or update one actionable review/fix item on a short-drama storyboard shot, such as continuity issues, prompt fixes, redraw/erase/upscale/reshoot tasks, or production notes. Use after continuity checks so findings are attached to the exact shot instead of only written in chat.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID to attach the review item to.", required: true),
                AgentToolParameter(name: "item_id", type: .string, description: "Optional review item UUID to update; omit to create.", required: false),
                AgentToolParameter(name: "kind", type: .string, description: "continuity, prompt, redraw, erase, upscale, reshoot, or note. Defaults to note.", required: false),
                AgentToolParameter(name: "severity", type: .string, description: "low, medium, or high. Defaults to medium.", required: false),
                AgentToolParameter(name: "status", type: .string, description: "open, doing, or resolved. Defaults to open.", required: false),
                AgentToolParameter(name: "title", type: .string, description: "Short actionable title, e.g. '衣服颜色和上一镜不一致'.", required: true),
                AgentToolParameter(name: "detail", type: .string, description: "Optional evidence or explanation.", required: false),
                AgentToolParameter(name: "suggested_action", type: .string, description: "Optional concrete next action, e.g. redraw selected area, erase logo, upscale chosen keyframe, reshoot with prompt X.", required: false),
                AgentToolParameter(name: "artifact_paths", type: .stringArray, description: "Optional local artifacts this item refers to.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_import_review_csv",
            description: "Import a CSV review sheet back into short-drama shot reviewItems. Use after a skill, Ruby script, spreadsheet, or editor reviews production-shot-list.csv, fills production-review-template.csv, or writes status back to production-review-queue.csv. Rows can add or update actionable columns such as review_item_id, review_title/title/issue, detail/notes, kind, severity, status/review_status, suggested_action, and artifact_paths.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "file_path", type: .string, description: "Optional local CSV file path. Can point to a filled production-review-template.csv, production-review-queue.csv, or another compatible review CSV. Use this or csv.", required: false),
                AgentToolParameter(name: "csv_path", type: .string, description: "Optional alias for file_path.", required: false),
                AgentToolParameter(name: "package_directory", type: .string, description: "Optional short-drama production package directory. When file_path/csv_path/csv is omitted, WillDeep imports production-review-template.csv from this directory; pass file_path when importing the package's production-review-queue.csv after an external repair script updates review_status.", required: false),
                AgentToolParameter(name: "csv", type: .string, description: "Optional inline CSV text. Must include shot_id and a review_title/title/issue column for rows that should create review items; include review_item_id and status/review_status to update or close existing reviewItems.", required: false),
                AgentToolParameter(name: "kind", type: .string, description: "Default review kind when a row omits kind: continuity, prompt, redraw, erase, upscale, reshoot, or note. Defaults to note.", required: false),
                AgentToolParameter(name: "severity", type: .string, description: "Default severity when a row omits severity: low, medium, or high. Defaults to medium.", required: false),
                AgentToolParameter(name: "status", type: .string, description: "Default status when a row omits status: open, doing, or resolved. Defaults to open.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, parse and validate the CSV without writing reviewItems. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_resolve_review_item",
            description: "Mark an existing short-drama review/fix item as resolved after the issue has been handled. Use this instead of rewriting the whole item when closing a continuity, redraw, erase, upscale, reshoot, prompt, or note task.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID that owns the review item.", required: true),
                AgentToolParameter(name: "item_id", type: .string, description: "Review item UUID to mark as resolved. review_item_id is also accepted as an alias.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_update_shot_statuses",
            description: "Batch update short-drama shot statuses for a project, one episode, or explicit shot_ids. Use dry_run before broad changes, for example after importing a plan, before generation, after review, or when marking generated shots ready/needs_review.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. When omitted, all project episodes are eligible.", required: false),
                AgentToolParameter(name: "shot_ids", type: .stringArray, description: "Optional explicit shot UUIDs. When omitted, every shot in the project/episode scope is updated.", required: false),
                AgentToolParameter(name: "status", type: .string, description: "New status: planned, scripting, generating, ready, or needs_review.", required: true),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, preview matching shots without writing changes. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_update_shot_links",
            description: "Batch assign or adjust short-drama shot scene and character links for a project, one episode, or explicit shot_ids. Use dry_run before broad continuity edits, then apply to keep episode shots aligned with selected scenes and recurring characters.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. When omitted, all project episodes are eligible.", required: false),
                AgentToolParameter(name: "shot_ids", type: .stringArray, description: "Optional explicit shot UUIDs. When omitted, every shot in the project/episode scope is updated.", required: false),
                AgentToolParameter(name: "scene_id", type: .string, description: "Optional scene UUID to assign to matched shots. Must refer to an existing scene in the project.", required: false),
                AgentToolParameter(name: "clear_scene", type: .boolean, description: "When true, clear the scene link for matched shots. Do not combine with scene_id.", required: false),
                AgentToolParameter(name: "character_ids", type: .stringArray, description: "Optional character UUIDs to replace or append on matched shots. Every UUID must refer to an existing project character.", required: false),
                AgentToolParameter(name: "append_character_ids", type: .boolean, description: "When true, append character_ids without duplicating existing character links. Defaults to false, which replaces the shot character list.", required: false),
                AgentToolParameter(name: "remove_character_ids", type: .stringArray, description: "Optional character UUIDs to remove from matched shots after replacement or append logic.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, preview matching shots and requested link changes without writing changes. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_select_shot_artifact",
            description: "Select one local generated artifact as the primary/keyframe artifact for an existing short-drama shot. Use when the user chooses one image from several candidates, or before generating video from the preferred keyframe.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID whose primary artifact should be selected.", required: true),
                AgentToolParameter(name: "artifact_path", type: .string, description: "Local artifact path to mark as the selected keyframe/main output for this shot.", required: true),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID carried through the selection result so the agent can keep follow-up media tasks and resolution on the same check item.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_list_projects",
            description: "List short-drama projects and their episode/shot/character/scene counts. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "short_drama_show_storyboard_widget",
            description: "Generate and queue the current short-drama project or a single episode as a sandboxed HTML storyboard widget, so it appears in the chat transcript and right-side Widget panel. Omit project_id to use the active project.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. When provided, the storyboard widget only includes that episode.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_show_image_choice_widget",
            description: "Generate and queue a sandboxed HTML image-choice widget for one short-drama shot. Use after a shot has multiple generated image candidates so the user can visually choose the primary/keyframe artifact from chat or the Widget panel; the widget asks the agent to call short_drama_select_shot_artifact with the selected path.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID whose image candidates should be shown.", required: true),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID copied into the image-choice handoff so follow-up media tasks stay on the same check item.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_open_media_tasks",
            description: "Open the media task side panel scoped to a short-drama project, episode, shot, character, scene, or review item so the user can inspect async some.im / Replicate / skill task status for that storyboard, asset, or fix item.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. Required for scope=episode or scope=shot.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional shot UUID. Required for scope=shot.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional asset kind for scope=asset: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional character or scene UUID for scope=asset.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional review item UUID for scope=review_item.", required: false),
                AgentToolParameter(name: "scope", type: .string, description: "project, episode, shot, asset, character, scene, review_item, or review. Defaults to review_item when review_item_id is present, asset when asset_id is present, shot when shot_id is present, episode when episode_id is present, otherwise project.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_refresh_media_tasks",
            description: "Immediately refresh active Replicate and some.im media tasks scoped to a short-drama project, episode, shot, character, scene, or review item, then open the media task side panel to that same scope.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. Required for scope=episode or scope=shot.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional shot UUID. Required for scope=shot.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional asset kind for scope=asset: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional character or scene UUID for scope=asset.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional review item UUID for scope=review_item.", required: false),
                AgentToolParameter(name: "scope", type: .string, description: "project, episode, shot, asset, character, scene, review_item, or review. Defaults to review_item when review_item_id is present, asset when asset_id is present, shot when shot_id is present, episode when episode_id is present, otherwise project.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_retry_media_task",
            description: "Retry a failed or canceled some.im short-drama media task from its stored project/episode/shot or character/scene anchor, preserving the original kind, prompt, model, and endpoint suffix where available. Use for failed storyboard image/video generations or failed character/scene reference image tasks.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "Media task handle from the side panel or list_media_tasks, e.g. media_ab12cd.", required: true),
                AgentToolParameter(name: "allow_succeeded", type: .boolean, description: "When true, allow submitting another variation even if the original task succeeded. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_retry_failed_media_tasks",
            description: "Retry all retryable failed or canceled some.im short-drama media tasks within a project, episode, shot, character, or scene asset scope. Supports dry_run to preview which tasks would be submitted before spending provider calls.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. Required for scope=episode or scope=shot.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional shot UUID. Required for scope=shot.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional asset kind for scope=asset: character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional character or scene UUID for scope=asset.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional review item UUID for scope=review_item.", required: false),
                AgentToolParameter(name: "scope", type: .string, description: "project, episode, shot, asset, character, scene, review_item, or review. Defaults to review_item when review_item_id is present, asset when asset_id is present, shot when shot_id is present, episode when episode_id is present, otherwise project.", required: false),
                AgentToolParameter(name: "dry_run", type: .boolean, description: "When true, only list retryable failed tasks without submitting new provider jobs. Defaults to false.", required: false),
                AgentToolParameter(name: "max_tasks", type: .integer, description: "Safety cap for retry submissions in one call. Defaults to 20; maximum 50.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_open_image_editor",
            description: "Open a short-drama shot's selected image artifact in the right-side image mask editor, anchored to the same project, episode, and shot. Use when the user wants to redraw/inpaint or erase part of a storyboard keyframe from chat or a storyboard widget.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID whose image should be edited.", required: true),
                AgentToolParameter(name: "operation", type: .string, description: "inpaint/redraw or erase. Defaults to inpaint.", required: false),
                AgentToolParameter(name: "artifact_path", type: .string, description: "Optional local image artifact path. Defaults to the shot's selected artifact, then first image artifact.", required: false),
                AgentToolParameter(name: "image_path", type: .string, description: "Optional backward-compatible alias for artifact_path. Prefer artifact_path in new handoffs.", required: false),
                AgentToolParameter(name: "mask_path", type: .string, description: "Optional existing local PNG mask to reopen as the editor's base layer.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this edit is intended to resolve.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_upscale_shot_artifact",
            description: "Submit a Replicate image upscale task for a short-drama shot's selected image artifact, anchored to the same project, episode, and shot so completed artifacts return to the storyboard.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Episode UUID that owns the shot.", required: true),
                AgentToolParameter(name: "shot_id", type: .string, description: "Shot UUID whose image should be upscaled.", required: true),
                AgentToolParameter(name: "artifact_path", type: .string, description: "Optional local image artifact path. Defaults to the shot's selected artifact, then first image artifact.", required: false),
                AgentToolParameter(name: "image_path", type: .string, description: "Optional backward-compatible alias for artifact_path. Prefer artifact_path in new handoffs.", required: false),
                AgentToolParameter(name: "version", type: .string, description: "Optional Replicate workflow version override. Defaults to Settings -> Integrations -> Replicate image upscale version.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Optional task note/prompt stored on the media task.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID this upscale is intended to resolve.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "short_drama_export_production_package",
            description: "Export the current short-drama project, or one episode, as a local production package with production-package.json and production-package.md. Use before handing a storyboard to skills, external scripts, or review workflows that need stable file paths for shots, selected artifacts, assets, and open review items.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "project_id", type: .string, description: "Optional project UUID. Defaults to the active short-drama project.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional episode UUID. Omit to export the full project.", required: false),
                AgentToolParameter(name: "include_resolved_review_items", type: .boolean, description: "Whether to include resolved review items. Defaults to false so the package focuses on remaining production work.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "generate_image",
            description: "Submit an async image generation task through the configured some.im relay. Use this for image creation requests when Settings -> some.im is configured; it defaults to the user's image model preference, normally gpt-image-2. The task appears in WillDeep's media task side panel and downloaded results are rendered when the async task finishes.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "Detailed prompt for the image generator.", required: true),
                AgentToolParameter(name: "size", type: .string, description: "Optional output size such as 1024x1024. Defaults to 1024x1024.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im image model override. Leave empty to use Settings -> some.im priority, default gpt-image-2.", required: false),
                AgentToolParameter(name: "output_directory", type: .string, description: "Optional workspace-relative subdirectory for the generated image. Defaults to the workspace root.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "edit_generated_image",
            description: "Edit a previously generated local image through some.im `gpt-image-2` by sending the workspace image path as the reference image. Use when the user right-clicks/quotes a generated image marker like <generated-image-reference ... /> and asks to modify that image. Do not ask the user to upload the image again; pass image_path from the marker path (or pass the whole marker as reference_marker). Saves outputs in the workspace root by default.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "image_path", type: .string, description: "Workspace-local image path from the generated-image reference marker. Relative paths resolve from the workspace root.", required: false),
                AgentToolParameter(name: "reference_marker", type: .string, description: "Optional full <generated-image-reference ... /> marker; used to recover image_path when image_path is omitted.", required: false),
                AgentToolParameter(name: "prompt", type: .string, description: "Edit instruction describing how to modify the referenced image.", required: true),
                AgentToolParameter(name: "size", type: .string, description: "Optional output size such as 1024x1024.", required: false),
                AgentToolParameter(name: "model", type: .string, description: "Optional some.im image edit model override. Defaults to gpt-image-2.", required: false),
                AgentToolParameter(name: "output_directory", type: .string, description: "Optional workspace-relative subdirectory for edited outputs. Defaults to the workspace root.", required: false)
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
            name: "capture_screenshot",
            description: "Capture a screenshot and hand the pixels back to you for visual analysis. Targets: `mac_screen` (this Mac's display), `android` (a connected device/emulator via adb), or `ios_simulator` (a booted simulator via simctl). The image is attached to the tool result so vision-capable models see it directly; the payload also carries the saved full-resolution path and local OCR text so text-only models can follow up with `visual_qa_screenshot`. Use for UI verification after a change, inspecting app/device state, or when the user asks what something looks like. Requires approval because screenshots can contain private information.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "target", type: .string, description: "What to capture: `mac_screen` (default), `android`, or `ios_simulator`.", required: false),
                AgentToolParameter(name: "device", type: .string, description: "Optional device selector: adb serial for Android (from `adb devices`), or simulator UDID for iOS (defaults to the booted simulator).", required: false),
                AgentToolParameter(name: "display", type: .integer, description: "Optional 1-based display index for `mac_screen` when multiple monitors are attached.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_permissions",
            description: "Read the separate WillDeep Computer Use helper's Accessibility and Screen & System Audio Recording permission status. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "computer_use_request_permissions",
            description: "Open macOS permission prompts for the separate WillDeep Computer Use helper. Ask only after the user has explicitly approved enabling desktop control. It may request Accessibility for app controls and Screen & System Audio Recording for visual state screenshots.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "accessibility", type: .boolean, description: "Request Accessibility permission. Defaults to true.", required: false),
                AgentToolParameter(name: "screen_capture", type: .boolean, description: "Request Screen & System Audio Recording permission. Defaults to true.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_list_apps",
            description: "List running macOS applications visible to the separate WillDeep Computer Use helper. Read-only.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "computer_use_launch_app",
            description: "Launch one macOS app in the background through the separate WillDeep Computer Use helper. It does not activate the app or steal focus. Requires approval.",
            risk: .write,
            parameters: [AgentToolParameter(name: "app", type: .string, description: "Application bundle identifier, for example `com.apple.Notes`.", required: true)]
        ),
        AgentToolDescriptor(
            name: "computer_use_get_app_state",
            description: "Read a macOS app's Accessibility tree and capture only its visible front window. Returns fresh element refs plus a screenshot. Requires approval because the screenshot may contain private information. Always call this before desktop actions and refresh after every action.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "app", type: .string, description: "Running application bundle identifier or localized app name. Omit only when pid is provided.", required: false),
                AgentToolParameter(name: "pid", type: .integer, description: "Running application process ID. Omit only when app is provided.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_click",
            description: "Click a fresh Accessibility element ref, or click coordinates in the most recent target-window screenshot. Requires approval. Use element refs first; use pixels only when the app exposes no usable Accessibility tree.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "ref", type: .string, description: "Fresh element ref from computer_use_get_app_state. Omit for pixel fallback.", required: false),
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID; optional when ref is supplied.", required: false),
                AgentToolParameter(name: "x", type: .integer, description: "Screenshot-relative x coordinate for pixel fallback.", required: false),
                AgentToolParameter(name: "y", type: .integer, description: "Screenshot-relative y coordinate for pixel fallback.", required: false),
                AgentToolParameter(name: "click_count", type: .integer, description: "1, 2, or 3. Defaults to 1.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_secondary_action",
            description: "Open an element's context menu with Accessibility, falling back to a right-click at screenshot coordinates. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "ref", type: .string, description: "Fresh element ref; omit for pixel fallback.", required: false),
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID; optional when ref is supplied.", required: false),
                AgentToolParameter(name: "x", type: .integer, description: "Screenshot-relative x coordinate for pixel fallback.", required: false),
                AgentToolParameter(name: "y", type: .integer, description: "Screenshot-relative y coordinate for pixel fallback.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_scroll",
            description: "Scroll the target macOS app after a fresh state snapshot. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID.", required: true),
                AgentToolParameter(name: "direction", type: .string, description: "up, down, left, or right.", required: true),
                AgentToolParameter(name: "pages", type: .integer, description: "1 through 8 pages; defaults to 1.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_drag",
            description: "Drag from one screenshot-relative coordinate to another in the target macOS app. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID.", required: true),
                AgentToolParameter(name: "from_x", type: .integer, description: "Screenshot-relative starting x coordinate.", required: true),
                AgentToolParameter(name: "from_y", type: .integer, description: "Screenshot-relative starting y coordinate.", required: true),
                AgentToolParameter(name: "to_x", type: .integer, description: "Screenshot-relative ending x coordinate.", required: true),
                AgentToolParameter(name: "to_y", type: .integer, description: "Screenshot-relative ending y coordinate.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_type_text",
            description: "Type text into the target macOS app. Requires approval because it can change external app state. Never use for passwords, API keys, one-time codes, or other sensitive data.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID.", required: true),
                AgentToolParameter(name: "text", type: .string, description: "Non-sensitive text to type.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_press_key",
            description: "Send a keyboard key or modifier combination such as `cmd+s`, `tab`, or `return` to the target macOS app. Requires approval.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "pid", type: .integer, description: "Target process ID.", required: true),
                AgentToolParameter(name: "key", type: .string, description: "Key or combination such as cmd+s, ctrl+shift+t, tab, return, escape, or left.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_set_value",
            description: "Set a value through a fresh Accessibility element ref, for example a text field or slider. Requires approval and should not be used for secrets.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "ref", type: .string, description: "Fresh editable element ref.", required: true),
                AgentToolParameter(name: "value", type: .string, description: "Non-sensitive value to set.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "computer_use_restart_helper",
            description: "Restart only the separate WillDeep Computer Use helper and then report its permissions. Use after the user changes macOS permissions; WillDeep itself does not need a restart.",
            risk: .write,
            parameters: []
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
            name: "embedded_browser_status",
            description: "Inspect the visible in-app Embedded Browser side panel state: current URL, title, loading state, navigation availability, last error, and latest screenshot path. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: []
        ),
        AgentToolDescriptor(
            name: "embedded_browser_navigate",
            description: "Navigate the visible in-app Embedded Browser side panel to a URL or domain. Requires approval because it loads external web content. Requires the Browser Ops expert and an open Embedded Browser side panel.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "url", type: .string, description: "Absolute URL or bare domain to open, e.g. `https://example.com` or `example.com`.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_read_page",
            description: "Read the current page in the visible in-app Embedded Browser side panel. Returns title, URL, readable text, link summaries, and basic form element summaries. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_chars", type: .integer, description: "Maximum readable text characters to return. Defaults to 20000, capped at 100000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_snapshot",
            description: "Snapshot visible interactive elements in the in-app Embedded Browser side panel. Returns refs, generated CSS selectors, stable selector guesses, text, roles, editability, clickability, and bounds. Use before clicking or typing so selectors are grounded in the current DOM. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_elements", type: .integer, description: "Maximum interactive elements to return. Defaults to 100, capped at 300.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_click",
            description: "Click an element in the visible in-app Embedded Browser side panel using a CSS selector. Requires approval because it changes browser/page state. Requires the Browser Ops expert.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "selector", type: .string, description: "CSS selector for the element to click, e.g. `button[type=submit]`.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_type",
            description: "Focus an element in the visible in-app Embedded Browser side panel and replace its text/value using a CSS selector. Requires approval because it can edit web apps. Requires the Browser Ops expert.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "selector", type: .string, description: "CSS selector for the input, textarea, editable element, or text-like target.", required: true),
                AgentToolParameter(name: "text", type: .string, description: "Text to put into the target element.", required: true)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_wait_for",
            description: "Wait until the in-app Embedded Browser side panel matches a condition, polling the current page without blocking the UI. Use after navigation, click, or form submit. Supports condition values: selector, text, url_contains, title_contains. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "condition", type: .string, description: "One of: selector, text, url_contains, title_contains.", required: true),
                AgentToolParameter(name: "value", type: .string, description: "Selector/text/URL fragment/title fragment to wait for.", required: true),
                AgentToolParameter(name: "timeout_ms", type: .integer, description: "Timeout in milliseconds. Defaults to 5000, capped at 30000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_eval",
            description: "Run explicit JavaScript in the in-app Embedded Browser page context and return a JSON/stringified result. This can inspect or mutate web apps, so prefer embedded_browser_snapshot/read_page/console/network first. Requires approval and the Browser Ops expert.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "javascript", type: .string, description: "JavaScript body to execute inside an async function. Return a JSON-serializable value when possible.", required: true),
                AgentToolParameter(name: "max_chars", type: .integer, description: "Maximum result characters to return. Defaults to 20000, capped at 100000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_console",
            description: "Read captured console/debug/info/warn/error messages plus window error and unhandled promise rejection events from the in-app Embedded Browser side panel. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum console events to return. Defaults to 100, capped at 300.", required: false),
                AgentToolParameter(name: "levels", type: .stringArray, description: "Optional levels to include, such as debug, log, info, warn, error.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_network",
            description: "Read Performance Resource Timing data from the in-app Embedded Browser page: resource URLs, initiator types, protocol, transfer/encoded/decoded bytes, duration, DNS/connect/request/download timings, and estimated bytes per second. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum resource timing entries to return. Defaults to 150, capped at 500.", required: false),
                AgentToolParameter(name: "include_data_urls", type: .boolean, description: "Include data: URLs. Defaults to false.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_requests",
            description: "Read captured fetch/XMLHttpRequest AJAX/API calls from the in-app Embedded Browser side panel, including method, URL, status, timing, redacted request headers, and redacted response headers. Use this for API inspection that Resource Timing cannot expose. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum captured requests to return. Defaults to 100, capped at 500.", required: false),
                AgentToolParameter(name: "include_headers", type: .boolean, description: "Include redacted request/response header values. Defaults to true; sensitive headers such as cookies, auth, tokens, secrets, and API keys are always redacted.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_export_har",
            description: "Export a HAR 1.2 JSON file for the in-app Embedded Browser side panel. Captured fetch/XHR entries include redacted request and response headers; optional Resource Timing entries include timings and sizes but not headers because WebKit does not expose them. Read-only file export. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum captured request/resource entries per source. Defaults to 500, capped at 1000.", required: false),
                AgentToolParameter(name: "include_resource_timings", type: .boolean, description: "Include Resource Timing entries in addition to captured fetch/XHR entries. Defaults to true.", required: false),
                AgentToolParameter(name: "include_har_json", type: .boolean, description: "Also return the HAR JSON inline. Defaults to false because HAR can be large.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_storage",
            description: "Inspect same-origin cookies, localStorage, sessionStorage, and IndexedDB database names for the in-app Embedded Browser page. Values are omitted by default; when values are requested, sensitive-looking names are redacted and values are truncated. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "include_values", type: .boolean, description: "Include non-sensitive truncated storage/cookie values. Defaults to false.", required: false),
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum entries per storage type. Defaults to 100, capped at 500.", required: false),
                AgentToolParameter(name: "max_value_chars", type: .integer, description: "Maximum characters for each included value. Defaults to 500, capped at 2000.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_performance",
            description: "Read page performance diagnostics from the in-app Embedded Browser: navigation timing, paint entries, captured Web Vitals where supported, long tasks, memory where available, and resource summaries by initiator, slowest, and largest resources. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum resource entries used for summaries. Defaults to 150, capped at 500.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_failed_resources",
            description: "Aggregate failed browser resources for the in-app Embedded Browser: DOM resource load errors, failed or non-2xx/non-3xx fetch/XHR calls, and Resource Timing entries with HTTP status >= 400 when WebKit exposes responseStatus. Read-only. Requires the Browser Ops expert.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "max_entries", type: .integer, description: "Maximum failures per bucket. Defaults to 100, capped at 500.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "embedded_browser_capture_screenshot",
            description: "Capture the visible in-app Embedded Browser side panel as a PNG and return the local file path. Requires approval because screenshots may expose private information. Requires the Browser Ops expert.",
            risk: .write,
            parameters: []
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
            name: "schedule_task",
            description: "Schedule a recurring task that runs on its own later, in a fresh background session, and shows an inline card in this transcript. Use when the user asks for something to happen repeatedly or to be watched over time (\"每30分钟看一下\", \"每天早上汇总\", \"盯着 X 直到 Y\"). Provide `prompt` (what each run should do). Give a schedule via either `interval_minutes` OR `daily_at` (HH:MM). Optionally give a `goal`: when set, each run is told to check whether the goal is met and, if so, call `complete_scheduled_task` to remove itself — so a watch task disappears once it's done. Returns a task_id; the card lets the user open the task's detail. This does NOT run anything now — use run_command / a workflow for immediate work.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "prompt", type: .string, description: "The instruction each scheduled run executes (as the first user message of a fresh session). Make it self-contained.", required: true),
                AgentToolParameter(name: "title", type: .string, description: "Short display name for the task card / sidebar. Optional; defaults to the goal or prompt.", required: false),
                AgentToolParameter(name: "goal", type: .string, description: "Optional natural-language completion goal, e.g. \"CI on main is green\". When set, each run evaluates it and calls complete_scheduled_task if met (self-completing watch task).", required: false),
                AgentToolParameter(name: "interval_minutes", type: .string, description: "Run every N minutes (as a number string, e.g. \"30\"). Mutually exclusive with daily_at.", required: false),
                AgentToolParameter(name: "daily_at", type: .string, description: "Run every day at HH:MM 24h local time, e.g. \"09:00\". Mutually exclusive with interval_minutes.", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "complete_scheduled_task",
            description: "Remove a scheduled task by id, so it stops running and its card/sidebar entry disappears. The primary use is self-completion: when a scheduled run (see schedule_task with a goal) determines its goal is met, it calls this with its own task_id. Also usable to cancel a task the user no longer wants.",
            risk: .write,
            parameters: [
                AgentToolParameter(name: "task_id", type: .string, description: "The scheduled task's id (UUID) returned by schedule_task or provided in the run's context.", required: true),
                AgentToolParameter(name: "reason", type: .string, description: "Optional short reason (e.g. \"goal met: CI is green\").", required: false)
            ]
        ),
        AgentToolDescriptor(
            name: "show_widget",
            description: "Render an interactive HTML/SVG visualization inline in the transcript and the right-side Widget panel. Use for dashboards, calculators with sliders/inputs, comparison tables that benefit from a live UI, charts, mockups, short-drama storyboards, or HTML pages generated by a skill/Ruby script. Pass either `html` for inline markup or `html_path` for a UTF-8 .html/.htm/.svg file inside the current workspace or WillDeep's short-drama export package directory. The HTML runs in a strict WKWebView sandbox: NO network requests (connect-src 'none'), NO navigation, NO file access, NO popups. You must inline all styles and scripts — external <script src=...> or <link href=...> are blocked by CSP. CSS variables `--bg`, `--fg`, `--secondary`, `--accent` are pre-set to match the host theme; use `var(--fg)` etc. for colors so light/dark looks right. Widget JavaScript may call `sendPrompt(text)` for natural-language chat handoff or `sendToolAction({tool, arguments, note, action_key})` for structured tool handoff; widgets never execute tools directly. Returns immediately with a short ack; the rendered card appears in the transcript next turn.",
            risk: .read,
            parameters: [
                AgentToolParameter(name: "title", type: .string, description: "Short title shown on the widget card (1-5 words). Also used as the file name when the user exports the widget.", required: true),
                AgentToolParameter(name: "html", type: .string, description: "Optional full HTML/SVG to render. Inline <style> and <script> are allowed; external `src`/`href` are blocked. Keep under ~200 KB for snappy load. Required when html_path is omitted.", required: false),
                AgentToolParameter(name: "html_path", type: .string, description: "Optional workspace-relative path, workspace-contained absolute path, or WillDeep short-drama export package path to a UTF-8 .html/.htm/.svg file generated by a skill or script. Required when html is omitted.", required: false),
                AgentToolParameter(name: "source_label", type: .string, description: "Optional short label for the skill, Ruby script, or workflow that generated the widget. Included when the widget is sent back to chat.", required: false),
                AgentToolParameter(name: "source_path", type: .string, description: "Optional local source file path for the generated widget or manifest. Included in widget follow-up context.", required: false),
                AgentToolParameter(name: "package_directory", type: .string, description: "Optional short-drama production package directory associated with this widget.", required: false),
                AgentToolParameter(name: "widget_context", type: .string, description: "Optional compact structured context (<=2 KB) that should ride along with sendPrompt() and side-panel chat handoff.", required: false),
                AgentToolParameter(name: "recommended_tool", type: .string, description: "Optional next tool name the agent should consider when the user interacts with the widget.", required: false),
                AgentToolParameter(name: "recommended_arguments", type: .string, description: "Optional comma-separated or natural-language arguments for recommended_tool. Keep concise.", required: false),
                AgentToolParameter(name: "project_id", type: .string, description: "Optional short-drama project UUID anchor for this widget.", required: false),
                AgentToolParameter(name: "episode_id", type: .string, description: "Optional short-drama episode UUID anchor for this widget.", required: false),
                AgentToolParameter(name: "shot_id", type: .string, description: "Optional short-drama shot UUID anchor for this widget.", required: false),
                AgentToolParameter(name: "asset_kind", type: .string, description: "Optional short-drama asset kind anchor, such as character or scene.", required: false),
                AgentToolParameter(name: "asset_id", type: .string, description: "Optional short-drama character or scene UUID anchor for this widget.", required: false),
                AgentToolParameter(name: "review_item_id", type: .string, description: "Optional short-drama review/fix item UUID anchor for this widget.", required: false)
            ]
        )
    ]

    static func tools(
        activeExperts: Set<AgentExpert>,
        interactionMode: AgentInteractionMode = .normal
    ) -> [AgentToolDescriptor] {
        all.filter { descriptor in
            if interactionMode == .goal, descriptor.name == "change_workspace" {
                return false
            }
            if descriptor.name.hasPrefix("short_drama_") {
                return activeExperts.contains(.shortDrama)
            }
            if descriptor.name.hasPrefix("embedded_browser_") || descriptor.name.hasPrefix("chrome_") {
                return activeExperts.contains(.browserOps) || activeExperts.contains(.webCoding)
            }
            return true
        }
    }

    static func isSessionMutationTool(_ name: String) -> Bool {
        name == "rename_session" || name == "change_workspace"
    }

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
