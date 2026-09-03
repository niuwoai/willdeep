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
