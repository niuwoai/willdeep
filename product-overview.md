# VeilWriter Product Overview

> Last updated: 2026-06-03 | Current version: v1.49.0-rc4

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

VeilWriter is configured for non-App-Store distribution without App Sandbox so it can access local project files with fewer permission interruptions.

## Current Capabilities

- Browse a selected folder through a native sidebar file tree.
- Resize the file tree by dragging its divider, and double-click an editor tab title to maximize or restore the editor area.
- Recognize common file types in the sidebar through colored SF Symbols-based icons.
- Preview common raster image files from the sidebar by double-clicking them.
- Select files from compact full-width sidebar rows for easier clicking.
- See lightweight Git file markers in the sidebar and the current branch in the status bar.
- Create files and folders from the sidebar context menu.
- Reveal sidebar items in Finder, open Terminal at their folder, and copy absolute or relative paths.
- Open files from the current window and open folders into separate editor windows from menu commands, recent folders, the command palette, or the empty sidebar state.
- Open text files, source files, and folders from Finder's Open With menu.
- Open individual files from the File menu.
- Open a new window by choosing the folder that window should browse.
- Create a fresh untitled editor tab from the File menu or with Command-T.
- Reveal the current file in Finder with Open Containing Folder.
- Open bundled macOS Help from the system Help menu for core workflows and troubleshooting.
- Install the `veilwriter` command line tool from Settings into `~/.local/bin` and open files or folders from Terminal.
- Start from a centered empty workspace view with open-file, open-folder, recent files, and recent folders grouped in the main editor area when no folder is open.
- Show a focused no-file prompt without recent items when a folder tree is open but no editor tab is selected.
- Keep temporary test and scratch paths out of recent files and folders.
- Keep recent folders and files available as explicit launch choices instead of automatically restoring the previous workspace on startup.
- Run common actions from the Command-Shift-P command palette with keyboard selection, highlighted rows, fuzzy matching, keyword lookup, and shortcut hints.
- Open Terminal, copy active-file paths, and refresh Git status from the command palette.
- Search and open project files quickly with Command-P.
- Keep multiple files open in tabs, each with its own unsaved state.
- Keep the first editor tab clear of macOS window controls when the file tree is collapsed or the editor is maximized.
- Switch tabs with previous/next commands or Command-1 through Command-9.
- Reopen the most recently closed tab with Command-Shift-T.
- Open multiple windows, each with its own independent tab set and editor state.
- Close the active tab from the File menu or with Command-W.
- Jump to a specific line with Command-L.
- Jump to symbols in the active file with Command-Shift-O.
- Find and replace text in the active editor, all open tabs, or the selected folder with highlighted matches and next/previous navigation.
- Use the right inspector for a lightweight minimap and document/code structure view, with click-to-jump navigation into the current tab.
- Choose the default right inspector view and whether Minimap or Structure appears first in the Inspector control.
- Use Focus Mode to hide editor chrome when reading or writing.
- Open a lightweight split editor pane to view another text file beside the active editor.
- Use a first-phase project Agent panel backed by an OpenAI-compatible streaming chat API, with current folder, active file, and selected text included as compact context.
- Configure Agent providers from a tabbed Settings window, with built-in OpenAI-compatible presets for OpenAI, DashScope, DeepSeek, Kimi, Moonshot, Claude, and custom endpoints.
- Fetch Agent model IDs from provider `/models` endpoints and assign returned models to separate Flash and Pro slots in Settings. Agent routing can run cost-first through Auto/Flash or force Pro for stronger turns. API keys remain stored in Keychain.
- Review Agent-generated unified diff proposals in the Agent panel, then apply or reject them explicitly. Accepted patches are limited to existing files inside the current workspace and update open tabs plus Git status.
- Let the Agent call built-in workspace tools (`search_files`, `grep_files`, `read_file`, `list_directory`, `git_status`, `run_command`, `ask_user`) via OpenAI function-calling. `search_files` does literal text matching while `grep_files` supports full regular expressions plus an optional filename `include` glob (e.g. `*.swift`). Read-only tools run automatically; `run_command` requires per-call Allow/Deny approval, or an explicit Always Allow rule for matching command families such as `git push`; destructive commands additionally require typing `confirm` before running. `ask_user` lets the agent pause mid-turn and ask the user a clarifying question; when the answer is one of a small known set the model can pass `options` so the card renders clickable choice buttons (or checkboxes for `multi_select`), with a free-form text input still available as an escape hatch.
- Let the Agent discover installed Codex skills with `list_skills` and load a selected `SKILL.md` with `read_skill`, so specialized workflows can be pulled into context only when needed.
- Let the Agent inspect configured MCP servers with `list_mcp_servers`, list one server's MCP tools with `list_mcp_tools`, and call a selected MCP tool with `call_mcp_tool`; sensitive environment values are redacted and MCP tool calls require approval.
- Automatically run conservatively parsed read-only `run_command` chains, such as workspace-relative or workspace-absolute `cd` prefixes followed by `git diff`, `ls`, `cat`, `rg`, or `grep`, plus workspace-safe `git -C ... diff`; commands that write, redirect, pipe, substitute, or move outside the workspace still require approval or confirmation. Shell commands inherit a supplemental macOS PATH with common Homebrew and local binary directories so tools such as `rg` remain available when VeilWriter is launched from the GUI.
- Show the full `run_command` command text on approval and destructive-confirmation cards so the exact command is visible before the user allows it.
- Keep Agent tool-call rows compact by default and collapse consecutive calls into an expandable group so long multi-step runs remain scannable, with arguments, output, and errors available from explicit expand controls.
- Switch the window into a dedicated Agent mode (Cmd+Shift+A) with a project-grouped session sidebar on the left and a wide chat pane on the right. Sessions persist as JSON under `~/Library/Application Support/VeilWriter/agent-sessions/` and are grouped by workspace.
- Paste, drag-drop, or attach images directly in the Agent composer; staged images appear as removable thumbnails and, for supported multimodal providers, are sent inline as base64 `image_url` content parts in the request body.
- Configure a separate Image Understanding provider with its own API key; for text-only Agent providers such as DeepSeek, multiple attached images are first described by that image-capable provider, then the generated description is appended to the user message before the main model runs.
- Send Agent-mode messages with Return, while Shift-Return, Option-Return, and Control-Return remain available for multiline composition.
- Queue follow-up messages while the agent is responding — additional sends become "Queued" bubbles that auto-fire when the current turn ends. Stop the current response without dropping the queue; Clear Queue removes them explicitly.
- Show an inline "正在思考" activity divider while the Agent is waiting for the model to start responding or to continue after tool output.
- See the estimated context-window utilization in the chat header (≈ remaining tokens / model window) based on the actual next provider request shape, including system context, normalized history, collapsed tool results, images, and tool schemas. Switch the active session to a concrete model override from a picker fed by previously fetched model IDs, while the default path follows the configured Flash/Pro route.
- Auto-approve safe Agent shell commands: a built-in allowlist runs read-only commands (cat, head, tail, ls, find -name, git diff/log/status, rg, grep, wc, file, …) immediately. Anything else can fall through to an LLM judge (using the current chat model) that returns YES/NO; only a confirmed YES auto-runs. Destructive patterns still require typing `confirm`. Toggle via Settings > Agent > Tool approval > Auto-approve safe commands; user-pinned "Always allow" signatures continue to work alongside.
- Reclaim context budget without losing state: a Compress button in the status bar (surfaces once usage crosses 50%) summarizes the older transcript into a single assistant message via the configured Flash model. The last few messages stay verbatim. Older `tool` results auto-collapse to a small placeholder in the request payload so long sessions don't blow up the prompt. Once usage crosses 75% the compression also runs automatically between turns — the status bar shows a `Compressing…` spinner and any queued message waits for compression to finish before dispatching.
- Show an inline transcript divider while context compression is running so the chat view explains the temporary pause instead of looking idle.
- Expand Agent provider errors to inspect the method, URL, provider, model, input message summary, redacted request body, HTTP status, and response body for debugging failed requests.
- Normalize Agent tool-call history before provider requests so stale or incomplete tool messages from older sessions do not cause OpenAI-compatible request errors.
- See current Agent worktree changes with clickable filenames, per-file added/deleted line counts, total changed files, total line deltas, and a one-click review action for the Agent to inspect uncommitted changes. Modified entries with no real diff or only `+0 -0` line stats are suppressed so the summary does not appear when nothing actually changed.
- Define Agent Routines that fire on a schedule (interval / daily HH:MM / weekdays HH:MM / specific weekday HH:MM) and automatically start a brand-new Agent session with the routine's prompt, bound to the routine's workspace and optional model override. Routines are managed from a dedicated section in the Agent-mode sidebar (hover to enable/disable or run immediately; right-click for full menu) and edited in a sheet with name, prompt, workspace picker, model picker, schedule, and enabled switch. A 30s scheduler tick coalesces double-fires, catches up routines whose target time slipped past app sleep, and politely waits if the current chat is mid-turn so a scheduled run never interrupts a live conversation. Optional macOS notifications announce each run when the user has granted permission. Routines persist as JSON under `~/Library/Application Support/VeilWriter/agent-routines/`, one file per routine.
- Run multiple Agent sessions concurrently — each session owns its own runtime (messages, request task, tool waiter, composer draft, mode/plan/goal) and dispatches its own provider request, so switching away from a streaming session doesn't kill it; the outgoing turn keeps running in the background and the sidebar status dot pulses green while it works (orange when it's paused on a tool decision). Routines spawn background runtimes that don't yank the user's UI — they appear as new rows in the sidebar with their own status indicator. Concurrent dispatches are capped per-provider (default 3, user-tunable 1–8 in Settings → Agent → Concurrency) so a fleet of routines hitting the same provider queues FIFO instead of stomping the rate limit; different providers are isolated, so running 3 DashScope sessions never blocks an OpenAI session.
- Preview Markdown and HTML beside the editor with richer lightweight block rendering for headings, lists, quotes, dividers, code, and common HTML content nodes.
- Read current file state from a compact status bar with cursor position, language, file size, and version.
- Reload when the active file has changed on disk outside VeilWriter.
- Read selected character and line counts from the status bar when text is selected.
- See lightweight dirty gutter marks for lines changed since the last saved content.
- Highlight matching bracket pairs around the cursor for common code delimiters.
- Fold and expand detected code scopes from the line-number gutter without changing the underlying file content.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, shell/bash, YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C# files.
- Override syntax highlighting per editor tab from the editor context menu.
- Extract language-aware document structure, including shallow HTML node outlines for title, h1-h5, div, list, and semantic layout elements.
- Customize editor font, font size, line height, sidebar file-tree text size and line height, color style, line numbers, current-line focus highlighting, inspector preferences, Agent settings, Agent always-allow command rules, and command-line tooling from tabbed Settings with immediate refresh.
- Choose a custom editor background image with opacity, fit mode, and size controls, while keeping sidebar chrome on the native window background.
- Apply editor setting changes after the current SwiftUI update pass so preference changes avoid publishing-during-view-update warnings.
- Optionally trim trailing whitespace and ensure a final newline on save.
- Keep indentation flowing with newline auto-indent plus Tab and Shift-Tab line indentation.
- Duplicate the current line with Command-D and move it with Option-Up/Option-Down.
- Decode UTF-8 first, then fall back through NSString encoding detection and ISO Latin 1.
- Detect binary files before opening.
- Track dirty state, save with Cmd+S, and save copies with Save As.
- Warn before loading files larger than 1 MB.

## Performance Direction

- Keep file IO off the main thread.
- Skip generated dependency/build directories during project-wide scans, and cap Quick Open candidate collection so huge workspaces remain responsive.
- Keep Git status and Agent network requests bounded with output caps and timeouts so unavailable providers or huge repositories cannot leave the UI waiting indefinitely.
- Allow longer bounded Agent tool sessions so normal multi-step work can continue, while still pausing after 64 tool rounds to prevent accidental loops.
- Persist only command-family approvals for Agent `run_command`, and keep destructive commands behind confirmation even if a related safe command was always allowed.
- Apply completed file loads back on the main thread and target the tab that requested the load.
- Force the editor view to re-render after tab activation or closure so syntax highlighting remains visible.
- Expand and load the restored project root as soon as the sidebar tree appears.
- Keep the default editing path optimized for files under 1 MB.
- Show a file's plain text immediately on open; never block the main thread on a full-file syntax-highlight pass. Highlighting runs off the main thread and is swapped in when ready.
- For large files (>= ~100 KB), highlight only the visible range plus an overscan margin and extend on scroll, applying attributes in place so scroll/layout are preserved. Smaller files highlight the whole document once.
- Remember each tab's caret and scroll position so switching tabs returns to where you left off rather than the top of the file.
- Keep tab switching responsive on large files: no full-document layout pass on switch, local-layout scroll restore, and inspector outline/minimap computed off the main thread so the editor area appears first. (Non-contiguous layout was tried and reverted — it made Dock re-activation janky.)
- Scope folding invalidates layout only from the fold downward (not the whole document) and caches folded character ranges, so toggling a fold on a large file is immediate.
- Require explicit confirmation before loading larger files, with a core loader guard as a backstop.
- Cache the Go to Symbol outline when the panel opens (recompute only when file content or language changes) so arrow-key navigation and query typing don't re-run the regex extraction on every body pass.
- Cache the Quick Open file list cross-session on disk (in `~/Library/Caches`, outside the project directory) keyed by a SHA-256 of the project root path. Serve it instantly on project open, verify it with a background scan, and invalidate per-entry by modification time + size (no content hashing). Cap the cache at the 50 most-recently-used projects.

## Open Questions

- Decide whether the Quick Open / file-list cache should honor `.gitignore` (currently it mirrors the raw enumerator walk).
- Extend the cross-session disk cache to the Go to Symbol outline (currently cached only in-memory per panel session).
- Extend Agent edit proposals to support multi-step patch review, new-file creation, and richer before/after diff rendering.
- Add provider-specific model discovery fallbacks for vendors whose model catalog endpoint is not fully OpenAI-compatible.
- Add MCP server configuration and tool invocation once the first-phase Agent chat is stable.

- Add line-number and search workflows without making the editor feel heavy.
- Refine keyboard-first tab workflows around unsaved-change prompts and bulk closing.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
