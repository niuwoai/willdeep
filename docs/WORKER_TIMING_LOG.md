# Worker 计时日志（`worker-timing.jsonl`）

> 自 1.318.0-rc1 起。位置：`~/Library/Application Support/WillDeep/AgentAudit/worker-timing.jsonl`，
> 与 `judge.jsonl` / `sandbox.jsonl` 同目录。达到 16 MB 时整文件挪成 `worker-timing.1.jsonl` 再新建（只保留一代）。

## 为什么要有它

会话侧车（`agent-sessions/*.json` 与 `usage-v1/`）记的是按会话归档的用量，会随会话删除一起消失，
且每次都整文件重写。要回答"改成多 Worker 之后一个回合到底慢了多少、慢在派发前还是派发后"，
需要一份跨会话、只追加、能直接 `tail` / `grep` / 丢进 notebook 的平面文件。

不记任何提示词或输出正文，只有标识、时间戳、计数和模型名。

## 记录种类

每行一个 JSON 对象，`kind` 区分两类，键按字母序排列，时间为 ISO 8601。

### `worker_run`：每个 Worker 运行一行

| 字段 | 含义 |
|---|---|
| `runID` / `sessionID` / `userMessageID` | 运行、会话、触发它的用户消息 |
| `profileID` | 工种（scout / reader / implementer …） |
| `source` | 谁发起的：`modelSpawn`（主模型前台 `spawn_agent`）、`backgroundSpawn`（`run_in_background`）、`requestPreflight`（串行预检）、`speculativeScout`（并行 scout）、`failedCommandRepair`、`automaticCoding*`、`codingPlanCacheHit` |
| `status` | 终态。前台/后台 spawn 为 `completed` / `failed` / `cancelled`；宿主发起的为 `succeeded` / `failed` / `denied`；并行 scout 额外有 `delivered` / `dropped` / `timedOut` |
| `requestedAt` / `startedAt` / `finishedAt` | 请求、开跑、结束 |
| `queueSeconds` | `startedAt - requestedAt`，卡在审批或 provider 槽上的时间 |
| `runSeconds` | `finishedAt - startedAt`，Worker 自己的墙钟 |
| `rounds` / `toolInvocations` | 模型轮次与工具调用数 |
| `inlinedFiles` / `inlinedCharacters` | 仅前台 `modelSpawn`：任务包在 Worker 开场消息里实际内联的文件数与字符数；受总字符预算裁剪后的真实值，不是请求里的路径数 |
| `promptTokens` / `completionTokens` / `totalTokens` | 用量 |
| `acceptedOutput` | 报告是否被采纳（并行 scout 交付即视为采纳） |
| `deliveredAtToolBoundary` | 仅并行 scout：报告是否在回合结束前赶上了某个工具边界 |
| `note` | 升档重跑等备注 |

### `turn`：每个主 Agent 回合一行

| 字段 | 含义 |
|---|---|
| `sessionID` / `turnID` | 会话与回合 |
| `providerID` / `model` | 主模型 |
| `routeProfileID` / `routeConfidence` | 关键词（或本地模型补判后）的路由判决 |
| `delegationPolicy` | `automatic` / `required`（`/subagent`）/ `forbidden`（`/no-subagent`） |
| `dispatchedAt` | 派发（用户发送）时刻；后台唤醒的回合为唤醒时刻 |
| `requestSentAt` | 首个 provider 请求发出时刻 |
| `firstTokenAt` | 首个可见 delta |
| `firstToolBoundaryAt` | 首次执行工具调用 |
| `finishedAt` | 回合结束 |
| `preStreamSeconds` | `requestSentAt - dispatchedAt`：路由、预检、提示词组装等首字前开销 |
| `firstTokenSeconds` | `firstTokenAt - dispatchedAt`：用户感知的首字延迟 |
| `firstToolBoundarySeconds` / `totalSeconds` | 同理 |
| `rounds` | provider 请求次数 |
| `workerRuns` | 本回合的 `spawn_agent` 次数 + 并行 scout（有则 +1） |
| `parallelScout` | `delivered` / `dropped` / `cancelled` / `timedOut` / `failed`，没有并行 scout 时缺省 |
| `outcome` | `succeeded` / `failed` / `cancelled` |

## 怎么用

```bash
# 最近 20 个回合的首字延迟与 Worker 数
grep '"kind":"turn"' ~/Library/Application\ Support/WillDeep/AgentAudit/worker-timing.jsonl \
  | tail -20 | jq -r '[.firstTokenSeconds, .totalSeconds, .workerRuns, .parallelScout // "-", .routeProfileID // "-"] | @tsv'

# 并行 scout 的交付率
grep '"source":"speculativeScout"' ~/Library/Application\ Support/WillDeep/AgentAudit/worker-timing.jsonl \
  | jq -s 'group_by(.status) | map({status: .[0].status, n: length})'

# 有 Worker 与无 Worker 回合的总耗时对比
grep '"kind":"turn"' ~/Library/Application\ Support/WillDeep/AgentAudit/worker-timing.jsonl \
  | jq -s 'group_by(.workerRuns > 0) | map({withWorkers: .[0].workerRuns > 0, n: length, medianTotal: (map(.totalSeconds) | sort | .[length/2|floor])})'
```

## 写入位置（代码）

- 前台 `spawn_agent`：`AppStateAgentToolMessages.swift` 的 `persist(...)`。
- 后台 `spawn_agent`：`AppState.swift` 的 `agentSubagentRegistry.onRunFinished`。
- 宿主发起的 Worker（预检、修复、编码流水线）：`AppStateAgentHostWorkerLedger.swift` 的 `finishHostWorkerRun`。
- 并行 scout：`AppStateAgentSpeculativeScout.swift`，在交付/丢弃/取消/失败时各写一次。
- 回合：`AppStateAgentLoop.swift` 的 `runAgentLoop` defer → `finalizeTurnTiming`。

写入走 `AgentWorkerTimingLogWriter` actor（`Task.detached(.utility)`），主线程不等磁盘。

## 姊妹台账：`model-routing.jsonl`（1.408.0-rc5 起）

计时日志只记"最后用了哪个模型"，不记"为什么是它"。同目录下的 `model-routing.jsonl`（`AgentModelRouteLog.swift`）每遇到一次**非直达**的模型决策写一行，`kind` 为 `model_route`：

| surface | 什么时候写 | 关键字段 |
|---|---|---|
| `worker_binding` | Worker 工种的档位/绑定没解析成功、退回父模型 | `subject`=工种 id，`requested`=`tier:<档>` 或绑定模型，`reason` |
| `managed_routing` | 省心托管每回合选主模型 | `requested`=裁判建议的 target_model，`model`=实际用的，`detail`=裁判给的理由 |
| `quality_judge` | 质检裁判不可用、或判不合格触发升档 | `subject`=failure_type，`model`=升档后的模型 |

`reason` 取值：`binding_unconfigured`、`private_parent_keeps_provider`（私有会话不外溢到 some.im，这是有意的，但要看得见）、`provider_unavailable`、`missing_api_key`、`judge_unavailable`、`judge_model_rejected`、`routed`。

```bash
# 哪些工种最常退回父模型、为什么
grep '"surface":"worker_binding"' ~/Library/Application\ Support/WillDeep/AgentAudit/model-routing.jsonl \
  | jq -s 'group_by([.subject, .reason]) | map({subject: .[0].subject, reason: .[0].reason, n: length})'
```

同一版本起，安全裁判、路由裁判、质检裁判的每次请求，以及托管升档时被丢弃的那一版回答，都作为辅助请求（`safetyJudge` / `routeJudge` / `qualityJudge` / `discardedEscalationAttempt`）记入会话用量。
