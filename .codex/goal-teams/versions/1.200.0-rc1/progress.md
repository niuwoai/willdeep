# Progress — 1.200.0-rc1

## 2026-07-25

- 用户确认默认方案：准备室、2～6 位专家组队、两阶段真流式、新增四类专家。
- 核对当前分支与 `develop` 均指向 `9094bcf8`，工作区无未提交改动。
- 从 `develop` 创建 `feature/roundtable-setup-streaming`。
- 创建版本索引、计划、任务清单与决策日志。
- 产品规格、架构说明、验收清单与单文件离线 HTML 原型完成。
- 会前准备室、澄清对话、讨论框架、带理由的专家推荐及 2～6 位专家选择完成。
- 专家池扩展到十位，新增法律合规、数据研究、市场增长、组织运营及四套独立 SVG 头像；心理专家升级定位。
- 专家发言改为两阶段真流式：可见正文 delta 与 reasoning 分离，首 token 立即显示、80ms UI 刷新、1 秒持久化检查点；正文完成后结构化分析，失败不丢正文。
- 新增可恢复流式草稿与分析完成态；取消/失败清理激活专家和草稿。
- 独立 QA 发现并推动修复确认门禁：仅 `.selectingExperts` 可启动，7 位专家严格拒绝而非静默截断。
- Debug 主工程构建通过；版本一致性报告 PASS（1.200.0-rc1）；Go agent 全部测试通过。
- 独立 QA 完成三套 Swift 定向测试：`AgentRoundtableTests`、`RoundtableSetupAndAnalysisTests`、`AgentSubagentStreamingTests`，共 40 项全部通过；覆盖旧 Codable 缺字段兼容、准备 payload、2～6 人模型边界、正文与推理隔离、分析正文不改写、草稿节流/reset/finish 及流完成态持久化。
- Ruby 交互契约扩展到 18 项并全部通过；新增准备路由、业务层门禁、十位专家资源/i18n、两阶段真流式、草稿节流和取消/失败清理断言，同时保留 AppKit 文本布局循环回归断言。
