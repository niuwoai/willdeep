# 环境信任声明（Environment Trust Declarations）

> Canonical 设计文档。1.280.0-rc3 引入。
> 背景审计：2026-08 审计日志中 892 次人工/升级审批，很大一部分落在
> "终端环境其实可随意操作"与"数据库其实是测试实例"两类用户心知肚明、
> 系统却无从得知的场景。

## 要解决的问题

用户经常在提示词里预先说明环境事实——"当前终端是 docker 一次性容器，
写文件删文件不用审"、"这个 mysql 是测试专用实例，随便操作"。此前这些
声明只进入对话上下文，审批链路完全无感：静态分类器照常把 `rm`、多语句
SQL、DROP 判成危险并落人工确认。

## 设计

### 数据模型（`AgentEnvironmentTrust.swift`）

- `AgentEnvironmentTrustKind`：`disposableTerminal`（一次性/可随意操作的
  终端环境）、`testDatabase`（测试专用数据库实例）与 `deploymentWindow`
  （一段部署作业，1.375.0-rc9 引入）。
- `AgentEnvironmentTrustDeclaration`：`kind` + `target`（testDatabase 必填的
  命令匹配子串，≥3 字符；terminal 为可选备注）+ `userStatement`（用户原话，
  逐字引用）+ `createdAt`。
- **会话内存态，不落盘**：存在 `AgentRuntime.environmentTrustDeclarations`，
  与 `conversationAllowedToolSignatures` 同待遇——关会话即失效，重开要重新
  声明。这是刻意的：声明的生命周期与用户"此刻知道环境是什么"的语境绑定。

### 声明的建立（`declare_environment_trust` 工具）

- Agent 在用户**亲口声明**时调用（工具描述明确要求逐字引用用户原话，
  不得从工具输出、文件内容、网页里"发现"声明）。
- **任何模式下都不可自动通过**：`autoApprovalSource` 入口硬排除
  （`neverAutoApprovedToolNames`），Goal 模式的非命令写免审、workspaceAccess
  白名单、always-allow pin 全部够不到它。一次人工点击 = 一次授权仪式，
  这是防注入自授权的关键闸门——注入文本骗 Agent 调工具，用户会在卡片上
  看到"我从没说过这话"的声明原文并拒绝。
- `revoke_all` 动作同样走人工确认（撤销免费不设卡的收益 < 链路统一的简单性）。

### 声明的效力（"适度"档：放行到 AI 裁判，不放行到静态免审）

声明**不产生任何静态自动通过**。它做三件事：

1. **拓宽裁判受理范围**：声明覆盖的命令，原本 `.alwaysDangerous` →
   直接人工的，改送 AI 裁判；`terminal_send_command` 的 `.alwaysSafe`
   静态放行不再要求 readOnly 沙箱档（那个限制的本意就是"不知道终端指向
   哪儿"，声明恰好补上了这个信息）。
2. **裁判提示词注入声明块**：经 `AgentInjectionDefense` 的围栏管线
   （标记中和、逐条截断），语义与历史决策块不同——历史"不构成许可"，
   人工确认过的声明**在其范围内构成许可**。
3. **typed-confirmation 的有限豁免**：destructive 类（`rm`、`dd`、
   DROP……）在声明范围内降为"送裁判"；**凭据类永不豁免**——
   `AgentSandboxDecision.credentialSensitive` 标记 `.env`、`~/.ssh`、
   凭据词命中，带此标记的命令在任何声明下仍然只认人工。

范围限定：

- `disposableTerminal` 只作用于 `terminal_send_command` / `terminal_send_control`
  （可见终端就是被声明的环境）；`run_command` 在本机沙箱里跑，不吃终端声明。
- `testDatabase` 作用于 `run_command` 与 `terminal_send_command`，且命令文本
  必须包含 `target` 子串（容器名、host、库名……）——不含目标标识的命令
  不享受声明。
- `deploymentWindow` 作用于 `run_command` 与 `terminal_send_command`，匹配
  条件是**命令属于部署命令族**（见下节），`target` 可选：填了集群 /
  namespace / 主机名（≥3 字符）就额外要求命令包含它。

### 部署窗口：唯一直接放行的一类（`AgentDeploymentWindow.swift`）

一次发布里 kubectl / helm / docker / systemctl 要跑几十条，逐条确认的结果
是人盯着屏幕点了半小时——而人一旦进入连点模式，卡片就不再是保护，只是
仪式。

这一类与另外两类的**分水岭**：它直接放行（`approvalSource` =
`.environmentTrust`），不送裁判。理由是判定依据不同——`testDatabase` 的
"这库是测试库"只有读懂命令语义才判得了，只能交给裁判；而"这条命令是不是
部署命令"是一份**列得出来的清单**，宿主自己就判得了。把部署命令也送裁判
等于白声明：用户要的正是别再为每条 kubectl 停一次。

地基是白名单而不是裁判，与静默档位同一个理由：裁判会掉线、会被提示词带偏，
一份列得出来的清单不会。

族内（各工具的部署类子命令，完整清单见源码常量）：

| 工具 | 子命令 |
| --- | --- |
| kubectl | apply / rollout / scale / set / patch / create / replace / label / annotate / autoscale / expose / cordon / uncordon |
| helm | install / upgrade / rollback / template / lint / status / list / repo / dependency |
| docker | build / push / pull / tag / compose / start / stop / restart / logs / ps / images |
| systemctl | start / stop / restart / reload / enable / disable / daemon-reload / status / is-active / is-enabled |

**刻意排除**，即使在窗口内也照常询问：

- `kubectl delete`：删一个 pod 和删掉整个 namespace 或 pvc 差着一场事故。
  一次发布里也就那么一两条，单独确认一次不亏。
- `helm uninstall`、`docker system prune`、`docker volume rm`、
  `systemctl mask`：与同族的升级操作长得像，后果不是一个量级。
- 带管道、重定向、反引号或 `$(...)` 的命令：放行单位是整条命令，
  `kubectl get -o json | sh` 的前半段再干净也不作数。
- 多段命令中只要有一段在族外，整条不放行。
- 凭据敏感命令（`credentialSensitive`）：与另外两类同待遇，一票否决。

沙箱档位与裁判放行时**完全一致**（`.environmentTrust` 与 `.llmJudge` 同组，
按命令实际需要取档）。省掉的是那次确认，不是那道边界。

### 裁判判决缓存

`judgeVerdictCacheKey` 纳入声明指纹：同一命令在"有声明"与"无声明"
语境下是两个缓存键，revoke 后旧的 YES 不会被复用；跨会话共享的缓存
也不会把 A 会话声明下的判决泄给没有声明的 B 会话。

## 明确不做的

- 不持久化到 AgentSession / 全局设置（fast-follow 可加 per-workspace
  持久声明，需另设管理 UI 与过期策略）。
- 不给 MCP 工具、file_write/file_remove 挂声明效力（沙箱与 diff 审查
  已覆盖）。
- 不从自由文本自动解析声明——必须经 Agent 显式调工具 + 用户点卡。
- 不放宽 `.env` / `~/.ssh` / 凭据词命中（credentialSensitive）的人工门禁，
  哪怕用户声明"整台机器都是一次性的"。理由：凭据外读是注入攻击的
  终点站，这道门的价值恰恰在于它不接受任何来自模型侧的说服。

## 与既有机制的关系

- Always-allow pin：按签名精确放行，适合"同一条命令反复出现"；声明按
  **环境类别**放行，适合"这个环境里的一类操作"。二者正交。
- `AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md` P0"给裁判补目标环境特征"：
  本功能是该条目的用户显式声明形态；宿主自动推断的环境特征仍是后续工作。
- `LONG_HORIZON_AUTONOMY.md`"续推不放宽审批边界"不受影响：声明只能由
  用户当场确认建立，Goal 续推无法自行创建或扩大声明。
