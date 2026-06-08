# VeilWriter Product Overview

> Last updated: 2026-06-08 | Current version: v1.54.1-rc9

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

VeilWriter is configured for non-App-Store distribution without App Sandbox so it can access local project files with fewer permission interruptions.

## 架构概览

VeilWriter 是 SwiftUI + AppKit 桥接的 macOS 应用，单进程多窗口。代码层次：

- **入口** — `XeditApp.swift`：`@main App`，注入唯一 `AppState` `@StateObject` 给整个窗口树。
- **状态枢纽** — `AppState.swift`：全局 `ObservableObject`，承载工作区根目录、tab 集、find/replace、git 状态、Agent 配置库等"窗口级"状态。rc42 完成体检阶段 3：把原 4946 行的 AppState 用 `extension` 拆成 6 个伴生文件（`AppStateAgentLoop`、`AppStateAgentSessions`、`AppStateFileOperations`、`AppStateGitStatus`、`AppStateEditorTextUtilities`、`AppStatePersistenceStores`），主类瘦身到 ~1364 行，所有伴生文件 < 1400 行；门面 + callsite 不动。**per-session Agent 状态已经在 rc2 抽到 `AgentRuntime`**：22 个原本 `@Published` 在 AppState 上的 Agent 字段（messages / patchProposals / queue / mode / plan / goal …）下沉到 `AgentRuntime`，AppState 上保留同名 get/set delegate 转发到 `activeRuntime`，并把 `activeRuntime.objectWillChange` 通过 `subscribeToActiveRuntime()` republish 到自身的 publisher 上，UI 端无感。
- **视图层** — `ContentView.swift`（rc40 拆完，1798 行）是主窗口外壳，子视图（背景、空状态、窗口 chrome、Markdown 预览）独立成 `ContentViewBackgrounds.swift` / `EmptyStateViews.swift` / `MainWindowChrome.swift` / `MarkdownPreview.swift`。Agent 面板有两套渲染：`AgentPanelView`（侧边 panel 模式）和 `AgentModeView`（Cmd+Shift+A 进入的全屏 mode），共用 `AgentChatHistoryTextView`（TextKit 历史）和 `AgentModeComposerView`（输入区）。
- **Agent 运行时** — `AgentRuntime.swift` 一个会话一个实例，独占自身的 messages / requestTask / toolDecisionWaiter / 模式 / 草稿等；多个 runtime 可以并发跑（后台 routine 不会抢占用户的 active session）。`AgentClient.swift` 负责 OpenAI 兼容的流式请求、image 路由、X-App-Version header；`AgentTools.swift` 是内建工具（`search_files` / `grep_files` / `read_file` / `list_directory` / `git_status` / `run_command` / `ask_user` / skill / MCP）。`AgentSessionStore` 负责 JSON 持久化（`~/Library/Application Support/VeilWriter/agent-sessions/`），`AgentRoutineStore` + `AgentRoutineScheduler` 负责定时 routine。
- **编辑器内核** — `EditorView.swift` 包 `NSTextView`，搭配 `SyntaxHighlighter.swift`（NSRegularExpression 静态缓存，viewport 高亮）/ `ScopeGuideCalculator.swift`（fold + scope guide）。

## 目录结构

源码全部在 `Xedit/` 下，单 module。截至 rc42 的主要 Swift 文件（按行数倒序选）：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `AppState.swift` | ~1364 | 全局状态枢纽 + 6 个 manager 伴生文件聚合（rc42 拆完） |
| `AppStateAgentLoop.swift` | ~1382 | `dispatchAgentMessage` / `runAgentLoop` / `awaitToolDecision` / 工具决策处理 / context 压缩 / patch 应用（rc42 拆出） |
| `AppStateAgentSessions.swift` | ~1052 | sendAgentMessage / sessions/routines 生命周期 / Plan & Goal / provider library 切换 / 附件管理（rc42 拆出） |
| `AppStateFileOperations.swift` | ~540 | NSOpenPanel / file load/save / session restore / security-scoped bookmark（rc42 拆出） |
| `AppStateGitStatus.swift` | ~488 | git porcelain 解析 + `loadGitStatus` / `refreshGitStatusAfterAgentTool` / worktree snapshot/diff preview（rc42 拆出） |
| `AppStateEditorTextUtilities.swift` | ~180 | nonisolated 文本工具：findRanges / changedLineNumbers / 行操作 / 目录枚举（rc42 拆出） |
| `AppStatePersistenceStores.swift` | ~111 | RecentItemsStore / SessionStore / CompressionSummaryCollector（rc42 拆出） |
| `AgentModeView.swift` | ~88 | Agent mode 主壳（rc45 拆完） |
| `AgentMessageView.swift` | ~870 | 消息气泡 / 助手 Markdown 渲染器 / token breaker / footer / queued row / 空状态（rc45 拆出） |
| `AgentSessionsSidebar.swift` | ~504 | 左侧会话侧栏：CHATS / provider 状态 / workspace 分组 / 归档分区（rc45 拆出） |
| `AgentChatTranscript.swift` | ~381 | Plan/Goal banner / 历史 + 流式分流 / tool group / 错误卡（rc45 拆出） |
| `AgentChatHeader.swift` | ~78 | 会话标题 + 复制 + 新会话 + 切回 editor（rc45 拆出） |
| `AgentStatusIndicators.swift` | ~305 | StatsDashboard / StatCell / PlanStatusPill（rc45 拆出） |
| `AgentPlanGoalCards.swift` | ~528 | Plan card / 修订行 / 步骤行 / 简单 sheet / Goal card / Goal editor（rc45 拆出） |
| `AgentTools.swift` | ~944 | 共享类型 / UI 状态 / JSON 辅助 / Tool runner（rc45 拆完） |
| `AgentToolRegistry.swift` | ~458 | 工具描述符表 + read-only shell 分级 + 安全 path 检查（rc45 拆出） |
| `AgentSkillDirectory.swift` | ~255 | Codex skill 发现 + `list_skills`/`read_skill` 工具入口（rc45 拆出） |
| `AgentToolAuthorization.swift` | ~118 | always-allow 签名归一化（rc45 拆出） |
| `AgentModeComposerView.swift` | ~986 | Composer 主壳 + Worktree banner + status bar + slash/@ 弹层（rc45 拆完） |
| `ComposerTextInput.swift` | ~449 | NSTextView 桥接 + 历史 cursor + @-token 派生（rc45 拆出） |
| `AgentComposerPickers.swift` | ~428 | Workspace / Model / Mode 三个 pill picker（rc45 拆出） |
| `AgentComposerAttachments.swift` | ~112 | AttachButton / SendStopButton / QueueBadge（rc45 拆出） |
| `AgentChatHistoryTextView.swift` | ~541 | NSViewRepresentable 包装 + NSTextView 子类 + bubble layout manager（rc45 拆完） |
| `AgentChatHistoryFormatter.swift` | ~1247 | Markdown normalizer + AgentChatHistoryRenderer TextKit baker（rc45 拆出） |
| `AgentChatChromeRenderers.swift` | ~121 | 代码 copy 按钮 + footer 按钮 NSAttributedString builder（rc45 拆出） |
| `ContentView.swift` | ~1798 | 主窗口外壳（rc40 拆完） |
| `EditorView.swift` | ~1692 | NSTextView 包装、滚动、caret/scroll 记忆、folding |
| `AgentPanelView.swift` | ~1610 | 侧边 panel 形态的 Agent 面板 |
| `EditorSettingsView.swift` | ~1393 | Settings 主窗口：通用 / 字体 / Agent / Skills / Memory / MCP |
| `AgentModels.swift` | ~1116 | `AgentSession` / `AgentMessage` / `AgentConfiguration` / `AgentProviderLibrary` 等数据模型 |
| `SyntaxHighlighter.swift` | ~902 | 多语言正则规则 + 静态 NSRegularExpression 缓存 + viewport 高亮 |
| `AgentMCPBridge.swift` | ~891 | MCP server 发现（App / Cursor / Codex）+ stdio / streamable-http 调用 |
| `MarkdownPreview.swift` | ~727 | 编辑器右侧 Markdown / HTML 预览（rc40 抽出） |
| `AgentClient.swift` | ~672 | OpenAI 兼容流式请求、provider header、image_url 路由、X-App-Version |
| `AgentRuntime.swift` | — | 每会话一个：messages / requestTask / toolDecisionWaiter / mode/plan/goal |
| `ContentViewBackgrounds.swift` | ~201 | 主窗口背景、视觉效果、resize handle（rc40 抽出） |
| `EmptyStateViews.swift` | ~308 | 空工作区 / 空 tab hero + recent（rc40 抽出） |
| `MainWindowChrome.swift` | ~423 | 键盘快捷键 / 窗口 chrome 配置 / 调色板转发（rc40 抽出） |
| `AgentMarkdownTableFormatter.swift` | ~111 | CJK 双宽列对齐表格格式化（rc38 抽出，两条渲染路径共用） |

其余文件（`AgentMemoryStore` / `AgentSkillSettingsStore` / `FileTreeView` / `EditorInspector` / `EditorAppearance` / `EditorTab` / `FileSystemNode` / `ProjectFileListCache` / `CommandLineToolInstaller` / `AgentImageViews` / `AgentRoutine*` 等）单一职责、规模可控（<500 行），目前不在重构清单。

CLAUDE.md §10 的软上限是 2000 行，硬上限是 3000 行。rc42 拆完 `AppState.swift`（1364 行）；rc45 拆完 `AgentModeView.swift` / `AgentTools.swift` / `AgentModeComposerView.swift` / `AgentChatHistoryTextView.swift` 共 14 个新文件，全部低于 1500 行任务目标。当前所有 `Xedit/*.swift` 主文件均 ≤ 1798 行（`ContentView.swift`）。

## 关键概念

- **AgentRuntime per session** — 一个 `AgentSession` 配一个 `AgentRuntime`。runtime 内独占 `messages`、`requestTask`（当前流式 Task）、`toolDecisionWaiter`（pending 工具批准的 continuation）、`composerDraft`、`mode/plan/goal`、`turnStartedAt` 等。AppState 通过 `activeSessionID -> activeRuntime` 选中"当前"，但其他 runtime 继续在后台跑。切换会话不会取消正在流式的请求；用户回来时还能看到完整 transcript。
- **@MainActor isolation** — AppState 本身是 `@MainActor`，所有 `@Published` mutation 必须在主线程发生。runtime 的 hot 字段亦然，但 `AgentClient` 的 URLSession 流式回调跨线程时通过 `Task { @MainActor in ... }` 拥抱主线程。`AppState.deinit` 不能 cancel runtime——rc38 曾尝试 `MainActor.assumeIsolated` 但 Swift Testing 在非主线程 release 触发 precondition fail，rc41 回退；清理走 session 显式删除路径。
- **Per-provider concurrency cap** — 多 runtime 并发跑时，同一 provider 的活跃请求按 `AgentSettingsStore` 的 `concurrencyLimit`（默认 3，1–8 可调）FIFO 排队；不同 provider 互不阻塞。这样 routine 集中触发也不会冲烂同一家 API 的速率。
- **find/replace 内容哈希缓存** — `AppState.findMatchRanges` 与 `changedLineNumbers` 用 `(content.hashValue, query/savedContent)` 双键缓存（rc39 落地）。SwiftUI body 多次读这俩属性时不再每次重扫全文。
- **NSRegularExpression 静态缓存** — `SyntaxHighlighter` 把已编译的 `NSRegularExpression` 按 pattern + options 放进 NSLock 保护的静态字典（rc38 落地）。viewport 高亮的 O(N × 规则数) 编译降到 O(规则数) 一次。
- **Tool 调用容错** — `argumentsJSON` 解析失败时该 tool call 标 `.failed`，把坏 JSON 通过 tool message 反馈回模型自纠（rc38），而不是悄悄落入空 dict。
- **Auto-approve 安全判定** — 静态 allowlist（cat/head/tail/ls/git diff/log/status/rg/grep/wc/file …）自动放行；越界命令落 LLM judge，**走 Flash 模型而非当前 turn 的模型**（rc41 修正，避免昂贵模型重复评估）。返回 YES 才自动跑；destructive 模式仍需键入 `confirm`。
- **Worktree baseline diff** — Agent turn 开始时记录 git 变更基线，结束后对比快照。只有相对基线发生变化才标 session `didEditFiles`，避免旧的未提交改动误触发"已编辑文件"卡片。
- **Provider 数据流单向（rc8 落地）** — `agentProviderLibrary` 是 provider 主字段（providerID / baseURL / apiKey / flash / pro / routing）的**唯一**真相源，legacy `agentConfiguration` 上的同名字段是**派生态**，只读不写——不允许从 cfg 回灌 library。唯一的同步方向是 `applyActiveProviderLibraryEntry()`（library → cfg）；cfg.didSet 只持久化 `imageDescription` / `titleModel` 这些 library 不接管的字段。这是 rc8 修复 API key 串台 bug 的根本约束——双向同步会让"OpenAI 的默认 providerID"反向污染 DeepSeek 条目。给后续修改者：动 cfg 主 provider 字段时，先确认你不是在重新引入回灌路径；如果新需求需要从某个旧入口改 provider，改的应该是 library entry，再让 `applyActiveProviderLibraryEntry()` 把它投射到 cfg。

## 版本号约定

遵循 CLAUDE.md §5：

- 格式 `MAJOR.MINOR.PATCH` 或 `MAJOR.MINOR.PATCH-rcN`，例 `1.53.0` / `1.52.1-rc46`。
- **bugfix**（含文档、release 流程改进）：只递增 `rcN`。
- **feature 新增**：可提升 `PATCH` / `MINOR`，rc 归位 `rc1`。
- 前后端版本号必须一致——这里"后端"指 `AgentClient` 出站请求的 `X-App-Version` header（值从 `Bundle.main.CFBundleShortVersionString` 取，等价 pbxproj `MARKETING_VERSION`）。
- 8 处需同步更新：`Xedit.xcodeproj/project.pbxproj` 里 6 个 `MARKETING_VERSION` 块（debug / release × 三个 target）。`Help/VeilWriter.help/Contents/Info.plist` 与本文件顶部 `Current version` 一并同步。
- 每次版本变更必须同步在 `CHANGELOG.md` 顶部写一节、更新本文件头部的 `Current version` 字段。
- git commit 后建议打 `v{版本号}` tag 并推送 origin（`scripts/release.sh` 公证完成后会交互确认是否打 tag/push）。

## 国际化（i18n）

**当前状态：部分落地。** 项目已经引入 `Localizable.xcstrings`（Xcode 15+ String Catalog）和 `L10n` enum 强类型访问，覆盖一部分主窗口、Agent footer、空状态和本轮新增的 pasted-text 附件文案；仍有大量历史 SwiftUI 文案直接写死在视图中（混合中英文）。

CLAUDE.md §2 要求 React 部分必须走 i18n，但 VeilWriter 是 SwiftUI macOS 应用，不在该条款约束范围内。即便如此，后续仍应继续把所有用户可见文案抽到 String Catalog（见 [ROADMAP.md](./ROADMAP.md) 阶段 5），至少保持 zh-Hans / en 双语。

## 测试与 CI

- **本地测试**：详见 [TESTING.md](./TESTING.md)。`XeditTests/` 12 个 Swift Testing（`@Suite` / `@Test`）风格的单测，覆盖 Agent 历史渲染、模型选路、目标 checklist 解析、MCP 服务发现、Memory 存储、Plan 进度、Provider library、Session 持久化、Skill 目录、Markdown 列表嵌套与表格解析。Xcode 跑：`Cmd+U`；命令行跑：`xcodebuild test -project Xedit.xcodeproj -scheme Xedit -destination 'platform=macOS'`。
- **已知 flaky**：CHANGELOG rc41 提到的 7-8 个测试由 AppState init 中的磁盘 IO 在测试间相互污染引起，已 spawn 独立任务追踪，不在本轮范围。
- **CI**：**未落地。** 仓库下没有 `.github/workflows/`。后续阶段计划：PR 触发 `xcodebuild test` + lint + 版本号一致性校验。详见 [ROADMAP.md](./ROADMAP.md) 阶段 6。

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
- Let the Agent discover built-in, user-created, and plugin Codex skills with `list_skills` and load a selected `SKILL.md` with `read_skill`, so specialized workflows can be pulled into context only when needed. Built-in skills are bundled from Alma under `BundledSkills`; user skills live in `~/.codex/skills`; plugin skills continue to come from `~/.codex/plugins/cache`.
- Let the Agent inspect configured MCP servers with `list_mcp_servers`, list one server's MCP tools with `list_mcp_tools`, and call a selected MCP tool with `call_mcp_tool`; server discovery merges App user MCP servers, Cursor `~/.cursor/mcp.json`, and Codex `~/.codex/config.toml`. Both stdio and Cursor-style `streamable-http` MCP transports are supported, with sensitive headers and environment values redacted before display; MCP tool calls still require approval.
- Automatically run conservatively parsed read-only `run_command` chains, such as workspace-relative or workspace-absolute `cd` prefixes followed by `git diff`, `ls`, `cat`, `rg`, or `grep`, plus workspace-safe `git -C ... diff`; commands that write, redirect, pipe, substitute, or move outside the workspace still require approval or confirmation. Shell commands inherit a supplemental macOS PATH with common Homebrew and local binary directories so tools such as `rg` remain available when VeilWriter is launched from the GUI.
- Show the full `run_command` command text on approval and destructive-confirmation cards so the exact command is visible before the user allows it.
- Keep Agent tool-call rows compact and collapsed by default, separated from the preceding assistant output by a dedicated vertical gap, and collapse consecutive calls into low-emphasis expandable groups so long multi-step runs remain scannable. A lightweight current-turn activity summary covers explored paths, searches, run commands, and active file edits; longer command/path previews remain visible in the gray summary and full arguments, output, approval controls, and errors are available only after explicit expand controls.
- Switch the window into a dedicated Agent mode (Cmd+Shift+A) with a project-grouped session sidebar on the left and a wide chat pane on the right. Sessions persist as JSON under `~/Library/Application Support/VeilWriter/agent-sessions/` and are grouped by workspace. The empty-state dashboard summarizes recent usage and stretches its activity heatmap across the available stats card width.
- Render Agent chat history, transcript reader windows, and single-message reader windows with lightweight TextKit Markdown for headings, paragraphs, lists, quotes, syntax-highlighted code blocks, inline formatting, links, dividers, HTML details-as-code fallback, and pipe-table fallback while avoiding SwiftUI per-block transcript layout. The in-pane history keeps chat-style visual chrome through TextKit-drawn rounded bubbles, right-side hover-only user message columns with left-aligned body text, safe right padding, and pre-reserved low-contrast hover-time timestamp/copy controls, lighter full-width assistant cards with a gray star-style assistant mark, slightly inset syntax-highlighted code blocks with a little top breathing room plus clickable larger code-copy controls and 3-second success feedback, larger per-message copy footers, assistant elapsed/input/output token summaries with matching icon sizing, latest-assistant retry affordance, and collapsed low-emphasis tool-call groups that expand in place to show longer command/path/pattern arguments inside a padded gray group without overlapping adjacent user bubbles.
- Paste, drag-drop, or attach images directly in the Agent composer; staged images appear as removable thumbnails and, for supported multimodal providers, are sent inline as base64 `image_url` content parts in the request body.
- Paste large text blocks into the Agent composer as compact `.txt` attachments instead of expanding them inline in the chat bubble. The visible transcript shows a small filename/size chip, while provider requests, token estimates, queued messages, persistence, and message-copy payloads retain the full pasted text.
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
- See current Agent worktree changes in a Codex-style edited-files card with clickable filenames, Xedit new-window / default-app / Finder open options, per-file added/deleted line counts, total changed files, total line deltas, and a one-click local diff review sheet with copy support. The Agent composer also mirrors the active session workspace summary above the input area with changed-file count, total `+/-` lines, and the same diff review entry. Modified entries with no real diff or only `+0 -0` line stats are suppressed, and Agent turns compare against a start-of-turn git baseline so old uncommitted changes do not masquerade as files edited by the current run.
- Define Agent Routines that fire on a schedule (interval / daily HH:MM / weekdays HH:MM / specific weekday HH:MM) and automatically start a brand-new Agent session with the routine's prompt, bound to the routine's workspace and optional model override. Routines are managed from a dedicated section in the Agent-mode sidebar (hover to enable/disable or run immediately; right-click for full menu) and edited in a sheet with name, prompt, workspace picker, model picker, schedule, and enabled switch. A 30s scheduler tick coalesces double-fires, catches up routines whose target time slipped past app sleep, and politely waits if the current chat is mid-turn so a scheduled run never interrupts a live conversation. Optional macOS notifications announce each run when the user has granted permission. Routines persist as JSON under `~/Library/Application Support/VeilWriter/agent-routines/`, one file per routine.
- Run multiple Agent sessions concurrently — each session owns its own runtime (messages, request task, tool waiter, composer draft, mode/plan/goal) and dispatches its own provider request, so switching away from a streaming session doesn't kill it; the outgoing turn keeps running in the background and the sidebar status dot pulses green while it works (orange when it's paused on a tool decision). Routines spawn background runtimes that don't yank the user's UI — they appear as new rows in the sidebar with their own status indicator. Concurrent dispatches are capped per-provider (default 3, user-tunable 1–8 in Settings → Agent → Concurrency) so a fleet of routines hitting the same provider queues FIFO instead of stomping the rate limit; different providers are isolated, so running 3 DashScope sessions never blocks an OpenAI session.
- Manage Agent memory from Settings → Memory, including feature enablement, automatic retrieval, query rewriting, retrieval limits, similarity threshold, automatic summaries, daily maintenance timing, transient/archive retention, tool model selection, embedding model selection, statistics, manual memory creation, text search, inline editing, archiving, restoration, deletion, clearing, and JSON snapshot export. Memory settings and records persist locally through UserDefaults; the current maintenance cycle performs local TTL archiving and expired archive cleanup while leaving LLM-assisted merge controls ready for the future retrieval pipeline.
- Manage Agent skills from Settings → Skills, including automatic skill extraction settings, minimum tool-call threshold, search, refresh, opening the user skill folder, creating new user skills, viewing skill bodies, and enabling/disabling individual built-in, user, or plugin skills. Disabled skills are hidden from Agent tools and the composer `@` picker while remaining visible in Settings for re-enabling.
- Manage MCP servers from Settings → MCP, including Cursor-like server rows, per-server enablement, tool-count refresh, creating and deleting App user servers, opening Cursor `mcp.json`, and clearing Authorization headers for App-managed servers.
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
- Customize editor font, font size, line height, sidebar file-tree text size and line height, color style, line numbers, current-line focus highlighting, inspector preferences, Agent settings, Agent memory, Agent skills, MCP servers, Agent always-allow command rules, and command-line tooling from tabbed Settings with immediate refresh.
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
- Keep Agent-mode chat scrolling out of SwiftUI lazy-stack placement: historical messages and transcript readers render through a single TextKit attributed string, with Markdown, syntax-highlighted code, code-block copy affordances, compact tool summaries, and chat-like bubble chrome baked into that string instead of building nested SwiftUI Markdown block views.
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
- Keep Agent-mode chat scrolling out of SwiftUI lazy-stack placement: the transcript uses an eager stack with a stable bottom scroll sentinel, while historical messages render through TextKit-backed `NSTextView`.

## Open Questions

- Decide whether the Quick Open / file-list cache should honor `.gitignore` (currently it mirrors the raw enumerator walk).
- Extend the cross-session disk cache to the Go to Symbol outline (currently cached only in-memory per panel session).
- Extend Agent edit proposals to support multi-step patch review, new-file creation, and richer before/after diff rendering.
- Add provider-specific model discovery fallbacks for vendors whose model catalog endpoint is not fully OpenAI-compatible.
- Add MCP server configuration and tool invocation once the first-phase Agent chat is stable.
- Wire saved Agent memories into the actual turn context through semantic embedding retrieval, and add LLM-assisted duplicate merging during the memory maintenance cycle.
- Wire automatic skill extraction into completed conversations so repeated tool-heavy workflows can become user-reviewable skill drafts.

- Add line-number and search workflows without making the editor feel heavy.
- Refine keyboard-first tab workflows around unsaved-change prompts and bulk closing.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
