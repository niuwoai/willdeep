# WillDeep Product Overview

> Last updated: 2026-06-15 | Current version: v1.78.0-rc21

## Positioning

WillDeep is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

Official product domain: [willdeep.com](https://willdeep.com).

WillDeep is configured for non-App-Store distribution without App Sandbox so it can access local project files with fewer permission interruptions.

## 架构概览

WillDeep 是 SwiftUI + AppKit 桥接的 macOS 应用，单进程多窗口。代码层次：

- **入口** — `XeditApp.swift`：`@main App`，注入唯一 `AppState` `@StateObject` 给整个窗口树。
- **状态枢纽** — `AppState.swift`：全局 `ObservableObject`，承载工作区根目录、tab 集、find/replace、git 状态、Agent 配置库等"窗口级"状态。rc42 完成体检阶段 3：把原 4946 行的 AppState 用 `extension` 拆成 6 个伴生文件（`AppStateAgentLoop`、`AppStateAgentSessions`、`AppStateFileOperations`、`AppStateGitStatus`、`AppStateEditorTextUtilities`、`AppStatePersistenceStores`），主类瘦身到 ~1364 行，所有伴生文件 < 1400 行；门面 + callsite 不动。**per-session Agent 状态已经在 rc2 抽到 `AgentRuntime`**：22 个原本 `@Published` 在 AppState 上的 Agent 字段（messages / patchProposals / queue / mode / plan / goal …）下沉到 `AgentRuntime`，AppState 上保留同名 get/set delegate 转发到 `activeRuntime`，并把 `activeRuntime.objectWillChange` 通过 `subscribeToActiveRuntime()` republish 到自身的 publisher 上，UI 端无感。
- **视图层** — `ContentView.swift`（rc40 拆完，1804 行）是主窗口外壳，子视图（背景、空状态、窗口 chrome、Markdown 预览）独立成 `ContentViewBackgrounds.swift` / `EmptyStateViews.swift` / `MainWindowChrome.swift` / `MarkdownPreview.swift`。Agent 面板有两套渲染：`AgentPanelView`（侧边 panel 模式）和 `AgentModeView`（Cmd+Shift+A 进入的全屏 mode），共用 `AgentChatHistoryTextView`（TextKit 历史）和 `AgentModeComposerView`（输入区）。
- **Agent 运行时** — `AgentRuntime.swift` 一个会话一个实例，独占自身的 messages / requestTask / toolDecisionWaiter / 模式 / 草稿等；多个 runtime 可以并发跑（后台自动化不会抢占用户的 active session）。**`AgentClient.swift` 自 1.56 起是 facade**：根据 `configuration.providerKind` 把调用分派给 4 个原生适配器——`OpenAIChatAdapter`（OpenAI / DashScope / DeepSeek / Kimi / Moonshot / OpenRouter / SiliconFlow / AnyRouter / some.im / Custom）、`AnthropicMessagesAdapter`（claude preset，rc2 起原生 /v1/messages）、`GeminiAdapter`（gemini preset，rc4 起原生 /v1beta/models/{model}:streamGenerateContent）、`OpenAIResponsesAdapter`（openai-responses preset，rc5 起原生 /responses，给 o-系列推理模型用）。共享工具（HTTP timeouts、User-Agent、URL 拼接、错误体脱敏）抽到 `AgentNetworkSupport.swift`。UI 文案集中在 `AgentProviderL10n.swift`，每个 `AgentProviderKind` 与 `AgentProviderPreset` 都有 `shortLabel` / `helpText` / `apiKeySourceHint` / `inlineNotice` 工具属性。`AgentTools.swift` 是内建工具（`search_files` / `grep_files` / `read_file` / `list_directory` / `git_status` / `run_command` / `ask_user` / skill / MCP / 1.57 新增的 `list_jobs` / `get_job_output` / `kill_job`）。**1.57 起** `run_command` 支持 `run_in_background: true`，把长任务交给 `AgentBackgroundJobs.swift` 的 `AgentJobRegistry`：子进程在 host 这边继续跑，agent loop 在下一轮 turn 开头自动把完成事件渲染成 `.system` 消息塞进 history，不用模型 busy-poll；UI 用 AgentPanelView 右侧抽屉展示 alive jobs + 实时计时器 + Kill 按钮；1.58.0-rc1 起两个 transcript 底部还有 Claude Code 式「✳ N 个任务运行中」状态行（`AgentRunningTasksRow`，统计前台 `.running` 工具 + 存活后台作业，turn 结束后只要作业还活着就继续显示）。**1.58 起**新增 `spawn_agent` 子 agent（`AgentSubagents.swift`）：模型可派出只读子 agent（headless 循环复用 AgentClient 四适配器 + AgentToolRunner，工具面仅 search/grep/read/list/git_status/skills + read 风险 shell，无审批 UI 故任何需审批操作直接拒绝；嵌套封死一层，回合上限 12），同步模式内联返回报告，`run_in_background: true` 最多 3 个并行、完成后经 `AgentSubagentRegistry` 复用后台作业管道注入 `<subagent-report>` 系统消息。rc2 再加 `claude_code` 工具：把写任务委派给本机 Claude Code CLI（headless `claude -p`，薄组装层直接走 runCommand 后台管道；`.write` 风险逐次审批，Always Allow 签名按 permission_mode 区分，`bypassPermissions` 硬编码排除）。rc16 起 Settings 新增 Local Agents 标签，扫描 Claude Code / Codex CLI / OpenCode / Aider / Gemini CLI / Qwen Code / Cursor CLI / Cline CLI / Goose / Amp / Crush 的常见安装路径与 PATH，并标明哪些已接入为可直接委派的 Agent 工具。rc17 起新增 `codex_cli` 与 `cursor_agent` 两个委派工具：分别调用本机 `codex exec` 和 `cursor agent --print`，默认后台运行，按 permission_mode 提供只读 plan/ask 与 workspace-write 模式，并固定排除 dangerous bypass / yolo / force 路径。1.65.0-rc1 起新增 `cline_cli` 委派工具：调用本机 `cline --json` 一次性任务，支持 `permission_mode: plan` 映射 Cline `--plan`、`--cwd` 工作区和可选 `--model`，同样默认后台运行并走 WillDeep 审批与后台作业链路。`AgentSessionStore` 负责 JSON 持久化（`~/Library/Application Support/WillDeep/agent-sessions/`），`AgentRoutineStore` + `AgentRoutineScheduler` 作为兼容存储层负责自动化调度。
- **编辑器内核** — `EditorView.swift` 包 `NSTextView`，搭配 `SyntaxHighlighter.swift`（NSRegularExpression 静态缓存，viewport 高亮）/ `ScopeGuideCalculator.swift`（fold + scope guide）。

## 目录结构

源码全部在 `Xedit/` 下，单 module。截至 rc42 的主要 Swift 文件（按行数倒序选）：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `AppState.swift` | ~1364 | 全局状态枢纽 + 6 个 manager 伴生文件聚合（rc42 拆完） |
| `AppStateAgentLoop.swift` | ~1382 | `dispatchAgentMessage` / `runAgentLoop` / `awaitToolDecision` / 工具决策处理 / context 压缩 / patch 应用（rc42 拆出） |
| `AppStateAgentSessions.swift` | ~1280 | sendAgentMessage / sessions/automations 生命周期 / Plan & Goal / provider library 切换 / 附件管理（rc42 拆出） |
| `AppStateFileOperations.swift` | ~540 | NSOpenPanel / file load/save / session restore / security-scoped bookmark（rc42 拆出） |
| `AppStateGitStatus.swift` | ~488 | git porcelain 解析 + `loadGitStatus` / `refreshGitStatusAfterAgentTool` / worktree snapshot/diff preview（rc42 拆出） |
| `AppStateEditorTextUtilities.swift` | ~180 | nonisolated 文本工具：findRanges / changedLineNumbers / 行操作 / 目录枚举（rc42 拆出） |
| `AppStatePersistenceStores.swift` | ~111 | RecentItemsStore / SessionStore / CompressionSummaryCollector（rc42 拆出） |
| `AgentModeView.swift` | ~88 | Agent mode 主壳（rc45 拆完） |
| `AgentMessageView.swift` | ~870 | 消息气泡 / 助手 Markdown 渲染器 / token breaker / footer / queued row / 空状态（rc45 拆出） |
| `AgentSessionsSidebar.swift` | ~504 | 左侧会话侧栏：CHATS / provider 状态 / workspace 分组 / 归档分区（rc45 拆出） |
| `AgentChatTranscript.swift` | ~381 | Plan/Goal banner / 历史 + 流式分流 / tool group / 错误卡（rc45 拆出） |
| `AgentChatHeader.swift` | ~78 | 会话标题 + 复制 + 新会话 + 切回 editor（rc45 拆出） |
| `AgentStatusIndicators.swift` | ~558 | StatsDashboard / StatCell / Models 用量列表 / PlanStatusPill / 呼吸 icon / RunningTasksRow（rc45 拆出，rc13 扩展 Models tab） |
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
| `ContentView.swift` | ~1804 | 主窗口外壳（rc40 拆完） |
| `EditorView.swift` | ~1782 | NSTextView 包装、滚动、caret/scroll 记忆、folding |
| `AgentPanelView.swift` | ~1977 | 侧边 panel 形态的 Agent 面板 |
| `EditorSettingsView.swift` | ~1393 | Settings 主窗口：通用 / 字体 / Agent / Skills / Memory / MCP |
| `AgentModels.swift` | ~1567 | `AgentSession` / `AgentMessage` / `AgentConfiguration` / `AgentProviderLibrary` 等数据模型 |
| `SyntaxHighlighter.swift` | ~902 | 多语言正则规则 + 静态 NSRegularExpression 缓存 + viewport 高亮 |
| `AgentMCPBridge.swift` | ~891 | MCP server 发现（App / Cursor / Codex）+ stdio / streamable-http 调用 |
| `MarkdownPreview.swift` | ~727 | 编辑器右侧 Markdown / HTML 预览（rc40 抽出） |
| `AgentClient.swift` | ~125 | Facade：按 `providerKind` 分派给具体适配器（1.56 重构） |
| `AgentClientOpenAIChat.swift` | ~561 | OpenAI Chat Completions 方言适配器（1.56 拆出，含 SSE/tools/image_url/usage） |
| `AgentClientAnthropic.swift` | ~757 | Anthropic Messages 原生适配器：line-pair SSE / system 顶层 / tool_result 块 / image base64 / stop_reason 映射（1.56-rc2 新增） |
| `AgentClientGemini.swift` | ~814 | Gemini generateContent 原生适配器：模型在 URL 路径 / x-goog-api-key header / functionCall by name + 合成 id / SCHEMA 大写枚举 / JSONValue helper（1.56-rc4 新增） |
| `AgentClientOpenAIResponses.swift` | ~734 | OpenAI Responses API 原生适配器：line-pair SSE / instructions 顶层 / function_call + function_call_output items / reasoning_summary.delta 路由到 reasoningDelta / finish_reason 映射（1.56-rc5 新增） |
| `AgentNetworkSupport.swift` | ~163 | 协议无关共享工具：timeouts / User-Agent / endpoint 拼接 / 错误体 & URL 脱敏（1.56 拆出） |
| `AgentProviderL10n.swift` | ~95 | Provider/Kind 的 UI 文案集中：shortLabel / helpText / apiKeySourceHint / inlineNotice（1.56 新增） |
| `AgentRuntime.swift` | — | 每会话一个：messages / requestTask / toolDecisionWaiter / mode/plan/goal |
| `ContentViewBackgrounds.swift` | ~201 | 主窗口背景、视觉效果、resize handle（rc40 抽出） |
| `EmptyStateViews.swift` | ~308 | 空工作区 / 空 tab hero + recent（rc40 抽出） |
| `MainWindowChrome.swift` | ~423 | 键盘快捷键 / 窗口 chrome 配置 / 调色板转发（rc40 抽出） |
| `AgentMarkdownTableFormatter.swift` | ~111 | CJK 双宽列对齐表格格式化（rc38 抽出，两条渲染路径共用） |

其余文件（`AgentMemoryStore` / `AgentSkillSettingsStore` / `FileTreeView` / `EditorInspector` / `EditorAppearance` / `EditorTab` / `FileSystemNode` / `ProjectFileListCache` / `CommandLineToolInstaller` / `AgentImageViews` / `AgentRoutine*` 等）单一职责、规模可控（<500 行），目前不在重构清单。

CLAUDE.md §10 的软上限是 2000 行，硬上限是 3000 行。rc42 拆完 `AppState.swift`（1364 行）；rc45 拆完 `AgentModeView.swift` / `AgentTools.swift` / `AgentModeComposerView.swift` / `AgentChatHistoryTextView.swift` 共 14 个新文件，全部低于 1500 行任务目标。当前所有 `Xedit/*.swift` 主文件均 < 2000 行（`AgentPanelView.swift` 约 1977 行，已接近软上限，后续扩展应优先拆分）。

## 关键概念

- **AgentRuntime per session** — 一个 `AgentSession` 配一个 `AgentRuntime`。runtime 内独占 `messages`、`requestTask`（当前流式 Task）、`toolDecisionWaiter`（pending 工具批准的 continuation）、`composerDraft`、`mode/plan/goal`、`turnStartedAt` 等。AppState 通过 `activeSessionID -> activeRuntime` 选中"当前"，但其他 runtime 继续在后台跑。切换会话不会取消正在流式的请求；用户回来时还能看到完整 transcript。
- **Remote Runtime（1.60.0-rc5）** — Agent session 的 workspace 现在可记录为本地路径或远端 runtime + 远端路径。Settings → Runtimes 管理 SSH runtime 和 Daemon runtime。SSH 使用系统 `ssh -o BatchMode=yes` 探测远端 Linux/macOS 与 arm64/x86_64 架构，并记录 git / rg / shell、Node/npm/yarn、Python/pip、Ruby、Go、Java、GitHub CLI (`gh`) 版本与登录状态、npm/yarn registry、npm/pip proxy 与 `http_proxy` / `https_proxy` / `no_proxy` 等环境变量；未检测到 `gh` 或登录状态时会提示用户在远端安装并执行 `gh auth login`。SSH 配置可选 identity file path，WillDeep 只保存路径、不保存私钥内容；Daemon runtime 连接 `willdeep-agent` HTTP/WebSocket endpoint，token 存 Keychain，建议通过 SSH tunnel 访问 `127.0.0.1` 绑定的远端 daemon。Agent 工具 `search_files` / `grep_files` / `read_file` / `list_directory` / `git_status` / `run_command` 会按 session workspace 路由到本地、SSH 或 daemon；daemon 后台命令可通过 `get_job_output` / `kill_job` 查询或停止。
- **Mobile Gateway（1.67.0-rc1）** — `willdeep-agent serve-mobile` 新增局域网手机网关协议，面向后续 Android 客户端。Gateway 只负责短期二维码配对 payload、一次性 pairing token、设备 token 鉴权、设备撤销、桌面 peer / mobile peer WebSocket 转发和版本 header；Agent 会话执行、工具审批、补丁应用、Plan gate、danger confirm、workspace path guard 与 MCP trust 仍由 macOS Swift 主应用负责。公开 `GET /mobile/health` 不暴露 pairing token；桌面 peer 通过 bearer token 访问 `GET /mobile/pairing` 获取二维码 payload，通过 `POST /mobile/devices/revoke` 撤销设备；移动端通过 `POST /mobile/pair/claim` 换取 device token，再连接 `GET /mobile/ws` 订阅事件和发送受控命令。完整协议见 `docs/MOBILE_GATEWAY_REQUIREMENTS.md`。
- **Mobile Gateway Desktop Peer（1.68.0-rc1，1.70.0-rc1 扩展审批桥接，1.71.0-rc1 增加 diff.get，1.72.0-rc1 增加 job 控制，1.73.0-rc1 增加 file.read，1.74.0-rc1 增加 queue.update，1.75.0-rc1 增加 conversation snapshots，1.76.0-rc1 增加 worktree changed-files，1.78.0-rc2 补强 AppState 安全桥接测试，1.78.0-rc3 增加实时消息增量事件，1.78.0-rc6 补强真实发送入口测试，1.78.0-rc7 标记危险工具确认需求）** — macOS 侧新增 `AgentMobileGatewayBridge`，作为 Swift desktop peer 连接 Go Mobile Gateway 的 `/mobile/ws`，解码统一 envelope，把 `session.list` / `session.create` / `session.select` / `message.send` / `turn.stop` 路由回现有 `AppState` Agent 会话入口，并把 `state.snapshot`、`session.upsert`、`message.append`、`message.delta`、`message.done`、`tool.pending`、`patch.upsert`、`job.updated`、`worktree.updated`、queued message snapshots、recent conversation snapshots、worktree changed-file snapshots、`ack` / `command.error` 事件发回 gateway。连接期间 desktop peer 会对 AppState 变化做防抖并自动重发快照，同时用增量消息事件让手机端更快看到 Mac Agent 的用户消息、assistant 输出增长和消息完成状态。手机端发来的写代码需求现在能进入 WillDeep 的正常 Agent dispatch 流程；Android 发回的 `tool.decide` / `patch.decide` 会落回 macOS 既有工具审批和补丁应用/拒绝入口，danger-tier 工具仍要求 typed confirmation，不允许移动端绕过安全门，rc7 会在 pending tool payload 里下发 `requires_confirmation` 让 Android 先提示输入 `confirm`。Android 还可以通过 `diff.get` 请求 pending patch 的 unified diff，并在手机端查看后再决定是否应用；后台任务通过 session-scoped `job.kill` 回到既有 `AgentJobRegistry.kill`；`file.read` 只读取当前 session 本地 workspace 内的文本文件，拒绝越界、目录和二进制文件；`queue.update` 通过桌面端 AppState 管理队列消息的新增、删除、清空和立即发送。rc2 的 `AgentMobileGatewayBridgeTests` 已使用真实 `AppState` 覆盖 workspace path guard、danger typed confirmation、`ask_user` answer requirement、patch apply/reject 状态机，证明 Android 指令仍走桌面端既有安全边界；rc3 测试覆盖消息 append/delta/done 事件生成，提升 live Android smoke 对 Mac Agent activity 的观测可靠性；rc6 增加真实 `AppState.mobileGatewaySendMessage` 测试，确认移动端 `message.send` 会进入 `sendAgentMessage()`，创建 user message、清空输入并启动 runtime request task。
- **Mobile Gateway Settings（1.68.0-rc2，1.78.0-rc1 增加配对刷新，1.78.0-rc20 修复启动解码并默认 8877）** — Settings 新增 Mobile Gateway tab：默认关闭，用户启用后由 Swift coordinator 启动本机 `willdeep-agent serve-mobile`，通过受保护 token 文件传递 desktop bearer，连接 Swift desktop peer，显示局域网配对地址、协议版本、二维码 payload、已配对设备列表和撤销按钮。Xcode 主 target 会把 `willdeep-agent` 编译进 app Resources，设置页也保留自定义可执行文件路径兜底。Go gateway 提供 desktop-only `GET /mobile/devices`，只返回设备元数据，不返回 token 或 token hash；`POST /mobile/pairing/rotate` 可在不重启网关的情况下刷新短期二维码 payload，方便 Android 实机配对和 smoke 自动化。rc20 起成功响应缺省 `error` 字段不会导致 Swift 启动失败，设置页端口改为仅接收数字的文本输入，默认端口统一为 `8877`。
- **Mobile Gateway Integration Test（1.77.0-rc1，1.78.0-rc1 扩展配对刷新，1.78.0-rc4 覆盖消息流事件，1.78.0-rc5 增加验收证据，1.78.0-rc8 增加 live readiness，1.78.0-rc9 增加跨仓库总控验收，1.78.0-rc10 增加 Android 预检证据，1.78.0-rc11 强制 Android code-activity gate，1.78.0-rc12 强制默认 workspace-edit 请求，1.78.0-rc13 强制目标文件信号，1.78.0-rc19 强制既有目标文件更新信号，1.78.0-rc21 对齐 8877 readiness 默认端口）** — `scripts/mobile_gateway_integration_test.rb` 会启动真实本地 `willdeep-agent serve-mobile`，用 Ruby stdlib 模拟 desktop peer 和 Android mobile peer，覆盖 health、二维码配对 payload、pair claim、desktop-authenticated pairing rotate、WebSocket 鉴权、`message.send` 转发与 `ack`、unknown-command `error`、`message.append` / `message.delta` / `message.done` 事件顺序广播、`worktree.updated` 广播、设备撤销断开与旧 token 拒绝重连，并输出带 acceptance evidence 的 `build/mobile_gateway_integration/report.json` 与 `report.md`。`scripts/mobile_gateway_live_readiness.rb` 面向 Android 真机验收前的 Mac 侧检查：默认探测 `http://127.0.0.1:8877` 的 public health、默认 desktop-token 文件、desktop-authenticated pairing rotate、协议和配对开关，输出 `build/mobile_gateway_live_readiness/report.json` 与 `report.md`，且不打印 bearer token 或 pairing token。`scripts/mobile_gateway_end_to_end_acceptance.rb` 会先跑 Mac readiness，并始终记录 `/Users/rocky/Sites/willdeep-android` 仓库、live acceptance 脚本和 `adb devices` 预检证据，还会静态检查 Android final wrapper 是否默认启用 `MOBILE_GATEWAY_EXPECT_CODE_ACTIVITY=1`、是否默认发送 `default_workspace_file_edit` 请求并指向 `WILLDEEP_ANDROID_LIVE_ACCEPTANCE.md`、是否要求该目标文件出现在 Mac patch/worktree activity、Android 是否把既有目标文件的 kind/diff 统计变化视作有效目标文件信号，以及 Android live acceptance / connected smoke 默认桌面端口是否为 `8877`；Mac readiness 通过后才调用 Android live acceptance wrapper，最终汇总跨仓库 JSON/Markdown 证据。
- **Composer Git Worktrees（1.69.0-rc1）** — Agent composer 的 Workspace 菜单新增 Git worktree 区域：在当前 Git 仓库内可创建 sibling worktree（自动按输入分支名生成安全路径）、切换到已有 worktree、删除当前非主 worktree，并清理 stale worktree。新建成功后会自动打开该目录并把当前空 Agent 会话迁移过去；已有历史的会话沿用既有规则创建新的 workspace-bound session。Git root 识别改走 `git rev-parse --show-toplevel`，因此 `.git` 为文件的 worktree 根目录也能正确显示 branch、diff 和工作区变更摘要。
- **Codex-style Tool Activity Summary（1.70.0-rc1）** — Agent 工具调用的收起态不再默认展示底层 tool 名称、参数和命令，而是汇总成“已读取 N 个文件 / 已浏览 N 个目录 / 已搜索代码 / 已查看 Git 状态 / 已运行 N 条命令”等用户可读活动摘要。SwiftUI 实时 transcript 与 TextKit 历史 transcript 保持同一口径；展开后仍保留完整参数、输出、错误与审批来源，满足排查和审计。
- **Agent Memory Retrieval（1.67.0-rc2）** — Agent memory 现在会真正进入 Agent turn：每轮请求按最近用户消息、当前文件和选中文本检索相关全局/项目记忆，并把紧凑 memory context 注入 system prompt；回合结束后会从明确的长期偏好、项目规则和 must/prefer 语句中抽取候选记忆。记忆条目新增全局/项目作用域、项目 fingerprint、topics、confidence、敏感内容脱敏标记和 provenance；Settings → Memory 支持手动创建/编辑项目作用域 memory，并展示 topics、confidence、脱敏标记、来源、项目 fingerprint 和最后召回时间。维护周期会归档过期 transient memory、删除过期 archive，并合并重复记忆。
- **Composer Approval Modes（1.60.0-rc6）** — Agent composer 底部提供会话级审批模式选择：每次询问、智能审批、Workspace 访问。审批模式随 `AgentSession` 持久化；旧会话默认迁移为智能审批。每次询问会让 write-tier 工具回到逐次确认；智能审批沿用 SafeCommand、Always Allow、MCP trust 与 Goal mode 逻辑；Workspace 访问可自动放行当前 workspace 的命令与代理类写操作，但仍保留 danger confirm、Plan gate、路径越权保护和未信任 MCP 审批。
- **Plugin & Conversational Goal（1.60.0-rc7，1.76.0-rc1 self-check 强化）** — Agent composer 增加“插件”菜单，展示 plugin-cache skills 与 MCP servers；插件技能可直接附加到下一条消息。Goal 模式切换不再弹表单，首次开启后由 Agent 在对话里追问或归纳目标，并通过 `goal` fenced block 自动生成 Goal 卡；Goal 卡仍保留手动编辑入口。1.76.0-rc1 起，Goal 激活后每轮助手回复必须结尾做 Goal self-check，说明目标 complete / in progress / blocked，并始终输出 `goal-check` 块以同步清单变化或显式记录无变化。
- **Agent Queue Composer（1.60.0-rc8）** — Agent 忙碌时 composer 同时提供停止与排队发送；排队消息在 transcript 中使用更多菜单管理，可编辑、立即发送或删除。停止当前轮次或插队发送队列消息时，会同步关闭等待用户回答的 `ask_user` 卡，避免旧询问残留阻塞后续 turn。
- **Automations（1.60.0-rc9）** — 旧 Routines UI 对用户改名为“自动化”，侧栏空状态提供“每日简报 / 每周回顾 / 项目监控”模板；创建与编辑弹窗统一使用自动化文案和 String Catalog 本地化。底层 `AgentRoutine` / `agent-routines` JSON 路径保留，避免破坏已有定时任务。
- **Brand Cleanup（1.60.0-rc10）** — Settings → Local Agents 的接入状态标题不再暴露旧品牌名，统一显示 WillDeep；当前产品文档中面向用户的打开方式描述也同步改为 WillDeep。
- **App Icon（1.60.0-rc12）** — macOS App icon 使用旧版科技网格作为底部背景，上层叠加深度镜头抽象标识，强调 AI 聚焦、层次感与简洁科技气质；`AppIcon.appiconset` 与 `appicons/` 保持同步。
- **Agent Models Usage（1.60.0-rc13）** — Agent mode 新会话统计卡的 Models tab 不再复用概要格子，而是按 provider + 完整 model id 聚合会话内用量，显示输入/输出 token、缓存命中率、reasoning token 和估算费用。`AgentMessage` 新增 cached/cache-write/reasoning token 字段，四个 `AgentClient` 适配器会解析各自官方 usage 字段；`AgentSession` 同步记录 provider 快照，旧会话则用模型名前缀做 best-effort 归类。
- **Agent Terminology（1.60.0-rc18）** — 编辑器右上角进入 Agent mode 的短按钮中文从“代理”改为“智能体”，避免和网络代理 / proxy 语义混淆；tooltip 继续使用“Agent 模式”说明完整模式语义。
- **Settings Terminology（1.60.0-rc21）** — Settings 窗口标题固定为“Settings / 设置”；主模型服务商配置 tab 改名为“AI Providers / AI 服务商”，与“Local Agents / 本机 Agent”明确区分。
- **Credential Store（1.60.0-rc22）** — 新增统一 `AgentCredentialStore`，MCP 用户服务器的敏感 header/env 会在保存时自动转成 `keychain://` 引用并写入 macOS Keychain；运行 stdio/streamable-http MCP 时再解析注入真实值，列表和工具输出继续只显示脱敏值。Skill Marketplace 条目可声明凭据需求，安装时通过安全输入框写入 Keychain，并在 skill metadata 中记录环境变量到 Keychain 引用的映射。
- **Goal Status Bar（1.60.0-rc27）** — Goal 模式正在执行时，composer 上方会显示紧凑状态行，包含目标进行中标签、当前目标摘要与实时耗时；若同一轮产生文件改动，它会自然排在“文件已更改 / 审查”提示下方，避免用户只看到改动数量却不知道目标仍在跑。
- **Markdown Table Detail Window（1.61.0-rc1）** — Agent 聊天历史里的 Markdown 表格继续在主 transcript 中走低内存 TextKit 等宽文本 fallback，但表格区域可点击打开独立 `NSTableView` 窗口，以真实列、网格线、交替行背景和横向滚动查看完整表格，避免把 per-cell view 成本压回聊天主滚动路径。
- **AIPipe SDK Integration（1.62.0-rc1）** — 仓库通过 vendored git 源码方式集成 `smarterlog/iossdk` 的 iOS/macOS SDK，并把 `AIPipe` Objective-C 源码纳入 Xcode target；SwiftUI 入口使用 `@NSApplicationDelegateAdaptor` 注入 `WillDeepAppDelegate`，启动时从 `AIPIPE_API_KEY` / `AIPipeAPIKey` 读取 API key、从 `AIPIPE_ENDPOINT` / `AIPipeEndpoint` 读取 endpoint（默认 `https://17push.com/api/v1`），可选 `AIPIPE_TOPIC` / `AIPipeTopic` 设置 topic。未配置 API key 时 SDK 不初始化；退出路径会主动 `flush`，避免正常关闭时丢日志。真实 AIPipe key 不进入仓库，只能走环境变量或外部 Info.plist 注入。
- **Lightweight App Update Check（1.63.0-rc1）** — 非 App Store 分发路径新增启动时自动更新检查：客户端请求 `https://meta.niuwoai.com/willdeep/meta.json`，读取 `version`、`download_url` / `downloadURL`、可选 `release_notes_url` / `releaseNotesURL`、`minimum_system_version` / `minimumSystemVersion` 和 `notes`；当远端语义化版本高于当前 `CFBundleShortVersionString` 时，用 `NSAlert` 通知用户下载或查看发行说明。客户端只提示并打开下载链接，不静默下载、不自动安装；服务端元数据格式见 `docs/UPDATE_META.md`。
- **Goal Mode Retry & Task Clarity（1.63.0-rc2）** — Goal 模式遇到临时网络错误、上游超时、限流或 5xx 时会自动等待 3 秒重试，最多 5 次；底部任务行会区分“Agent 轮次仍在任务中”和“本轮已结束但后台任务仍在运行”，排队消息菜单的移除动作统一显示为“删除”。
- **Remote Runtime Form Polish（1.63.0-rc3）** — Settings → Runtimes 的 SSH / Daemon 输入控件改为带边框文本输入；SSH 端口可直接键入数字，identity file path 新建默认 `~/.ssh/id_rsa`，执行 ssh 前会展开 `~`。
- **Queue Stop & Compact Rows（1.63.0-rc4）** — Composer 中止当前输出后会立即发送队首排队消息；排队消息在 transcript 中合并为一个紧凑列表，每行右侧直接显示发送、删除、编辑图标按钮。
- **Global Agent Rules（1.64.0-rc1）** — Settings 新增 Rules 标签页，可启用/停用全局规则文件、选择任意 Markdown 路径并直接编辑保存。默认路径为 `~/.willdeep/CLAUDE.md`；每轮 Agent system prompt 会先注入全局规则，再注入当前仓库的 `AGENTS.md` / `CLAUDE.md` / README / product overview，让个人偏好跨项目生效，同时保留项目规则的更具体约束。
- **Agent Sandbox & Escalation（1.60.0-rc27）** — Agent 工具执行新增 Codex-style 沙箱策略：只读命令默认使用脱敏环境与临时 HOME，并在 macOS 可用时通过 `sandbox-exec` 禁止网络和越权写入；workspace-write 命令仍需审批，只允许 workspace / 临时目录写入；网络、凭据/macOS Keychain、系统路径和破坏性 shell 形态进入 escalated 模式。Goal mode 会自动放行 write 层动作，并额外允许通过公共 URL 校验的 `web_fetch` 网络读取；Workspace Access 仍不静默放行 escalated。工具卡展示 `_sandbox`、`_approval_reason`、`_prefix_rule`，执行结果写入 `~/Library/Application Support/WillDeep/AgentAudit/sandbox.jsonl` 并对 token/secret 脱敏。rc27 修正风险分级边界：forceful git 操作仍为 danger，workspace 外只读/重定向为普通 write 审批，`git -C <workspace>` 只读命令可回到 read 风险；1.65.0-rc3 起，公网 `curl` GET/HEAD 与 `ssh host "只读命令"` 也可降为 read 风险，POST/上传/输出文件/私网 URL/远端危险命令仍需审批或确认；1.65.0-rc4 起，`go build/test` 与常见 `yarn/npm/pnpm run dev/build/test/lint/typecheck` 作为低风险 workspace-write 自动放行。
- **Static Skill Marketplace（1.60.0-rc20）** — Settings → Skills 新增静态 Skill Marketplace 区域，首批内置 WillDeep 官方 skill 条目支持搜索、安装、更新和卸载；安装器将条目写入 `~/.codex/skills/<slug>/SKILL.md`，用 frontmatter 记录 marketplace id/version，并保护同名用户 skill 不被覆盖。rc20 扩展 PDF Design 与 Image Processing 条目，其中 Image Processing 会随安装写入 `scripts/process_image.py`，支持裁剪、缩放、格式转换、透明色处理、透明边裁切、画布填充与扁平化。安装后复用既有 `AgentSkillDirectory`，立即进入 Agent 工具、Settings 技能列表和 composer `@` 选择器。
- **Large workspace guardrails（1.60.0-rc17）** — Editor 文件树、Quick Open、跨文件夹查找替换、Agent 本地工具和远端 daemon 均跳过常见依赖/构建目录（如 `node_modules` / `.git` / `target` / `.gradle` / `.terraform` / `.dart_tool` / `DerivedData` / `Pods` / `vendor`），并对目录项、遍历节点数和搜索文件数设硬上限，避免打开或扫描大目录时内存暴涨。macOS deployment target 同步降为 14.6，便于在 Sonoma 14.6+ 运行。**1.60.0-rc15** 同步修复 chat history copy chrome 测试：代码块和消息 footer 的复制按钮现在按 attributed string 的 link / payload / hidden style 断言，不再依赖 SF Symbol 附件在 `.string` 中呈现为固定 glyph；background job lifecycle 测试改用带 `TERM` trap 的长跑样本，减少全量并发测试中的时序误报。
- **@MainActor isolation** — AppState 本身是 `@MainActor`，所有 `@Published` mutation 必须在主线程发生。runtime 的 hot 字段亦然，但 `AgentClient` 的 URLSession 流式回调跨线程时通过 `Task { @MainActor in ... }` 拥抱主线程。`AppState.deinit` 不能 cancel runtime——rc38 曾尝试 `MainActor.assumeIsolated` 但 Swift Testing 在非主线程 release 触发 precondition fail，rc41 回退；清理走 session 显式删除路径。
- **Per-provider concurrency cap** — 多 runtime 并发跑时，同一 provider 的活跃请求按 `AgentSettingsStore` 的 `concurrencyLimit`（默认 3，1–8 可调）FIFO 排队；不同 provider 互不阻塞。这样自动化集中触发也不会冲烂同一家 API 的速率。
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
- 10 处需同步更新：`Xedit.xcodeproj/project.pbxproj` 里 6 个 `MARKETING_VERSION` 块（debug / release × 三个 target）、`willdeep-agent/internal/agent/version.go`、`Help/WillDeep.help/Contents/Info.plist`、README version badge 与本文件顶部 `Current version` 一并同步。
- 每次版本变更必须同步在 `CHANGELOG.md` 顶部写一节、更新本文件头部的 `Current version` 字段。
- git commit 后建议打 `v{版本号}` tag 并推送 origin（`scripts/release.sh` 公证完成后会交互确认是否打 tag/push）。

## 国际化（i18n）

**当前状态：部分落地。** 项目已经引入 `Localizable.xcstrings`（Xcode 15+ String Catalog）和 `L10n` enum 强类型访问，覆盖一部分主窗口、Agent footer、空状态和本轮新增的 pasted-text 附件文案；仍有大量历史 SwiftUI 文案直接写死在视图中（混合中英文）。

CLAUDE.md §2 要求 React 部分必须走 i18n，但 WillDeep 是 SwiftUI macOS 应用，不在该条款约束范围内。即便如此，后续仍应继续把所有用户可见文案抽到 String Catalog（见 [ROADMAP.md](./ROADMAP.md) 阶段 5），至少保持 zh-Hans / en 双语。

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
- Install the `willdeep` command line tool from Settings into `~/.local/bin` and open files or folders from Terminal.
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
- Add selected editor text to the side Agent conversation from the editor context menu, or open the side Agent panel with that selection attached as a removable text chip for a follow-up question.
- Configure Agent providers from a tabbed Settings window, with built-in OpenAI-compatible presets for OpenAI, DashScope, DeepSeek, Kimi, Moonshot, Claude, and custom endpoints.
- Fetch Agent model IDs from provider `/models` endpoints and assign returned models to separate Flash and Pro slots in Settings. Agent routing can run cost-first through Auto/Flash or force Pro for stronger turns. API keys remain stored in Keychain.
- Review Agent-generated unified diff proposals in the Agent panel, then apply or reject them explicitly. Accepted patches are limited to existing files inside the current workspace and update open tabs plus Git status.
- Let the Agent call built-in workspace tools (`search_files`, `grep_files`, `read_file`, `list_directory`, `git_status`, `run_command`, `ask_user`) via OpenAI function-calling. `search_files` does literal text matching while `grep_files` supports full regular expressions plus an optional filename `include` glob (e.g. `*.swift`). Read-only tools run automatically; `run_command` requires per-call Allow/Deny approval, or an explicit Always Allow rule for matching command families such as `git push`; destructive commands additionally require typing `confirm` before running. `ask_user` lets the agent pause mid-turn and ask the user a clarifying question; when the answer is one of a small known set the model can pass `options` so the card renders clickable choice buttons (or checkboxes for `multi_select`), with a free-form text input still available as an escape hatch.
- Let the Agent discover built-in, user-created, and plugin Codex skills with `list_skills` and load a selected `SKILL.md` with `read_skill`, so specialized workflows can be pulled into context only when needed. Built-in skills are bundled from Alma under `BundledSkills`; user skills live in `~/.codex/skills`; plugin skills continue to come from `~/.codex/plugins/cache`.
- Configure SSH remote runtimes from Settings → Runtimes, bind Agent sessions to a remote workspace from the composer workspace picker, and run Agent file reads, search/grep, Git status, foreground/background shell commands, builds, tests, and delegated local-agent CLI calls on that remote host while keeping chat UI, approvals, and session persistence local.
- Let the Agent inspect configured MCP servers with `list_mcp_servers`, list one server's MCP tools with `list_mcp_tools`, and call a selected MCP tool with `call_mcp_tool`; server discovery merges App user MCP servers, Cursor `~/.cursor/mcp.json`, and Codex `~/.codex/config.toml`. Both stdio and Cursor-style `streamable-http` MCP transports are supported, with sensitive headers and environment values redacted before display; MCP tool calls still require approval.
- Automatically run conservatively parsed read-only `run_command` chains, such as workspace-relative or workspace-absolute `cd` prefixes followed by `git diff`, `ls`, `cat`, `rg`, or `grep`, plus workspace-safe `git -C ... diff`; commands that write, redirect, pipe, substitute, or move outside the workspace still require approval or confirmation. When no workspace is bound, `run_command` executes from the user's home directory. Shell commands inherit a supplemental macOS PATH with common Homebrew and local binary directories so tools such as `rg` remain available when WillDeep is launched from the GUI.
- Show the full `run_command` command text on approval and destructive-confirmation cards so the exact command is visible before the user allows it.
- Keep Agent tool-call rows compact and collapsed by default, separated from the preceding assistant output by a dedicated vertical gap, and collapse consecutive calls into low-emphasis expandable groups so long multi-step runs remain scannable. A lightweight current-turn activity summary covers explored paths, searches, run commands, and active file edits; longer command/path previews remain visible in the gray summary and full arguments, output, approval controls, and errors are available only after explicit expand controls.
- Switch the window into a dedicated Agent mode (Cmd+Shift+A) with a project-grouped session sidebar on the left and a wide chat pane on the right. Sessions persist as JSON under `~/Library/Application Support/WillDeep/agent-sessions/` and are grouped by workspace; the composer workspace picker migrates an empty active session in place, while existing conversations get a fresh session for the selected workspace. The empty-state dashboard summarizes recent usage and stretches its activity heatmap across the available stats card width.
- Render Agent chat history, transcript reader windows, and single-message reader windows with lightweight TextKit Markdown for headings, paragraphs, lists, quotes, syntax-highlighted code blocks, inline formatting, links, dividers, HTML details-as-code fallback, and pipe-table fallback while avoiding SwiftUI per-block transcript layout. The in-pane history keeps chat-style visual chrome through TextKit-drawn rounded bubbles, right-side hover-only user message columns with left-aligned body text, safe right padding, and pre-reserved low-contrast hover-time timestamp/copy controls, lighter full-width assistant cards with a gray star-style assistant mark, slightly inset syntax-highlighted code blocks with a little top breathing room plus clickable larger code-copy controls and 3-second success feedback, larger per-message copy footers, assistant elapsed/input/output token summaries with matching icon sizing, latest-assistant retry affordance, and collapsed low-emphasis tool-call groups that expand in place to show longer command/path/pattern arguments inside a padded gray group without overlapping adjacent user bubbles.
- Paste, drag-drop, or attach images directly in the Agent composer; staged images appear as removable thumbnails and, for supported multimodal providers, are sent inline as base64 `image_url` content parts in the request body.
- Paste large text blocks into the Agent composer as compact `.txt` attachments instead of expanding them inline in the chat bubble. The visible transcript shows a small filename/size chip, while provider requests, token estimates, queued messages, persistence, and message-copy payloads retain the full pasted text.
- Configure a separate Image Understanding provider with its own API key; for text-only Agent providers such as DeepSeek, multiple attached images are first described by that image-capable provider, then the generated description is appended to the user message before the main model runs.
- Send Agent-mode messages with Return, while Shift-Return, Option-Return, and Control-Return remain available for multiline composition.
- Queue follow-up messages while the agent is responding — additional sends become numbered "Queued" cards that auto-fire when the current turn ends. Each queued card can be edited back into the composer or promoted for immediate send; Stop does not drop the queue, and Clear Queue removes it explicitly.
- Show an inline "正在思考" activity divider while the Agent is waiting for the model to start responding or to continue after tool output. For providers that stream a separate reasoning trace (DashScope qwen3/qwq, DeepSeek-R1, Claude extended thinking), the divider grows a fixed two-line live preview showing the newest tail of the thinking text; the whole area — divider and preview — disappears as soon as the first answer token or tool call arrives.
- See the estimated context-window utilization in the chat header (≈ remaining tokens / model window) based on the actual next provider request shape, including system context, normalized history, collapsed tool results, images, and tool schemas. Switch the active session to a concrete model override from a picker fed by previously fetched model IDs, while the default path follows the configured Flash/Pro route. Agent mode's workspace-grouped session sidebar shows each session's last update as a compact relative timestamp such as `5m`, `3h`, or `2d`.
- Auto-approve safe Agent shell commands: a built-in allowlist runs read-only commands (cat, head, tail, ls, find -name, git diff/log/status, rg, grep, wc, file, …) immediately. Anything else can fall through to an LLM judge (using the current chat model) that returns YES/NO; only a confirmed YES auto-runs. Destructive patterns still require typing `confirm`. Toggle via Settings > Agent > Tool approval > Auto-approve safe commands; user-pinned "Always allow" signatures continue to work alongside.
- Reclaim context budget without losing state: a Compress button in the status bar (surfaces once usage crosses 50%) summarizes the older transcript into a single assistant message via the configured Flash model. The last few messages stay verbatim. Older `tool` results auto-collapse to a small placeholder in the request payload so long sessions don't blow up the prompt. Once usage crosses 75% the compression also runs automatically between turns — the status bar shows a `Compressing…` spinner and any queued message waits for compression to finish before dispatching.
- Show an inline transcript divider while context compression is running so the chat view explains the temporary pause instead of looking idle.
- Expand Agent provider errors to inspect the method, URL, provider, model, input message summary, redacted request body, HTTP status, and response body for debugging failed requests.
- Normalize Agent tool-call history before provider requests so stale or incomplete tool messages from older sessions do not cause OpenAI-compatible request errors.
- See current Agent worktree changes in a Codex-style edited-files card with clickable filenames, WillDeep new-window / default-app / Finder open options, per-file added/deleted line counts, total changed files, total line deltas, and a one-click local diff review sheet with copy support. The Agent composer also mirrors the active session workspace summary above the input area with changed-file count, total `+/-` lines, and the same diff review entry. Modified entries with no real diff or only `+0 -0` line stats are suppressed, and Agent turns compare against a start-of-turn git baseline so old uncommitted changes do not masquerade as files edited by the current run.
- Define Automations that fire on a schedule (interval / daily HH:MM / weekdays HH:MM / specific weekday HH:MM) and automatically start a brand-new Agent session with the automation prompt, bound to the selected workspace and optional model override. Automations are managed from a dedicated section in the Agent-mode sidebar (template buttons for Daily Brief / Weekly Review / Project Monitor, hover to enable/disable or run immediately, right-click for full menu) and edited in a sheet with name, prompt, workspace picker, model picker, schedule, and enabled switch. A 30s scheduler tick coalesces double-fires, catches up automations whose target time slipped past app sleep, and avoids interrupting a live conversation. Optional macOS notifications announce each run when the user has granted permission. Existing data persists as JSON under `~/Library/Application Support/WillDeep/agent-routines/`, one file per automation, for compatibility with the former Routine feature.
- Run multiple Agent sessions concurrently — each session owns its own runtime (messages, request task, tool waiter, composer draft, mode/plan/goal) and dispatches its own provider request, so switching away from a streaming session doesn't kill it; the outgoing turn keeps running in the background and the sidebar status dot pulses green while it works (orange when it's paused on a tool decision). Automations spawn background runtimes that don't yank the user's UI — they appear as new rows in the sidebar with their own status indicator. Concurrent dispatches are capped per-provider (default 3, user-tunable 1–8 in Settings → Agent → Concurrency) so a fleet of automations hitting the same provider queues FIFO instead of stomping the rate limit; different providers are isolated, so running 3 DashScope sessions never blocks an OpenAI session.
- Manage Agent memory from Settings → Memory, including feature enablement, automatic retrieval, query rewriting, retrieval limits, similarity threshold, automatic summaries, daily maintenance timing, transient/archive retention, tool model selection, embedding model selection, statistics, manual memory creation, text search, inline editing, archiving, restoration, deletion, clearing, and JSON snapshot export. Memory settings and records persist locally through UserDefaults; Agent turns now retrieve relevant global/project memories with a local hybrid scorer, inject them into the system prompt, track access counts, redact secret-shaped content on save, auto-extract durable candidate memories from explicit user/project rules, and merge duplicate entries during maintenance.
- Manage Agent skills from Settings → Skills, including a static Skill Marketplace for first-party installable skills, automatic skill extraction settings, minimum tool-call threshold, search, refresh, opening the user skill folder, creating new user skills, viewing skill bodies, and enabling/disabling individual built-in, user, marketplace-installed, or plugin skills. Disabled skills are hidden from Agent tools and the composer `@` picker while remaining visible in Settings for re-enabling.
- Manage MCP servers from Settings → MCP, including Cursor-like server rows, per-server enablement, tool-count refresh, creating and deleting App user servers, opening Cursor `mcp.json`, and clearing Authorization headers for App-managed servers.
- Preview Markdown and HTML beside the editor with richer lightweight block rendering for headings, lists, quotes, dividers, code, and common HTML content nodes.
- Read current file state from a compact status bar with cursor position, language, file size, and version.
- Reload when the active file has changed on disk outside WillDeep.
- Read selected character and line counts from the status bar when text is selected.
- See lightweight dirty gutter marks for lines changed since the last saved content.
- Highlight matching bracket pairs around the cursor for common code delimiters.
- Fold and expand detected code scopes from the line-number gutter without changing the underlying file content.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, shell/bash, YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, C#, and unified diff/patch files, with diff blocks showing GitHub-style red/green added and removed lines in editors, Markdown preview, and Agent chat code fences.
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
- Add optional provider-backed embeddings and LLM-assisted memory review on top of the current local hybrid retrieval/merge pipeline.
- Wire automatic skill extraction into completed conversations so repeated tool-heavy workflows can become user-reviewable skill drafts.

- Add line-number and search workflows without making the editor feel heavy.
- Refine keyboard-first tab workflows around unsaved-change prompts and bulk closing.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
