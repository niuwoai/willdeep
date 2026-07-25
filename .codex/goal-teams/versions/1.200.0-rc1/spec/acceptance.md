# Acceptance：专家圆桌准备室与真流式发言（验收初稿）

> 目标版本：1.200.0-rc1 / Build 144  
> 状态：自动化定向验收通过；Release 真模型 GUI 待验收  
> 初稿 Owner：产品-议题准备流程规格  
> 最终 Validator：测试-圆桌流程独立验收

## 1. 当前结论

产品范围、用户流程、门禁、两阶段流式语义、错误/恢复和旧会话兼容标准已经明确；当前文档不代表功能已实现或通过测试。最终验收必须以实现 diff、自动化执行结果、Release 构建和真实模型 GUI 证据为准。

## 2. 验收清单

| ID | 验收项 | 状态 | 所需强证据 |
| --- | --- | --- | --- |
| A-01 | 新议题先进入准备室 | Pending | 状态/调用单测 + Release 截图 |
| A-02 | AI 生成精炼问题、3～5 框架、1～3 澄清问题 | Pending | payload 测试 + GUI |
| A-03 | 用户补充后可修订且原始议题不丢 | Pending | revision/迟到响应测试 + GUI |
| A-04 | 推荐 3～4 位并逐位解释理由 | Pending | 推荐模型测试 + 专家卡截图 |
| A-05 | 完整专家池包含新增 4 类，心理定位升级 | Pending | 枚举、资源、i18n 证据 |
| A-06 | 2～6 人约束在 UI 与业务层同时生效 | Pending | 边界单测 + GUI |
| A-07 | 仅明确开始按钮可越过门禁 | Pending | Enter/恢复/双击负例 + AppState 集成 |
| A-08 | 专家正文有多个真实流式 delta | Pending | fake stream 事件序列 + 真实模型录屏 |
| A-09 | 正文完成后才执行 OSR | Pending | 调用顺序测试 |
| A-10 | OSR 失败仍保留正文并降级待定 | Pending | 错误注入测试 + GUI |
| A-11 | 看板更活泼且立场不只靠颜色 | Pending | UI/可访问性检查 + 截图 |
| A-12 | 三行输入、整条引用、划词引用可用 | Pending | 消息 round-trip 测试 + GUI |
| A-13 | 准备/推荐/启动/流式/分析错误可恢复 | Pending | 故障矩阵 |
| A-14 | 取消、重试、迟到结果不重复消息 | Pending | 并发/幂等测试 |
| A-15 | 准备、选人、发言中重启采取保守恢复 | Pending | 持久化 fixture + GUI |
| A-16 | 旧会话与结论 Markdown 路径不回归 | Pending | 旧 fixture、文档保存/渲染测试 |
| A-17 | 新文案 i18n、键盘与辅助功能完整 | Pending | 静态契约 + 人工走查 |
| A-18 | 版本、CHANGELOG、Product Overview 一致 | Pending | 版本报告 |

## 3. 产品验收口径

以下情况不能以“基本完成”通过：

- 准备室只是动画过场，用户不能真正修改框架。
- 推荐只有专家名单，没有针对议题的理由。
- UI 显示 2～6 人，但底层可用 1 人或 7 人启动。
- 发言采用预制打字动画或拆分完整文本，不是真实 provider delta。
- 流式仍依赖半截 JSON/tool arguments。
- OSR 失败导致整段发言消失。
- 重启后自动开始，或把未确认建议当成已确认。
- 只验证 Debug/假数据界面，没有 Release 真模型路径。

## 4. 最终验收记录模板

### 自动化

| 验证 | 结果 | 数量 | 证据 |
| --- | --- | --- | --- |
| 准备/门禁定向测试 | PASS | 7 个准备/分析测试 + 业务门禁契约 | `RoundtableSetupAndAnalysisTests`、Ruby 报告 |
| 流式/幂等定向测试 | PASS | 7 个流式管线/草稿测试 + 18 项契约 | `AgentSubagentStreamingTests`、Ruby 报告 |
| 持久化/旧会话测试 | PASS | 旧字段缺失 + 流完成态 round-trip | `AgentRoundtableTests`、`RoundtableSetupAndAnalysisTests` |
| 相关回归 | PASS | 3 suites / 40 tests | 定向 `xcodebuild test` 结果 |
| 无筛选全仓回归 | Pending | — | — |
| 版本一致性 | Pending | — | — |

### 构建与 GUI

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| Release 构建 | Pending | — |
| 真模型准备室 | Pending | — |
| 真模型流式发言 | Pending | — |
| 专家选择边界 | Pending | — |
| 引用/划词引用 | Pending | — |
| 重启恢复 | Pending | — |
| Markdown 结论与保存 | Pending | — |

## 5. 未决项

- 最终实现需锁定“有部分正文时流式中断”的持久化语义；QA 按锁定结果验收。
- 若所选 Provider 无法提供正文 delta，必须在验收报告中明确标记能力降级，不能用打字动画冒充真流式。
- VoiceOver、键盘与灰阶走查若未执行，必须列为缺口，不能仅凭代码存在宣称通过。
