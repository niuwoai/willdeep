# 后续任务说明：Worker 模式提速（续 1.318.0-rc1）

> 写给接手的编码助手（Codex）。基线：`develop` @ 1.318.0-rc1（`06e1b88a`）。
> 背景与已完成部分见 `docs/REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md`，计时日志字段见 `docs/WORKER_TIMING_LOG.md`。
> 目标不变：**主 Agent 当大脑、Worker 干活，同时首字和整回合都不能比"主 Agent 自己干"慢。**

## 续写状态（1.319.0-rc1）

- A 已完成：连续的前台只读 `spawn_agent` 最多五路并发，工具结果按 staged 原序回填；后台和写入边界不变。
- B 已完成数据落点并抽样：计时行新增实际内联文件数/字符数。抽取 2026-08-28 至 2026-09-02 的 30 条前台运行，只有 3 条（10%）在第 1–2 轮以 `read_file` / `list_directory` 找文件，未达到 50% 的提示词强化阈值，因此没有改 schema、工种提示或并行 scout 提示。
- C 已完成本轮安全项：套餐状态只读缓存并后台刷新；裁判上限 8 秒并退 floor；两批 Git 捕获与提示组装重叠；共享配置按 mtime + 文件大小缓存。Git 超时与上一快照回退仍可结合真实 `preStreamSeconds` 长尾再决定，避免引入跨回合陈旧修订。
- D 已完成：历史确认后仅更新两条断言，生产代码未为旧结构倒车。
- E 未到数据窗口：最早于 **2026-09-17** 读取两周日志再做三个产品决定。
- F 保持跨仓库独立任务，不混入本次 Xedit 提交。
- G 本轮完成判路日志升级；scout 卡片与懒预热驻留说明继续以数据/产品需要为门槛，且不得破坏下文三条不变量。

## 0. 开工前必读的仓库规则

- 从 `develop` 拉分支（`git checkout develop && git pull && git checkout -b feat/xxx`），不要在 `develop` / `main` 上直接改。每个任务一个分支一个 PR，不混 feat + fix。
- 改完必须：跑单测 → 提交 → 合回 `develop`。单测用 `ruby scripts/run_tests_fast.rb -only-testing:XeditTests/<Suite>`，全量本地会被网络用例卡死，交给 CI。
- 每次代码改动都要提版本号 + 写 `CHANGELOG.md`。功能新增提 minor 并重置为 `-rc1`，bugfix 只递增 rc。用 `ruby scripts/bump_version.rb <old> <new>`，跑完看 `git diff`，再跑 `ruby scripts/version_consistency.rb`。CHANGELOG 顶部新条目要手写，头部那行"当前文件保留最新版本（X 至 …）"也要改。
- 用户可见文案走 `L10n` + `Xedit/Localizable.xcstrings`，五种语言（en / zh-Hans / ja / es / fr）都要有。**xcstrings 只能文本级插入，绝对不能 `json.dump` 回写**（会重排全文件撞红测试）。新 key 按字母序插到正确位置，改完用 `git diff --numstat` 确认除有意修改外零删除，`ruby scripts/i18n_coverage_guard.rb` 要 pass。
- 新增 Swift 文件不用改 pbxproj（工程用 file-system-synchronized group）。
- 不用 heredoc / echo 重定向生成文件，用编辑器能力写文件。
- 并发会话共用一个工作树，提交时 `git add <精确文件>`，勿 `git add -A`。
- 本机已知存量红：`AgentProviderLibraryTests` 两条（见任务 D），不是你的锅，但别顺手改代码去迎合断言。
- CI 可能被 org 账单拦住（Actions 秒挂 0 steps），那不是代码问题。

## 1. 现状一句话

首字之前，默认安装下 Worker 判路层已经是零 await：关键词路由同步、模型补判只在 generalist 兜底且本地模型已驻留时才问、串行预检默认关、并行 scout 与主模型请求同时起跑。剩下的首字预算大头在 some.im 托管路径和 git 子进程上（任务 C）。Worker 派出去之后的真实成本是串行往返（任务 A、B）。这些都还没有数据，所以任务 E 是所有决策的前提。

## 2. 任务清单（按优先级）

### 任务 A：同一轮多个只读 `spawn_agent` 并行执行

**问题。** 主模型在一轮里发出多个 `spawn_agent`（比如同时派 scout 查两个模块），现在 `AppStateAgentLoop.swift` 的 `for (stagedIndex, staged) in stagedCalls.enumerated()`（约 :2251）逐个 `await`，前台 Worker 一个跑完才跑下一个。`parallelReadBatchToolNames`（约 :2302）只并行普通读工具，不含 `spawn_agent`。

**要做的。**
- 同一轮里、profile 非写入（`!profile.requiresWriteAccess`）、未指定 `run_in_background` 的多个 `spawn_agent`，用 `withTaskGroup` 并发执行 `executeSpawnAgentToolCall`（`AppStateAgentToolMessages.swift:67`），每个仍然各自 `appendToolMessage` 回自己的 `tool_call_id`。
- 写入类 Worker 一轮最多一个，仍串行（它们持有编辑锁和回合级审批）。
- 并发上限沿用 `AgentSubagentRegistry.maxConcurrentPerRuntime = 5`（`AgentSubagents.swift:170`）。
- 注意工具结果顺序：OpenAI / Anthropic 都要求每个 tool_call 都有对应结果，顺序不强制；但 `runtime.messages` 里的追加顺序会影响缓存前缀，按 staged 顺序落消息、只并行执行即可（先收集结果再顺序 append）。

**验收。** 两个只读 spawn 的总耗时 ≈ max 而不是 sum（用 `worker-timing.jsonl` 里同一 `turnID` 的两条 `worker_run` 的 `startedAt` 重叠证明）；写入 Worker 与只读 Worker 混排时写入的仍串行；`/no-subagent` 轮次行为不变。

**测试。** 给 `executeSpawnAgentToolCall` 注入可控的 `RunOperation`（`AgentSubagents.swift:151-163` 已可注入）模拟两个各睡 300ms 的 Worker，断言总时长 < 500ms 且两个 tool message 都在。

### 任务 B：Worker 开场消息真的带上上下文了吗

**问题。** 任务包机制已经存在：`composedTaskPacketPrompt`（`AppStateAgentToolMessages.swift:993`）会把 `packet.inlineFiles` 的内容读进 Worker 开场消息，预算按 32K 窗口算（`AgentSubagentTaskPacket.swift:48`）。但没有数据说明主模型派活时**有没有填** `read_files`，以及 Worker 有多少轮花在重新找文件上。

**要做的。**
- 在 `worker_run` 计时行里补两个字段：`inlinedFiles`（开场消息内联了几个文件）、`inlinedCharacters`。写入点在 `persist(...)`（`AppStateAgentToolMessages.swift` 约 :619）附近，任务包信息在同一作用域。
- 用 `subagent-transcripts/*.json` 抽 30 条前台 Worker 运行，统计"第 1–2 轮是不是在 `read_file` / `list_directory`"。如果 > 50% 的运行开场就在找文件，在 `spawn_agent` 的 schema 说明和工种提示词里强化"必须填 `read_files`"，并把 `<runtime-route>` 引导段里的措辞改成明确要求。
- 并行 scout 目前只拿到请求原文（`AppState.preflightPrompt`），没有任务包。可以考虑把路由判决命中的关键词、当前工作区最近编辑过的文件（`runtime.session.agentEditedPaths`）作为提示塞进 scout 的开场消息，让它少走一轮。

**验收。** 新字段落盘；抽样结论写进本文档或 review 文档；若改了提示词，跑 `AgentContextBuilderPromptTests` 看提示词快照哈希是否要重录（有三档哈希重录流程，见 `docs/` 与 CHANGELOG 历史）。

### 任务 C：把首字前剩余的阻塞挪开

都在 `AppStateAgentLoop.swift`，都在 `client.streamChat` 之前。只对命中的用户生效，但命中时比整套 Worker 判路都贵。

1. **some.im 套餐状态刷新**（约 :625，`refreshedSomeIMCodingPlanStatusIfNeeded().isActiveNow`）。托管会话每 10 分钟一次控制面 HTTPS GET，走 180s 请求超时。改成：回合开始只读缓存（哪怕过期），刷新放到后台定时器（`startSomeIMCodingPlanRefreshTimer` 已存在，`AppState.swift` 约 :853）或回合结束后触发；如果一定要同步刷新，超时压到 3s。
2. **托管裁判**（约 :626，`SomeIMManagedRouting.route`）。远程非流式调用，`AgentInjectionDefense.judgeTimeout = 35s`（`AgentInjectionDefense.swift:566`）。裁判专用超时压到 5–8s，超时退到 `floor` 档，不要让首字等 35 秒。
3. **git 子进程**：`loadAgentWorktreeSnapshot`（约 :717）和 `AgentWorkspaceRevisionCapture.capture`（约 :961，每轮）。同一回合内缓存；或者与提示词组装并行（`async let`）；给一个 2s 上限，超时用上一次的快照。
4. **`AgentSharedRuntimeConfig.load()`**（`AgentSharedRuntimeConfig.swift:54`）现在每回合在 MainActor 同步读 config.toml 三次（路由默认参数、预检门禁、并行 scout 门禁）。按 mtime 缓存一份。

**验收。** 用 `worker-timing.jsonl` 的 `turn` 行对比改前改后的 `preStreamSeconds` 中位数（some.im 托管会话单独看）。每一项都要有单测：缓存命中不发请求、超时退回缓存值、裁判超时退 floor。

### 任务 D：修两条存量红（改断言，不改代码）

`XeditTests/AgentProviderLibraryTests.swift`：
- `someIMPresetDefaultsToTheStandardTierForChat`（约 :655）断言默认模型为 `glm-5`，而 some.im 预设已改为 `someim-auto-flash`（`AgentManagedRoutingModels.swift:198`）。先 `git log -S` 查清是预设有意改的还是回归；如果是有意的，改断言并把注释里"flash/default slot is the 256K M tier"改准。
- `requestEntryPointsRepairSomeIMCredentials`（约 :874）要求"凭据修复 → 取当轮配置"两行片段在 `AppStateAgentLoop.swift` 出现两次，现在只出现一次。查这是入口被合并了还是真少了一处修复调用；前者改断言，后者才补代码。

这是 bugfix，只递增 rc。

### 任务 E：两周后拿数据做三个决定

数据源：`~/Library/Application Support/WillDeep/AgentAudit/worker-timing.jsonl`（`jq` 用法见 `docs/WORKER_TIMING_LOG.md`）。

1. **并行 scout 默认开还是收紧。** 看 `source == "speculativeScout"` 的 `status` 分布：`delivered` 占比低于 30%，或者 `delivered` 的回合 `totalSeconds` 并不比同路由无 scout 的回合短，就把触发条件收紧到 scout / git_detective / log_inspector 三个工种，或改成默认关。
2. **判路模型去留。** 看 `turn` 行里 `routeProfileID == "generalist"` 的占比；很低就删掉 `refineRouteDecisionWithModelIfNeeded` 整条模型路径和 `AgentLocalModelResidency` 的懒预热分支，只保留"启动常驻"开关。
3. **串行预检是否以并行形态回归写入路由。** 看 `routeProfileID in (editor, implementer)` 的回合里主模型前几轮是不是在读文件；是的话给写入路由也开并行 scout（`speculativeScoutProfileID` 里去掉 `autoDispatchEligible` 的限制，改为读 `preflightProfileID`），并加独立开关。

产出是一段写进 `docs/REVIEW_*.md` 的结论 + 对应的代码改动，不要只改 memory。

### 任务 F：willdeep-rs 同名配置键

`~/Sites/willdeep-rs` 侧实现 `agent.speculative_scout`（语义见 `docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md` §6 表格），并在 rs 的 `docs/` 引用 Xedit 这份文档。两端缺省都是开。跨仓库任务，单独排期。

### 任务 G：小项

- `AppStateAgentWorkerRouting.swift` 的 `workerRoutingLog` 三处 `.info` 改 `.notice`，否则统一日志查不到判路事件。
- 并行 scout 的卡片现在没绑 `subagentRunID`，舰队面板看不到它；如果需要可见，给 `AgentSubagentLiveActivity` 加一条不依赖 registry 的路径，但**不要**为了可见把它改回 registry 后台运行（原因见 `AppStateAgentSpeculativeScout.swift` 文件头注释）。
- `AgentLocalModelResidency` 的懒预热用 `keep_alive=10m`，判路请求本身走 `/v1/chat/completions` 不带 keep_alive，会把驻留重置回 5 分钟；如果不开常驻开关，实际驻留窗口比文案短。要么在设置文案里说清楚，要么判路请求后补一次 keep_alive。

## 3. 关键文件索引

| 文件 | 作用 |
|---|---|
| `Xedit/AppStateAgentLoop.swift` | 回合主循环；派发（`dispatchAgentMessage`）、首字前 await、回合结束 defer（`finalizeTurnTiming`）都在这 |
| `Xedit/AppStateAgentSpeculativeScout.swift` | 并行 scout 全部逻辑 |
| `Xedit/AppStateAgentReadOnlyPreflight.swift` | 串行预检（显式开启才跑） |
| `Xedit/AppStateAgentWorkerRouting.swift` / `AgentWorkerRoutingModel.swift` / `AgentRequestRouter.swift` | 关键词路由与本地模型补判 |
| `Xedit/AgentLocalModelResidency.swift` | Ollama 探针、懒预热、启动常驻守护者 |
| `Xedit/AgentWorkerTimingLog.swift` | 计时 JSONL 写入与记录类型 |
| `Xedit/AppStateAgentToolMessages.swift` | `spawn_agent` 执行、任务包渲染、前台 Worker 计时写入 |
| `Xedit/AgentSubagents.swift` | Worker runner 与 registry（后台运行、取消、pending report） |
| `Xedit/AgentSharedRuntimeConfig.swift` | `~/.willdeep/config.toml` 的 `[agent]` 段 |
| `XeditTests/AgentSpeculativeScoutTests.swift` 等 | 对应测试 |

## 4. 三条不变量，改任何东西前先对一遍

1. **首字之前不允许出现任何 Worker 的 await。** 要么同步零网络，要么真并行。
2. **投机型 Worker 不进后台唤醒通道。** registry 的 `pendingReports`、内核事件、槽位释放扫描三条路都会在回合结束后再起一轮主模型。回合内有效、过期即弃的东西一律由回合自持。
3. **`/no-subagent` 是硬边界。** 任何自动派工（预检、并行 scout、失败命令修复、未来的并行 spawn）都要先看 `runtime.currentTurnDelegationPolicy != .forbidden`。
