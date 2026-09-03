# 审查记录：Worker 判路与首字延迟（2026-09-03，1.317.0-rc7 / rc8）

> 范围：`05280b8c fix(agent): honor full access and reduce routing latency`（rc7 + rc8 合并提交，已合入 develop/main）。
> 方法：逐文件读 diff；追溯相关行为的引入提交；在 main（rc8）上重跑 5 个定向测试套件；扫描本机落盘数据与统一日志；对照 Codex 给出的五条调整建议。
> 结论先行：**方向正确，rc8 已落地其中四条；第三条（预检并行、工具边界注入）没有做，只是把预检关掉了。** 另外找到一处比判路更大的慢因（09-02 引入、rc7 修掉），以及 rc8 新代码的 4 个小问题。

## 1. 对 Codex 五条建议的逐条核对

| Codex 建议 | rc8 现状 | 评价 |
| --- | --- | --- |
| 没启用本地辅助模型时，不同步调用远程模型做判路 | 做到了，而且更进一步：本地模型冷态也不调远程，`workerRoutingConfigurationCandidates(fallback:)` 整个删掉 | 正确。远程判路每次 1.3–2.0s 且计费，收益不成比例 |
| 默认只做零成本关键词路由 | 做到了。`shouldConsultModel` 收窄到"置信度 < 86 且 profile == generalist"，implementer(78) 兜底不再问模型 | 正确 |
| 自动预检不阻塞首字，可并行，结果在工具边界注入 | **没做**。只是把 `auto_dispatch_read_only` 缺省从 true 翻成 false | 见 §4，这是保住"大脑 + Worker"模式又不慢的关键一步 |
| 简单任务主 Agent 直接做；显式 `@Worker`、复杂检索、真并行才派 | 做到了。`enforcesDelegatedExecution(for:)` 只对点名、`/subagent`、ops_runner 硬闸，其余改成建议性 steering | 正确 |
| 自动编码流水线保留，只用于边界清晰、确能省主模型工作的任务 | 流水线代码保留，但它的唯一入口是预检产出的 coding plan；预检默认关 = 流水线默认不可达 | 逻辑上没错，等于暂时下线。要不要回来取决于 §4 的并行方案 |

## 2. 一个比判路更大的慢因（已在 rc7 修掉，但值得知道）

- 2026-09-02 14:32 `47749a02 feat(agent): add five-worker fleet and unified approval badge` 引入了父会话侧的 `resolveSubagentToolApproval`。
- 从那时到 09-03 16:01 rc7 之前：非严格只读工种（implementer / editor / generalist 等）的**每一条 read 档 `run_command`（sed / grep / ls / git log …）都会在父会话生成一张 `pendingApproval` 卡并阻塞等人点**。子端 `AgentSubagents.swift` 无条件把所有命令交父会话审核；父端对 `.read` 走 `autoApprovalSource`，而该函数对非 write 直接返回 nil，于是落到人工。
- 这不只影响"完全访问"，**所有审批档位都中招**（完全访问下 `fullAccessApprovalSource` 对 `.read` 同样返回 nil）。CHANGELOG rc7 把它描述成"完全访问模式下仍反复弹审批"，范围写窄了。
- 一个 Worker 跑 10 次 grep 就要点 10 次，这基本能解释"改成多 Worker 之后速度慢了"里最痛的那部分。rc7 在子端（`shouldRequestParentCommandReview`）和父端（`guard risk != .read`）两头都补上了，修法正确。

建议：CHANGELOG rc7 的措辞补一句"影响全部审批档位"，避免以后排查时被误导。

## 3. rc8 新代码的问题（按严重度）

### 3.1 判路模型在本机实际上已经"名存实亡"（中）

触发条件叠加起来极窄：

1. 只有 generalist 兜底（置信度 70）才问模型；
2. 只有 Ollama 已经把模型驻留在内存里才问；
3. 冷态时才**开始**后台预热（`keep_alive 10m`），本轮直接放弃。

也就是说第一次含糊请求永远拿不到模型判决，只有 10 分钟内再来一次含糊请求才会用上。本机实测 `curl 127.0.0.1:11434/api/ps` 返回 `{"models":[]}`，即当前就是冷的；而判路请求本身走 `/v1/chat/completions`，不带 keep_alive，Ollama 默认 5 分钟就会卸载，实际驻留窗口比设置页文案说的还短。

本机设置：本地加速已开、`preferForWorkerRouting = true`、模型 `gemma4:e4b-it-qat`、`http://127.0.0.1:11434/v1`。

建议二选一：

- 开着这个开关就在 App 启动、会话窗口激活时主动预热并每 8 分钟续一次 keep_alive；
- 或者干脆承认这条路径收益太小，默认关掉 `preferForWorkerRouting`，只留关键词。

顺带一提：`docs`/memory 里做过的本地路由基准结论是 e2b 更适合判路，而这里复用的是 summaryModel（e4b，thinking 关不掉会慢 15–20 倍、偶发空回复）。不是本次改动引入，但和"判路模型基本不起作用"是同一件事。

### 3.2 探针和预热没走 `loopbackSession()`（低-中）

`AgentLocalModelRoutingWarmup` 的 `/api/ps` 探针和 `/api/generate` 预热都用裸 `URLSessionConfiguration.ephemeral`，会遵循系统代理。仓库里已有 `AgentNetworkSupport.loopbackSession()`，注释写明就是因为系统代理吞过 127.0.0.1 流量（移动网关健康探针卡在 Starting）。

本机现状：系统代理 127.0.0.1:7890 开着，实测 Clash 会正常转发到 11434（200，1ms），所以今天没有真的坏。但换一个不转发 loopback 的代理，探针会 350ms 超时 → 永远"冷" → 后台预热也走代理失败 → 每一次 generalist 兜底白等 350ms 且模型永远用不上。修法很便宜：两处 session 换成 `loopbackSession()` 派生（保留 0.35s / 120s 超时）。

另外每次探针 `URLSession(configuration:)` 新建后不 `finishTasksAndInvalidate()`，是已知的泄漏模式；仓库其他地方也这么写，属于历史欠账，不单独算 rc8 的账。

### 3.3 Ollama 没起来时没有负缓存（低）

本地加速开着但 Ollama 进程没跑：每一次 generalist 兜底都要吃满 350ms 探针超时，再起一次注定失败的后台预热。建议记一个"上次探针失败时间"，60 秒内直接跳过。

### 3.4 非 localhost / 非 Ollama 的本地模型被静默禁用（低）

`ollamaEndpoint` 只接受 localhost / 127.0.0.1 / ::1。局域网 Ollama、LM Studio、MLX 这类 OpenAI 兼容端点会得到 nil → `isWarm == false` → 永远不问模型，但设置页开关看起来还是开着的。CHANGELOG 写了"只使用已驻留的本地 Ollama 模型"，算有交代；设置页 hint 最好也点明"仅限本机 Ollama"。

### 3.5 其他核对项（无问题）

- `refineRouteDecisionWithModelIfNeeded` 读 `runtime.currentTurnDelegationPolicy`，该值在 `dispatchAgentMessage` 第 52 行先于路由决策写入，顺序正确。
- `AgentWorkerRouteGuard` 唯一调用点已传入 per-turn policy；`Decision.steering` 兼容属性只剩测试在用。
- 完全访问对 Worker danger 档的自动批准复用 `fullAccessApprovalSource`，恶意命令黑名单、`change_workspace`、会话管理、不信任 MCP、环境信任声明五道硬闸都还在。
- `.read` 提前放行放在 `isUnattendedDispatchTask` 之前，调度任务里的只读命令从"拒绝"变成"放行"，是顺手修正而非回归。
- i18n：`settings.local-model.worker-routing-hint` 五种语言（en / zh-Hans / ja / es / fr）全部更新，与 `knownRegions` 一致。
- 单测：在 main（rc8）本地重跑 `AgentHybridWorkerRoutingTests`、`AgentRequestRouterTests`、`AgentWorkerRoutingModelTests`、`AgentReadOnlyPreflightTests`、`AgentApprovalLifecycleTests`，**59 项 / 5 套件全部通过**（CHANGELOG 写的 74 项应包含另外的契约套件，不矛盾）。`AgentLocalModelRoutingWarmup` 这个 actor 本身没有测试覆盖（冷→预热→去重→完成），只测了纯函数。
- `AgentSharedRuntimeConfig.load()` 每回合在 MainActor 上同步读两次 config.toml（路由默认参数 + 预检门禁）。量级微小，但在首字路径上，可按 mtime 缓存。

## 4. 怎样既保留"主 Agent 当大脑、外派 Worker"，又不慢

先说三条原则，再说具体做法。

**原则 A：用户与主模型首字之间不允许出现任何 Worker。** 首字之前只允许同步、零网络的工作（关键词路由）；其余要么并行，要么挪到工具边界之后。
**原则 B：派不派是大脑在工具边界做的决定，宿主只给便宜的提示，不再做"前置阶段"。**
**原则 C：Worker 只有在并行时才可能让整体变快；串行 Worker 永远是纯加法。** 所以要投入的是"后台/并行/投机执行"，而不是"更聪明的前置判路"。

### 4.1 P0：先量出来，再吵

- 现在没有一条端到端的"提交 → 请求发出 → 首字 → 首个工具边界 → 回合结束"时间线。rc6 的请求分析只给判路那一次调用计时；`worker-routing` 日志是 `.info` 级，统一日志不落盘（`/usr/bin/log show --last 2d` 该 category 为空）；本机 291 个会话侧车里 `auxiliaryModelRequests` / `hostWorkerRuns` 全是 0（rc6 今天 13:35 才加，没数据是正常的）。
- 建议：给每条 assistant message 记 `submittedAt / requestSentAt / firstTokenAt / firstToolBoundaryAt / finishedAt`，并把首字前每个 await 单独打点（判路补判、预检、流水线、some.im 套餐状态刷新、托管裁判、git 快照）。判路日志升到 `.notice`。有了这个，"多 Worker 慢了多少、慢在哪"才是数字而不是体感。

### 4.2 P0：投机并行 scout（Codex 第三条的正确做法）

- 对高置信只读路由（scout / reader / git_detective / log_inspector），在**发出主模型请求的同时**启动只读 Worker，而不是之前。主模型立刻开始流式输出。
- Worker 报告在**首个工具边界**以 `<subagent-report>` 系统消息注入——这套机制已经存在：`agentSubagentRegistry.startBackground` + 每轮开头 drain `subagentReportNotice`。只需要在 dispatch 时加一个"自动后台 spawn"，以及回合结束时的取消钩子。
- 若主模型在 Worker 回来前就结束了回合，取消 Worker（或丢弃报告）。投机 scout 必须有**墙钟上限**（建议 45s）和轮次上限（建议 4），现在预检/流水线完全没有墙钟上限（只有 12 轮的轮次上限）。
- 写入类工种天然不能后台（文件锁和审批绑定在回合上），这条只对只读工种生效。这也回答了 08-24 把预检默认打开的初衷——scout/reader 当时 0 次运行是因为没有确定性入口。投机并行既保住确定性入口，又不碰首字。

### 4.3 P0：判路模型要么主动预热，要么退役

见 §3.1。实现上：开关打开 → App 启动和会话激活时预热（走 `loopbackSession()`），Ollama 掉线做 60 秒负缓存。如果一个月后数据显示 generalist 兜底占比很低，直接退役这条模型路径，省掉一整套 actor。

### 4.4 P1：让"真的派出去"这件事本身变便宜

多 Worker 的真实成本是串行往返：主模型一轮 → spawn → Worker 跑 N 轮 → 报告 → 主模型再一轮。能压的地方：

- **任务包预装上下文。** 大脑派任务时把 `read_files` 的相关片段直接放进任务包，Worker 不用再花 3–5 轮重新找文件。需要确认 runner 现在是只把路径列表给 Worker 还是把内容也带上；如果只是路径，这是最大的一块浪费。
- **只读 spawn 并行扇出。** 现在 `stagedCalls` 逐个 await，`parallelReadBatchToolNames` 只并行普通读工具，不含 `spawn_agent`。同一轮里多个只读工种的 spawn 应当自动并行（加入并行批，或自动升级为后台）。写入工种一轮最多一个。
- **小任务跳过 verifier / reviewer 阶段**；按档位限制 Worker 轮数；scout / reader 固定用最快的基础档模型（三档配置已经有了）。
- 进度已经能实时显示在状态条和舰队面板，这块不缺。

### 4.5 P1：首字预算现在的大头其实不在 Worker

按 rc8 之后的代码，默认安装（本地模型关、无 config.toml）判路层在首字前是零 await。真正还卡在首字前的是：

1. `refreshedSomeIMCodingPlanStatusIfNeeded`（`AppStateAgentLoop.swift:588`）：some.im 托管会话每 10 分钟一次控制面 HTTPS GET，走 180s 请求超时，只是为了选模型别名。应改成后台定时刷新、回合开始只读缓存、超时压到 3s。
2. 托管裁判 `SomeIMManagedRouting.route`（`:589`）：远程非流式调用，35s 超时，每个托管回合首字前都跑一次。至少压到 5–8s 并退到 floor 档。
3. `compressBeforeManagedEscalationIfNeeded`（`:633`）：跨档时整次压缩调用，无上限。
4. 两批 git 子进程（`loadAgentWorktreeSnapshot :680`、`AgentWorkspaceRevisionCapture.capture :917`）：都 await、都无上限、随工作区体积增长。可缓存到回合级，或与提示词组装并行。
5. config.toml 两次同步读（§3.5）。

如果用户主要用 some.im 托管路由，1 和 2 对首字的影响比整套 Worker 判路都大，建议放进下一个 rc。

### 4.6 P2：把"什么时候值得派"写成可执行的规则

rc8 的建议性 steering 已经写了"独立有界、避免重复上下文、可并行才派"。可以再具体成大脑能照做的经验法则：

- 预计只读工具调用 ≥ 6 次，或需要隔离大体量输出（日志、构建输出）→ 派只读工种；
- 有 ≥ 2 个互不依赖的子任务 → 并行派；
- 显式 `@Worker` / `/subagent` / ops 路由 → 必派（现有硬闸）；
- 其余一律自己做。

## 5. 后续处理（1.318.0-rc1，同日）

- §2 CHANGELOG rc7 措辞已放宽为"全部审批档位"。
- §3.2 探针与预热改走 `AgentNetworkSupport.loopbackSession()`；§3.3 加了 60 秒不可达负缓存；§3.1 新增"启动 WillDeep 时预热 LLM 模型并常驻内存"开关（`AgentLocalModelResidencyKeeper`，keep_alive=-1，每 4 分钟续一次）；§3.4 设置页文案注明仅支持本机 Ollama。
- §4.2 并行 scout 已实现（`AppStateAgentSpeculativeScout.swift`）：与主模型首个请求并行、工具边界注入、回合结束取消/丢弃、4 轮 / 45 秒上限、`/no-subagent` 生效、共享配置 `agent.speculative_scout`。刻意不走 registry 后台通道，避免回合后唤醒。
- §4.1 端到端计时落到本地 `AgentAudit/worker-timing.jsonl`（见 `docs/WORKER_TIMING_LOG.md`）。
- 未做：§4.4 的任务包预装上下文与同轮多只读 spawn 并行；§4.5 的 some.im 套餐状态刷新、托管裁判超时、git 子进程缓存。

## 6. 原建议的后续动作（保留）

1. rc9：§3.2 换 `loopbackSession()`、§3.3 负缓存、§3.1 启动预热或默认关、CHANGELOG rc7 措辞修正。都很小。
2. 下一个 minor：§4.1 端到端计时 + §4.2 投机并行 scout（复用后台 Worker 机制）+ §4.5 的 1、2 两项。
3. 拿到两周数据后再决定：判路模型去留、预检是否以"并行投机"形态默认回归、自动编码流水线是否重新接入。

## 7. 续写落地（1.319.0-rc1，同日）

- 同一模型轮连续的前台只读 `spawn_agent` 已改为最多五路并发执行，工具消息等待全部结束后按模型原始顺序写回；后台与写入 Worker 仍是批次边界，`/no-subagent` 判定仍在收集前完成。两个各 300ms 的可控执行在 0.308 秒内完成。
- 前台 Worker 计时新增 `inlinedFiles` / `inlinedCharacters`，记录经过 24K 字符预算裁剪后真正进入开场消息的文件量。抽取本机 30 条前台运行（2026-08-28 至 2026-09-02），第 1–2 轮以 `read_file` / `list_directory` 重新找文件的只有 3 条（10%）；低于 50% 门槛，本次不扩大提示词或 scout 上下文。
- some.im 套餐过期不再阻塞回合：当前回合采用缓存值并异步刷新；托管裁判使用独立 8 秒上限，超时按 floor 回退。回合基线与每轮修订捕获分别和内存读取、提示组装并行；共享运行时配置按 mtime 与文件大小缓存。
- 两条 `AgentProviderLibraryTests` 存量红经历史核对确认均为断言陈旧：默认模型采用 `someim-auto-flash` 是有意变更，凭据修复入口在 durable runtime kernel 合并为单一路径。本次只更新断言。
- 定向验证：并行 Worker 1 项通过；Worker 计时、共享配置、托管路由、provider library、并行 scout、串行预检共 88 项通过。两周决策窗口最早为 2026-09-17；跨仓库 `willdeep-rs` 配置键保持独立排期。
