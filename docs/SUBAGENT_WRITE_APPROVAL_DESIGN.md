# 子代理写入与审批升格设计

> 状态：设计已定，尚未实施。第 0/1 步为地基，第 2 步是核心，第 3 步单独立项。
> 起草日期：2026-08-28（1.301.0-rc2 时点）
> 关联文档：`docs/SUBAGENT_PROFILES_DESIGN.md`、`docs/ORCHESTRATOR_DESIGN.md`、`docs/ENVIRONMENT_TRUST_DECLARATIONS.md`
> 一句话：让工种能干带写入性质的活，并且遇到风险时走和主模型**同一套**判定，包括在需要时把人叫来——而不是像今天这样，撞上人就只能死一次。

---

## 1. 要解决的问题

目标形态是星型：**人 ↔ 主 agent ↔ 各工种**。主 agent 坐镇、拿需求、派活、收结果；工种干活，遇到风险按和主 agent 一样的规矩判定，该问人的问人。

今天这个形状已经搭起来一多半，缺的是同一根线：**工种通往人的那根**。

`AgentSubagents.swift` 顶部的注释就是天花板：

> No approval UI exists down here, so nothing that would need approval may run.

工种撞上「该问人」的事，问不到人。它只能被 deny，在结题报告里跟父说一声「这条命令我跑不了」，父再重新 spawn 一个带 `target_command` 的 `ops_runner` 去要授权。相当于工人死一次、重新投胎一次：上下文丢了，干了一半的活丢了，时间也丢了。

---

## 2. 现状盘点

### 2.1 写入：三道门已经上线

`AgentSubagentWriteAccess` 给写入工种一个**声明式、路径受限**的能力：

| 门 | 机制 |
| --- | --- |
| 策略 | Smart / 工作区访问继承父会话的写授权；严格模式在一张卡上列出全部目标文件 |
| 路径 | `apply_patch` / `create_file` 在**执行层**解析 diff header，只放行 spawn 时声明过的路径（≤16 个）。删除、重命名、越界一律 deny |
| 锁 | `AgentSubagentEditorLock`，一文件一编辑者，per 父会话，全有或全无 |

关键在于第二道门**不是靠提示词求模型守规矩**，是在 `executeToolCall` 里逐次校验。补丁本身走父会话的 patch 管线（`autoApplySource: .subagentEditor`），进 artifact ledger 和撤销路径。

### 2.2 命令：判定顺序

`executeToolCall` 里的 guard：

1. 静态分类为只读 → 直接放行
2. 模糊、非敏感、非确定性危险的命令 → 送**父会话那个同一个安全裁判**（`safetyJudgeApproval`）批一次
3. `requiresTypedConfirmation` / `credentialSensitive` / 确定性危险 → 模型永远够不到，只能父会话拿 `ops_runner` + `target_command` 找人批，**精确文本匹配**
4. 终端：只有 `terminal_operator` 拿得到 controller，且 `send_command` 的命令文本必须分类为只读

### 2.3 审计现状

- `AgentSandboxAuditLog` 写 `sandbox.jsonl`：toolName / mode / approvedBy / summary / reason / outcome
- `recordJudge` 写 `judge.jsonl`：toolName / command / model / verdict / detail

---

## 3. 三个缺口

### 缺口一：审批 UI 到不了子层

见 §1。这是整件事的核心。

### 缺口二：工种的工具调用根本不进 sandbox.jsonl

`AgentSandboxAuditLog.append` 的调用点**全部在父层**——`AppStateAgentLoop`、`AppStateAgentLoopToolBatching`、`AgentBackgroundJobs`、`AppStateAgentComposer`、`AppStateAgentSandboxEscalation`。`AgentSubagents.swift` 里一处都没有。

补丁是安全的（走父会话 patch 管线，进 ledger），但**「哪个工种在什么时候批了什么命令」查不出来**。`judge.jsonl` 能查到裁决，可 `JudgeEntry` 只有 toolName / command / model / verdict / detail，没有 runID、没有 profileID、没有 parentRuntimeID。

开放写入之前这个必须先补，否则出了事没法复盘。

### 缺口三：等待槽只有一个

`awaitToolDecision` 用的是 `runtime.toolDecisionWaiter` 单槽 + 单 `toolDecisionWaiterCallID`。两个工种并行、同时要人批，就会互相踩。

---

## 4. 方案：四步，风险递增

### 第 0 步 · 审计带上身份（先决条件）

- `Entry` 与 `JudgeEntry` 各加 `workerRunID` / `profileID` / `parentRuntimeID`
- `approvedBy` 加一个取值区分「子层裁判批的」——今天工种走裁判批的命令，`approvedBy` 落的是父会话的值，分不出是谁批的
- 把 `AgentSandboxAuditLog.append` 接进 `AgentSubagents.executeToolCall`

纯加字段，向后兼容（旧行缺字段照样解析）。**不开放任何新能力**，是开放前的先决条件。

### 第 1 步 · waiter 改成 keyed map

`toolDecisionWaiter: CheckedContinuation?` → `[AgentToolCall.ID: CheckedContinuation]`。

`onCancel` 分支要一次性 resume 全部——否则就是 rc38 修过的那个「continuation 存了没 resume，卡死工具派发循环」的并行版复发。

纯地基，不新增能力，可以单独发一版。

### 第 2 步 · 审批升格（核心）

一条 `approvalEscalator` 通道，注入位置与现在的 `commandReviewer` 完全一样。语义是**挂起，不是杀死**：

- 工种 await
- 父会话在自己的 transcript 上挂一张卡，标题写清「工种 X · run agent_ab12cd 请求：<命令>」
- 复用现成的 `AgentToolCall` + `awaitToolDecision`，不新造 UI
- 批了就跑；拒了拿到带理由的 deny 字符串，**接着干别的活**，子 loop 不被 kill

判定顺序一行不改地复用主模型那套（`autoApprovalSource`）。

### 第 3 步 · 中途沟通（单独立项）

今天 `onProgress` 是单向的（1.301.0-rc1 起工种能逐轮把公开正文说进聊天区，但仍然只是单向）。要做到「不断沟通进度、及时调整」，需要 `ask_parent` 这类子层工具：工种提问 → 父决定自己答还是转给人 → 答案回灌子 loop。

放在第 2 步稳定之后做：它把工种从「一次性任务」变成「长时对话」，round cap 和 token 预算都要重算。

---

## 5. 子层刻意收窄的三处

复用主模型的判定顺序，但在子层**收紧**，这三条是设计决定，不是照抄的疏漏：

**5.1 `requiresTypedConfirmation` / `credentialSensitive` 永不升格。** 维持现在「父会话 `ops_runner` + 精确文本」不变。打字确认的意义就是让人亲手打一遍，隔一层代理就没了。

**5.2 `.fullAccess`（完全访问）在子层降一档到 smart。** 完全访问是用户对「主模型这一个对象」的授权，不是对「主模型 + 它今天临时招的一堆工种」的授权。爆炸半径不该随 spawn 数量线性放大。

**5.3 工种点的「一律允许」只在本次 spawn 内有效。** 不写进会话级或持久化名单，否则一个工种能给整个会话开后门。

---

## 6. 明确不做的两件

**6.1 不让工种直连人（跳过父）。** 审批要有上下文才判得准，而上下文在父那儿。工种直连的结果是用户面对十几张没头没尾的卡片。星型拓扑是对的，`docs/ORCHESTRATOR_DESIGN.md` 里「WillDeep 是包工头，不是工人之一」「星型不做 mesh」说的是同一件事。

**6.2 不把声明式路径集换成「工作区随便写」。** spawn 时声明全集 + 执行层逐次校验，是这个特性里最硬的一块，开放写入恰恰要靠它扛。真要放宽，放宽的是 `maxTargetCount`（现在 16）或允许目录前缀，**不是撤掉校验**。

---

## 7. 验收

每一步各自可验收，不必等整条链路做完：

| 步骤 | 验收 |
| --- | --- |
| 0 | `sandbox.jsonl` / `judge.jsonl` 里能按 `profileID` 过滤出某个工种的全部决策；工种的工具调用有落账 |
| 1 | 两个并行工种同时申请人工审批，两张卡都能独立批/拒，取消整个回合时两个 continuation 都被 resume（无卡死） |
| 2 | 工种撞上需人工审批的命令 → 父 transcript 出卡 → 批准后**同一个子 loop 继续**（轮次不重置、上下文不丢）；拒绝后子 loop 拿到理由继续干别的 |
| 2 | 三条收窄各有测试：打字确认类不出现在子层卡片上；`.fullAccess` 会话里子层仍按 smart 判定；工种的「一律允许」不落进会话级名单 |

---

## 8. 未决

- 第 2 步的审批卡要不要显示工种当前的发言上下文（1.301.0-rc1 起 `AgentSubagentLiveActivity` 已经有这份数据）。倾向于显示：判断一条命令该不该批，「它为什么要跑这条」是关键信息。
- 后台派发（`run_in_background`）的工种如何参与审批。它的工具卡在派出去那一刻就 settle 了，挂一张需要人点的卡在「已成功」的记录底下自相矛盾。与「后台工种可见性」是同一个未决问题，见该项。
