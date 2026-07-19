# Goal Teams Tasklist

Goal：让 WillDeep Goal 模式先进行多身份辩证规划并由用户确认，再开始执行。

状态：completed

| Task ID | Member | Skill/Subagent | Claimed By | Status | Locked Scope | Deliverable | Done Criteria | Verification | Docs/SPEC Update |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| GT-001 | 需求分析-Goal Teams 流程契约 | goal_requirements_analyst | requirements_goal_teams | done | `spec/` | 需求规格卡 | 目标、流程、边界、非目标清晰 | 开发与 QA 独立校验 | Requirement Specification Card（验证通过） |
| GT-002 | 需求分析-Goal Teams 流程契约 | goal_requirements_analyst | requirements_goal_teams | done | `spec/` | PRD | 来自需求规格卡并含可测试验收标准 | 开发与 QA 独立校验 | PRD（AC-01～20 验证通过） |
| GT-003 | 开发-Goal Teams 规划编排 | goal_frontend / Swift | developer_goal_teams | done | Goal/Plan 状态与 prompt 最小文件 | 规划优先状态机 | Goal 多身份规划、Plan 确认、确认后执行 | QA 审查、专项与相关回归通过 | Architecture Design |
| GT-004 | 开发-Goal Teams 规划编排 | goal_frontend / Swift | developer_goal_teams | done | Goal/Plan UI 与工具门禁最小文件 | UI/安全门禁集成 | 未确认计划时无写操作，旧 Plan/Goal 不回归 | QA 与需求成员反向校验通过 | progress.md |
| GT-005 | 测试-Goal Teams 流程验收 | goal_qa | qa_goal_teams | done | 相关 Swift Tests | 定向自动化测试 | 正常、拒绝、降级、恢复路径有断言 | 需求成员校验测试有效性 | Test Plan |
| GT-006 | 测试-Goal Teams 流程验收 | goal_qa | qa_goal_teams | done | 测试与验收文档 | 独立验收 | 代码、测试、版本文档均有证据 | Goal Lead 复核通过 | Acceptance |
| GT-007 | Goal Lead | lead | claimed | done | 版本与发布文档 | 集成与版本一致性 | Swift/Go/资源版本为 1.189.0-rc1，CHANGELOG 与概览同步 | 版本与全仓回归 PASS | INDEX、CHANGELOG、product-overview |

## 阻塞与决策

| ID | Type | Owner | Status | Summary | Decision Needed |
| --- | --- | --- | --- | --- | --- |
| D-001 | 用户确认 | Goal Lead | resolved | 用户已确认三成员方案；因并行版本变化调整为 1.189.0-rc1 | 已确认 |
| D-002 | 范围 | Goal Lead | resolved | 首版对齐用户可见流程与安全语义，不照搬全部 JSONL runtime | 已按最小可靠范围完成 |
| D-003 | 验证 | Goal Lead | resolved | 全仓回归曾暴露“已安排”页面陈旧断言与高负载子进程超时 | 同步语义断言并修复超时调度；最终 1309/1309 通过 |
