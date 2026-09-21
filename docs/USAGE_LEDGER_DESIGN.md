# 双端 Token 用量账本设计（willdeep.usage-ledger.v1）

> Last updated: 2026-09-21 | 状态：**已确认，实施中**
> 关联版本：基于 Xedit 1.394.0-rc7（develop @ 2d090d4a）、willdeep-rs 0.80.0-rc2（develop @ 9cdeaad）
> 适用范围：Xedit（WillDeep macOS App，本仓库）与 willdeep-rs（CLI / TUI / Runtime，`~/Sites/willdeep-rs`）
> 本文件是双端共享的 canonical 规范；willdeep-rs 侧落地时在其 `docs/USAGE_LEDGER.md` 引用本文，不另写一份。
> 一句话：rs 按「每次模型调用一行」写一份只追加的本地账本，Mac 只读合并进 Token 活动与用量统计，并按「桌面 / CLI」分来源显示；历史从 daemon 事件日志回填。

## 0. 需求来源

2026-09-21 用户反馈：「我今天在 `~/Sites/willdeep-rs` 的 CLI 版里运行了很多次，为什么（Mac 的 Token 活动）现在还是只有 30 多万个 token 的用量？」截图里 9 月 21 日那格的提示是「请求：0 次 · Token：32.5 万」。

当天实测：

| 来源 | 模型调用 | Token |
| --- | --- | --- |
| Mac 会话目录（热力图唯一数据源） | 1 个会话有新消息：定时巡检「服务日志巡检与证书过期检查」 | 真实 31.3 万 + 估算 ≈ 32.5 万 |
| rs daemon 事件日志 `~/.willdeep/runtime/events.ndjson` | 704 次（含子 Agent 118 次） | 输入 3229 万（缓存命中 2857 万）+ 输出 67 万 ≈ **3297 万** |

CLI 的用量一条都没进统计，差了约 100 倍。另有一个附带现象：自动任务跨过零点后，当天那格显示「请求 0 次」却有 Token，看起来像统计坏了。

## 1. 现状盘点（代码锚点）

### 1.1 rs 侧：用量解析了，但没有按请求落盘的账本

| 位置 | 现在干什么 | 问题 |
| --- | --- | --- |
| `crates/willdeep-core/src/types.rs:258-267` | `Usage { input_tokens, output_tokens, total_tokens, cache_read_tokens }`，三家协议共用 | — |
| `provider/chat_completions.rs:247-267,374-377`、`provider/responses.rs:242-299`、`provider/responses/streaming.rs:148-156`、`provider/anthropic/streaming.rs:237-252` | 各协议把 usage 解析进上面的结构，含缓存命中 | — |
| `agent/streaming.rs:107`、`agent.rs:683-692,751-763,799-813` | 收到 `ProviderEvent::Usage` 后累加进本轮合计，发 `AgentEvent::Usage`（`agent.rs:134`） | 只是内存事件 |
| `agent/context.rs:336-344` | 压缩请求同样累加 | 同上 |
| `checkpoint.rs:149-195,409-414` | 把本轮运行的 `input_tokens/output_tokens/turns` 写进会话文件的 `execution_checkpoint` | 只是运行级累计，每次保存覆盖，无缓存命中、无时间戳，回退时清空（`session.rs:173`） |
| `~/.willdeep/sessions/<id>.json` 的 `messages[]` | 每条消息只有 `role / content / reasoning / tool_calls` | **没有 token、没有时间戳**，读了也分不出哪天用了多少 |
| `crates/willdeep-cli/src/daemon.rs:191-213` + `daemon/event_stream.rs:36-57` | daemon 回合的每个事件追加进 `~/.willdeep/runtime/events.ndjson`，其中每次模型调用一条 `{"type":"usage",…}`，子 Agent 为 `subagent_usage` | 唯一的按请求记录；但只覆盖 daemon 回合，usage JSON 以字符串塞在 `message` 里，要靠 `task_id` 连 `runtime/tasks.json` 才知道会话与模型；17 MB，自 2026-08-10 起从未轮转 |
| `telemetry.rs:576-601` | 每回合一条 `ai_request_finished` 进 `telemetry-queue.json` | 发走即删，上限 500，不是账本 |
| `audit_cmd.rs:717-718,849-850,1077-1081` | `willdeep audit export` 按会话显示 input/output | 读的是 `execution_checkpoint`，同样只有运行级累计 |
| `session.rs:719-729` | macOS 下 CLI 会读 Mac 的 `agent-sessions` 目录做会话列表 | 单向：Mac 从不读 CLI 的数据，CLI 也从不往 Mac 目录写用量 |

实测可回填性：`events.ndjson` 里 2282 条用量记录（2026-08-10 18:16 至今）**全部**能按 `task_id` 在 `tasks.json` 找到 `session_id / model / workspace / origin_client`。`origin_client` 取值为 `tui:<uuid>`、`cli:<uuid>` 或空（137 个早期任务）。

### 1.2 Mac 侧：统计只认自己的会话，且没有来源维度

| 位置 | 现在干什么 | 问题 |
| --- | --- | --- |
| `Xedit/AgentUsageStats.swift:317-341,414-454` | `AgentUsageSessionSnapshot` / `AgentUsageMessageSnapshot`，消息带 `usageTokens / promptTokens / completionTokens / cachedPromptTokens / origin / requestModelID / requestIsLocal / createdAt` | 没有「来源端」字段 |
| `AgentUsageStats.swift:789-829` | 热力图：「请求」= 当天 `role == .user` 的消息数（不看 `source`）；「Token」= 当天每条消息 `usageTokens`，没有就 `estimateTokens` | 请求与 Token 口径不一致：跨零点的回合在次日只有 Token 没有请求；注释（`:777`）说「user-authored」与实现不符 |
| `AgentUsageStats.swift:698-755` | 总览 Token、活跃天数、峰值时段、最爱模型 | 最爱模型按会话 `modelID` × 消息数加权，忽略逐条 `requestModelID` |
| `AgentUsageStats.swift:975-1103,1464-1496` | 模型拆分（assistant 消息 + worker run） | `.delegatedExternal` 显示为「Delegated CLI」一行，是唯一的来源概念 |
| `AgentRequestAnalytics.swift:234-308` | 「本地模型请求」与「API 请求 · 近 7 天」按模型调用（provider round）计 | 「API 请求 · 近 7 天」没有排除本地请求，名不副实 |
| `AppStateAgentSessions.swift:1647,1665` | 仪表盘首次打开时加载一次快照（SQLite 缓存 `AgentUsageDatabase.swift:72,108` + `usage-v1/` sidecar，`AgentSessionStore.swift:1260-1336`），之后只靠进程内 12 处 upsert 更新 | 没有文件监听，外部数据进不来，也不会刷新 |
| `AppState.swift:392-466` | 以 (revision, 日期) 为键在后台重算 | — |
| `AgentStatusIndicators.swift:139,476-499,640-719,2165,2213` | 仪表盘、请求计数条、热力图与格子 | 提示框 `heatmap-cell.tooltip`（`Localizable.xcstrings:36301`）：「%1$@ · 请求：%2$@ 次 · Token：%3$@」 |
| `WillDeepRuntimeClient.swift:1-40` | Mac 连 rs daemon 只读观察，按白名单拒绝提交回合 | **Mac 的回合从不经过 daemon**，两边合并不会重复计数 |
| `WillDeep.entitlements` | App Sandbox 关闭 | Mac 可以直接读 `~/.willdeep`；已有先例：`runtime/daemon.json`（`WillDeepRuntimeTransport.swift:33`）、`config.toml`、`dev-provider.json`（`AppStateAgentSessions.swift:279`） |

## 2. 结论：rs 写一份按调用粒度的本地账本，Mac 只读合并并分来源显示

不让 Mac 去解析 rs 的会话文件或内部事件日志：前者根本没有时间和用量，后者是 daemon 的内部协议，只覆盖一半执行路径，而且字段藏在字符串里。改为由 rs 在**唯一的用量汇合点**写一份格式公开、版本化的账本，daemon 回合与进程内回合走同一个写入口；Mac 把账本当作第二个数据源，并入现有统计，同时给所有统计补上「来源」这一维。

### 2.1 设计原则

1. **一次模型调用一行**。与 Mac 现有「模型调用」口径（`AgentRequestAnalytics`）对齐，不在写入端做任何聚合。
2. **账本只记数，不记内容**。没有提示词、没有回复、没有命令、没有路径以外的工作区信息。
3. **谁的数据谁写**。rs 写 rs 的账本（含历史回填），Mac 只读，不往 `~/.willdeep` 写任何东西。
4. **只追加、可重放、可去重**。每行有稳定 `id`，重复回填、并发写入、读到半行都不产生错账。
5. **写账本失败不能影响回合**。记账是旁路，任何 IO 错误只记日志。

## 3. 已拍板的决策

2026-09-21 用户确认 §15 全部按默认假设执行，逐条见 §16。

## 4. 总体架构

```
            willdeep-rs                                       Xedit (WillDeep.app)
 ┌─────────────────────────────────────┐        ┌──────────────────────────────────────────┐
 │ provider/* 解析 Usage                │        │ AgentSessionStore（桌面会话，现状不变）   │
 │        │                             │        │        │                                  │
 │        ▼                             │        │        ▼                                  │
 │ agent.rs / context.rs / subagent     │        │ agentUsageSnapshots ──┐                   │
 │   emit AgentEvent::Usage             │        │                       ├─► AgentUsageStats │
 │        │                             │        │ AgentCLIUsageLedger ──┘   （合并 + 来源）   │
 │        ▼                             │        │   增量读取 + 目录监听                       │
 │ UsageLedgerSink（新，唯一写入口）      │        │        ▲                                  │
 │   daemon 与进程内共用                 │        └────────┼──────────────────────────────────┘
 │        │ O_APPEND 单行写入             │                 │ 只读
 │        ▼                             │                 │
 │ ~/.willdeep/usage/2026-09.jsonl ─────┼─────────────────┘
 │        ▲                             │
 │ willdeep usage backfill（一次性回填）  │
 │   读 runtime/events.ndjson + tasks.json│
 └─────────────────────────────────────┘
```

## 5. 数据模型

### 5.1 账本文件

- 目录：`$WILLDEEP_HOME/usage/`，默认 `~/.willdeep/usage/`。
- 文件：按记录时间（UTC）的月份分片，`YYYY-MM.jsonl`，UTF-8，每行一个 JSON 对象，`\n` 结尾。
- 只追加，永不改写旧行。本机实测量级：一个月约 2000 条 × 约 400 字节 ≈ 1 MB，不做删除与压缩（见 §15 Q6）。

### 5.2 行格式 `willdeep.usage-ledger.v1`

```json
{
  "schema": "willdeep.usage-ledger.v1",
  "id": "0b8c…-uuid",
  "ts": "2026-09-21T08:52:31.402Z",
  "client": "tui",
  "client_instance": "62a6264a-2604-4429-ae5f-b8d4a01128f4",
  "execution": "daemon",
  "kind": "main",
  "session_id": "2500b85b-9324-472a-8aeb-5e154cf41100",
  "turn_id": "…",
  "task_id": "…",
  "agent_id": null,
  "workspace": "/Users/rocky/Sites/factify",
  "provider": "some.im",
  "model": "deepseek-v4-pro",
  "local": false,
  "input_tokens": 21342,
  "cache_read_tokens": 20864,
  "output_tokens": 1036,
  "total_tokens": 22378,
  "latency_ms": 5820,
  "outcome": "ok",
  "event_sequence": 80756,
  "backfilled": false
}
```

| 字段 | 必有 | 说明 |
| --- | --- | --- |
| `schema` | 是 | 固定 `willdeep.usage-ledger.v1`。读端遇到不认识的 schema 整行跳过 |
| `id` | 是 | 去重键。实时写入用 UUIDv4；回填用 `uuidv5(namespace, "events.ndjson#<sequence>")`，同一条事件永远得到同一个 id |
| `ts` | 是 | 模型调用**完成**时刻，RFC 3339 UTC，毫秒精度。热力图按读端本地时区换算日期 |
| `client` | 是 | `cli` / `tui` / `mobile` / `unknown`，取自 `origin_client` 前缀；回填遇到空值记 `unknown` |
| `client_instance` | 否 | `origin_client` 冒号后的实例 id |
| `execution` | 是 | `daemon` / `in_process` |
| `kind` | 是 | `main`（主回合）/ `subagent` / `compression` / `auxiliary`（标题、分类、裁判等辅助请求） |
| `session_id`、`turn_id`、`task_id`、`agent_id` | 否 | 能拿到就写，读端只用 `session_id` 统计会话数 |
| `workspace` | 否 | 工作区绝对路径，用于将来按项目统计；不含任何文件内容 |
| `provider`、`model` | 否 | 省心托管等拿不到具体模型时写 `null`，读端归入「省心托管 / 未知模型」 |
| `local` | 是 | 本地模型（Ollama 等）为 `true`，对应 Mac 的「本地模型请求」 |
| `input_tokens`、`cache_read_tokens`、`output_tokens`、`total_tokens` | 否 | 协议没报就是 `null`，**不估算**。`input_tokens` 包含缓存命中部分（与三家协议一致） |
| `latency_ms` | 否 | 请求发出到收完 |
| `outcome` | 是 | `ok` / `error` / `cancelled`；失败但已计费的请求也要记 |
| `event_sequence` | 否 | daemon 回合写入时对应的 `events.ndjson` 序号，回填据此跳过已实时记账的事件 |
| `backfilled` | 是 | 回填行为 `true` |

### 5.3 两端结构

rs（`crates/willdeep-core/src/usage_ledger.rs`，新增）：

```rust
pub struct UsageLedgerRecord {
    pub schema: &'static str,          // "willdeep.usage-ledger.v1"
    pub id: Uuid,
    pub ts: DateTime<Utc>,
    pub client: ClientKind,            // Cli | Tui | Mobile | Unknown
    pub client_instance: Option<String>,
    pub execution: Execution,          // Daemon | InProcess
    pub kind: UsageKind,               // Main | Subagent | Compression | Auxiliary
    pub session_id: Option<Uuid>,
    pub turn_id: Option<String>,
    pub task_id: Option<String>,
    pub agent_id: Option<String>,
    pub workspace: Option<PathBuf>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub local: bool,
    pub usage: Usage,                  // 复用 types.rs 的 Usage
    pub latency_ms: Option<u64>,
    pub outcome: Outcome,
    pub event_sequence: Option<u64>,
    pub backfilled: bool,
}
```

Mac（`Xedit/AgentCLIUsageLedger.swift`，新增）：

```swift
nonisolated struct AgentCLIUsageRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let client: String            // "cli" / "tui" / …
    let kind: String              // "main" / "subagent" / …
    let sessionID: UUID?
    let providerID: String?
    let modelID: String?
    let isLocal: Bool
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let latencyMilliseconds: Int?
    let succeeded: Bool
}

nonisolated enum AgentUsageSource: String, Codable { case desktop, cli }
```

## 6. 关键流程

### 6.1 实时写入（rs）

1. 新增 `UsageLedgerSink`，由 `agent.rs` 在收到 `ProviderEvent::Usage` 的同一处调用（主回合、`context.rs` 压缩、子 Agent 路径各一处），不在 provider 层写——那一层不知道会话与回合。
2. daemon 回合与进程内回合用同一个 sink；daemon 额外填 `event_sequence`。
3. 写入方式：序列化成一行（保证 < 4 KB），以 `O_APPEND` 打开当月文件、**一次 `write` 写完整行**。macOS / Linux 上小于 `PIPE_BUF` 的 `O_APPEND` 写入在本地文件系统上是原子的，daemon 与多个进程内 CLI 并发写同一文件不会交错。超长行（理论上不会出现）直接截断可选字段后再写。
4. 任何 IO 错误只记 `tracing::warn`，不上抛、不重试、不阻塞回合（原则 5）。
5. 为了不在热路径上做同步 IO，sink 内部走一个有界通道 + 单个写线程；进程正常退出时 flush，进程被杀时最多丢在途的几行（可接受，见 §13）。

### 6.2 历史回填（rs）

1. 新子命令 `willdeep usage backfill [--dry-run]`，并在 daemon 启动时**自动跑一次**（用 `~/.willdeep/usage/.backfill-v1.done` 标记，写有回填到的最大 sequence）。
2. 读 `runtime/events.ndjson` 中 `type ∈ {usage, subagent_usage}` 的行，按 `task_id` 连 `runtime/tasks.json` 补 `session_id / model / workspace / origin_client`，`ts` 取事件 `timestamp`（秒级）。
3. `id = uuidv5(ns, "events.ndjson#<sequence>")`；已存在于账本的 `id`，或 `event_sequence` 已被实时记账的，跳过。回填可以反复跑，结果不变。
4. 进程内回合在账本上线前的历史**无法回填**：它们只有运行级累计，没有时间。账本上线前的 CLI 用量以此为准，文档与 UI 不做补假数据。

### 6.3 读取与合并（Mac）

1. 仪表盘首次打开时，`AgentCLIUsageLedger` 扫描 `~/.willdeep/usage/*.jsonl`（`WILLDEEP_HOME` 环境变量优先），按文件记录「inode + 已读偏移」，只读新增部分；读到不完整的最后一行（没有 `\n`）先不消费，下次再读。
2. 解析后按 `id` 去重，存入内存数组；偏移与已解析的按日聚合写进现有 `usage.sqlite`（新表，schema 升一版），下次启动不用从头读。
3. 仪表盘打开期间，用 `DispatchSource` 监听 `usage/` 目录与当月文件的写入事件，节流 2 秒后增量读取，bump `agentUsageStatsRevision` 触发现有的后台重算（`AppState.swift:392-466`）。仪表盘关闭即停止监听。
4. `AgentUsageStats` 的各聚合函数增加一个 `cliRecords` 入参，与桌面快照一起计算；每项统计都能按 `AgentUsageSource` 拆分。
5. 桌面快照的计算逻辑一行不改，保证「只有桌面数据时」所有数字与现在完全一致（回归测试守住）。

### 6.4 「请求」口径统一

现状热力图的「请求」数 user 消息，「API 请求 · 近 7 天」数模型调用，同一个词两种意思；CLI 账本天然是模型调用。建议统一为：

- **请求 = 模型调用次数**（主回合、子 Agent、压缩、辅助请求都算），两端同口径，跨零点的回合也不会再出现「0 次请求却有 Token」。
- 另保留「对话轮次」（用户发起的回合）作为次要指标，只出现在提示框里。

这是用户可见的口径变化，见 §15 Q1。

## 7. 不可让渡的不变量

1. 账本**不含任何内容**：提示词、回复、推理、工具参数与结果、命令一律不写。rs 侧由 `UsageLedgerRecord` 的类型保证（没有这类字段），测试断言序列化结果里没有这些 key。
2. 账本**只在本机**：不进 telemetry、不进 some.im 同步、不随会话交接走 git。
3. Mac 对 `~/.willdeep` **只读**：`AgentCLIUsageLedger` 只用读取 API 打开文件，不创建、不改名、不删除；缓存写在 Mac 自己的 Application Support。
4. 记账失败**不影响回合**：写入路径上不存在会让 Agent 回合报错或变慢的分支。

## 8. 失败与边缘状态

| 场景 | 表现 |
| --- | --- |
| 从没装过 CLI / 没有 `~/.willdeep/usage/` | 与现在完全一样，不显示 CLI 相关元素 |
| 有 CLI 但账本为空（刚升级、还没跑过） | 来源筛选里 CLI 为 0；仪表盘底部一行提示「CLI 用量从 rs 0.81 起记录，更早的 daemon 用量已回填」（i18n） |
| 某行 JSON 坏了 / schema 不认识 | 跳过该行，计数进诊断日志；不影响其它行 |
| 最后一行写到一半 | 不消费，等下一次读取 |
| 文件被删或 inode 变了 | 视为新文件从头读，靠 `id` 去重 |
| 记录的 token 为 `null` | 计入请求数，Token 不加、不估算；提示框不显示「估算」字样之外的任何猜测 |
| 时钟回拨 / 时区变化 | 按记录的 UTC 时刻落到读端本地日期，不做纠正 |
| 账本很大（多年） | 按月分片 + 偏移缓存，冷启动只解析新增部分；首次全量解析在后台，仪表盘先显示桌面数据，CLI 数据到了再刷新 |
| rs 写账本时磁盘满 | 回合照常，丢这几行账 |

## 9. 兼容与迁移

- **rs 旧版本**：不写账本；daemon 事件日志照旧，升级后首次启动 daemon 自动回填。
- **Mac 旧版本**：不读账本，行为不变。
- **新 Mac + 旧 rs**：只能看到回填（需要新 rs 才会回填），在此之前 CLI 为 0，属预期。
- **schema 演进**：只加可选字段不升版本；语义变化升 `v2`，读端同时认 v1/v2。
- **`events.ndjson` 轮转**：本方案不改它。账本上线后，事件日志即使将来轮转也不影响用量历史。
- **不做的迁移**：不把桌面历史写进账本（见 §14）。

## 10. UI 设计

平台：macOS，现有用量仪表盘（`AgentStatusIndicators.swift`），信息密度不变，文案全部走 `Localizable.xcstrings`（en / zh-Hans / ja / es / fr）。

1. **来源筛选**：热力图标题行右侧、「每日 / 每周 / 累计」旁加一组分段：「全部 / 桌面 / CLI」，默认「全部」，记住上次选择。没有 CLI 数据时整组隐藏。
2. **热力图提示框**：`9月21日 · 请求 704 次（桌面 25 · CLI 679）· Token 3330 万（缓存命中 87%）`。只有一个来源时不显示括号拆分。
3. **总览数字**：Token 总量、活跃天数、连续天数、峰值时段都合并两端；「最爱模型」改为按逐次调用的模型计。
4. **模型拆分**：CLI 调用的模型与桌面合并到同一模型行，行内显示来源小标（「桌面 / CLI」）；现有「Delegated CLI」一行保留原义（桌面把任务委派给外部 CLI Agent）。
5. **请求计数条**：「本地模型请求」「API 请求 · 近 7 天」合并两端，并修正后者把本地请求也算进去的问题（`AgentRequestAnalytics.swift:242,247`）。
6. **加载态**：CLI 数据在后台解析，期间热力图先按桌面数据画，完成后刷新，不加 loading 遮罩。

## 11. 分期落地

| 期 | 仓库 | 内容 | 可独立验收 | 预计版本 |
| --- | --- | --- | --- | --- |
| R1 | willdeep-rs | `UsageLedgerSink` + 实时写入（daemon 与进程内、主回合 / 子 Agent / 压缩 / 辅助）+ `willdeep usage backfill` + daemon 启动自动回填 + rs `docs/USAGE_LEDGER.md` 引用本文 | 是：跑一轮 TUI 后账本出现对应行；回填两次结果一致 | 0.81.0-rc1 |
| X1 | Xedit | `AgentCLIUsageLedger` 增量读取 + 偏移缓存 + 目录监听；聚合函数接入 `cliRecords`；仅桌面数据时全部数字不变 | 是：本机仪表盘 9 月 21 日显示约 3300 万 | 1.395.0-rc1 |
| X2 | Xedit | 来源筛选、提示框拆分、模型行来源标、「请求」口径统一（§6.4，取决于 Q1）、「API 请求」排除本地 | 是：截图对照 + 单测 | 1.395.0-rc2 |

R1 先行，X1 在 R1 之前也能先用本机手工造的账本文件开发与测试。

## 12. 测试计划与验收

**rs（R1）**

- `usage_ledger` 单测：序列化字段集合恰好是 §5.2 列出的 key，**不含** `content / prompt / messages / arguments` 等任何内容字段。
- 并发：16 个线程各写 1000 行到同一文件，读回 16000 行、每行都能解析、`id` 不重复。
- 写失败：账本目录不可写时回合正常完成，只多一条 warn。
- 回填：用一份截取的 `events.ndjson` + `tasks.json` 夹具，回填两次结果逐字节相同；与实时记账重叠的 sequence 不重复记。
- 端到端：进程内 `willdeep exec` 与 daemon 回合各跑一次，账本各出现一行 `execution` 正确的记录。

**Mac（X1 / X2）**

- `AgentCLIUsageLedgerTests`：增量读取、半行不消费、坏行跳过、inode 变化重读、`id` 去重、`WILLDEEP_HOME` 覆盖。
- `AgentUsageStatsTests` 扩展：`cliRecords` 为空时，热力图、总览、模型拆分、请求计数与改动前**逐项相等**（回归守卫）；有 CLI 记录时按来源正确拆分；跨零点的回合不再出现「请求 0、Token > 0」（取决于 Q1）。
- 监听：仪表盘打开时追加一行，2 秒内 revision 变化；关闭后不再监听。

**验收（本机真实数据）**

1. 升级 rs 后执行 `willdeep usage backfill --dry-run`，报告的 2026-09-21 模型调用数与 Token 与本文 §0 的 704 次 / 约 3297 万一致（容差：实时写入与回填时刻不同导致的几条差异）。
2. Mac 仪表盘 9 月 21 日一格显示约 3300 万 Token，提示框拆分出桌面与 CLI。
3. 切到「桌面」时，9 月 21 日恢复为 32.5 万，与改动前一致。

## 13. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 实时写与回填重复计数 | 数字翻倍 | 回填 id 由 sequence 确定性生成 + 实时行带 `event_sequence`，两道去重；验收 1 专门核对 |
| 进程被杀丢在途记录 | 少记几次调用 | 写线程每行即 `write`，通道有界且很短；可接受 |
| 旧的进程内 CLI 历史无法回填 | 9 月 21 日前的进程内用量缺失 | 如实缺失，提示文案说明起始时间；不估算补数 |
| 缓存命中让 Token 看起来很夸张（3297 万里 2857 万是缓存） | 用户误判花费 | 提示框显示缓存命中比例；Token 总数口径待 Q3 |
| 读端解析大文件阻塞主线程 | 仪表盘卡顿 | 全部在后台任务里读，主线程只收聚合结果；沿用现有 revision 机制 |
| 口径变化让老用户觉得「请求数变多了」 | 困惑 | CHANGELOG 与仪表盘说明文字写清「请求 = 模型调用」 |

## 14. Non-goals

- 不做花费（金额）计算与计价表。
- 不上传账本，不做跨设备汇总（将来走 some.im 控制平面另议）。
- v1 不让 Mac 也写这份账本；桌面历史继续从桌面会话计算。
- 不改 rs 的会话文件格式，不给消息补时间戳或 token 字段。
- 不改 `events.ndjson` 的格式与轮转策略。
- 不在 rs 侧做用量仪表盘；`willdeep usage` 子命令 v1 只有 `backfill`，查询汇总另议。

## 15. 待确认问题

（已全部拍板，见 §16。）

## 16. 已确认决策（2026-09-21）

| # | 问题 | 决策 |
| --- | --- | --- |
| Q1 | 「请求」统一成什么口径？ | **模型调用次数**（两端一致，跨零点不再出现 0 次）；「对话轮次」退到提示框次要信息 |
| Q2 | 子 Agent、压缩、标题 / 分类 / 裁判等辅助请求算不算进用量？ | 全都算，账本用 `kind` 区分，UI v1 不单独拆 |
| Q3 | Token 总数包不包含缓存命中？ | 包含（与三家协议的 input 口径一致），提示框显示缓存命中比例 |
| Q4 | 历史回填范围 | `events.ndjson` 里全部（2026-08-10 起的 daemon 回合）；进程内历史接受缺失 |
| Q5 | 回填怎么触发 | daemon 启动时自动跑一次（幂等标记），另提供手动 `willdeep usage backfill` |
| Q6 | 账本存放与保留 | `~/.willdeep/usage/YYYY-MM.jsonl`，永久保留不删 |
| Q7 | Mac 什么时候刷新 CLI 数据 | 仪表盘打开时读一次，打开期间监听目录（节流 2 秒）；关着不监听 |
| Q8 | 来源维度的 UI 形态 | 热力图旁「全部 / 桌面 / CLI」分段 + 提示框拆分 + 模型行来源标 |

### 16.1 落地后补记的实现要点

**Mac 侧（X1 + X2 合并在 1.395.0-rc1 一次落地）**

- 读取器 `Xedit/AgentCLIUsageLedger.swift`：`AgentCLIUsageRecord.decode(line:)` 用 `JSONSerialization` 宽松解析，缺字段、`null`、未知 schema、坏行都只跳过该行；`AgentCLIUsageLedgerReader` 按文件记「inode + 已读字节」，只消费到最后一个 `\n`，按 `id` 去重。
- **与设计的差异 1**：没有把读取偏移与按日聚合写进 `usage.sqlite`（§6.3.2）。实测全部历史约 2300 行、不到 1 MB，每次启动后台全量解析是毫秒级，缓存的维护成本高于收益。账本增长到解析可感知时再加。
- **与设计的差异 2**：§10.5 提议让「API 请求 · 近 7 天」排除本地请求，落地时撤回。`AgentUsageStatsTests` 里两条用例明确钉着「本地端点也算 API」的口径（`request analytics separates local traffic…`、`session helper calls participate in local and seven-day request totals`），这不在 §15 的拍板范围内，保持原口径。
- 「请求 = 模型调用」统一由 `AgentRequestAnalytics.requestEvents(for:cliRecords:)` 产出，热力图、最爱模型、请求页都用它：桌面主循环按带请求证据的 assistant 消息计 1 次（Token 仍从消息本身取），worker 按 `roundCount` 计并补上它自己的 Token，辅助请求各计 1 次并补 Token（Q2），CLI 每行计 1 次。
- 「最爱模型」改按逐次调用的模型计；早期会话没有逐次请求证据时，退回原来的「会话模型 × 消息数」。
- 来源筛选 `AgentUsageSourceFilter` 存 `UserDefaults`（`com.willdeep.usageDashboard.sourceFilter.v1`），在 `AppState.scheduleAgentUsageDashboardRefresh` 处按来源裁剪输入；没有 CLI 数据时整组隐藏。
- 单测进程里 `agentCLIUsageLedgerReader` 为 nil，真实 `~/.willdeep` 不会渗进测试结果。
- 新增测试 `AgentCLIUsageLedgerTests`（12 项）。

## 附：相关文档

- [GOAL_TEAMS_ROLES_DESIGN.md](GOAL_TEAMS_ROLES_DESIGN.md)：同样的「Xedit 放 canonical、rs 引用」双端文档先例
- [CROSS_PLATFORM_CLI_STRATEGY.md](CROSS_PLATFORM_CLI_STRATEGY.md)
- willdeep-rs：`docs/RUNTIME_DAEMON.md`（事件流一节）、`docs/AUDIT_EXPORT.md`、`docs/AGENT_METRICS.md`
