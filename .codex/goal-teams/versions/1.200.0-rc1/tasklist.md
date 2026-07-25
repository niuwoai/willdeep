# Tasklist — 1.200.0-rc1

| ID | Task | Owner | Status | Dependencies | Evidence |
| --- | --- | --- | --- | --- | --- |
| RT-001 | 建立版本规格、索引、状态与架构基线 | 统筹-圆桌升级集成 | Done | none | `INDEX.md`、`plan.md`、`decisions.md` |
| RT-002 | 完成议题准备室需求规格、PRD 与 HTML 原型 | 产品-议题准备流程规格 | Done | RT-001 | `spec/`、`prototype/index.html` |
| RT-003 | 实现专家正文真流式事件与草稿生命周期 | 开发-专家流式发言基础设施 | Done | RT-001 | `AgentSubagents.swift`、`RoundtableStreamingSupport.swift`、定向测试 |
| RT-004 | 实现澄清、框架确认、专家推荐与选择界面 | 开发-专家组队与准备界面 | Done | RT-002 | `RoundtablePreparationView.swift`、`RoundtableExpertSelectionView.swift` |
| RT-005 | 增加四类专家、独立头像和 i18n | 开发-专家组队与准备界面 | Done | RT-002 | Assets、L10n、专家模型 |
| RT-006 | 集成准备状态机、两阶段发言与会话恢复 | 统筹-圆桌升级集成 | Done | RT-003, RT-004 | Engine/AppState/Route；Debug build PASS |
| RT-007 | 补齐兼容、门禁、流式、取消、错误与恢复测试 | 测试-圆桌流程独立验收 | Done | RT-006 | Swift 定向 3 suites / 40 tests PASS；Ruby 18/18 PASS |
| RT-008 | 执行 Release 构建与真实模型 GUI 验收 | 测试-圆桌流程独立验收 | In Progress | RT-007 | Release 构建与 GUI 验收进行中 |
| RT-009 | 更新版本、CHANGELOG、Product Overview，提交并合并 develop | 统筹-圆桌升级集成 | Pending | RT-008 | Git 与文档记录 |
