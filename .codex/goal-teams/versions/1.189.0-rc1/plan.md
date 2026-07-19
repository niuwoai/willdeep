# WillDeep Goal Teams 对齐计划

## 用户目标

检查 Codex 最新 Goal Teams 流程，并让 WillDeep 尽量一致：Goal 先由多个独立身份进行基于证据的辩证分析，汇总为可执行计划，用户确认后再进入实现。

## 环境检查

| 项目 | 结果 | 建议 |
| --- | --- | --- |
| 仓库 AGENTS/agent 指南 | missing | 本会话已提供严格项目规则；建议后续将其保存为根目录 `AGENTS.md` |
| CLAUDE 指南 | missing | 本次不阻塞；沿用会话规则与 Goal Teams 默认指南 |
| 当前工作树 | dirty | 仅修改锁定范围，保留现有关于页、密钥输入等未提交改动 |
| 当前仓库版本 | 1.188.0-rc1 | 新增功能目标版本采用 1.189.0-rc1，并保持 Swift/Go/资源版本一致 |
| 文档目录 | ready | `.codex/goal-teams/versions/1.189.0-rc1/` |

## 只读差异结论

| 能力 | Codex Goal Teams | WillDeep 当前 | 本次动作 |
| --- | --- | --- | --- |
| Goal 启动 | 强制规划优先 | Goal 定义后直接自主执行 | 增加规划闸门 |
| 多身份分析 | 独立子代理、角色+具体任务 | 会诊功能独立于 Goal | Goal 自动编排独立只读角色 |
| 辩证过程 | 独立观点、分歧审查、Lead 汇总 | 会诊已有两轮评审，但需手动启动 | 抽取并复用其提示词/子代理能力 |
| 最终产物 | Teams 规划表与可执行计划 | 普通 Goal checklist | 生成 `plan` 块并进入现有 Plan 确认卡 |
| 执行门禁 | 用户确认后启动 worker | Goal 写操作可立即自动批准 | 未确认计划时拒绝写级工具 |
| 任务治理 | owner、locked scope、测试与 validator | 无 Goal Team 契约 | 注入精简 Teams 表契约和独立验证要求 |
| SPEC/文档 | 按需创建版本化文档 | 无 Goal 原生规范 | 对工程任务要求按适用性发现/更新，不强制无意义文档 |

## 当前假设

| 假设 | 影响 | 验证方式 | 是否需确认 |
| --- | --- | --- | --- |
| “一致”优先指用户可见主流程与安全语义，而非逐字移植 Codex 的 JSONL 运行时 | 控制首版范围，避免重写整个 Agent runtime | 流程测试与 UI 卡片验收 | 是 |
| 多身份优先使用 WillDeep 内置只读 `spawn_agent`，不依赖用户安装 Claude/Codex/Cursor CLI | 所有用户都能使用，外部 CLI 会诊仍保留 | 无外部 CLI 环境测试 | 是 |
| 规划成员默认三类：需求/反方、架构/实现、测试/风险 | 兼顾范围、可行性与反例 | Prompt 单测和集成测试 | 否，可后续配置化 |
| 现有 Plan 卡片承担用户确认与执行进度，不新造一套确认 UI | 改动小且交互一致 | UI 状态与工具门禁测试 | 否 |

## Teams 规划表

| Member | Skill/Subagent | Goal Slice | Claimed Tasks | Locked Scope | Deliverable | Done Criteria | Docs/Tasklist Updates | Test Owner | Validator |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 需求分析-Goal Teams 流程契约 | goal_requirements_analyst | 对照 Codex 规范、锁定验收边界 | GT-001, GT-002 | `.codex/goal-teams/versions/1.189.0-rc1/spec/` | 需求规格卡、PRD、差异验收清单 | 核心流程、非目标、降级行为清楚 | INDEX、PRD、tasklist | 测试-Goal Teams 流程验收 | 开发-Goal Teams 规划编排 |
| 开发-Goal Teams 规划编排 | goal_frontend / Swift 实现 | Goal 规划状态机、提示词、Plan 门禁与 UI 复用 | GT-003, GT-004 | `Xedit/AgentContextBuilder.swift`、Goal/Plan 状态与相关最小文件 | 可运行实现与架构说明 | Goal 未确认不写；多角色分析后生成 Plan；确认后执行 | Architecture Design、progress、tasklist、版本文档 | 测试-Goal Teams 流程验收 | 测试-Goal Teams 流程验收 |
| 测试-Goal Teams 流程验收 | goal_qa | 独立验证提示词、解析、门禁、降级与回归 | GT-005, GT-006 | `XeditTests/*Goal*`、`XeditTests/*Plan*`、测试报告文档 | 自动化测试与验收记录 | 关键路径通过，失败/无子代理时安全停住 | Test Plan、Acceptance、progress、tasklist | 本成员 | 需求分析-Goal Teams 流程契约 |

## SPEC Readiness

| SPEC | Exists | Action | Owner | Output |
| --- | --- | --- | --- | --- |
| Requirement Specification Card | no | create | 需求分析-Goal Teams 流程契约 | `spec/requirement-spec-card.md` |
| PRD | no | create | 需求分析-Goal Teams 流程契约 | `spec/PRD.md` |
| Architecture Design | no | create | 开发-Goal Teams 规划编排 | `spec/architecture-design.md` |
| HTML Prototype | not applicable | skip | Goal Lead | 复用原生卡片 |
| Test Plan | no | create | 测试-Goal Teams 流程验收 | `spec/test-plan.md` |
| Acceptance | no | create | 测试-Goal Teams 流程验收 | `spec/acceptance.md` |

## 独立验证计划

| Artifact | Author | Validator | Method | Evidence |
| --- | --- | --- | --- | --- |
| 需求规格卡 / PRD | 需求分析-Goal Teams 流程契约 | 开发-Goal Teams 规划编排 | 与当前代码和 Codex 规范逐项核对 | `progress.md` |
| Swift 实现 | 开发-Goal Teams 规划编排 | 测试-Goal Teams 流程验收 | 代码审查 + 定向测试 + 构建 | `progress.md`、`acceptance.md` |
| 测试用例 | 测试-Goal Teams 流程验收 | 需求分析-Goal Teams 流程契约 | 断言目标、反例与边界覆盖审查 | `spec/test-plan.md` |
| 版本/CHANGELOG/Product Overview | Goal Lead | 测试-Goal Teams 流程验收 | 全仓版本一致性与文档核对 | `acceptance.md` |

## 风险与停止条件

| Item | Risk | Owner | Approval Needed | Stop Condition |
| --- | --- | --- | --- | --- |
| 脏工作树 | 与用户现有未提交改动重叠 | Goal Lead | 是 | 目标文件出现无法安全合并的并行改动 |
| Goal/Plan 双状态 | 破坏现有 Plan 或 Goal 会话恢复 | 开发-Goal Teams 规划编排 | 否 | 旧会话无法解码或模式切换丢状态 |
| 子代理不可用 | Goal 永远卡在规划阶段 | 开发-Goal Teams 规划编排 | 否 | 无安全降级为单 Lead 规划并明确提示的路径 |
| 工具门禁 | 计划前误放行写操作 | 测试-Goal Teams 流程验收 | 否 | 任一未确认写级工具可执行 |
| 版本文件重叠 | 当前 1.188.0-rc1 改动来自其他工作 | Goal Lead | 是 | 发现版本提升会覆盖未完成发布意图 |

## 确认后的执行顺序

1. 需求成员完成 Requirement Specification Card 与 PRD，开发成员独立校验。
2. 开发成员实现 Goal 规划优先状态机、多身份提示词、Plan 解析/确认和写工具门禁。
3. 测试成员独立审查代码并补充/运行关键自动化测试；需求成员反向校验测试有效性。
4. Goal Lead 集成冲突、运行更广验证，更新版本、CHANGELOG、product-overview、SPEC 与验收记录。

## 只读落点审计

| 落点 | 当前证据 | 计划改动 |
| --- | --- | --- |
| Goal 提示词 | `AgentContextBuilder.systemPrompt` 在 Goal 定义后立即宣告自主写入 | 增加 `planning -> proposed -> approved/executing` 三阶段契约；首轮三个独立身份，次轮反方仲裁，最后输出 Teams 表与 `plan` 块 |
| Plan 解析 | `AgentPlanParser` 已能稳定解析 fenced `plan` | 允许 Goal 模式捕获同一格式，无需新增解析协议 |
| 写操作门禁 | `AgentRuntime.isPlanGateActive` 仅识别 `.plan` | Goal 已定义但计划未批准时也激活同一 gate；批准/执行后解除 |
| 用户确认 | Composer banner 与 transcript Plan Card 仅识别 `.plan` | 允许 Goal-backed Plan 显示和确认，复用既有交互 |
| 确认后执行 | `confirmAgentPlanAndExecute` 仅接受 `.plan` | 同时接受 Goal-backed Plan，并要求 `progress` 与 `goal-check` |
| 自动衔接 | Goal 定义在 turn defer 中被捕获 | 定义成功后排入一条 host instruction，自动开始只读团队规划，无需用户再说“继续” |
| Goal 状态 | `AgentSession` 已同时持久化 `currentGoal` 与 `currentPlan` | 不新增破坏性持久化字段；旧会话保持可解码 |
| 子代理 | `spawn_agent` 为内置只读工具，单会话最多并行三个 | 第一轮三个角色可并行；第二轮待报告齐全后串行进行分歧仲裁 |

### 默认规划身份

1. `需求分析-目标边界质疑`：核对真实目标、范围、非目标、隐含假设。
2. `架构-实现路径论证`：基于仓库证据提出最小可靠实现、锁定范围与迁移风险。
3. `测试-失败路径审查`：寻找反例、回归面、验收证据与停止条件。
4. `评审-分歧仲裁`：读取前三份报告，指出冲突、弱证据和应接受/拒绝的主张。

### 安全降级

- 子代理部分失败：至少两份有效独立报告才允许综合；否则停在 planning 并向用户说明。
- `spawn_agent` 不可用：不得静默直接执行，Lead 只能产出明确标注“未完成独立辩证验证”的草案并继续等待确认。
- 计划被拒绝：清空 `currentPlan`，保留 `currentGoal`，下一轮重新规划。
- 计划执行完但 Goal checklist 未完成：重新激活规划 gate，禁止把旧计划当永久通行证。

当前状态：用户已确认，Goal Teams 第一轮 SPEC/架构/测试规划执行中。
