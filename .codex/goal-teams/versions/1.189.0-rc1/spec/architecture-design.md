# WillDeep Goal-backed Plan 架构设计

> 版本：`1.189.0-rc1`
> 任务：GT-003、GT-004
> 状态：已实现，并经 QA 代码审查与独立测试验证
> 范围：Goal 定义后进行多身份辩证规划，生成可确认的 Plan；确认前禁止写入

## 1. Doc Capsules

### Capsule A：Codex Goal Teams 规范

- source：`/Users/rocky/.codex/skills/goal-teams/SKILL.md`、`references/goal-teams-runtime.md`
- decision：Goal Teams 必须先 Plan、后执行；成员独立、角色名具体、产物需非作者校验。
- must_do：Goal 定义、独立成员分析、分歧仲裁、Teams 规划表、用户确认、locked scope、独立测试。
- must_not_do：确认前启动实现成员或写实现文件；让实现者自测后自行宣布完成；成员嵌套创建团队。
- test_refs：状态转换、确认门禁、失败降级、独立报告数量、Plan 完成后的续接。
- doc_update_refs：版本化 Architecture Design、Test Plan、Acceptance、tasklist/progress。
- open_questions：首版是否要求把完整 Goal Teams JSONL runtime 搬入 WillDeep；本设计结论为不需要。

### Capsule B：已确认的产品方向

- source：`.codex/goal-teams/versions/1.189.0-rc1/plan.md`
- decision：复用 `AgentPlan`、现有 Plan 卡和内置只读 `spawn_agent`；不新造第二套确认协议。
- must_do：三类独立角色、反方仲裁、Goal-backed Plan、确认后自动执行、安全降级。
- must_not_do：Goal 定义后直接获得永久写权限；无足够独立证据时静默降级为普通自主执行。
- test_refs：至少两份有效独立报告；计划拒绝/修改；Plan 完成但 Goal 未完成。
- doc_update_refs：本 Architecture Design；后续 Test Plan 与 Acceptance。
- open_questions：无。

### Capsule C：现有 Goal/Plan 状态与 UI

- source：`AgentModels.swift`、`AgentContextBuilder.swift`、`AgentRuntime.swift`、`AppStateAgentSessions.swift`、`AppStateAgentLoop.swift`、`AgentModeComposerView.swift`、`AgentChatTranscript.swift`、`AgentPlanGoalCards.swift`
- decision：`AgentSession` 已可同时持久化 `currentGoal` 与 `currentPlan`，授权 gate 无需新 schema；但 AC-20 所需的成员/报告/错误恢复仍需一个 optional 规划证据账本。捕获、gate、确认和显示当前都以 `.plan` 模式为硬条件。
- must_do：让 Plan 成为 Goal 模式内的执行契约；Goal 模式保持不变，不通过切换到 `.plan` 获得该能力。
- must_not_do：调用 `setAgentInteractionMode(.plan)` 进入执行，因为该函数当前会清空 `currentGoal`。
- test_refs：旧会话解码；Goal 与 Plan 同时持久化；模式切换不串状态。
- doc_update_refs：本设计的符号清单。
- open_questions：无。

### Capsule D：子代理与会诊能力

- source：`AgentSubagents.swift`、`AgentConsultation.swift`
- decision：内置 `spawn_agent` 已是 read risk、只读工具集、禁止嵌套、每 runtime 最多三名后台成员，且完成报告能自动唤醒 parent；会诊已有“独立评审→初步综合→同侪质疑→最终综合”的成熟提示词语义。
- must_do：复用 `spawn_agent` 的安全边界和后台报告通道；复用会诊的证据优先、保留分歧、反方仲裁原则。
- must_not_do：直接复用 `AgentConsultationEngine` 作为 Goal runtime。它依赖外部 CLI 专家配置，身份模型和 Goal Teams 内置成员不一致。
- test_refs：三成员并行上限；部分失败；报告自动续接；仲裁失败。
- doc_update_refs：无直接代码文档更新。
- open_questions：未来是否抽取通用 consultation prompt primitives；首版不需要。

### Capsule E：工作树风险

- source：`git status --short --branch`、目标文件定向 `git diff`
- decision：工作树为 dirty；`AppStateAgentSessions.swift` 和 `AgentModeComposerView.swift` 已有并行未提交改动。
- must_do：后续实现逐符号窄 patch，每次 patch 前重读目标片段，完成后核对定向 diff。
- must_not_do：整文件替换、格式化整个文件、撤销或覆盖现有改动。
- test_refs：`git diff --check`、目标文件定向 diff、现有密钥插入与 session destination 行为回归。
- doc_update_refs：本设计风险章节。
- open_questions：无。

## 2. 架构结论

采用“Goal 模式内附着 Plan + 最小规划证据账本”的方案：

1. `interactionMode` 始终保持 `.goal`。
2. `currentGoal` 表示长期目标，`currentPlan` 表示当前一轮、经用户确认的执行合同。
3. 规划阶段只允许 read-tier 工具；`spawn_agent` 本身为 read-tier，因此可完成多身份分析。
4. host 确定性启动三名后台子代理并行给出独立意见；三名均到达 terminal 后，至少两份有效报告才允许启动一名同步反方仲裁者。
5. Parent 根据独立报告与仲裁结果输出 Teams 规划表和唯一的 fenced `plan` 块，然后停止。
6. 现有 `AgentPlanParser` 捕获为 `.proposed`；用户必须明确点击 Plan 卡的批准按钮。
7. 批准后沿用现有 `progress`、自动续跑上限和 Goal `goal-check`。

授权阶段仍完全由现有三元组派生；但为了 host 能强制证明“恰有三名、至少两份有效、仲裁成功后才可 proposed”，并满足重启后不丢成员错误/报告的 AC-20，需要新增一个**可选、向后兼容**的 `AgentGoalPlanningState?`。旧会话缺省为 `nil`，再由 Goal/Plan 安全状态恢复，不做破坏性迁移。

### 2.1 最小持久化模型决策

```text
AgentGoalPlanningState (Codable, Equatable)
  schemaVersion: Int
  generationID: UUID
  goalFingerprint: String
  phase: collecting | arbitrating | readyForProposal |
         awaitingApproval | executing | blocked | completed
  members: [Member]                 // 固定三项
    roleID / displayName / runID?
    status: pending | running | completed | failed | interrupted
    report? / errorMessage?
  arbitration:
    status: pending | running | completed | failed | interrupted
    report? / errorMessage?
```

约束：报告入库前做敏感信息清理并限制长度；不持久化 provider 凭据、完整子代理 transcript 或 Task。`AgentGoalPlanningState`、成员状态和仲裁状态采用 tolerant decode：缺少 `schemaVersion` 按首版 schema 读取，未知/未来 schema、未知 phase/status、缺少关键字段或矛盾组合都正规化为 `blocked`，不得让 `AgentSession` 整体解码失败，更不得猜测为 `executing`。应用重启时，`running` 一律正规化为 `interrupted` 并进入 `blocked`，保留已完成报告，默认收紧权限；用户重试时创建新的 `generationID`，旧 run 的迟到报告因 generation/runID 不匹配而丢弃。

## 3. 派生状态机

| 状态 | 判定条件 | 允许行为 | 退出条件 |
| --- | --- | --- | --- |
| G0 Goal setup | `.goal` 且 Goal 为空 | 对话澄清、read-tier、`ask_user` | 捕获非空 `goal` |
| G1 Planning | `.goal`、Goal 非空、Plan 为空或 `.rejected`，规划账本 collecting/arbitrating/ready | read-tier、三成员分析、仲裁 | host 证据门槛满足后捕获 `plan`，或明确阻塞 |
| G2 Awaiting approval | Plan `.proposed` | read-tier、用户编辑/拒绝/批准 | 用户批准、拒绝或更新 Goal |
| G3 Approved | Plan `.approved` | 解锁普通 write-tier；danger 仍需确认 | 首个 `progress`、用户修改 Goal |
| G4 Executing | Plan `.executing` | 执行、测试、文档、`progress`、自动续跑 | Plan terminal、用户修改 Goal、续跑保护暂停 |
| G5 Cycle complete | Plan `.done` | 若 Goal checklist 全完成则停；否则准备下一轮规划 | Goal 完成，或清空 Plan 并自动进入 G1 |
| GB Blocked | 独立证据不足、仲裁失败、连续无进展或续跑超限 | 只读诊断、向用户说明 | 用户补充信息或重试 |

关键转换：

```text
Goal setup
  -> 捕获 Goal
Planning
  -> 3 个只读成员全部 terminal
  -> 至少 2 份有效报告
  -> 反方仲裁成功
Awaiting approval
  -> 用户明确批准
Approved/Executing
  -> Plan done + Goal done      -> Complete
  -> Plan done + Goal 未完成    -> 清空本轮 Plan -> Planning
  -> Goal 被用户实质修改        -> 立即废止旧 Plan -> Planning
```

### 3.1 Goal 完成判定

- checklist 非空且全部 `done`：可判定 Goal 完成，不再自动创建下一轮 Plan。
- checklist 非空且仍有未完成项：Plan 完成后必须重新锁门并进入下一轮规划。
- checklist 为空：不得用 `allSatisfy` 的空集合真值误判完成；停止自动循环并要求模型给出明确自检/由用户决定是否继续。

## 4. Tool gate 不变量

以下不变量必须由 host 代码保证，不能只靠 system prompt：

1. `.goal` 且 Goal 尚未定义时，write/danger 工具一律被 gate 拒绝。
2. `.goal` 且 Goal 已定义，但 Plan 为 `nil/.proposed/.rejected/.done` 时，write/danger 工具一律被 gate 拒绝。
3. 只有 Plan 为 `.approved/.executing` 时，普通 write-tier 才可进入既有审批/自动批准策略。
4. danger-tier 即使在 Goal + approved Plan 中仍保持 typed confirmation，不因 Goal 自动批准而降级。
5. read-tier 始终可用；`ask_user` 继续走现有 user-input 分支；合法公网 `web_fetch` 维持现有规划研究例外。
6. 原生 Agent tool loop 与 delegated composer 两条执行路径必须读取同一个 `runtime.isPlanGateActive`，不可只修一条。
7. 用户实质修改 Goal statement 或 checklist 文本时，已批准 Plan 立即失效；仅勾选 checklist 完成状态不应使 Plan 失效。
8. Plan `.done` 不是永久通行证；若 Goal 未完成，下一轮写操作必须重新批准。
9. Goal 模式的 `plan` 只有在规划账本为 `readyForProposal` 时才可被捕获；模型提前输出的 `plan` 不能成为可批准授权。

建议保留 `isPlanGateActive` 名称以缩小改动，但更新注释为“Plan approval gate for Plan mode and Goal-backed Plan”。

## 5. 多身份辩证规划编排

### 5.1 第一轮成员

| label | 身份 | 主要问题 | 输出合同 |
| --- | --- | --- | --- |
| `需求分析-目标边界质疑` | 需求/反方 | 真实目标、范围、非目标、隐含假设 | 结论、证据、反例、建议 done criteria |
| `架构-实现路径论证` | 架构/实现 | 最小实现、符号落点、依赖与迁移风险 | 路径/符号、替代方案、风险、验证 |
| `测试-失败路径审查` | QA/风险 | 越权写入、失败降级、回归和验收证据 | 失败矩阵、测试、停止条件 |

三者由 host coordinator 通过 `AgentSubagentRegistry` 的 Goal-planning 专用受控 API 启动，与现有每 runtime 三并发上限完全匹配。该 API 不直接暴露 `startBackground(...)` 的原始逐个完成/逐个 parent wake 合同，而是由 coordinator 一次登记 generation、三个稳定 role/runID，固定只读 tool policy 与结构化 output schema，并在内部聚合全部 terminal 结果。不要仅靠 parent 模型“自觉调用三次 `spawn_agent`”：那样无法对 AC-03/04/06/20 给出确定断言。

每个 `runID` 在启动后立即写入规划账本；completion hook 只接受 generation/runID 匹配的结果，并独立更新对应成员，不以完成顺序映射角色。报告先按统一结构（结论、证据/缺口、风险、建议）验证，再经过既有敏感信息清理与字符上限裁剪，错误文本、空白、越界或结构不完整输出不得算有效报告。单个成员完成只更新账本，不向 parent 排入综合指令；只有三个成员全部 terminal，且有效报告不少于两份时，才触发一次仲裁。0/1 份有效时直接 blocked；迟到、重复或旧 generation completion 是 no-op。

### 5.2 第二轮仲裁

三名成员全部 terminal 后：

- 有效报告不少于两份：coordinator 调用第四名同步只读 `AgentSubagentRunner.run(...)`，身份为 `评审-分歧证据仲裁`。
- 有效报告少于两份：进入 GB，不生成可批准 Plan。
- 仲裁者必须收到目标、三份报告（失败项显式标记）、仓库证据要求与输出上限。
- 仲裁者输出：共识、真实分歧、证据不足项、接受/拒绝建议、推荐任务顺序、locked scope、测试 owner、validator、停止条件。

选择同步仲裁是刻意的：第一轮并行降低延迟；第二轮必须建立在完整报告集上，同步调用可避免又引入一套后台等待状态。仲裁完成后账本进入 `readyForProposal`，coordinator 才向 parent 排入综合 host instruction。

### 5.3 Parent 最终产物

Parent 只在仲裁成功后输出：

1. 简短结论与关键假设。
2. Teams 规划表，必须完整包含 `Member`、`Skill/Subagent`、`Goal Slice`、`Claimed Tasks`、`Locked Scope`、`Deliverable`、`Done Criteria`、`Docs/Tasklist Updates`、`Test Owner`、`Validator` 十列。
3. 风险/停止条件。
4. 唯一 fenced `plan` 块，步骤必须覆盖完整交付、测试、文档和独立验证。
5. 明确提示“等待用户确认”，随后停止，不调用任何工具。

`AgentPlanParser` 仅解析 fenced block；表格作为对话审计证据保留，无需扩展 `AgentPlan` schema。Goal 模式捕获前必须同时检查账本 `readyForProposal`，并强制通过 `AgentGoalPlanProposalValidator`：Teams 表十列必须齐全、每行必填值非空、Member 为“角色-具体任务”、Validator 与产物作者不同；fenced Plan 必须非空且覆盖实现、测试、文档、版本与验收五类，或对不适用类别明确写出 `N/A` 及理由；每个步骤必须关联 member、task ID 或明确产物。任一验证失败都保持 planning/blocked，不创建 `.proposed` Plan，也不展示批准入口。捕获成功后才转为 `awaitingApproval`。

## 6. 自动续接设计

### 6.1 Goal 定义后的安全续接

`runAgentLoop` 的 `defer` 当前顺序是：捕获 Plan → 捕获 Goal 定义 → 捕获 Goal evaluation → persist → 消费队列。应保持这一安全时序，并在捕获到“本轮首次定义 Goal”时追加一条 `source: .hostInstruction` 的规划指令到 `runtime.queuedMessages`。

这样做的原因：

- 捕获发生时当前 turn 仍处于 `isResponding = true`，直接 dispatch 会重入。
- `defer` 随后把 `isResponding` 清零，再由 `consumeNextQueuedMessageIfNeeded` FIFO 派发，复用成熟路径。
- host instruction 不显示为用户人工输入，但会进入模型上下文并可审计。
- 不需要用户再发“继续”，也不需要伪造后台 job。

建议让 `captureAgentGoalDefinitionFromLatestMessage(for:)` 返回 `Bool`，仅从空 Goal 成功变为非空时返回 true；调用方据此创建新 generation 并排入一次“启动规划 coordinator”的 host continuation。coordinator 自己启动三成员，不依赖模型决定成员数量。

### 6.2 Plan 完成后的续接

在本轮 Plan 捕获与 Goal evaluation 都完成后再判断，避免同一条回复同时把最后一步和最后一个 Goal item 标记完成时误开新一轮：

- Plan `.done` + checklist 仍有未完成项：清空 `currentPlan`、持久化、排入新的 host planning instruction。
- Plan `.done` + checklist 全完成：保留完成 Plan，不排队。
- Plan `.done` + checklist 为空：不自动排队，避免无限循环。

手动 `completeAgentPlan()` 也必须走同一 helper，避免按钮路径与模型 `progress` 路径语义不一致。

### 6.3 用户修改与拒绝

- 用户修改 Goal 文本/验收项：立即清空旧 Plan；正在响应时排入更新后的 Goal planning instruction，后续 write call 会被 gate 拒绝。
- 用户拒绝 proposed Plan：Goal 模式把 Plan 标记为 `.rejected` 以保留审计证据并立即失效授权；普通 Plan 模式维持当前“清空 Plan”的既有行为。不要立即生成一份可能完全相同的计划；等待用户补充，下一条输入按 G1 重规划。
- 用户点击“重新规划”并附说明：Goal 模式也应允许 `requestPlanRevision(note:)`，清空 Plan 后发送现有 revision host/user instruction。

## 7. UI 与确认策略

Goal-backed Plan 必须使用显式确认，不能继承 Plan composer banner 的 8 秒倒计时自动执行：Goal Teams 规范要求用户确认成员、scope 与执行计划。

- `AgentChatTranscript`：collecting/arbitrating/blocked 时显示轻量 `AgentGoalPlanningCard`（阶段、三成员状态/错误、仲裁状态、Retry）；Goal 模式有 Plan 时同时显示 `AgentGoalCard` 与 `AgentPlanCard`，建议 Goal 在上、当前轮 Plan 在下。
- `AgentPlanCard`：在 Goal 模式 proposed 状态，批准按钮调用可派发执行的 `confirmAgentPlanAndExecute()`；拒绝仍调用 `rejectAgentPlan()`。
- `AgentModeComposerView`：继续显示 Goal 状态条；`AgentPlanAutoExecutionBanner` 仍只属于 `.plan`，不要把 Goal 模式加入 `bannerPlan()` 或 silent auto-execute 条件。
- `AgentSidePanelPlanView`：已按 `currentPlan != nil` 展示，无模式限制，可直接复用。
- `AgentPlanRevisionRow` / restart：相关 AppState guard 应接受 `.goal`，否则 Goal 模式展示了 Plan 卡却无法重规划或从某一步重跑。
- 所有新增阶段、失败、Retry 文案进入 `L10n.swift`/`Localizable.xcstrings`，状态图标与文本并用，不只靠颜色。

## 8. 精确文件与符号清单

| 文件 | 符号/条件 | 最小改动 | 可复用/备注 |
| --- | --- | --- | --- |
| `Xedit/AgentContextBuilder.swift` | `systemPrompt(...)` Goal 分支 | 把 Goal active 文案改为 stage-aware；规划阶段注入三成员、等待、仲裁、Teams 表与 `plan` 合同；批准后复用 Plan progress 合同 | 复用 `AgentPlanParser`、`AgentPlanAutoContinuationPolicy` |
| `Xedit/AgentRuntime.swift` | `isPlanGateActive` | 扩展到 Goal setup 与 Goal-backed Plan；只有 approved/executing 解锁 | 不新增持久化字段 |
| `Xedit/AppStateAgentSessions.swift` | `captureAgentPlanFromLatestMessage(for:)` | 接受 `.goal` 且 Goal 非空、规划账本已 `readyForProposal`；继续复用 parser/progress | 当前文件有并行 diff，必须窄 patch |
| 同上 | `captureAgentGoalDefinitionFromLatestMessage(for:)` | 返回是否首次定义；供 defer 安排 host continuation | 复用队列路径 |
| 同上 | `confirmAgentPlanAndExecute()` | guard 接受 `.plan` 或 Goal-backed Plan；发送执行 host instruction；Goal 账本进入 executing | Goal 卡批准后不应停在已批准但未派发状态 |
| 同上 | `rejectAgentPlan()` | Goal 模式保留 `.rejected` 审计态并失效授权；普通 Plan 模式保持清空行为 | 满足 AC-14 且不回归普通 Plan |
| 同上 | `setAgentGoal(...)` | Goal 文本/验收项实质变化时废止旧 Plan，并安全续接规划 | checklist 勾选不走此失效逻辑 |
| 同上 | `completeAgentPlan()`、`requestPlanRevision(note:)`、`restartAgentPlanFromStep(...)` | Goal 模式采用同一 Plan 生命周期 | 抽取小 helper 避免三套条件 |
| `Xedit/AppStateAgentLoop.swift` | `runAgentLoop(...).defer` | 首次 Goal 定义后排队规划；Plan/Goal 捕获后处理“Plan done 但 Goal 未完” | 必须在 Goal evaluation 后判断 |
| 同上 | 两处 gate 错误文案 | 从“Plan mode”改为中性的“Plan approval required”，Goal 模式不误导 | gate 逻辑仍复用静态 helper |
| `Xedit/AppStateAgentComposer.swift` | delegated agent gate 文案/路径 | 保证 delegated executor 同样受 Goal-backed Plan gate；更新中性文案 | 现有已调用同一 `isPlanGateActive` |
| `Xedit/AgentChatTranscript.swift` | Plan/Goal pinned 条件 | 规划中显示状态卡；`.goal` 且有 Plan 时也显示 Plan 卡 | 保持 Goal 卡同时显示 |
| `Xedit/AgentPlanGoalCards.swift` | proposed Approve、revision、restart；新增轻量 planning card | Goal 模式批准时调用 confirm+dispatch；Goal 模式允许 revision/restart；显示成员阶段/错误/Retry | 不新增页面，复用卡片视觉体系 |
| `Xedit/AgentModeComposerView.swift` | `bannerPlan()`、silent auto-execute 条件 | 明确保留 `.plan` only；不为 Goal 开倒计时 | 当前文件有大段并行密钥 UI diff，原则上无需修改 |
| `Xedit/AppStateEditorPresentation.swift` | `shouldShowComposerGoalCard` | 无需改；Goal 状态条继续工作 | 复用 |
| `Xedit/AgentSubagents.swift` | `maxConcurrentPerRuntime`、Goal planning 受控 API | 复用三并发与底层只读 runner；专用入口固定结构化 schema/限长/脱敏/generation-runID，单项完成不逐个唤醒 parent；增加按 runID 读取/定向取消 | 第一轮三个角色正好匹配上限，不直接暴露原始 background 报告合同 |
| `Xedit/AgentConsultation.swift` | `AgentConsultationPromptBuilder` 语义 | 首版不改；在 Goal prompt 中复用其“证据优先/保留分歧/同侪质疑”原则 | 不直接复用 external CLI engine |
| `Xedit/AgentModels.swift` | `AgentSession`、新增 `AgentGoalPlanningState` | 增加 optional `goalPlanningState`、`schemaVersion` 与最小成员/仲裁账本；自定义 tolerant decode | 默认 nil；未知 schema/phase/status 收紧 blocked，不能拖垮整个 session decode |
| `Xedit/AgentRuntime.swift` | init/persist | 在 session 与 runtime 间同步 optional 规划账本 | `running -> interrupted/blocked` 可在恢复时正规化 |
| `Xedit/AgentSessionStore.swift` | session index decode | `decodeIfPresent` 新字段；缺失时 nil | 不做版本迁移脚本 |
| `Xedit/AppState.swift` | `agentSubagentRegistry.onRunFinished` | Goal-planning 单项完成只记 ledger 并抑制通用 wake；全部 terminal 后由 coordinator 仲裁；仲裁成功后仅一次排综合指令/唤醒 parent；非 Goal 子代理沿用旧 wake | 拒绝旧 generation 的迟到/重复报告，避免逐成员 pending wake |
| 新建 `Xedit/AppStateAgentGoalPlanning.swift` | coordinator、报告 validator、proposal readiness | 集中三成员启动、完成聚合、至少两份门槛、同步仲裁、重试/恢复 | 避免继续膨胀已接近 2000 行的 sessions/loop 文件 |
| `Xedit/L10n.swift`、`Xedit/Localizable.xcstrings` | Goal planning card 文案 | 增加阶段、成员失败、Retry、blocked 文案 | 禁止 SwiftUI 硬编码用户文本 |

## 9. 建议测试

### 9.1 单元测试

优先扩展 `XeditTests/AgentPlanProgressTests.swift`：

1. Goal 为空时 gate active。
2. Goal 非空 + Plan nil/proposed/done 时 gate active。
3. Goal 非空 + Plan approved/executing 时 gate inactive。
4. Goal 模式可捕获 `plan`，普通模式不可误捕获。
5. Goal-backed approved Plan 仍适用自动续跑策略。
6. Plan done + Goal checklist 未完生成下一轮 planning decision；全部完成不生成；空 checklist 不自动循环。

扩展 `XeditTests/AgentGoalChecklistParserTests.swift` 或新增窄文件：

7. 同一回复 `progress` 完成 Plan 且 `goal-check` 完成最后 item 时，不排下一轮。
8. 用户修改 Goal 文本会废止 approved Plan；仅 toggle item 不废止。
9. 首次捕获 Goal 只排一条 host instruction，重复 defer 不重复排队。

扩展 `XeditTests/AgentWebToolsTests.swift` / gate 测试：

10. Goal planning gate 允许 `spawn_agent`（read）。
11. Goal planning gate 拒绝 `apply_patch`、写级 `run_command`、外部可写 coding agent。
12. 合法公网 `web_fetch` 例外保持；私网 fetch 仍阻止。
13. Goal 模式在账本未 `readyForProposal` 时忽略/拒绝提前出现的 `plan`；门槛满足后才可捕获。
14. 旧 generation 的迟到 run report 不得污染新 generation。

### 9.2 集成测试

1. 输入明确 Goal → 自动开始规划，无需第二条用户消息。
2. 三个 background 子代理报告未齐时不出现 proposed Plan。
3. 三份 terminal、至少两份有效 + 仲裁成功后出现 Goal 卡与 Plan 卡。
4. 少于两份有效报告时显示 blocker，且尝试写工具被 host gate 拒绝。
5. Goal Plan 卡批准后立即派发执行；批准前没有任何写入。
6. Goal 模式不出现 8 秒自动执行 banner，也不读取 silent auto-execute workspace 记忆。
7. 执行中修改 Goal 后，旧 Plan 失效，下一次写调用被拒绝并重新规划。
8. 会话保存/重开后 Goal + proposed/approved Plan 状态恢复正确。
9. 重启时 running member/arbitration 正规化为 interrupted + blocked，已完成报告和错误保留；用户重试生成新 generation。

### 9.3 回归验证

- 现有 Plan 模式的 proposed/approve/progress/done 与 8 秒 banner 行为不变。
- 普通 Goal checklist 捕获与 Goal 状态条行为不变。
- Goal mode 现有 danger typed confirmation 不变。
- delegated agent 两条 gate 路径一致。
- 并行工作树现有“保存的密钥插入”和“session destination”改动仍在。

## 10. 风险与控制

| 风险 | 严重度 | 控制 |
| --- | --- | --- |
| 只改 prompt，漏改 host gate | 高 | 以 `runtime.isPlanGateActive` 为唯一安全事实，原生/委派路径都测 |
| Goal 修改后旧批准仍有效 | 高 | `setAgentGoal` 实质变化立即清 Plan |
| 后台报告未齐就综合 | 高 | host 账本检查“三份 terminal 后才仲裁”；不足只允许 blocker；不能只靠 prompt |
| 第一轮成员部分失败 | 中 | 全部 terminal + 至少两份有效；失败信息交给仲裁者 |
| Goal 无 checklist 造成无限循环 | 高 | 空 checklist 不自动续轮 |
| Plan 卡批准后没有新 turn | 中 | Goal 模式批准调用 `confirmAgentPlanAndExecute`，不只改 status |
| Goal 模式误用倒计时自动执行 | 高 | composer banner 继续 `.plan` only |
| dirty worktree 覆盖并行改动 | 高 | 窄 patch、改前重读、改后定向 diff；不格式化整文件 |
| 规划账本扩大会话文件 | 中 | 每份报告脱敏并限长；不保存子代理完整 transcript |
| 迟到报告污染重试 | 高 | generationID + runID 双重匹配，旧结果丢弃 |

## 11. 完成状态

- GT-003 架构分析：完成。
- GT-004 精确改动与 UI/门禁方案：完成设计，未进入 Swift 实现。
- Swift、测试、版本、CHANGELOG、product overview：本轮均未修改。
- 工作树重叠风险：已识别，重点为 `AppStateAgentSessions.swift` 与 `AgentModeComposerView.swift`。
- 独立验证：本 Architecture Design 尚待测试成员验证；需求规格卡与 PRD 已完成代码事实/可实现性校验，结论见本成员回报（需求文档本轮不修改）。
