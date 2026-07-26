# WillDeep 调度者（Orchestrator）设计文稿

> 状态：MVP 已实现，完整调度状态机按阶段继续收口
> 起草日期：2026-07-26
> 关联文档：`docs/MULTI_EXPERT_CONSULTATION.md`、`docs/SOME_IM_MANAGED_ROUTING_DESIGN.md`、`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`、`product-overview.md`
> 一句话：把 WillDeep 从「会用外部编码 CLI 的 agent」升级为「指挥 Claude Code / Codex / Cursor / 自研 loop 一起干活的调度者」。

---

## 1. 背景与动机

WillDeep 目前已能以 headless 子进程方式委派 Claude Code、Codex CLI、Cursor Agent、Cline CLI（1.195.0-rc1 起统一任务契约），但委派语义停留在「某一轮对话里的一次工具调用」：

- 派出去就是一锤子买卖，**没有可续接的执行器会话**（返工只能重新冷启动）；
- 委派没有一等的**任务对象**，不可持久化、不可跨会话查看、不可重派；
- 用户**看不见**「谁在哪个分支上干什么活、干到哪了」，只有 transcript 里一行工具调用摘要；
- 多个执行器并行时，隔离（worktree）、限流（进程数/账号限额）、合并（验收后 merge）全靠主模型临场发挥，没有确定性的调度层。

目标形态：用户给 WillDeep 一个目标（Goal），WillDeep 拆解成子任务，按任务特征把活分派给最合适的执行器（Claude Code / Codex / Cursor / 自研 agent loop），各执行器在独立 worktree 上并行干活，WillDeep 负责验收、返工、换人和最终合并——**WillDeep 是包工头，不是工人之一**。

## 2. 目标与非目标

### 目标

1. 执行器统一抽象：四类执行器（三家外部 CLI + 自研 loop）走同一个适配器协议，支持派工、流式进度、**会话续接（resume）**、中断、产出提取。
2. 一等任务对象 `DispatchTask`：持久化、可跨会话查看、有完整生命周期状态机。
3. 确定性调度层：执行器选择（judge 或用户指定）、per-executor 并发槽、失败返工/换人策略、worktree 隔离与合并收口。
4. 调度台 UI：侧栏一级入口 + 任务看板 + transcript 派工卡片 + Composer 派工模式开关。
5. 复用既有资产（任务契约、worktree、后台 job、并发槽、省心托管裁判模式），不另起炉灶。

### 非目标（本期不做）

- 不做多节点 daemon、自动容量调度和跨机器迁移；MVP 允许用户选已有 SSH runtime，把任务放到该远端 workspace 执行。
- 不动专家圆桌 / 多专家会诊两条线（它们是「讨论/评审」编排，本设计是「执行」编排；未来可互相引用但不合并实现）。
- 不做执行器之间的直接对话（所有协调经过 WillDeep，星型拓扑，不做 mesh）。
- 不承诺 Cursor Agent 与 Cline 的完整能力对齐（见 §10 风险）。

## 3. 现状资产盘点

| 能力 | 位置 | 复用方式 |
| --- | --- | --- |
| 外部 CLI 目录与探测 | `Xedit/LocalAgentCLI.swift`（catalog 12 个，4 个可直调） | 执行器注册表的数据源 |
| 委派工具实现 | `Xedit/AgentTools.swift`（`claudeCodeCommandLine` 等，权限模式映射，刻意排除 bypassPermissions） | 升级为 ExecutorAdapter 的命令构造层 |
| 任务契约 | 1.195.0-rc1：执行器交证据 → 只读复核 → WillDeep 独立验收，≤3 轮返工 | 直接作为 DispatchTask 的验收状态机 |
| 后台 job 管线 | `Xedit/AgentBackgroundJobs.swift`（job handle、输出缓冲、kill、完成通知） | 执行器进程的宿主 |
| git worktree | `Xedit/AgentGitWorktrees.swift`（创建、并发碰撞检测） | 每任务一 worktree 的隔离层 |
| 并发槽 | `Xedit/AppStateAgentDispatchQueue.swift`（per-provider FIFO） | 模式复制为 per-executor 槽 |
| 路由裁判 | `Xedit/SomeIMManagedRouting.swift`（轻量 judge + 会话级 floor） | 模式复制为执行器选择 judge |
| 委派终端 | `Xedit/AgentDelegatedTerminalRunner.swift`、`AgentSidePanelTerminalView.swift` | 派工卡片「查看实时输出」的落地 |
| 卡片挂载套路 | `Xedit/AgentMessageModels.swift`（`AgentRole`：`.workflowReport` / `.widget` / `.scheduledTask` 先例） | 新增 `.delegatedTask` 卡片 |
| 侧栏目的地 | `Xedit/AgentSessionsSidebar.swift`（`.roundtable` 先例） | 新增 `.dispatchBoard` 调度台入口 |

### 3.1 MVP 已落地的边界

- Goal 清单被投影为持久化的任务图；Goal 是一级对象，任务依赖、执行器策略、环境策略和最近指令可在调度台直接查看。
- Goal 必须显式绑定一个主工作区；没有工作区的旧 Goal 只读展示为“未绑定工作区”，补绑前不能启动、发指令或进入 Goal 模式。
- 本机与 SSH 是执行环境，不是工作区。一个 Goal 可以为同一项目显式登记多个 checkout 映射；环境选择只列出已有映射，任务运行时必须使用对应映射的精确路径。
- 默认由确定性静态规则自动选执行器（测试/搜索优先 Codex，跨文件架构工作优先 Claude，其余回落 WillDeep）；用户可在 Goal 或单任务级强制指定，指定项不可用时明确阻塞，不静默换人。
- 本机执行器来自 `LocalAgentCLI` 探测；SSH runtime 探测会附带 Claude Code、Codex、Cursor Agent、Cline CLI 的可执行路径，调度器据此判断远端可用执行器。
- 普通 Goal 指令在当前步骤结束后的安全点进入下一轮；追加任务、暂停/恢复等纯调度动作立即生效；“立即中断”必须二次确认，保留已有输出后停止当前轮次并优先应用新指令。
- MVP 复用真实 `AgentRuntime` 启动本机或 SSH 任务会话。独立 worktree 自动创建、外部 CLI resume、自动验收返工与合并仍属于后续阶段，不在 UI 中伪装成已完成能力。

## 4. 总体架构

```
┌─────────────────────────────────────────────────────────┐
│  WillDeep 主会话（Dispatcher / 包工头）                    │
│  Goal 拆解 → DispatchPlan（子任务 DAG）                    │
└──────────────┬──────────────────────────────────────────┘
               │ 派工（DispatchTask）
┌──────────────▼──────────────────────────────────────────┐
│  DispatchCoordinator（确定性调度层，非 LLM）                │
│  · 执行器选择（judge / 用户指定 / 会话默认）                 │
│  · per-executor 并发槽 + FIFO 队列                        │
│  · worktree 分配、生命周期状态机、返工/换人策略               │
└───┬──────────┬──────────┬──────────┬────────────────────┘
    │          │          │          │  ExecutorAdapter 协议
┌───▼───┐ ┌────▼────┐ ┌───▼────┐ ┌───▼─────────┐
│Claude │ │ Codex   │ │ Cursor │ │ 自研 loop    │
│Code   │ │ CLI     │ │ Agent  │ │(AgentRuntime)│
└───┬───┘ └────┬────┘ └───┬────┘ └───┬─────────┘
    │  各自独立 git worktree + 分支    │
┌───▼──────────▼──────────▼──────────▼─────────┐
│  验收（任务契约）→ merge 集成分支 → 冲突再派工   │
└──────────────────────────────────────────────┘
```

关键原则：

1. **星型拓扑**：执行器之间不直接通信，所有上下文交换经 WillDeep 汇总转述。
2. **调度层是确定性代码，不是 LLM**：LLM 只出现在两处——Goal 拆解（主模型）与执行器选择 judge（轻量模型，可选）。状态机、槽、队列、超时、返工计数全部是普通 Swift 代码，可单测。
3. **执行器是黑盒工人**：只关心「输入（prompt+worktree+约束）→ 流式进度 → 产出（diff+证据）」，不关心内部实现。
4. **Workspace 与 Environment 正交**：层级是 `Workspace / Project → Goal → Task`，执行环境只是某个 Workspace checkout 的运行地点。自动选择可在已映射环境中决定，但不得自动猜测另一个目录属于同一项目。

## 5. 执行器适配层（ExecutorAdapter）

### 5.1 协议

```swift
protocol ExecutorAdapter {
    var kind: ExecutorKind { get }            // .claudeCode / .codexCLI / .cursorAgent / .native
    var capabilities: ExecutorCapabilities { get } // resume / structuredEvents / planMode …

    /// 派工：在指定 worktree 启动一次执行，返回可续接的执行器会话句柄
    func start(_ assignment: ExecutorAssignment) async throws -> ExecutorSessionHandle
    /// 续接：携带返工意见继续同一执行器会话（能力不支持时降级为带上下文摘要的冷启动）
    func resume(_ handle: ExecutorSessionHandle, feedback: String) async throws
    /// 事件流：统一事件模型（见 5.3）
    func events(_ handle: ExecutorSessionHandle) -> AsyncThrowingStream<ExecutorEvent, Error>
    func cancel(_ handle: ExecutorSessionHandle) async
}
```

`ExecutorAssignment` 至少包含：任务描述 prompt、worktree 绝对路径、目标分支、约束（禁改路径 glob、验收标准原文、超时上限、允许的权限模式）。

### 5.2 各执行器的 headless 形态

| 执行器 | 派工命令 | 结构化输出 | 续接 | 备注 |
| --- | --- | --- | --- | --- |
| Claude Code | `claude -p <prompt> --output-format stream-json --permission-mode <m>` | ✅ stream-json 事件流 | ✅ `claude -p --resume <session-id>` | 能力最全，Phase 1 主力 |
| Codex CLI | `codex exec <prompt> --json` | ✅ JSONL 事件 | ✅ `codex exec resume <session-id>` | Phase 1 主力 |
| Cursor Agent | `cursor-agent -p <prompt> --output-format json` | ⚠️ 有但字段较少 | ⚠️ 不稳定 | Phase 1 保持现状「可用不承诺」，resume 走降级路径 |
| 自研 loop | 进程内 `AgentRuntime`（不起子进程） | ✅ 原生 | ✅ 原生 | 后端即省心托管模型池；也是其余三家不可用时的兜底 |

- 命令构造复用 `AgentTools.swift` 现有的 executable 探测与权限模式映射；**继续排除 bypassPermissions**，执行器内部的危险命令由其自身权限模式 + 我方 seatbelt 双层兜底。
- 版本探测进 `capabilities`：CLI 版本过旧缺 flag 时降级并在任务卡片上明示，不静默。

### 5.3 统一事件模型

```swift
enum ExecutorEvent {
    case started(sessionID: String?)
    case progress(text: String)                  // 文本进度/思考摘要
    case toolActivity(name: String, detail: String) // 执行器内部的工具调用摘要
    case fileChanged(path: String, kind: ChangeKind)
    case evidence(ExecutorEvidence)              // 测试输出、构建结果等证据块
    case finished(exitCode: Int32, summary: String)
}
```

各 adapter 负责把 stream-json / JSONL / 纯文本解析成上述事件；解析失败时降级为 `progress(原始行)`，**永不因解析失败丢任务**。事件双写：喂 UI（任务卡片实时区）+ 追加到任务日志文件（`~/Library/.../DispatchTasks/<id>/events.jsonl`，供事后审计与验收复核）。

## 6. 任务模型与生命周期

### 6.1 DispatchTask

```swift
struct DispatchTask: Codable, Identifiable {
    let id: UUID
    var title: String
    var goalID: UUID?                 // 所属 Goal（可空：手动派工）
    var originSessionID: UUID         // 发起会话
    var executorKind: ExecutorKind
    var executorSessionID: String?    // CLI 侧 session id，续接用
    var worktreePath: String
    var branchName: String            // dispatch/<goal-slug>/<task-slug>
    var assignment: ExecutorAssignment
    var state: DispatchTaskState
    var reworkCount: Int              // ≤ 3（沿用任务契约）
    var executorHistory: [ExecutorKind] // 换人记录
    var evidence: [ExecutorEvidence]
    var usage: DispatchUsage          // token / 时长 / 进程时长
    var createdAt: Date
    var updatedAt: Date
}
```

持久化：独立目录 JSON 文件（一任务一文件），**不进会话消息体**；卡片只存 taskID 引用。落盘走既有串行后台写管线的同款套路（seq 保序）。

### 6.2 状态机

```
queued → running → reviewing → accepted → merging → merged
   ↑         │          │                    │
   │         │          ├→ rework(≤3) ───────┤  （resume 携带验收意见）
   │         │          └→ reassigned ───────┘  （换执行器，冷启动 + 上下文摘要）
   │         └→ failed / cancelled / timeout
   └── blocked（依赖的前置任务未 merged）
```

- **reviewing**：沿用任务契约三步——执行器证据 → 只读上下文复核 → WillDeep 独立验收。验收在**主 worktree 之外**以只读方式检查任务 worktree（diff + 跑测试），验收 prompt 里附验收标准原文。
- **rework**：验收意见作为 feedback 走 `resume`；第 3 次仍不过 → 自动转 `reassigned`（换 judge 排名次优的执行器）或升级到人（用户设置决定）。
- **merging**：验收通过后 merge 回集成分支（默认 develop 或 Goal 的集成分支）。冲突时**不在原任务里硬解**，生成一个新的 `DispatchTask`（title: "解决 X 与 Y 的合并冲突"）走正常派工流程。
- 所有终态都释放并发槽并清理/归档 worktree（merged 的 worktree 删除；failed 的保留 48h 供尸检）。

### 6.3 依赖与并行

`DispatchPlan` 是子任务的 DAG（由 Goal 拆解产出，主模型生成、用户可在计划模式下审阅修改）。Coordinator 只发射入度为 0 的任务；一个任务 merged 后重新计算入度。**禁改路径 glob 用于静态并行冲突预判**：两个任务的改动范围声明有交集时自动串行化，即使 DAG 上无依赖。

## 7. 调度策略

### 7.1 执行器选择

三档，Composer 可选（默认自动）：

1. **自动调度**：复刻省心托管裁判模式——轻量 judge（someim-judge 同款通道）输入任务特征（类型：新功能/重构/测试补齐/修 bug；预估体量；是否需要长上下文；语言栈），输出执行器排名。judge 不可用时走静态规则表兜底（可配置，如「测试补齐 → Codex，跨文件重构 → Claude Code」）。
2. **指定执行器**：用户在派工卡片或 Composer 上点名。
3. **只用本机**：全部走自研 loop（离线/合规场景）。

裁判结论缓存到任务对象，换人时按排名顺延。

### 7.2 并发与限额

- per-executor 并发槽，独立于现有 per-provider 槽（外部 CLI 不占 provider 槽，占进程槽）。默认：Claude Code 2、Codex 2、Cursor 1、自研沿用 provider 槽；全局执行中任务上限默认 4。全部可在设置里调。
- 排队 FIFO + 依赖就绪优先；槽满时任务停在 `queued`，卡片明示「排队中（前面还有 N 个）」——吸取「无 provider 槽消息进无形队列」的教训，**排队必须可见**。
- 超时：单任务默认 30 分钟无 `finished` 且事件流静默超过 5 分钟 → 判 `timeout`（idle 静默兜底，不只等收尾行）。

## 8. UI 设计

### 8.1 侧栏：调度台（一级入口）

`AgentSessionsSidebar` 在「专家圆桌」同级新增 `.dispatchBoard` 目的地「调度台」。MVP 采用用户选定的 Goal-first 方案：

- 左栏上半区是 Goal 列表与进度，下半区是这台 Mac 和 SSH 执行环境；没有把执行器/机器选择的负担先甩给用户。
- 新建 Goal 先选择主工作区；旧 Goal 未绑定时显示醒目标记，顶部和检查器均可补绑。顶部工作区菜单允许为同一项目添加本机或 SSH checkout 映射。
- 中间以 Goal 标题、声明和任务 DAG 为主视觉，任务卡显示状态、执行器、环境和依赖；点选任务后在右侧检查器查看或覆盖策略。
- 顶部 Goal 级策略默认自动；用户可以强制指定执行器或已映射环境。右侧任务级选择优先于 Goal 级选择，未映射环境不会进入选项。
- 底部是 Goal 指令栏，明确展示“立即生效 / 当前步骤后生效 / 需要中断确认”的结果，并提供追加任务、调整计划、暂停/恢复快捷动作。
- 任务启动后复用真实对话运行时；用户可以从检查器打开对应任务对话继续交互。

完整版本再增加多 Goal 汇总看板、实时事件流、diff、证据、返工与合并操作；这些能力不阻塞 MVP 的 Goal 交互和 SSH 执行闭环。

### 8.2 Transcript：`.delegatedTask` 卡片

按 `.scheduledTask` 先例落地：`AgentRole` 新增 case → AgentClient 各 adapter 过滤不发 LLM → `AgentChatTranscript` 分派到新 `AgentDispatchTaskCardView`。

- 卡片内容 = 任务对象的投影（按 taskID 实时取），显示状态徽标、执行器、分支、最近一条进度、操作按钮（查看详情 / 取消）。
- **不变量（历史教训，硬性要求）**：新 role 必须在 transcript 有真实渲染路径（不能只加 `AgentModeMessageView` 分支）；`messageHash` 必须包含状态、进度摘要等全部展示字段，否则状态变了卡片不刷新。

### 8.3 Composer 与状态栏

- Composer 模式区（现「省心托管 / 普通 / 智能审批」一排）新增**派工**开关：`自动调度 / 指定执行器 / 只用本机`。默认自动，延续「不让用户操心选型」哲学。
- 底部状态栏（`EditorStatusBar`）分支名旁新增活跃执行器计数（如 `⚙2`），点击跳调度台。
- 新对话空态页的统计块接入调度台数据（进行中任务数、今日合并数），并放调度台入口。

### 8.4 文案

所有新增用户可见文案走 L10n 资源（调度台、派工、验收、返工、换人、排队中等），中英双语，不硬编码。

## 9. 安全与审批边界

- 外部执行器的权限模式映射维持现状：普通派工 → 各 CLI 的受限模式；**永不注入 bypassPermissions / 全自动模式**。
- 执行器只在自己的 worktree 内工作；assignment 中的禁改 glob 同时作为验收检查项（越界改动 = 验收直接不过）。
- merge 操作由 WillDeep 侧执行且遵守既有智能审批语义；merge 到共享分支前如集成分支即 develop，走一次用户确认（可在设置中对单 Goal 授权「本 Goal 内自动合并」）。
- 执行器 stdout 中疑似密钥按既有脱敏规则处理后再入事件日志。

## 10. 风险与对策

| 风险 | 对策 |
| --- | --- |
| Cursor Agent headless 能力弱（resume 不稳、事件字段少） | Phase 1 标注「可用不承诺」；resume 走降级冷启动；capabilities 探测 + 卡片明示降级 |
| CLI 版本漂移导致 flag 失效 | 启动时 `--version` 探测入 capabilities；构造命令前校验，缺失即降级并明示 |
| 外部 CLI 登录态过期 | start 前 preflight（各 CLI 的 auth 检查命令）；失败任务状态 `blocked` + 卡片给「去登录」指引，不静默吞 |
| 多执行器并行打满机器（CPU/内存） | 全局执行中上限默认 4；后续接入负载感知（内存水位高时暂停发射新任务） |
| worktree 泄漏堆积 | 终态自动清理 + 启动时孤儿 worktree 扫描回收（failed 保留 48h） |
| 复杂度失控（P0 红线） | 全部新类型开新文件（`AgentDispatch*.swift` 前缀）；不向 `AppStateAgentSessions.swift` / `AppState.swift` 聚合区加逻辑，AppState 只挂一个 `dispatchCoordinator` 引用；complexity_guard 阈值内 |
| 主会话与执行器改同一文件 | 静态禁改 glob 交集预判 + 既有 `AgentWorkspaceCollision` 碰撞检测双保险 |

## 11. 分期路线

### Phase 1 — 委派显性化（不动调度智能）

1. `ExecutorAdapter` 协议 + Claude Code / Codex 两个 adapter（含 resume、stream-json/JSONL 解析）；Cursor 包一层降级 adapter。
2. `DispatchTask` 模型 + 持久化 + 状态机（无 DAG，单任务）。
3. 现有 `claude_code` / `codex_cli` / `cursor_agent` 委派工具改为产出 DispatchTask（自动 worktree 隔离）。
4. `.delegatedTask` transcript 卡片 + 任务详情页（先不做看板）。
5. 验收流对接任务契约；返工走 resume。

验收标准：在一个会话里派 Claude Code 和 Codex 各一个任务并行执行，卡片实时刷新，一个任务验收返工一次后通过，merge 回集成分支，全程无需用户进终端。

### Phase 2 — 自动调度

1. 执行器选择 judge + 静态规则兜底 + Composer 派工模式开关。
2. Goal 拆解产出 `DispatchPlan`（DAG）+ 依赖调度 + 禁改 glob 串行化。
3. per-executor 并发槽 + 排队可见 + 超时/换人策略。

### Phase 3 — 调度台

1. 侧栏 `.dispatchBoard` 看板视图（五列）。
2. 状态栏执行器计数、空态页统计接入。
3. 成本/限额感知（各 CLI 账号限额探测、token 预算）、负载感知发射。

每个 Phase 独立可发布，走 feature 分支 + 单测全绿 + rc 版本递增的既有流程。

## 12. 待确认问题

1. 集成分支策略：子任务统一 merge 回 develop，还是每个 Goal 先开集成分支、Goal 完成后一次性回 develop？（建议后者，隔离更干净）
2. 验收用哪个模型：主会话当前模型，还是固定用省心托管 coding 档？（涉及成本）
3. Cline CLI 是否进 Phase 1 的 adapter 列表？（headless 能力待实测，建议 Phase 2 再评估）
4. 「本 Goal 内自动合并」授权的默认值（建议默认关，按 Goal 显式开启）。
5. 移动网关是否需要看到调度台（手机上看任务进度）？若要，DispatchTask 的只读投影需进网关协议。
