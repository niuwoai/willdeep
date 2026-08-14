# 长程自主执行设计（long-horizon.v1）

> Last updated: 2026-08-13 | 状态：设计草案（§7 默认假设待确认，确认前不进入编码）
> 适用范围：Xedit（WillDeep macOS App，本仓库，1.250.0-rc5）与 willdeep-rs（CLI/Runtime，`~/Sites/willdeep-rs`，0.22.0-rc5）
> 本文件是双端共享的 canonical 规范；willdeep-rs 侧的引用与落地映射见其 `docs/LONG_HORIZON_AUTONOMY.md`。
> 与 `docs/GOAL_TEAMS_ROLES_DESIGN.md`（goal-teams.v1）是**互补关系**：那份解决「谁来做、做完谁验收」，本份解决「怎么一直做下去、按什么清单做」。两份可并行推进，无相互阻塞（§6.3）。

## 0. 背景与动机

对标对象同样是 Codex 目标模式（`/goal`，CLI 0.128.0 起，内部称 Ralph loop）。goal-teams.v1 已经拆解了它的**组织构件**（角色、里程碑、交接物）；本设计拆解的是它的**续推构件**——即「为什么它能连续跑很多小时甚至很多天而不停」。据公开资料（见附录），这部分只有五个机制，没有一个是魔法：

1. **目标是一等运行时实体**：`/goal` 把目标持久化为 thread 上的结构化记录，而不是会随上下文漂走的聊天消息；
2. **每轮注入完整态势**：目标 + 已耗时 + token 用量 + 预算余量同时在场，模型据此选择「下一个具体动作」；
3. **continuation 注入**：模型想收尾时，若 harness 判定目标未达，自动注入续推提示词（`goals/continuation.md`）把它顶回执行——这是「不放弃」的全部实现；
4. **预算软停**：token 预算耗尽不是硬断，而是把目标标记为 `budget_limited` 并注入收尾引导（`goals/budget_limit.md`）：停止新的实质工作，总结剩余工作与阻塞点；
5. **暂停/恢复一等化**：中断即暂停，恢复即自动重激活，命令层直接暴露 pause / resume / clear。

**核心判断：两端的差距不在「有没有 goal」，而在「模型想停的时候，harness 站在哪一边」。** Xedit 站在暂停一边（连续 2 轮无进展就交还控制权），willdeep-rs 干脆没有立场（模型不调工具即视为完成）。

两端现状（2026-08-13 探查结论，代码锚点见 §6）：

| 构件 | Xedit 1.250.0-rc5 | willdeep-rs 0.22.0-rc5 |
|---|---|---|
| 目标为一等实体 | **有**：`AgentGoal` / `AgentGoalRoadmap` 全套 Codable 随会话落盘 | **无**：`Session.goal` 是 `Option<String>`，Web 端仅前端 state，刷新即丢 |
| 每轮注入态势 | **半个**：goal / roadmap / plan 每轮从 runtime 重拼进 system prompt，但**不含耗时与预算余量** | **半个**：仅 `<goal>` 字符串前缀，无进度、无预算 |
| continuation 注入 | **有但方向相反**：8 轮（普通）/ 24 轮（Goal）自动续推，然而连续 2 轮无进展即**硬暂停** | **无**：`tool_calls.is_empty()` 即判定完成，system prompt 反而鼓励早停 |
| 预算软停 | **无**：无 token / wall-clock / 成本任何维度的预算闸门 | **无**：主 Agent `token_budget` 恒为 `None`，`MaxTurns` 是**报错退出**而非可续状态 |
| 暂停/恢复 | **半个**：崩溃恢复五态策略完备，但软停后**只能用户手点 UI，无自动恢复路径** | **无**：daemon 重启后动过工具的任务一律 `Interrupted`，不可续推 |
| 计划接口 | **文本围栏块**：` ```plan ` / ` ```progress ` / ` ```goal-check `，无 plan 类工具 | **完全没有计划态**：20 个内置工具全是执行类 |

核心缺口四件：**续推策略与长程目标背道而驰**、**没有任何预算维度因而无法软停**、**计划接口是脆弱的文本围栏而非工具**、**多天运行的工程保障缺位**。本设计只补这四件。

## 1. 设计原则

1. **续推是 harness 的立场，不是模型的自觉**。「继续干」不能靠 system prompt 里写一句 "Continue until the goal is complete"，必须是执行路径上的拦截：目标未达 + 预算未尽 = 注入续推，无条件。
2. **预算是唯一的硬边界**。取消「N 轮无进展就停」这类代理指标做硬停——它惩罚的是「在等 CI」这种正常状态。真正该收口的是 wall-clock、token、成本三个可解释的维度。预算未尽时只退避，不放弃。
3. **软停是有序收尾，不是失败**。预算耗尽必须产出状态快照（分支、未提交文件、当前版本、剩余清单、阻塞点），且可恢复；不得中途 abort，也不得静默变成一句「我先停下了」。
4. **计划态用工具，不用围栏块**。provider 侧 schema 校验 + 失败回灌重试，比宿主解析自由文本可靠一个数量级；现有为补格式失配而生的对账逻辑因此可以大幅收窄。
5. **复用既有基建**。Xedit 复用 `AgentPlanAutoContinuationPolicy` 的四态决策骨架、`ProgressEvidence` 活跃证据、崩溃恢复 checkpoint、`AgentRoutineScheduler` 的 catch-up 惯例；willdeep-rs 复用 `AgentInstructionInbox` 续推钩子、事件游标、turn 调度队列。
6. **新逻辑落独立文件**。遵守 `AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md` 的 P0 复杂度约束：预算与退避不得回塞 `AppStateAgentLoop.swift` / `AppStateAgentGoalPlanning.swift`。

## 2. 续推契约（Continuation Contract）

### 2.1 判定与四种出口

每当模型给出「无工具调用」的回复且当前 Goal 处于执行态，harness 必须走一次续推判定，出口只有四个：

| 出口 | 条件 | 动作 |
|---|---|---|
| `complete` | 验收清单全勾 **且** 当前 phase 的验收标准满足 | 正常收口，进入下一 phase 或结束 Goal |
| `continue` | 目标未达 且 预算未尽 | 注入 continuation steering（§2.3），继续外层循环 |
| `backoff` | 目标未达 且 本轮无进展证据 且 预算未尽 | 按阶梯退避（§2.2）后再 `continue` |
| `soft_stop` | 任一预算维度耗尽 | 注入收尾引导（§3.2），产出状态快照并标记 `budget_limited` |

**没有 `hard_pause` 出口。** 现有「连续 2 轮验收清单无进展 → 暂停」（`AppStateAgentGoalPlanning.swift:663`）降级为退避阶梯的第一档，不再是终态。用户显式 Stop 仍然是终态，且优先级最高——本设计不改变任何用户主动中断的语义。

### 2.2 退避阶梯

无进展轮次不再是「计到 2 就停」，而是驱动一个阶梯。计数器持久化在 Goal 上（跨 turn、跨重启存活），任一轮出现进展证据即归零：

| 连续无进展轮次 | 档位 | 行为 |
|---|---|---|
| 1–2 | 引导 | 注入 continuation，要求模型**对照清单指名下一个未完成项**，并说明上一轮为何没有进展 |
| 3–4 | 只读对账 | 强制一轮 reconciliation：封锁 write / danger 工具（复用现有 `allowsToolRiskDuringProgressReconciliation`），要求模型用 git / 文件系统实际状态核对清单，纠正虚假勾选或遗漏 |
| 5+ | 退避重试 | 指数等待（默认 1 / 5 / 15 分钟，上限 15 分钟）后重试；等待期间不占用 provider 槽 |

**进展证据的定义沿用并扩展 `ProgressEvidence`**（`AgentContextBuilder.swift:1346`）：本轮有工具成功执行、或有后台 job / 子代理存活、或清单勾选状态发生变化，三者任一即算活跃。「在等一个长 CI」因此天然不会进入退避——这正是现有硬暂停最常见的误伤场景。

### 2.3 continuation steering 的内容契约

注入的 system 消息不是一句「请继续」，必须包含四段（顺序固定，便于模型定位）：

1. **目标与剩余清单**：Goal statement + 未完成项（带 1-based 索引），已完成项只给计数不展开；
2. **态势**：本 Goal 已耗时、已用 token / 成本、各维度预算余量（§3.1）；
3. **上一轮判定**：为什么 harness 认为目标未达（哪几项未勾选），以及若处于退避档位，本轮的额外约束（如只读对账）；
4. **动作要求**：指名下一个要推进的清单项并立即执行；明确禁止「总结已完成工作」「询问用户是否继续」这两种空转回复。

第 4 段是关键：长程运行中最常见的失败不是模型拒绝干活，而是模型用一段漂亮的总结冒充进展。

## 3. 预算与软停

### 3.1 预算维度

新增 `AgentGoalExecutionBudget`，随 Goal 持久化，三个维度独立计量、任一耗尽即软停：

| 维度 | 默认值 | 说明 |
|---|---|---|
| `wallClock` | 4 小时/段（可配置至 72 小时） | 从 Goal 进入执行态起算，暂停期间不计；跨重启累计 |
| `tokens` | 无默认上限（可配置） | 累计 prompt + completion，锚定 provider 报告的真实用量而非本地估算 |
| `cost` | 无默认上限（可配置） | 依赖 `COST_ENGINE_DESIGN.md` 落地；未落地前该维度为空，不阻塞其余两维 |

三个维度**都必须可显示**：Composer 的 Goal 卡片与 turn report 展示余量。用户看不见的预算等于没有预算。

### 3.2 软停契约

预算耗尽时**不得中途 abort 当前 turn**，而是：

1. 把 Goal 标记为 `budget_limited`（新增状态，区别于用户主动 `paused`）；
2. 注入收尾引导：停止一切新的实质工作，不再开新文件、不再起后台任务；
3. 要求模型产出**状态快照**：当前分支、未提交文件清单、当前版本号、验收清单剩余项、明确的阻塞点、下一步建议；
4. 快照落盘（goal-teams.v1 已定的归档目录 `<workspace>/.willdeep/goal-teams/versions/<version>/progress.md`，两份设计在此对接）；
5. 后台任务按既有生命周期规则处理：`turn` / `phase` 级终止，`goal` / `persistent` 级保留。

### 3.3 恢复

| 触发 | 行为 |
|---|---|
| 后台任务完成事件 | 若 Goal 处于 `budget_limited` 且仅 wall-clock 维度耗尽，**自动续期并恢复**（复用现有后台完成唤醒链路） |
| 用户显式恢复 | 重置预算段，从状态快照续推 |
| token / 成本维度耗尽 | **不自动恢复**，必须用户确认——这是花钱的闸门，不能自动放行 |

现有恢复入口只有 Composer 里的 pin 按钮（`AgentModeComposerView.swift`），需补一个「续期并继续」动作与之并列。

## 4. 计划工具化（`update_plan`）

### 4.1 现状问题

模型必须正确产出 ` ```plan ` / ` ```progress ` / ` ```goal-check ` 围栏块，宿主才能推进状态机。整套 `ProgressEvidence`、对账轮次、校验失败重发逻辑，本质都在补「模型忘了发块 / 发错格式」的洞。围栏块还有一个隐性代价：它占用模型的自然语言输出通道，与「给用户看的解释」抢位置。

### 4.2 工具 schema（双端同构）

```json
{
  "name": "update_plan",
  "description": "Record or update the execution plan and checklist progress for the active goal.",
  "input": {
    "merge": true,
    "steps": [
      { "id": "s1", "title": "…", "status": "pending|in_progress|done|skipped|failed", "note": "…" }
    ],
    "checklist": [
      { "index": 1, "done": true, "evidence": "tests: 128 passed / 0 failed" }
    ],
    "blocked_reason": "…"
  }
}
```

- `merge: true` 时按 `id` / `index` 局部更新，避免每次重发全量计划（长清单下的 token 浪费与漂移主因）；
- `evidence` 字段是硬要求：勾选清单项必须给出证据串，为 goal-teams.v1 的交叉验收留接口——**没有证据的勾选视为未勾选**；
- schema 校验失败走既有 `structured_output` 的回灌重试机制，不消耗续推预算。

### 4.3 迁移

围栏块解析保留为兼容路径，优先级低于工具调用（同 turn 内两者都出现时以工具为准）。保留期见 §7 假设 4。迁移期埋一个计数：统计「仅用围栏块」的 turn 占比，降到阈值以下再摘除解析器。

### 4.4 顺带统一三套清单

Xedit 目前有三个互不相通的「清单」，长程运行中会让用户和模型都迷路：

| 机制 | 定位（本设计确定） |
|---|---|
| `AgentPlan.steps` / `AgentGoal.checklist` | **Goal 内 todo 的唯一真源**，由 `update_plan` 驱动 |
| `schedule_task` / `complete_scheduled_task` | 会话内定时任务（cron 语义），与 todo 无关；可引用 goal，但不参与清单状态机 |
| `todo` bundled skill（`.willdeep/todos/<session-id>.md`） | 降级为**投影**：由 plan 状态机导出的 Markdown 视图，不再作为独立写入源 |

## 5. 多天运行工程包

四件与模型无关、纯工程的保障，缺一件都会让「跑很多天」变成空话：

| 项 | 现状 | 措施 |
|---|---|---|
| 睡眠抑制 | **完全没有**（`beginActivity` / `IOPMAssertion` 在 `Xedit/*.swift` 中零命中），Mac 一睡循环停摆，且主循环没有 `AgentRoutineScheduler` 那样的 catch-up | Goal 执行期间持有 `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`，暂停 / 软停即释放；唤醒后补一次 catch-up 扫描 |
| roadmap 续接 | 封顶 6 phase × 6 步 = 36 步（`AgentModels.swift:1085-1086`），跑满即无路可走，只能用户改 Goal | phase 全部完成但清单未尽时，归档已完成 phase 到 goal-teams 归档目录，追加下一批 phase；Goal 不因 roadmap 满而失败 |
| 工具轮上限 | 单 turn 256 轮（`AppState.swift:17`），撞顶给 banner 后停 | 撞顶不再是终态：走 §2 续推判定，预算未尽则开新 turn 继续 |
| 重启可续 | Xedit 有 checkpoint 五态恢复；**rs 侧动过工具的任务一律 `Interrupted`** | rs 侧改为由计划态驱动恢复（§6.2 RA4），而非 turn 重放 |

## 6. 两端落地映射与实施里程碑

### 6.1 Xedit（代码锚点为 2026-08-14 / 1.250.0-rc5 现状）

| 步骤 | 内容 | 关键位点 |
|---|---|---|
| XA1 | 续推契约：硬暂停降级为退避阶梯；四出口判定；continuation steering 四段内容契约。**新逻辑落独立文件**（如 `AgentGoalContinuationBudget.swift`），不回塞 loop / planning 主文件 | `AgentContextBuilder.swift:1333-1440`（现策略）、`AppStateAgentGoalPlanning.swift:663`（硬暂停）、`AppStateAgentLoop.swift:649`（turn 局部计数）、`:1301-1345`（续推决策点） |
| XA2 | `AgentGoalExecutionBudget`：wall-clock + token 两维先行；软停状态与状态快照；后台完成事件自动续期；Composer 补「续期并继续」动作 | `AppStateAgentLoop.swift:305-362`（后台唤醒链路）、`AgentModeComposerView.swift`（恢复入口）、`AppStateAgentContextCompression.swift:92`（真实 usage 锚定惯例） |
| XA3 | `update_plan` 工具；围栏块降级为兼容路径；三套清单归一 | `AgentToolRegistry.swift`（工具注册）、`AgentContextBuilder.swift:951`（现解析器）、`AppStateAgentSessions.swift:619/779/804`（捕获入口）、`BundledSkills/todo/SKILL.md` |
| XA4 | 多天工程包：睡眠抑制 + 唤醒 catch-up；roadmap 续接；256 轮撞顶改为可续；成本维度接 COST_ENGINE 最小版 | `AgentModels.swift:1085-1086`（roadmap 上限）、`AppState.swift:17`（轮上限）、`AgentRoutineScheduler.swift`（catch-up 参照）、`docs/COST_ENGINE_DESIGN.md` |

### 6.2 willdeep-rs

| 步骤 | 内容 | 关键位点 |
|---|---|---|
| RA1 | 停止条件改造：`tool_calls.is_empty()` 时若 goal 激活则先过目标判定，未达注入 continuation；system prompt 的早停引导在 goal 模式下改写 | `crates/willdeep-core/src/agent.rs:248`（主循环）、`:279`（现停止条件）、`:316`（`append_pending_instructions` 续推钩子）、`crates/willdeep-core/src/prompt.rs:30`（早停引导） |
| RA2 | 计划态对象 + `update_plan` 工具（schema 同 §4.2）。**与 goal-teams.v1 的 R3 合并推进**，一并替换 `Session.goal` 单字符串、修 Web 端刷新即丢 | `crates/willdeep-core/src/session.rs:50`、`crates/willdeep-core/src/tools.rs:328/507-528`（工具表与分发）、`crates/willdeep-cli/src/tui.rs:2452`（`enrich_prompt`）、`crates/willdeep-cli/src/web.rs:351` |
| RA3 | 预算维度 + 软停：`MaxTurns` 从错误改为可续软停状态；主 Agent 补 token / wall-clock 预算；压缩摘要把「计划与剩余步骤」列为不可压缩固定区 | `agent.rs:313`（现 `MaxTurns` 报错）、`crates/willdeep-cli/src/harness.rs:319`（默认 24 轮）、`:585`（主 Agent 无预算）、`agent.rs:395/411`（压缩摘要） |
| RA4 | daemon 重启由计划态驱动恢复：动过工具的任务不再一律 `Interrupted`，而是按已落盘的 plan 状态续推 | `crates/willdeep-cli/src/daemon.rs:2397`（现一刀切）、`session_store.rs:251`（现 turn 重放救生索） |

### 6.3 步序约束与并行关系

- **XA1 / RA1 无前置依赖，建议最先做**：它们是「能不能连续跑一天」的直接开关，改动面小、可独立验收。
- XA2 / RA3（预算与软停）依赖 XA1 / RA1 的判定骨架。
- XA3 / RA2（计划工具化）双端共用 §4.2 schema，应同期定稿；RA2 与 goal-teams.v1 的 R3 是同一块持久化改造，**合并做一次，不要拆两次改 `Session.goal`**。
- XA4 / RA4（工程包）可与上述任意步骤并行。
- 与 goal-teams.v1 的接口只有两处：软停快照写入其归档目录（§3.2），以及 `update_plan` 的 `evidence` 字段为其交叉验收供料（§4.2）。除此之外两份设计互不阻塞。

## 7. 默认假设清单（待确认）

| # | 假设 | 默认值 | 备注 |
|---|---|---|---|
| 1 | wall-clock 预算 | 4 小时/段，可配置至 72 小时 | 段内自动续推，跨段需触发恢复 |
| 2 | 退避阶梯 | 1–2 轮引导 / 3–4 轮只读对账 / 5+ 指数退避（1、5、15 分钟封顶） | 有进展证据即归零 |
| 3 | 软停后自动恢复 | 仅 wall-clock 维度耗尽且由后台任务完成事件触发时自动续期；token / 成本维度耗尽必须用户确认 | 花钱的闸门不自动放行 |
| 4 | 围栏块共存期 | 保留 2 个 minor 版本，其后只读兼容 | 以「仅围栏块的 turn 占比」决定摘除时机 |
| 5 | 睡眠抑制范围 | 仅 Goal 执行中启用 `idleSystemSleepDisabled`；不阻止合盖睡眠 | 用户合盖是明确意图，不对抗 |
| 6 | roadmap 续接 | 满 6 phase 后归档并追加下一批，不因跑满而失败 | 归档进 goal-teams 目录 |
| 7 | 清单唯一真源 | `AgentPlan.steps` / `AgentGoal.checklist`；`todo` skill 降为投影 | `schedule_task` 保持 cron 语义不变 |

## 8. Non-goals

- **不做「永不停止」**。预算是硬边界；软停是有序收尾，不是无限重试。任何让 Agent 无预算无限跑的实现都违反本设计。
- **不放宽审批边界**。续推不得成为绕过危险操作确认的通道；Goal 模式现有免审批范围（非 danger、非 command-shaped 的 write）保持不变。
- **不合并两端 runtime**，不引入共享控制协议（那是 `CROSS_PLATFORM_CLI_STRATEGY.md` / `CLI_TUI_RUNTIME_ROADMAP` 的另一条线）。本设计沿用文件层共享 schema 的既有模式。
- **不重做 goal-teams.v1 已定的角色、里程碑与 capsule 设计**。两份互补，接口只有 §6.3 列的两处。
- **不改用户主动中断的语义**。用户 Stop 永远是终态，优先级高于任何续推判定。

## 附：相关文档与资料

- `docs/GOAL_TEAMS_ROLES_DESIGN.md` — goal-teams.v1，执行期角色 / 版本锚定里程碑 / Doc Capsule（互补设计）
- `docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md` — P0 复杂度约束与执行自主性演进史
- `docs/COST_ENGINE_DESIGN.md` — 成本维度依赖（提案状态）
- `docs/SUBAGENT_PROFILES_DESIGN.md` — 工种设计（已实现，1.230.0-rc1）
- `docs/ORCHESTRATOR_DESIGN.md` — 外部执行器调度
- willdeep-rs `docs/LONG_HORIZON_AUTONOMY.md` — CLI 侧引用与落地映射
- willdeep-rs `docs/CLI_TUI_RUNTIME_ROADMAP.md` — rs 侧路线图既有位置

Codex 目标模式的机制描述来自公开资料（非源码），主要参考：Codex Knowledge Base 关于 `/goal` 持久化目标、token 预算与 pause/resume 的两篇分析，以及 `goals/continuation.md` / `goals/budget_limit.md` 两个提示词文件的公开讨论。引用时应理解为**行为层观察**，不是官方实现契约。
