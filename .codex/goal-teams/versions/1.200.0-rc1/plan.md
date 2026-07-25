# WillDeep 专家圆桌准备室与流式发言计划

## 用户目标

在正式讨论前增加与用户共同细化议题、确认讨论框架、推荐并选择专家的准备过程；正式讨论时让专家正文真流式出现，并扩充法律合规、数据研究、市场增长、组织运营等内置专家。

## 已确认默认决策

- 原始议题先进入准备室，不立即开始专家讨论。
- AI 提供精炼议题、3～5 个讨论维度、1～3 个澄清问题和带理由的专家推荐。
- 用户可以继续补充上下文、修改框架、增删专家，再明确确认开始讨论。
- 专家选择最少 2 位、建议 3～4 位、最多 6 位。
- 专家正文采用真流式输出；正文完成后再执行轻量结构化分析，提取立场、建议、风险与追问。
- 保留现有专家原始标识以兼容旧会话；心理专家升级为行为心理与决策定位。
- 新增法律合规、数据研究、市场增长、组织运营专家和独立头像资产。

## 环境检查

| 项目 | 结果 | 动作 |
| --- | --- | --- |
| 会话 AGENTS 规则 | ready | 严格遵守中文、版本、测试、文档与分支规则 |
| 仓库 CLAUDE 指南 | ready | 从 develop 建 feature 分支，测试后提交并合回 develop |
| 当前基线 | `develop@9094bcf8` | 已创建 `feature/roundtable-setup-streaming` |
| 当前版本 | 1.199.0-rc2 / Build 143 | 功能版本提升为 1.200.0-rc1 / Build 144 |
| 工作树 | clean at branch creation | 各成员仅写锁定范围 |
| 文档目录 | ready | `.codex/goal-teams/versions/1.200.0-rc1/` |

## Teams 规划表

| Member | Skill/Subagent | Goal Slice | Claimed Tasks | Locked Scope | Deliverable | Done Criteria | Docs/Tasklist Updates | Test Owner | Validator |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 统筹-圆桌升级集成 | Goal Lead | 共享状态机、引擎集成、版本与合并 | RT-001, RT-006, RT-009 | 公共引擎、工程文件、版本与发布文档 | 完整可运行实现 | 新旧会话兼容，准备室到结论文档闭环 | Architecture、progress、decisions、版本文档 | 测试-圆桌流程独立验收 | 产品-议题准备流程规格 |
| 产品-议题准备流程规格 | product_roundtable_setup | 需求、PRD、交互原型 | RT-002 | 本版本 `spec/` 需求文档与 `prototype/` | 规格卡、PRD、HTML 原型 | 正常、编辑、跳过、恢复、错误分支明确 | Requirement、PRD、prototype、tasklist | 测试-圆桌流程独立验收 | 统筹-圆桌升级集成 |
| 开发-专家流式发言基础设施 | developer_roundtable_streaming | 流式事件、草稿生命周期 | RT-003 | `AgentSubagents.swift`、新增流式支持文件、定向测试 | 可取消、可恢复的真流式正文 | 不解析半截 JSON；不逐 token 写盘；完成后可结构化 | progress、tasklist | 测试-圆桌流程独立验收 | 统筹-圆桌升级集成 |
| 开发-专家组队与准备界面 | developer_roundtable_setup | 准备模型、界面、专家资产与 i18n | RT-004, RT-005 | 新准备视图、圆桌模型、资源与新 i18n 文件 | 准备室、专家选择与新增专家 | 用户明确确认前不进入 opening；2～6 人约束有效 | progress、tasklist | 测试-圆桌流程独立验收 | 统筹-圆桌升级集成 |
| 测试-圆桌流程独立验收 | qa_roundtable_flow | 独立测试、Release GUI 与报告 | RT-007, RT-008 | 测试、验收文档与报告 | 自动化与 GUI 证据 | 所有验收条目有强证据或明确缺口 | Test Plan、Acceptance、progress、tasklist | 本成员 | 产品-议题准备流程规格 |

## 执行顺序

1. 产品成员完成需求规格、PRD 与 HTML 原型，Lead 核对实现边界。
2. 两名开发成员在互斥文件范围内实现流式基础设施和准备室体验。
3. Lead 集成公共圆桌引擎、状态迁移、版本与工程引用。
4. 测试成员独立补足单测、契约测试和验收文档。
5. Lead 运行完整自动化测试、Release 构建与真实模型 GUI 流程，修复缺口。
6. 更新 CHANGELOG、product overview、版本号和 Goal Teams 状态，提交功能分支并合回 develop。

## 风险与停止条件

| 风险 | 缓解 | 停止条件 |
| --- | --- | --- |
| 流式正文和结构化立场互相阻塞 | 两阶段生成，正文优先，结构化失败使用安全降级 | 正文仍需等待完整 JSON 才能显示 |
| 每个 token 持久化造成主线程或磁盘压力 | UI 节流更新，低频检查点，完成时正式持久化 | 出现明显卡顿、写盘风暴或布局循环 |
| 新状态破坏旧会话解码 | 新字段可选、枚举兼容解码、旧阶段保持路由 | 任一旧圆桌会话无法打开 |
| 专家数量导致成本失控 | 2～6 人硬约束和默认 3～4 人推荐 | 无法可靠执行人数上限 |
| 并行修改共享文件冲突 | 文件锁定，公共引擎仅 Lead 修改 | 目标文件出现无法安全判定来源的并行改动 |

