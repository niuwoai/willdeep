# 开工前复杂度判定与文档先行门设计

> Last updated: 2026-09-10 | 状态：**已确认，实施中**（2026-09-10 用户拍板：六项待确认全部按默认）
> 关联版本：基于 1.364.0-rc1（develop @ 09d187f7）
> 适用范围：Xedit（WillDeep macOS App）普通模式
> 关联文档：`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`、`docs/LONG_HORIZON_AUTONOMY.md`、`docs/GOAL_TEAMS_ROLES_DESIGN.md`、`docs/AGENT_EXECUTION_FRICTION_AUDIT_2026_08.md`
> 一句话：复杂任务开工前先由宿主确定性信号筛一道、模型复核一次，命中就先写一份设计文档落到 `docs/`，锁住写工具等用户点头。

---

## 0. 需求来源

用户原话：「我希望我们有套类似的技能，1、在复杂的需求时，先生成需求和设计、架构文档；2. 文档能当作产物分享出去。」随后明确「我要的是 WillDeep 具有这个能力」。

本轮先做第 1 件事。第 2 件（文档产物化分享）不在本设计范围内，见 §14。

**这不是新功能，是一次带条件的复活。** 详见 §1.3 与 §2.2。

---

## 1. 现状盘点（代码锚点）

### 1.1 复杂度判定：存在，但只用来选模型

| 位置 | 现在干什么 | 缺口 |
| --- | --- | --- |
| `Xedit/SomeIMManagedRouting.swift:66-73` | `SomeIMManagedComplexity { low, high }`，判据是「简单局部单步」对「复杂多步跨文件架构算法安全疑难调试」 | 判定结果只映射到能力档位 |
| `Xedit/AppStateAgentLoop.swift:531-545` | 把裁决写进 `turnConfiguration.model` | 唯一消费者是选型，无任何代码读它做别的决定 |
| `Xedit/AppStateAgentLoop.swift:500-501` | 双条件硬门禁：`managedRouting != nil` 且 provider 是 some.im | 自带 key 的用户根本不跑这次判定 |
| `Xedit/AgentRequestRouter.swift:188` | `classify(_:)` 关键词路由，纯本地零成本 | 输出是派给哪个 Worker 工种，不是复杂度 |

### 1.2 计划机制：刻意设计成事后测量

| 位置 | 现在干什么 |
| --- | --- |
| `Xedit/AgentPlanOnDemandPolicy.swift:44-63` | 已有成功写操作且工具轮次 ≥ 4，或成功写调用 ≥ 3，才要求补计划 |
| `Xedit/AgentPlanOnDemandPolicy.swift:66-77` | `requestNotice` 明说 `Planning is not a stopping point and needs no approval` |
| `Xedit/AppStateAgentSessions.swift:736-751` | 普通模式计划解析出来直接 `.approved`，无任何批准门 |
| `Xedit/AgentPlanGoalModels.swift:613-618` | `AgentPlan.Status.proposed` / `.rejected` 是死枚举值，注释写明仅为持久化兼容保留 |

`AgentPlan.Status.proposed` 虽然没有生产者了，**四处 UI 基建仍然认它**，这是本设计最便宜的复用点：Dock 徽标与快跳判定 `Xedit/AgentSessionApprovalBadge.swift:33-45`、侧边栏待办条 `Xedit/AgentSidebarPendingApprovalStrip.swift`、内核事件投射 `Xedit/AppStateAgentRuntimeKernel.swift:451-470`、计划卡默认展开 `Xedit/AgentPlanGoalCards.swift:87-89`。

### 1.3 这件事被做过，然后被砍掉

`CHANGELOG.md:8941`（1.211.0-rc6，2026-07-28）：

> **顶层交互收敛为普通 / Goal 两种模式**：移除独立 Plan 模式、复杂任务切换建议、倒计时横幅及计划批准/拒绝门禁。

被砍掉的那个切换建议，形态见 `CHANGELOG.md:12983`：普通模式发送前用保守的本地评分识别多步骤、跨文件、架构重构、迁移与测试验证的组合任务，命中后显示「直接执行 / 进入 Plan」提示条和 8 秒倒计时，用户不操作就自动切换。

按需计划那次改动给出了更根本的判断，`CHANGELOG.md:3319`：

> 判断权从"模型预测"收归"宿主测量"……模型对 "genuinely multi-step" 的判断系统性偏严——建计划显得尽责，宁滥勿缺，提示词层已被现实证伪。

策略文件里的原文更直接，`Xedit/AgentPlanOnDemandPolicy.swift:10-25`：`Models systematically over-trigger on that judgment — planning looks diligent`，结论是 `nothing plans upfront`。

**任何不正面回应这两条的设计都会被再砍一次。** §2.2 是本文档的核心，不是背景。

### 1.4 阻断与恢复：两套现成机制可照抄

| 机制 | 位置 | 可复用的部分 |
| --- | --- | --- |
| planning-only 门禁 | `Xedit/AppStateAgentLoop.swift:1931-1947` | 用户说「只规划别执行」时，write 与 danger 类工具在 Stage 1 被硬拦并回一句明确话术。**这就是本设计要的拦截形状，只需加一个触发源** |
| 判定谓词 | `Xedit/AgentPlanContinuation.swift:89` | `AgentExecutionIntentPolicy.blocksExecution(risk:)` 已经定义了「哪些风险等级算执行」 |
| dispatch 决策挂起 | `Xedit/AppStateAgentDispatchDecisions.swift:24-59` | 在任何副作用之前截住整批工具调用，把请求持久化，回合直接结束 |
| dispatch 决策恢复 | `Xedit/AppStateAgentDispatchDecisions.swift:91-135` | 复用同一 runtime 与同一份 messages，追加一条 `role: .user, source: .hostInstruction`，再 `dispatchAgentMessage` 续跑。带 digest 防重放 |

### 1.5 写 docs/*.md 的摩擦：零

`create_file` / `edit_file` / `apply_patch` 的风险等级都是 `.read`（`Xedit/AgentToolRegistry.swift:216`、`:237`、`:250`），不进审批卡分支。默认智能审核档下补丁自动落盘（`Xedit/AppStateAgentPatches.swift:631-649`），只有严格模式才需要用户点 Apply。

**结论：产出文档这一步不需要新建任何权限通道，需要新造的只是写完之后的「停」。**

### 1.6 判官的历史事故

`Xedit/AgentInjectionDefense.swift:460-493` 完整记录了智能审批安全裁判的翻车：输出预算最初 16 tokens，被隐藏推理吃光后每次返回 unclear；改 512 仍不够，实测判官在吐结论前先写 1800 到 3100 字符私有推理；**失败方向最坏，命令越复杂推理越长越容易掉线，而复杂命令正是裁判存在的理由**。现值 8192，超时同步抬到 35 秒。

量化后果见 `docs/AGENT_EXECUTION_FRICTION_AUDIT_2026_08.md:151-195`：1967 条裁决里 305 条不可用，八月以来 24%。

现役路由判官之所以 384 tokens 够用，唯一原因是它显式关掉思考（`Xedit/AgentClientOpenAIChat.swift:296-300`），且 `Xedit/SomeIMManagedRouting.swift:154-158` 的注释把这件事写死了。

---

## 2. 结论：确定性信号筛一道，模型只做复核，命中才停

三层结构，成本从零递增，任何一层失败都往「不挡路」的方向倒。

### 2.1 设计原则

1. **判定权在宿主，模型只有否决权**。模型不能把一个宿主认为简单的任务升级成复杂任务，只能把宿主怀疑复杂的任务降级放行。这直接对冲「模型系统性过度触发」。
2. **判定失败一律 fail-open**。判官超时、截断、无 key、解析不出，全部当作简单任务放行。挡错的代价是打断用户，放过的代价只是少写一份文档，两者不对称。
3. **先影子后阻断**。第一期只记录不拦人，用真实误报率决定阈值，而不是拍脑袋定分数。当年缺的就是这一步。
4. **停顿必须可解释**。用户看到的不是「系统认为这很复杂」，而是命中了哪几条具体信号。
5. **新逻辑落独立文件**。`Xedit/AppStateAgentLoop.swift` 已经 3002 行，踩在 `scripts/complexity_guard.rb` 的 3000 行硬阈值上。

### 2.2 和 2026-07 那次的区别

| 当年的做法 | 当年的问题 | 这次怎么改 |
| --- | --- | --- |
| 本地评分命中就弹条 | 评分是唯一判据，误报直接打断用户 | 评分只是**准入筛**，命中后还要过模型复核这道减法，且第一期完全不拦人 |
| 8 秒倒计时后自动切模式 | 用户不操作等于默认同意，沉默被当成授权 | **永不自动往前走**。用户不操作就一直停着，Dock 徽标亮着 |
| 切进 Plan 模式，产物是计划 | 计划不落盘，关掉会话就没了，也无法 review | 产物是 `docs/` 下的 markdown 文件，可 review 可追溯可交接 |
| 顶层多一种模式 | 模式枚举、持久化兼容、UI 选择器全要改，认知负担也重 | 普通模式里加一道可开关的门，不动顶层模式结构 |
| 判定结果无处可查 | 没有审计，无法证明它判得准不准，只能凭感觉砍掉 | 每次判定落 `spec-gate.jsonl`，含信号、裁决、用户最终选择。**误报率是可以算出来的数字** |

---

## 3. 已拍板的决策（2026-09-10）

| # | 决策 | 推论 |
| --- | --- | --- |
| 1 | 宿主确定性信号为主，模型只做复核 | 判定分两级，L2 只在 L1 命中时才跑，日常消息零额外开销 |
| 2 | 判定为复杂后硬阻断，写工具锁到用户点头 | 复用 planning-only 那条现成硬拦，不新增拦截点 |
| 3 | 接在普通模式里，做成可开关的门 | 不复活 Plan 模式，不动 `AgentInteractionMode` 枚举 |
| 4 | 文档落 `docs/` 的 md 文件，会话里一张卡指向它 | 需要新增一种消息 role，卡片承载确认与驳回按钮 |

---

## 4. 总体架构

```
用户消息
  ↓
[同步段] 关键词路由分类 (AgentRequestRouter.classify)      ← 已存在
  ↓
[异步段] 本地小模型精修路由                                  ← 已存在
  ↓
★ L1 确定性准入筛 (AgentSpecGateSignals)                    ← 新增，纯函数，零成本
  ↓ 未命中 → 照常开工
  ↓ 命中
★ L2 模型复核 (AgentSpecGateJudge)                          ← 新增，一次非流式请求，可失败
  ↓ 判为简单 / 判定失败 → 照常开工（fail-open）
  ↓ 确认复杂
★ 置 runtime.specGateState = .awaitingDocument              ← 新增
  ↓
runAgentLoop：系统提示词注入「先写设计文档」段
  ↓
模型用 create_file 写 docs/XXX_DESIGN.md                     ← 零摩擦，已有能力
  ↓
★ 宿主检测到文档已落盘 → 结束回合，发内核事件               ← 新增
  ↓
★ transcript 出现 .specProposal 卡片，写工具全锁             ← 新增
  ↓
用户点「按这份文档开工」
  ↓
★ 追加 hostInstruction 消息，同 runtime 续跑                 ← 照抄 dispatch decision
```

代码落点，全部是新文件：

| 文件 | 职责 | 可单测 |
| --- | --- | --- |
| `Xedit/AgentSpecGateSignals.swift` | L1 纯函数：输入信号结构体，输出命中的信号列表与分数 | 是，无依赖 |
| `Xedit/AgentSpecGateJudge.swift` | L2 纯逻辑 + 注入式 judge 闭包，照 `SomeIMManagedRouting` 的形状 | 是，闭包可打桩 |
| `Xedit/AgentSpecGateState.swift` | 门的状态机与持久化模型 | 是 |
| `Xedit/AppStateAgentSpecGate.swift` | AppState 扩展：调用点、恢复、审计写入 | 部分 |
| `Xedit/AgentSpecProposalCardView.swift` | 卡片视图 | 快照 |

`Xedit/AppStateAgentLoop.swift` 只加一处调用，位置在第 297 行之后（本地小模型精修路由与只读 preflight 之间），不加逻辑。

---

## 5. 数据模型

```swift
/// L1 命中的单条信号。用户看到的解释直接由它渲染，不另写文案。
struct AgentSpecGateSignal: Codable, Hashable {
    enum Kind: String, Codable {
        case crossModuleKeywords     // 跨模块、架构、迁移、协议、数据格式
        case explicitRequest         // 用户明说「先出设计」「做个方案」
        case newSubsystem            // 新增子系统、新模块
        case persistenceChange       // 改存档格式、迁移、跨版本兼容
        case multiSurface            // 跨端：macOS / Android / Go 网关 / 插件页
        case vagueGoal               // 描述的是问题或愿望，没有落点
    }
    let kind: Kind
    let evidence: String             // 命中的原文片段，截 200 字符并脱敏
}

/// 结构化裁决。刻意不是 Bool，照 AGENT_HARNESS_IMPROVEMENT_PRIORITIES 里
/// 「把 AgentToolApprovalSource? 升级为结构化审核结果」那条建议的形状。
struct AgentSpecGateVerdict: Codable {
    enum Outcome: String, Codable { case proceed, gate }
    enum Reason: String, Codable {
        case belowThreshold          // L1 没命中
        case judgeDowngraded         // L2 判为简单
        case judgeUnavailable        // L2 失败，fail-open
        case confirmed               // L2 确认复杂
        case disabled                // 开关关着
        case shadowOnly              // 影子期，记录但不拦
        case userOptedOut            // 用户本会话已选择不再判定
    }
    let outcome: Outcome
    let reason: Reason
    let signals: [AgentSpecGateSignal]
    let judgeModel: String?
    let judgeLatencyMS: Int?
}

/// 门的状态，随会话持久化。
enum AgentSpecGateState: String, Codable {
    case inactive
    case awaitingDocument            // 已判定，等模型写文档
    case awaitingUserReview          // 文档已落盘，等用户点头
    case released                    // 用户已确认，本会话不再判定
}
```

`AgentSpecGateState` 与两个枚举都必须写手动 `init(from:)` 容错，未知取值降级为 `inactive`。理由见 `Xedit/AgentPlanGoalModels.swift:78-85`：旧版本读到新档位时合成 Codable 会 throw，用户看到的是整个会话从列表里消失。

---

## 6. 关键流程

### 6.1 L1 准入筛

纯函数，输入是已有的信号，不新增任何采集：用户消息原文、`currentTurnRouteDecision`、workspace 是否可用、当前选中文件语言、会话内已有的消息数。

命中规则：任一强信号（`explicitRequest` / `newSubsystem` / `persistenceChange`）单独成立，或任意两条弱信号同时成立。阈值写成常量，第一期靠影子数据校准。

**只对 `source == .operatorInput` 生效**。系统回灌、工具循环续跑、dispatch 恢复都不判定，否则续跑一次触发一次。

### 6.2 L2 模型复核

只在 L1 命中时跑。判官选型按成本从低到高：

1. 本地已热的路由模型（`Xedit/AgentLocalModelSupport.swift:722-739` 的 `readyWorkerRoutingConfiguration`）。零成本零外发，冷的直接跳过不预热。
2. some.im 托管用户：复用现役路由判官的传输，`enable_thinking:false`，预算 384 足够。
3. 自带 key 用户：走 `Xedit/AppStateAgentToolDecisions.swift:1481-1508` 的 `safetyJudgeCandidateConfigurations()` 候选链。

**预算与超时按最坏情况给**，这是 §1.6 那次事故的直接教训：无法确认关掉思考的路径，输出预算给 4096，超时 20 秒。Anthropic 路径按模型上限钳制 `max_tokens`（照 `Xedit/AgentClientAnthropic.swift:196-207`），否则某些模型上是硬 400 而不是降级。

判官的提问方向是**减法**：「以下任务已被初筛判为复杂，请判断是否其实是一次局部改动。」这样模型的偏严倾向会推向放行，而不是推向拦截。

失败一律 fail-open，且 `judgeLogger.warning` 留痕。理由见 `Xedit/SomeIMManagedRouting.swift:487-490` 的注释：审批判官曾因为失败路径正好是静默的，连续失败数月无人发现。

**「没有判官」不算失败**（2026-09-10 实现期补充的区分，原设计漏了）。上面三条路径全都不可用是很常见的状态：没热本地模型、不是托管用户、也没有第二个带 key 的 provider。如果把这种情况当作 fail-open 放行，P4 上线后 gate 对这批用户直接整体失效，P3 等于白做。所以：

| 情况 | 原因码 | 结果 |
| --- | --- | --- |
| 判官答了，判为局部改动且置信足够 | `judgeDowngraded` | 放行 |
| 判官答了，判为不是局部改动 | `confirmed` | 拦 |
| 问了但没答上来：超时、截断、解析不出 | `judgeUnavailable` | 放行 |
| 压根没有判官可问 | `judgeUnconfigured` | **按 L1 结论走，即拦** |

置信度不足的「大概是局部改动」不算数（阈值 0.6）。判官唯一能推动结果的方向是不拦，所以含糊不能帮它。

### 6.3 阻断

置 `runtime.specGateState = .awaitingDocument` 后进 `runAgentLoop`。

拦截**不新增拦截点**，在 `Xedit/AppStateAgentLoop.swift:1931-1947` 那条 planning-only 硬拦上加一个触发源，判定谓词复用 `AgentExecutionIntentPolicy.blocksExecution(risk:)`。回给模型的话术改成：

> Blocked: this task was gated for a written design first. Create the design document under `docs/`, then stop. Do not ask for approval and do not start implementing.

`ask_user`（`.userInput`）豁免，与现有各门禁一致。文件工具是 `.read` 不受影响，模型能正常写文档。

### 6.4 停下与恢复

模型写完文档、本轮结束时，宿主检查 `docs/` 下是否新增或修改了 markdown 文件：

- 有 → `specGateState = .awaitingUserReview`，插入一条 `.specProposal` 消息挂上文档路径，发一条 `requiresUserAction: true` 的内核事件（`Xedit/AppStateAgentRuntimeKernel.swift:481-509`），回合结束。Dock 徽标、侧边栏待办条、Event Center 自动亮起，跨重启不丢。
- 没有 → 门降级为 `inactive` 并留一条审计，**不重试**。模型不写文档就不写，卡在这里比放它过去更糟。

用户点「按这份文档开工」后，照抄 `Xedit/AppStateAgentDispatchDecisions.swift:128-135`：复用同一 runtime 与同一份 messages，追加一条 `role: .user, source: .hostInstruction` 的消息，内容是文档路径加一句权限约束（「这次确认只解除设计门，不授予任何新的工具权限」），然后 `dispatchAgentMessage(..., existingUserMessageID:, source: .hostInstruction)` 续跑。`specGateState` 转 `.released`，本会话不再判定。

---

## 7. 不可让渡的安全不变量

1. **确认设计门不等于授予权限**。恢复消息里必须带明确约束，且恢复后所有工具照常走各自的审批与沙箱判定。拦截点在执行路径（Stage 1 的工具分类环节），不是 UI。
2. **用户 Stop 是终态**。Stop 之后门不得自行恢复、不得在后台续跑，与 `docs/LONG_HORIZON_AUTONOMY.md:242-246` 的既有 Non-goal 一致。
3. **永不自动往前走**。没有倒计时，没有超时默认同意。沉默永远解读为「还没决定」。
4. **判官载荷脱敏**。只发抽象信号与截断后的消息片段，不含本地路径、key、token，照 `Xedit/SomeIMManagedRouting.swift:23-25`。
5. **审计能区分「判过并放行」与「没判到而放行」**。`Reason` 枚举把 `judgeDowngraded` 和 `judgeUnavailable` 分开，照 `Xedit/AppStateAgentToolDecisions.swift:1228-1245` 那个 `allowedWithoutVerdict` 的教训。

---

## 8. 失败与边缘状态

| 场景 | 表现 |
| --- | --- |
| 开关关闭 | 完全不判定，零开销，一条审计都不写 |
| 影子期 | 判定照跑，落审计，**不拦人不出卡片不打扰** |
| L2 无可用判官 | fail-open 放行，审计记 `judgeUnavailable` |
| L2 超时 | 同上。开工前不能让用户等在判官身上 |
| 模型不写文档 | 门降级放行并留痕，不重试不追问 |
| 文档写了但用户驳回 | 卡片提供「直接开工」与「本会话不再判定」两个出口，文档留在仓库里 |
| 无 workspace | 不判定。没有工作区就没有 `docs/` 可写 |
| dispatch 无人值守子任务 | 不判定。没人看那张卡，照 `Xedit/AgentPlanOnDemandPolicy` 里同样的排除逻辑 |
| Goal 模式 | 不判定。那里已有证据规划门，两道门叠加会互相打架 |
| App 重启 | `specGateState` 随会话持久化，卡片与内核事件都在，恢复后照常等确认 |

---

## 9. 兼容与迁移

- 新增的 role、状态、审计文件都是增量，旧会话解码为 `inactive` 与 `nil`。
- 三个新枚举全部手写容错 `init(from:)`，未知值降级而不 throw。
- 不改 `AgentInteractionMode`，不复活 `.plan`，旧会话的模式解码路径不受影响。
- `AgentPlan.Status.proposed` 保持现状不动，本设计不复用它做计划批准，只复用它带起来的那四处 UI 基建的判定入口。

---

## 10. UI 设计

新增一种消息 role `.specProposal`，卡片内容：命中的信号列表（逐条给证据原文）、文档路径可点击打开、三个按钮。

| 按钮 | 行为 |
| --- | --- |
| 按这份文档开工 | 转 `.released`，续跑 |
| 我先改改文档 | 保持等待，用户编辑完再点第一个 |
| 直接开工，别管文档 | 转 `.released` 并记审计 `userOptedOut`，这是误报的主要度量口径 |

卡片状态可变（等待 → 已确认 / 已驳回），所以 **`messageHash` 必须包含每个展示字段**，照 `Xedit/AgentChatHistoryFormatter.swift:178-195` 里 `workflowReport` 的写法。widget 与 scheduledTask 没进 hash 是因为它们是不可变快照，本卡片不是，漏了这一步的表现是卡片永远停在初始状态。

新增 role 要补齐的穷尽 switch 覆盖十余个文件，含四个 provider 客户端的跳过分支、transcript 可见白名单、面板可见性、压缩摘要标签、阅读器标签。编译器能兜住大部分，`Xedit/AgentChatTranscript.swift:938-953` 的可见白名单兜不住，漏了卡片会被当 system 过滤掉。

文案走 `Xedit/Localizable.xcstrings`，用 `ruby scripts/i18n_add_keys.rb`，至少给 en 与 zh-Hans，否则 `scripts/i18n_coverage_guard.rb` 报红。不要全量解析回写 catalog。

---

## 11. 分期落地

| 期 | 内容 | 可独立验收 | 预计版本 |
| --- | --- | --- | --- |
| P1 | L1 信号 + 结构化裁决 + `spec-gate.jsonl` 审计 + 开关，**影子模式，不拦人** | 是 | 1.365.0-rc1 ✅ |
| P2 | 用误报率校准阈值，出一份数据小结 | 是 | 无代码，**待做** |
| P3 | 阻断 + 提示词段 + `.specProposal` 卡片 + 确认恢复 | 是 | 1.366.0-rc1 ✅ |
| P4 | L2 模型复核接入判官 | 是 | 1.366.0-rc1 ✅ |

P1 与 P2 之间必须真实跑一段时间。**这是本设计与 2026-07 那次最大的流程差异**：当年是先做完再看效果，效果不好只能整个砍掉；这次先拿数据再决定要不要装门。

**P3 与 P4 已于 P2 之前落地**（用户 2026-09-10 决定不等数据）。这个顺序调整没有推翻 P2 存在的理由，只是把它从「前置闸门」改成「默认值的依据」：阻断档 `com.willdeep.agentSettings.specGateEnforcement.v1` **默认关**，判定与审计照常跑。误报率达标之前，这个开关不会改默认值。

---

## 12. 测试计划与验收

单元测试（新 suite `AgentSpecGateTests`）：

- L1 六类信号各自命中与不命中，强信号单条成立、弱信号需两条。
- 非 `operatorInput` 来源一律不判定；无 workspace、dispatch 子任务、Goal 模式三种排除各一条。
- L2 打桩：判为简单则放行、超时则 fail-open、返回半截 JSON 则 fail-open，三条 `Reason` 各自正确。
- 状态机：`awaitingDocument` 下 write 被拦而 `ask_user` 与文件工具放行。
- 恢复：确认后消息以 `hostInstruction` 身份追加，且不携带任何权限提升。
- 容错解码：未知状态值降级为 `inactive`，会话不消失。
- `messageHash` 在卡片状态变化时改变。

验收标准：

- 影子期审计里，被判为复杂的会话中「用户最终选了直接开工别管文档」的比例低于 10%，才允许进 P3。
- 开关关闭时，`spec-gate.jsonl` 零写入，回合耗时无可测量变化。
- 全量单测通过，`scripts/complexity_guard.rb` 不因本次改动新增超阈文件。

---

## 13. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 误报打断用户 | 这正是当年被砍的原因 | 默认关 + 影子期 + 三个出口按钮 + 误报率硬指标 |
| 判官掉线 | 静默失效，无人发现 | fail-open + 每次失败 warning + 审计区分失败类型 |
| 判官预算不足被截断 | 越复杂越容易掉线 | 预算按推理加结论估，超时同步抬，provider 上限钳制 |
| 卡片 role 漏改 switch | 卡片不可见 | 编译器兜大部分，可见白名单补一条测试钉死 |
| `AppStateAgentLoop.swift` 继续膨胀 | 已在 3000 行硬阈值 | 只加一处调用，逻辑全在新文件 |
| 与 Goal 证据门叠加 | 两道门互相等待 | Goal 模式直接排除 |

---

## 14. Non-goals

- **不复活 Plan 模式**，不新增顶层交互模式。
- **不改现有按需计划策略**。计划与设计文档是两件事，`update_plan` 那条线原样保留。
- **不动 Goal 模式的证据规划门**。
- **不放宽任何审批边界**。确认设计门不授予工具权限。
- **不做文档产物化分享**。把文档发布成可分享链接是用户需求的第 2 件事，本期不做。
- **不做架构文档自动维护**。仓库根目前没有 `ARCHITECTURE.md`，是否新建不在本设计范围。

---

## 15. 待确认问题

无。六项已于 2026-09-10 全部拍板，见 §16。

---

## 16. 已确认决策（2026-09-10）

用户裁决：六项待确认全部按提出时的默认假设执行。

| # | 决策 | 推论 |
| --- | --- | --- |
| 1 | P1 影子模式默认开，P3 阻断档默认关由用户主动启用 | 影子期不打扰所以可以默认开；装门这件事必须用户自己点头 |
| 2 | 转正判据：误报率低于 10%，样本至少 30 次判定 | 误报的度量口径是用户点了「直接开工，别管文档」。样本不足 30 时不得进 P3，哪怕误报率是 0 |
| 3 | 文档文件名由模型起，宿主只校验落在 `docs/` 下且符合大写下划线命名 | 宿主检测「文档写好了」靠的是路径与命名规则，不是文件名白名单 |
| 4 | 已有相关设计文档时，提示模型先读它并在其上修改 | 需要在提示词段里给出检索指引，否则 `docs/` 会堆出互相打架的文档 |
| 5 | 开关不进 `~/.willdeep/config.toml`，只做 App 侧 `com.willdeep.agentSettings.specGate.v1` | 命令行工具本期不认这道门，跨端对齐留到以后 |
| 6 | 审计独立成 `spec-gate.jsonl` | 不并入 `judge.jsonl`，那份已知缺 runID 等字段且无轮转 |

### 16.1 落地后补记的实现要点

**P1 已落地（1.365.0-rc1）。** 与设计的差异：

- **文件少建了一个。** §4 列了五个新文件，P1 实际落三个：`AgentSpecGateSignals.swift`（L1 纯函数与信号类型）、`AgentSpecGateVerdict.swift`（结构化裁决与 `spec-gate.jsonl` writer）、`AppStateAgentSpecGate.swift`（调用点）。`AgentSpecGateState.swift` 的状态机在影子期没有任何状态要维护，推迟到 P3 与阻断一起建；卡片视图同理。
- **设置界面没做。** §16 的决策 1 说 P1 影子模式默认开，那么一个用户看不到效果的开关放进设置只会造成困惑。`com.willdeep.agentSettings.specGate.v1` 作为逃生阀存在并默认开，UI 留到 P3 随阻断档一起加。
- **审计写入比设计更保守。** 设计说 `disabled` 与 `excluded` 不写。实现进一步收紧：**一条信号都没命中的回合也不写**。否则一份用来算比率的总体日志会退化成逐条消息的追踪流，把真正要看的行淹掉。差一点点命中的回合仍然写，那是以后调阈值的依据。
- **排除条件检查了两遍。** `signals(for:)` 对「被排除」和「没匹配上」都返回空数组，调用点因此重新判一次排除条件，好让日志把两者分开。一行本不该被判定的回合如果记成 `belowThreshold`，会污染这份日志唯一存在的理由。
- **编码器是本地配的**。兄弟日志的 `agentSandboxEncoder` 是 fileprivate，为一个四字段结构去放宽它的可见性不值得，所以照抄了同样的配置（ISO-8601 加排序键）。

验证：`AgentSpecGateTests` 20 例通过，退出码、日志计数与报告三者一致。

**P3 与 P4 已落地（1.366.0-rc1）。** 与设计的差异：

- **提示词不进 `AgentContextBuilder`。** 那份文件已逼近 `scripts/complexity_guard.rb` 的 2000 行软线，而且更要紧的是位置：门的指令写成 `AgentSpecGateState.systemPromptBlock`，由 `AppStateAgentLoop` 在**动态上下文标记之后**拼接。落在稳定前缀里会破 provider 缓存并逼着三档快照哈希全部重录；落在标记之后一个都不用动。
- **拦截不新增拦截点**，在 planning-only 那条硬拦旁边加了并列的一支。刻意不与它合并：两种状态要模型做的事不一样，合并后一个被门拦住的回合会被告知「返回计划然后停下」，而它欠的是一份文档。
- **模型没写文档就放行**，不重试也不追问。把写工具扣在一份模型不肯写的文档上会把会话锁死，而再问一遍就是把门变成循环。
- **判官的第三种结局**：`judgeUnconfigured`。设计原稿只写了「失败一律 fail-open」，实现时发现「一台判官都请不来」是很多用户的常态而非失败，当成失败会让整个门对这批人静默失效。见 §6.2 的表。
- **卡片状态可变，所以进了 `messageHash`**（`AgentChatHistoryFormatter`）。widget 与 scheduledTask 没进是因为那两个是不可变快照；漏了这一步的表现是卡片永远停在待决定状态。
- **新增 role 共补齐 9 处穷尽分支**：三个 provider 客户端的跳过分支、transcript 可见白名单与历史标签、上下文压缩标签、面板卡片三处、阅读器窗口标题、编辑器展示分类。可见白名单是编译器兜不住的那一处，漏了卡片会被当作 chrome 过滤掉。

---

## 附：相关文档

- [AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md](AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md) — P0 复杂度约束与结构化审核结果的方向
- [LONG_HORIZON_AUTONOMY.md](LONG_HORIZON_AUTONOMY.md) — 计划态用工具不用围栏块、新逻辑落独立文件、Stop 是终态
- [GOAL_TEAMS_ROLES_DESIGN.md](GOAL_TEAMS_ROLES_DESIGN.md) — 目标模式已有的开工确认门与 SPEC 盘点
- [AGENT_EXECUTION_FRICTION_AUDIT_2026_08.md](AGENT_EXECUTION_FRICTION_AUDIT_2026_08.md) — 判官不可用率与解析失败率的量化取证
