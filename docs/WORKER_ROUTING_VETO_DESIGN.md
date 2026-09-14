# Worker 路由：本地模型否决权设计

> Last updated: 2026-09-14 | 状态：**部分落地（1.374.0-rc2）**
> 关联版本：基于 1.373.0-rc3（develop @ 4db470e5）
> 适用范围：Xedit（WillDeep macOS App）、willdeep-rs（镜像契约）
> 关联文档：[REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md](REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md)、[NEXT_TASKS_2026-09-03_WORKER_LATENCY.md](NEXT_TASKS_2026-09-03_WORKER_LATENCY.md)、[WORKER_ROUTING_CONTRACT.json](WORKER_ROUTING_CONTRACT.json)
> 一句话：本地模型获得对 `ops_runner` / `terminal_operator` 判决的**否决权**（只能降级），仍然没有**提名权**（不能升级）；判决与主模型请求并行发出，在第一个工具边界前到位，不碰首字。

## 0. 需求来源

2026-09-14，用户在 tokenhub 仓库输入：

> 那你把 deployment 里的注解改一下。

composer 上方显示「委派给「运维」Worker」。用户的反应是：

> 我感觉这个，不应该分派给运维啊，应该是"实现"或是"通用"之类的。

排查结论：`operationsMarkers` 里的 `"deploy"` 走裸子串匹配，`deployment` 一撞就中。代价不止是工种名难看——`ops_runner` 的 `enforcesDelegatedExecution` 无视委派策略恒为真，`AgentWorkerRouteGuard` 据此在工具边界拦住直接写文件，**一次误判把改 manifest 这活整个卡住**。

该子串问题已在 1.373.0-rc3 用词边界修掉（见该版本 CHANGELOG）。本文档处理的是它暴露出的**结构问题**：关键词表在中文里没有边界可用，穷举永远追不上真实语料，而错得最贵的恰好是特权档。

用户随后提出方向：

> 我们尽量让词表里的命中逻辑要求更精确才行，或者，如果给了本地的模型，就不再走这个精准的关键词逻辑？

本文档采纳后半句，但把「不再走关键词」改成「关键词降为可被否决的判决」——理由见 §2.1 与 §13。

## 1. 现状盘点（代码锚点）

### 1.1 关键词路由

| 位置 | 现在干什么 | 问题 |
| --- | --- | --- |
| `Xedit/AgentRequestRouter.swift:188` | `classify()` 纯函数、零 I/O，按分支顺序返回 `Decision` | 分支先撞先赢 |
| `Xedit/AgentRequestRouter.swift:181` | `operationsMarkers`，15 个词 | 中文词（"部署"）无边界可加；rc3 已给 ASCII 词加边界 |
| `Xedit/AgentRequestRouter.swift:198` | `terminalMarkers` → `terminal_operator`，94 分 | 同为特权档，同样裸子串 |
| `Xedit/AgentRequestRouter.swift:360` | `contains()` 裸子串匹配 | 其余全部词表仍是裸子串 |
| `Xedit/AgentRequestRouter.swift:372` | `containsWord()`，rc3 新增，ASCII 词边界 | 目前只有 `operationsMarkers` 在用 |
| `Xedit/AgentRequestRouter.swift:72` | `enforcesDelegatedExecution(for:)`：`ops_runner` 无视 policy 恒真 | 误判的代价集中在这一行 |
| `Xedit/AgentWorkerRouteGuard.swift:24` | `refusal(...)` 在工具边界拒绝直接写/跑命令 | 拦截点在工具边界，**不在首字前**——这是本设计可行的前提 |
| `Xedit/AppStateAgentLoop.swift:1665` | guard 的唯一调用点 | 判决只要赶在这里之前到位即可 |

### 1.2 模型路由（已存在，但名存实亡）

| 位置 | 现在干什么 | 问题 |
| --- | --- | --- |
| `Xedit/AgentWorkerRoutingModel.swift:158` | `shouldConsultModel`：`confidence < 86 && profileID == generalist` | 只覆盖「什么都不匹配」那一档（70 分） |
| `Xedit/AgentWorkerRoutingModel.swift:41` | `keywordTrustThreshold = 86` | 94 分的特权档永远够不着模型 |
| `Xedit/AgentWorkerRoutingModel.swift:69` | 候选菜单排除 `ops_runner` / `terminal_operator` | **刻意为之**，理由见 `WORKER_ROUTING_CONTRACT.json` 的 `excluded_profiles` |
| `Xedit/AgentWorkerRoutingModel.swift:167` | 合并语义：模型只能换 `profileID`，安全标志位全留关键词的 | 设计正确，本方案沿用 |
| `Xedit/AppStateAgentWorkerRouting.swift:31` | 调用点，八道门串联 | 见下 |
| `Xedit/AgentLocalModelSupport.swift:51` | 本地模型总开关 `enabled` 默认 **false** | 开箱即用时整条模型路径不存在 |
| `Xedit/AgentLocalModelSupport.swift:711` | 路由复用 `summaryModel`，默认 `gemma4:e4b-it-qat` | 实测 e2b 更适合判路，见 §13 |
| `Xedit/AgentLocalModelResidency.swift:120` | `/api/ps` 探针 0.35s，未驻留则本轮放弃 + 后台预热 | 冷启动头几轮必然缺席 |
| `Xedit/AppStateAgentWorkerRouting.swift:126` | 8 秒超时，失败一律回落关键词 | 回落语义已经是对的 |

现有八道门（全部为真才会问模型）：共享配置 `agent.small_model_routing != false` → 非 `/no-subagent` → 非 `agentPreferred` → 非操作员点名 → `shouldConsultModel` → 本地模型 `enabled` → `preferForWorkerRouting` → 模型已驻留。

`docs/REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md` §3.1 对此的结论是「判路模型在本机实际上已经"名存实亡"」。

### 1.3 既有结论与时间窗

- `REVIEW_2026-09-03` §6.3 与 §7 末尾：**判路模型去留的两周决策窗口最早为 2026-09-17**。
- `NEXT_TASKS_2026-09-03` 任务 E.2：若 `routeProfileID == "generalist"` 占比很低，就删掉 `refineRouteDecisionWithModelIfNeeded` 整条模型路径。

本设计是那个决策的**第三个选项**：不是去、也不是维持原用途，而是把这条路径从「填补兜底档」改用为「否决特权档」。

### 1.4 数据：ops 路由的实际规模与误伤面

2026-09-14 扫本机 `~/Library/Application Support/WillDeep/agent-sessions/` 全量落盘会话，统计脚本见 scratchpad（未入库）。提取规则与 `classify()` 对齐：只取 `role == "user"` 且 `source == "operatorInput"`，正文按 `AgentAttachedPromptDisplay.transform(...).userAuthoredText` 剥掉附件前置块，取前 600 字符 lowercase，用**修复前**的裸子串语义匹配。

| 项 | 值 |
| --- | --- |
| 会话文件 | 297（解析失败 0） |
| 时间范围 | 2026-07-26 — 2026-09-14（49 天） |
| 有真实用户请求的会话 | 217（空壳 80，占 26.9%） |
| 用户真实请求 | 970 条（去重后 850 条） |

命中规模：

| 分类 | 条数 | 占比 |
| --- | --- | --- |
| `operationsMarkers` → ops_runner（裸子串） | 130 | 13.4% |
| 同上，**去掉一条每日定时任务的 37 次重复** | 92 | 10.8%（按 850 去重口径） |
| `terminalMarkers` → terminal_operator | 29 | 3.0% |

逐词分布（一条可命中多词）：

| 关键词 | 命中 |
| --- | --- |
| 部署 | 78 |
| 重启服务 | 38 |
| systemctl | 38 |
| deploy | 14 |
| 生产环境 | 5 |
| 线上环境 | 4 |
| 其余 9 个词 | **0** |

**表里 15 个词有 9 个在 49 天真实流量里一次都没命中**，撑起全部命中的是前四个。

#### 1.4.1 对本设计不利、但必须记下的一条

**rc3 的词边界修复，实测净收益只有 2 条（130 → 128，降幅 1.5%）。**

14 条含 `deploy` 子串的请求里，4 条的 `deploy` 只出现在 `deployment` 中；其中 2 条另有「部署」等中文词兜底，仍判 ops_runner。真正被救回的是 2 条，其中一条正是 §0 的那次：

> 那你把 deployment 里的注解改一下。（2026-09-14T07:38:06Z）

这个数字直接说明：**词边界修复是对的，但它修不动大头。** 撑起 87% 命中的「部署」「重启服务」「systemctl」在中文/命令语境里没有边界可加，穷举词表这条路到此为止。这正是本设计存在的理由——与其继续雕词表，不如承认关键词只能"提出怀疑"，把"驳回怀疑"交给模型。

#### 1.4.2 一个被排除的假设（记录以免后人重走）

统计初稿显示有 3 条请求的 ops 命中完全来自宿主拼入的图片描述（`AppState.contentByAppendingImageDescription` 把视觉模型生成的文本追加进正文），量级比词边界修复还大，一度被当成第二个独立 bug。

**核实后不成立。** 时序是：路由决策在 `AppStateAgentLoopDispatch.swift:55`，图片描述拼接在同文件 `:207`，**路由在前**；且拼接写的是 `runtime.messages[liveIndex].content`，而 `classify()` 吃的是 dispatch 的 `text` 参数（该处注释：「Classified from what the user actually typed」）。图片描述不参与分类。

那 3 条是扫落盘 JSON 的口径假阳性——落盘正文是拼接后的，运行时分类器看到的不是。**后续任何基于 agent-sessions 的路由统计都要注意这条**：落盘正文 ≠ 分类器输入。

#### 1.4.3 拿不到的数

- **误伤真值率**：没有人工标注，无法回答"130 条里有多少确实不该走 ops_runner"。上面只能给机制层面可判定的那部分。
- **误伤后果**：`requiresDelegatedExecution` 究竟挡下过多少次正常编辑，落盘数据没有对应字段（run-history 只记 `startedAt`）。这正是 §8.2 要新增审计的原因之一。

### 1.5 一处契约与代码不一致（顺带发现）

`WORKER_ROUTING_CONTRACT.json` 的 `fallback_chain` 第二项写着「会话默认模型」，但 `workerRoutingConfigurationCandidates(fallback:)` 已在 1.317.0-rc8 整个删除（`REVIEW_2026-09-03` §1 第一行），现在没有任何远程回落。契约的双端守卫测试没有覆盖这个字段，所以一直没红。**本次一并修正契约文本**，见 §11 P0。

## 2. 结论：模型有否决权，没有提名权，且判决与主模型并行

关键词路由继续在首字前零成本地给出判决。当这个判决落在**特权档**（`ops_runner` / `terminal_operator`）时，宿主**并行**向本地模型发一次二选一的确认；判决在第一个工具边界之前到位。模型只能把特权档降级，不能把任何请求升级成特权档。模型缺席、超时、乱答，一律维持关键词判决。

### 2.1 设计原则

1. **权限只能收缩，不能扩张。** 模型的每一个可能输出都指向权限更小或相等的结果。这是本设计能够放宽"特权目的地只能由明确的关键词证据抵达"这条既有约束的唯一理由。
2. **回落方向是维持现状。** 本地模型没装、没驻留、超时、返回垃圾——行为与今天逐字节相同。零风险增量。
3. **不碰首字。** 遵守 `NEXT_TASKS_2026-09-03` §4 不变量 1：首字之前不允许出现任何 Worker 的 await。本设计的模型调用与主模型请求并行发出。
4. **只在贵的地方付钱。** 只有特权档判决才触发确认。其余分支判错的代价是选了个次优工种，不值得为它付一次模型往返。
5. **关键词表不再追求穷举精确。** 中文没有词边界，穷举是无底洞。词表负责"提出怀疑"，模型负责"驳回怀疑"。

## 3. 已拍板的决策

2026-09-14 用户逐条确认，全部采用默认假设。详见 §16。

| # | 决策 | 推论 |
| --- | --- | --- |
| 1 | 09-17 的判路模型去留，按本文档方向定：保留模型路径，用途改为否决特权档，generalist 兜底补判同时保留 | `refineRouteDecisionWithModelIfNeeded` 不删；`NEXT_TASKS` 任务 E.2 的"删除"选项作废 |
| 2 | 否决范围只含 `ops_runner` + `terminal_operator` | `test_fixer` / `build_fixer` 不产生强制后果，不进否决路径 |
| 3 | 标签先显示「运维」，否决后跳变成「实现」 | 不引入"判决未定"这个中间 UI 状态 |
| 4 | 路由模型与 `summaryModel` 解耦不提前，留在 P3 | P1 的实测效果受用户 summaryModel 选择影响，需在验收时记录当时用的是哪个模型 |
| 5 | 审计记请求原文前缀，截断 200 字符 | `route-veto.jsonl` 含用户输入片段，与 `judge.jsonl` 同级敏感度 |
| 6 | 其余词表暂不加词边界 | 同类病灶保留，但无强制后果 |

### 3.1 thinking 必须关（用户 2026-09-14 明确要求）

核实结论：**这条路径上已经关死**。

| 环节 | 位置 | 结论 |
| --- | --- | --- |
| 路由配置的 provider | `Xedit/AgentLocalModelSupport.swift:172` | 硬编码 `providerID: AgentProviderPreset.ollamaID` |
| 本地判定 | `Xedit/AgentLocalModelSupport.swift:195` | `providerID == "ollama"` → `isLocalProvider` 为真 |
| 注入 | `Xedit/AgentClientOpenAIChat.swift:617` / `:633` | 三个字段一起发：`reasoning_effort: "none"`、`reasoning: {effort: "none"}`、`think: false` |

`think: false` 只在内置 Ollama provider 上发（`includeOllamaThinkingFlag`）；其他 loopback 兼容端点只收 OpenAI 形状字段。由于路由配置硬编码走内置 ollama preset，否决路径不受此限制影响。

**残留风险与对策**：若模型仍无视这些字段而思考，表现是空 content（`done_reason=length`），走 `unusable_reply_cases` → `uphold` → 功能**静默失效**。对策：§8.2 审计必须单独记 `unusable` 原因，验收时检查空回复率（见 §12.4）。

## 4. 总体架构

```
用户输入
   │
   ├─► AgentRequestRouter.classify()            同步、零 I/O、零网络
   │      │
   │      └─► Decision（关键词判决）
   │             │
   │             ├─ 非特权档 ──────────────────► 直接采用（与今天一致）
   │             │
   │             └─ 特权档（ops_runner /
   │                 terminal_operator）
   │                        │
   │                        ▼
   │            ┌───────────────────────────┐
   │            │ 并行发起否决确认           │   ← 不阻塞首字
   │            │ AgentWorkerRoutingVeto     │
   │            └───────────────────────────┘
   │                        │
   ├─► 主模型请求（流式）────┤  两者同时进行
   │                        │
   ▼                        ▼
 首字流出              否决判决到位（或超时）
   │                        │
   └────────────┬───────────┘
                ▼
        第一个工具边界
        AppStateAgentLoop.swift:1665
        AgentWorkerRouteGuard.refusal(decision:)
                │
                └─► 此处读到的是**修订后**的 decision
```

要点：`AgentWorkerRouteGuard` 是 `Decision` 唯一产生强制后果的地方，而它在工具边界执行。所以否决判决的截止时间不是"首字前"，而是"第一个工具边界前"——通常有数百毫秒到数秒的富余。这是本设计与不变量 1 相容的根本原因。

## 5. 数据模型

### 5.1 否决判决

```swift
/// 对一次特权档关键词判决的确认结果。
/// 刻意不复用 AgentWorkerRoutingModel.Verdict：那个类型表达"选哪个工种"，
/// 本类型表达"关键词那个判断对不对"，语义不同，混用会让菜单泄漏进否决路径。
struct AgentWorkerRoutingVetoVerdict: Sendable, Equatable {
    /// true = 确认是特权档工作，维持关键词判决
    /// false = 否决，降级
    var upheld: Bool
    /// 0...100，仅用于审计与日志，不参与判定
    var confidence: Int
}
```

契约中的判决格式（新增，与既有 `verdict_format_line` 并列）：

```
{"upheld": true|false, "confidence": 0到100的整数}
```

沿用既有教训：提示词必须显式给出键名，否则本地 gemma4 会改吐 `{"category":...}`（见 `WORKER_ROUTING_CONTRACT.json` 的 `verdict_format_rationale`）。

### 5.2 降级目标

否决成立时，**不是**让模型选一个新工种（那等于提名权），而是**把请求重新交给关键词分类器，跳过特权档分支**：

```swift
// 伪代码
let downgraded = AgentRequestRouter.classify(requestText, skippingPrivilegedBranches: true)
```

这样降级结果仍然完全由关键词表决定，模型只影响"要不要跳过那两个分支"这一个布尔量。可审计、可测试、可预测。

### 5.3 契约新增字段

```json
"veto": {
  "enabled_profiles": ["ops_runner", "terminal_operator"],
  "verdict_format_line": "格式：{\"upheld\":true或false,\"confidence\":0到100的整数}",
  "timeout_seconds": 8,
  "on_unusable_reply": "uphold",
  "model_may": ["downgrade_privileged_decision"],
  "model_must_not": ["nominate_privileged_profile", "choose_downgrade_target"]
}
```

## 6. 关键流程

1. `dispatchAgentMessage` 调 `classify()`，拿到 `Decision`（同步，零网络）。
2. 若 `decision.profileID` 在 `veto.enabled_profiles` 里，且本地模型可用（`enabled` + `preferForWorkerRouting` + 已驻留），则 `Task.detached` 发起否决确认，句柄存进 `runtime.pendingRouteVeto`。**不 await。**
3. 主模型请求照常发出，首字照常流出。
4. 第一个工具边界（`AppStateAgentLoop.swift:1665`）调 `AgentWorkerRouteGuard.refusal` 之前：
   - 若 `pendingRouteVeto` 已完成 → 取结果；
   - 若未完成 → 最多再等 `max(0, 8s - 已用时)`，超时按 `uphold` 处理；
   - 若本轮根本没发起 → 直接用关键词判决。
5. `upheld == false` → 用 §5.2 的降级判决替换 `runtime.currentTurnRouteDecision`，并写一条 `.notice` 日志与审计行。
6. 回合结束时取消未完成的否决任务（遵守不变量 2：不进后台唤醒通道，回合自持、过期即弃）。

### 6.1 提示词

系统提示（中文，与既有判路提示同风格）：

```
用户向一个编程助手发出了下面的请求。关键词规则判断它属于"生产运维"类工作，
也就是要在生产环境或用户可见的终端里执行部署、发布、重启服务这类命令。

请判断这个判断是否正确。判断依据是请求要做的事，不是它提到的词——
提到 deployment、部署脚本、发布流程的文件名或代码，并不等于要执行部署。
修改文件、阅读代码、解释配置，都不是生产运维。

只输出 JSON，不要解释。格式：{"upheld":true或false,"confidence":0到100的整数}
```

用户提示：`请求：` + 前 600 字符（复用 `classifiedPrefixLength`）。

## 7. 不可让渡的安全不变量

1. **模型永远不能使任何请求获得它在纯关键词路径下不会获得的权限。** 否决路径的每一个输出都指向权限相等或更小的判决。实现上体现为：降级目标由 `classify(skippingPrivilegedBranches: true)` 决定，模型不参与选择；`AgentWorkerRoutingModel` 的候选菜单保持不变，`ops_runner` / `terminal_operator` 仍在 `excluded_profiles` 里。
2. **拦截点不变，仍在执行路径。** `AgentWorkerRouteGuard` 依旧是唯一的强制点，依旧在工具边界。本设计只改变它读到的 `Decision`，不改变它的判定逻辑，更不在 UI 层做任何拦截。
3. **不可用即维持。** 超时、空回复、JSON 非法、`upheld` 字段缺失或非布尔，一律按 `upheld = true` 处理。任何解析歧义都倒向"保持特权档"。
4. **`/no-subagent` 仍是硬边界。** `delegationPolicy == .forbidden` 时不发起否决确认（此时 guard 本就不生效）。
5. **操作员点名不可否决。** `decision.isOperatorPinned` 为真时跳过否决——用户手动选的 Worker，模型无权改。
6. **否决必须留痕。** 每一次否决成立都写审计行，见 §8.2。一个能悄悄改变路由的机制，出了问题必须能查。

## 8. 失败与边缘状态

| 状态 | 用户看到什么 | 系统行为 |
| --- | --- | --- |
| 本地模型未启用 / 未驻留 | 与今天完全一致 | 不发起否决，关键词判决直接生效 |
| 否决任务超时（8s） | 与今天一致 | `uphold`，日志 `.notice` |
| 否决成立，降级为 implementer | composer 上方工种名从「运维」变成「实现」 | 替换 decision，guard 不再拦 |
| 否决判决在工具边界后才回来 | 无感知 | 丢弃（回合已经按关键词判决走完） |
| 回合被用户中断 | 无感知 | 取消否决任务 |
| Ollama 掉线 | 与今天一致 | 复用 `AgentLocalModelResidency` 的 60 秒负缓存 |

工种名变化的可见性有一个取舍：如果否决在首字之后才到位，用户会看到 composer 上方的工种标签中途跳变一次。**默认接受这个跳变**（它反映了真实状态），但若 review 认为跳变比错误标签更糟，可以改成"判决未定时显示中性文案"，见 §15 问题 3。

### 8.2 审计

新增 `~/Library/Application Support/WillDeep/AgentAudit/route-veto.jsonl`，与既有 `judge.jsonl` / `sandbox.jsonl` 同族（`AgentDiagnosticsBundle.swift:147` 一并登记）。每行：

```json
{"at":"2026-09-14T15:52:21Z","sessionID":"...","keywordProfile":"ops_runner",
 "matchedMarker":"deploy","upheld":false,"confidence":88,
 "downgradedTo":"implementer","elapsedMs":1840,"model":"gemma4:e2b-it-qat",
 "requestPrefix":"那你把 deployment 里的注解改一下"}
```

`matchedMarker` 是关键的一列：它让"哪个词在误伤"这个问题可以直接查，而不是靠猜。既有的 `worker-timing.jsonl` 只记 `routeProfileID` / `routeConfidence`，区分不出关键词与模型来源（`REVIEW_2026-09-03` §3.5）。

## 9. 兼容与迁移

- 无持久化格式变更。`Decision` 是值类型，不落盘。
- 跨端：`WORKER_ROUTING_CONTRACT.json` 是 Swift / Rust 双端唯一事实来源，两侧各有守卫测试。**Rust 侧可以先只实现"读得懂新字段"**，否决逻辑本身按 `NEXT_TASKS_2026-09-03` 任务 F 的方式单独排期——契约里的 `veto` 段对未实现方是可忽略的附加段。
- 老版本：本功能默认关（跟随本地模型总开关），旧版本行为不变。

## 10. UI 设计

不新增界面。唯一的可见变化是 composer 上方的 Worker 标签可能中途从「运维」变为「实现」（见 §8 的取舍）。

设置页 `AgentLocalModelSettingsView.swift:49` 现有的「Worker 派发判断先用本地」开关文案需要补一句，说明它现在也用于纠正运维误判。文案走 i18n，五种语言（en / zh-Hans / ja / es / fr）同步，与 `knownRegions` 一致。

## 11. 分期落地

| 期 | 内容 | 可独立验收 | 预计版本 |
| --- | --- | --- | --- |
| P0 | 修正 `WORKER_ROUTING_CONTRACT.json` 的 `fallback_chain`（§1.5），并给该字段补上双端守卫断言 | 是 | 1.373.0-rc4 |
| P1 | 否决路径主体：`AgentWorkerRoutingVeto`、并行发起、工具边界取用、降级判决、审计 jsonl | 是 | 1.374.0-rc1 |
| P2 | 契约 `veto` 段 + Swift 侧守卫测试；设置页文案与 i18n | 是 | 1.374.0-rc2 |
| P3 | 路由模型与 `summaryModel` 解耦，单独可选（见 §13 风险 2） | 是 | 待定 |
| P4 | willdeep-rs 侧实现（跨仓库，单独排期，任务 F） | 是 | 待定 |

P1 之前先做 P0，因为契约不一致会让 P2 的守卫测试建在错误的基线上。

## 12. 测试计划与验收

### 12.1 单元测试

新增 `XeditTests/AgentWorkerRoutingVetoTests.swift`（独立 `@Suite`，不要挂进 `WillDeepTests` extension——否则 `-only-testing` 选不中，见 `docs/` 与项目记忆里的既有教训）：

| 用例 | 断言 |
| --- | --- |
| 否决成立 → 降级 | `ops_runner` + `upheld: false` → 结果 profileID 不是特权档，且 `enforcesDelegatedExecution(for: .automatic) == false` |
| 否决不成立 → 维持 | `upheld: true` → decision 逐字段等于关键词判决 |
| 超时 → 维持 | 模拟 8s 不回 → 维持，且不抛错 |
| 空回复 / 非法 JSON → 维持 | 复用 `unusable_reply_cases` 的四种情形 |
| **模型不能提名特权档** | 喂一个非特权档的关键词判决，无论模型返回什么，结果都不是 `ops_runner` / `terminal_operator` |
| 操作员点名不可否决 | `isOperatorPinned` → 不发起否决 |
| `/no-subagent` → 不发起 | `delegationPolicy == .forbidden` |
| 降级目标由关键词决定 | 同一请求两次否决，降级结果相同（确定性） |

### 12.2 回归

`AgentRequestRouterTests`、`AgentHybridWorkerRoutingTests`、`AgentWorkerRoutingModelTests`、`AgentWorkerRoutingContractTests`、`AgentReadOnlyPreflightTests`、`AgentPinnedWorkerTests`、`AgentSpeculativeScoutTests` 全绿。

判定方式（本仓库有假绿前科）：不看退出码，不看 `Test Suite ... passed`，只认日志里的 `✘` 计数与 `Test run with N tests in M suites` 的 M 值对得上。

### 12.3 手工验证

1. 开本地模型加速 + 常驻，模型设为 `gemma4:e2b-it-qat`。
2. 在任意仓库输入「那你把 deployment 里的注解改一下」。
3. 预期：composer 工种不是「运维」（或短暂显示后降级），助手可以直接编辑文件而不被 guard 拦。
4. 输入「部署到生产环境」。
5. 预期：工种是「运维」，`route-veto.jsonl` 里该行 `upheld: true`。
6. 关掉 Ollama，重复步骤 2。
7. 预期：行为回到关键词判决（显示「运维」），无卡顿、无报错。

### 12.4 验收标准

- 上述单测全绿，且「模型不能提名特权档」这条用例存在。
- `route-veto.jsonl` 能查到判决记录，含 `matchedMarker`。
- 关掉本地模型时，端到端行为与 1.373.0-rc3 无差异。
- 首字延迟不因本功能增加：`worker-timing.jsonl` 里 `firstTokenAt - requestSentAt` 在开关开/关两组间无统计差异。

## 13. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 小模型误否决真运维请求 | 真要部署时 guard 不拦了，主模型可能直接跑生产命令 | 这是本设计最大的风险。对策：否决只移除**强制**，不移除 steering——降级后的 decision 仍带建议性 steering 提示大脑考虑派 Worker；且危险命令黑名单、审批档位、沙箱四道闸与本设计正交，一道没动 |
| 路由复用 `summaryModel`（e4b） | e4b thinking 关不干净时慢 15–20 倍、偶发空回复，否决大概率超时 → 永远 uphold → 功能等于没上线 | P3 把路由模型拆成独立配置，默认 `gemma4:e2b-it-qat`。在此之前本功能的实际收益取决于用户的 summaryModel 选择，文档需说明 |
| 冷启动缺席 | 头几轮误判照旧 | 已有 `AgentLocalModelResidencyKeeper` 常驻开关（1.318.0-rc1）；文案引导用户开启 |
| 工种标签中途跳变 | 观感 | 见 §8 取舍与 §15 问题 3 |
| 增加一条可静默改变路由的路径 | 排查难度 | §8.2 的审计 jsonl 是这条风险的直接对策，必须与主体同期落地，不可延后 |
| 与 2026-09-17 的判路模型去留决策冲突 | 可能白做 | 本文档即为该决策的输入之一；建议 §15 问题 1 一并拍板 |

## 14. Non-goals

- **不做**让模型选择降级目标。降级目标永远由关键词分类器决定。
- **不做**把 `ops_runner` / `terminal_operator` 放进 `AgentWorkerRoutingModel` 的候选菜单。`excluded_profiles` 保持不变。
- **不做**继续扩充关键词表。rc3 的词边界修复之后，词表不再追求穷举精确。
- **不做**给非特权档（scout / implementer / editor 等）加否决。它们判错的代价不值一次模型往返。
- **不做**远程模型回落。判路不计费这条既有决定（1.317.0-rc8）保持不变。
- **不做**首字前同步等待。任何形态的"先问模型再回答"都违反不变量 1。
- **不做** willdeep-rs 侧的同期实现。跨仓库单独排期。

## 15. 待确认问题

无。六条已于 2026-09-14 全部拍板，见 §3 与 §16。

## 16. 已确认决策（2026-09-14）

用户逐条确认，六条全部采用文档给出的默认假设，另追加一条硬性要求：

> 4. 不提前。**而且我们一定要关 thinking 啊。**

thinking 的核实结论见 §3.1：当前路径已关死（三字段齐发），残留风险是模型无视字段导致空回复、功能静默失效，对策是审计单独记 `unusable` 原因并在验收时检查空回复率。

实施顺序按 §11：P0（契约修正）→ P1（否决路径主体）→ P2（契约 veto 段 + i18n）。P3 / P4 待定。

### 16.1 落地后补记的实现要点（P1，1.374.0-rc1）

**一、等待点从一个变成两个。设计漏了串行预执行。**

§4 的架构图只画了「工具边界收否决」。实现时查派发时序（`AppStateAgentLoopDispatch.swift:295-330`）才发现，`runReadOnlyPreflightIfNeeded` 是**首字前的 await**，并且它会照着路由判决真的把 worker 派出去——否决若等到工具边界才回来，worker 已经在跑了，降级也追不回来。

改为两个收取点：

| 预执行 | 收否决的位置 | 首字代价 |
| --- | --- | --- |
| 关（默认） | 第一个工具边界 | 零，完全并行 |
| 开 | `runReadOnlyPreflightIfNeeded` 之前 | 多等一次，但这条路径本来就是显式开启的同步路径 |

`resolveRouteVetoIfPending` 做成幂等（进门即清 ticket），所以两处都调也只有第一处真的等。§4 的图对默认配置仍然准确。

**二、`case let value as Bool` 不等于「只认布尔」。**

`JSONSerialization` 把 JSON 数字桥接成 `NSNumber`，而 `NSNumber as? Bool` 对 `0` / `1` 都会成功。于是 `{"upheld":0}` 会被读成一次**凭空的否决**——一个数字就能撤掉特权保护，而代码和注释读起来都像是在防这件事。改用 `CFGetTypeID(value) == CFBooleanGetTypeID()`。

这条是测试抓出来的，前提是把「模型答非所问的各种形态」当正经用例写，而不是只测 happy path。

**三、§8 与 §10 关于 UI 标签的描述需要再验证。**

文档写「composer 上方工种名从『运维』变成『实现』」。但该标签取自 `AgentSubagentFleetStatus.make(from: appState.agentToolCalls)`，即**正在跑的 `spawn_agent` 卡片**，而不是 `currentTurnRouteDecision`。预执行关着时本就没有这张卡片，也就无从跳变；预执行开着时否决在派发前就收了，卡片从一开始就是降级后的工种。

也就是说**两种配置下都不会出现设计里描述的那次跳变**，§3 决策 3 讨论的那个取舍在当前实现下不成立。功能行为不受影响（guard 读的是 decision，不是卡片），但文档的 UI 描述偏乐观了，标注为待验证；真要让标签反映否决，需要另接一条不依赖卡片的路径，属于 P2 之后的事。

**四、P2 已补齐（1.374.0-rc2）**：契约 `veto` 段（§5.3）与守卫断言、设置页文案五语言同步（§10）。
顺带修正了一句已经不准确的旧文案——原文说「只有含糊请求会询问本地 LLM」，否决问的是特权档而非含糊请求。

剩余未做：P3（路由模型与 `summaryModel` 解耦）、P4（willdeep-rs 侧实现）。§16.1 第三条那个 UI 标签的待验证项也仍未处理。

## 附：相关文档

- [REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md](REVIEW_2026-09-03_WORKER_ROUTING_LATENCY.md) — §3.1 判路模型名存实亡、§4 三条原则
- [NEXT_TASKS_2026-09-03_WORKER_LATENCY.md](NEXT_TASKS_2026-09-03_WORKER_LATENCY.md) — 任务 E.2 决策点、§4 三条不变量
- [WORKER_ROUTING_CONTRACT.json](WORKER_ROUTING_CONTRACT.json) — 双端契约，`excluded_profiles` 的既有理由
- [SMALL_MODEL_FIRST_RUNTIME_PLAN.md](SMALL_MODEL_FIRST_RUNTIME_PLAN.md) — §4 预执行、§6 共享配置键表
- [WORKER_TIMING_LOG.md](WORKER_TIMING_LOG.md) — 端到端计时字段
