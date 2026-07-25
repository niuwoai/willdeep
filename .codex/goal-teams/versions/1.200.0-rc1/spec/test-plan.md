# Test Plan：专家圆桌准备室与真流式发言

> 目标版本：1.200.0-rc1  
> 状态：自动化定向验收已通过；Release 真模型 GUI 待执行  
> 初稿 Owner：产品-议题准备流程规格  
> 最终 Test Owner：测试-圆桌流程独立验收

## 1. 测试目标

证明新圆桌在用户确认前不会开会，准备建议与阵容选择满足约束，专家正文是真实流式而非半截 JSON/伪动画，错误与恢复不会重复消息或扩大状态，并且旧会话和结论文档路径不回归。

## 2. 分层策略

| 层级 | 重点 | 建议证据 |
| --- | --- | --- |
| 纯模型/策略单测 | payload 校验、人数约束、revision、兼容解码、草稿状态机 | Swift Testing |
| 引擎 fake 集成 | 明确门禁、delta、OSR 二阶段、取消、迟到结果、幂等 | fake runner / fake stream |
| AppState/路由集成 | 新建、持久化、历史恢复、开始驱动、错误重试 | AppState fixture tests |
| UI/契约测试 | 三行输入、按钮禁用原因、专家卡、立场非颜色语义、引用 | SwiftUI/静态契约 |
| Release GUI | 真实模型端到端、首字延迟、滚动输入、保存文档 | 截图/录屏 + Markdown/JSON 报告 |

## 3. 核心测试矩阵

| ID | 覆盖 | 操作 / Fixture | 必须断言 |
| --- | --- | --- | --- |
| RT-QA-01 | AC-01 | 新建非空议题 | phase 为 clarifying；已持久化；未调用 opening/expert runner。 |
| RT-QA-02 | AC-01 | 空白议题、输入法候选确认 | 不创建会话；不误提交。 |
| RT-QA-03 | AC-02 | 合法准备 payload | 原始议题不变；3～5 框架、1～3 问题、3～4 推荐及理由完整。 |
| RT-QA-04 | AC-02/12 | payload 缺字段、未知角色、超量数组 | 有效部分保留，越界截断/拒绝有确定策略；不自动开会。 |
| RT-QA-05 | AC-03 | 用户补充后旧响应迟到 | 新 revision 胜出，旧响应不覆盖；用户消息不丢。 |
| RT-QA-06 | AC-03/04 | 快捷答案、自由补充、返回修改 | 更新建议稿；原始议题保留；开始确认失效。 |
| RT-QA-07 | AC-05 | 专家枚举/资源/i18n | 新增 4 类唯一 raw value、头像与文案；旧 6 类 fixture 可解码。 |
| RT-QA-08 | AC-06 | 依次选择 0、1、2、6、7 位 | 0/1 禁止；2～6 允许；第 7 位被业务层和 UI 阻止。 |
| RT-QA-09 | AC-06 | 重复 role / 推荐刷新 | 去重；用户手选不被静默删除；计数准确。 |
| RT-QA-10 | AC-07 | Enter、双击卡片、恢复选人页 | 均不启动；只有显式 confirmStart 进入 opening。 |
| RT-QA-11 | AC-07 | 使用过期 frameworkRevision 确认 | 开始失败并留在选人页；提示重新确认。 |
| RT-QA-12 | AC-08 | fake stream 输出 4 个 delta | 至少观察多个草稿更新；顺序拼接正确；仅一位 activeExpert。 |
| RT-QA-13 | AC-08/09 | 正文完成 + OSR 成功 | 草稿原子变正式消息；OSR 在正文完成后调用并绑定同一消息。 |
| RT-QA-14 | AC-09 | 正文成功 + OSR 抛错/超时/空结果 | 正文仍为正式消息；立场待定；可继续/重试分析。 |
| RT-QA-15 | AC-12/13 | delta 后取消，迟到 finish/OSR | 活跃任务清理；迟到事件丢弃；不产生重复正式消息。 |
| RT-QA-16 | AC-12/13 | 流式中断：零字 / 有部分正文 | 零字清空；部分正文按已选策略保留；重试使用稳定 message ID 幂等。 |
| RT-QA-17 | AC-10 | 看板在未发言/发言中/分析中/四种立场 | 每种都有文字与图标；未完成不提前推测立场。 |
| RT-QA-18 | AC-11 | 整条引用、划词引用、删除引用后发送 | speaker、excerpt、isSelection 正确；用户文本不丢；round-trip 一致。 |
| RT-QA-19 | AC-11 | 专家追问快捷答案 + 自由输入 | 均能恢复讨论且只续跑一次。 |
| RT-QA-20 | AC-12 | 准备/推荐/启动分别失败 | 保留安全状态和输入；重试目标准确；不重复会话或越过门禁。 |
| RT-QA-21 | AC-13 | 应用在 clarifying/selectingExperts 重启 | 路由恢复正确；不自动发请求/不自动开始；选择和消息保留。 |
| RT-QA-22 | AC-13 | 应用在 speaking/analyzing 重启 | 按保守策略显示中断/待定；不重复正式消息。 |
| RT-QA-23 | AC-14 | 不含新增字段的旧报告 fixture | 解码成功；opening/discussing/awaitingUser/completed 路由不倒退。 |
| RT-QA-24 | AC-14 | 最终文档生成/保存失败 | Markdown 正常渲染；成功有路径；失败有明确提示且可复制/导出。 |
| RT-QA-25 | AC-15 | i18n/可访问性静态与 UI 检查 | 新文案中英文齐全；按钮/专家/立场有 label/value；无纯色状态。 |
| RT-QA-26 | NFR-02 | 长正文高频 delta | UI 节流；无逐 token 同步写盘；输入和滚动无明显卡顿。 |

## 4. 必测负例

| 负例 | 一票否决 |
| --- | --- |
| 创建报告后仍立即运行 `driveRoundtable` | 用户未确认即出现开场或专家请求。 |
| 只有 1 位或 7 位专家仍能开始 | UI 禁用但业务入口可绕过也算失败。 |
| 用 tool-call 半截 JSON 作为发言 | 正文出现转义符、字段名或解析抖动。 |
| OSR 失败导致正文消失 | 用户已经看到的内容被删除或回滚。 |
| 取消后迟到事件追加消息 | 产生幽灵发言或重复消息。 |
| 重启选人页自动开始 | 恢复行为扩大用户授权。 |
| 旧会话解码失败或强制进入准备室 | 兼容性回归。 |
| 每 token 落盘 | 出现写盘风暴、主线程卡顿或明显输入延迟。 |
| 支持/反对只靠红绿颜色 | 灰阶或辅助功能无法辨认。 |

## 5. Release GUI 场景

使用真实可用模型和 Release 构建完成：

1. 输入“35 岁转行 AI 工程师，靠谱吗？”并按 Enter。
2. 观察先进入准备室；补充“已有 8 年后端经验，可接受 6 个月无收入”。
3. 检查精炼问题、框架与推荐理由随补充更新。
4. 接受框架；在推荐阵容基础上增加法律合规、移除一位，再确认 2～6 人约束。
5. 点击明确开始按钮，观察首位专家正文出现多个真实增量。
6. 在专家正文中划选一段引用并作为主持人发言。
7. 模拟或触发一次 OSR 分析失败，确认正文保留、看板显示待定。
8. 在选人阶段和讨论阶段分别重启一次，验证恢复不自动越过门禁、不重复消息。
9. 收敛后打开结论文档，确认 Markdown 渲染与保存/导出状态。

记录：

- 构建版本与模型/Provider（不得记录 token）。
- 每个阶段截图或录屏时间点。
- 首个可见 delta 与正文完成的大致时间。
- JSON 报告：用例 ID、结果、证据路径、错误。
- Markdown 报告：可读结论、缺口、剩余风险。

## 6. 停止验收条件

- 任一未确认路径进入 `opening/discussing`。
- 人数约束可被非 UI 调用绕过。
- 流式方案仍需等待完整结构化 JSON 才展示。
- 正文成功后因 OSR 失败而丢失。
- 取消、重试或恢复产生重复消息。
- 旧圆桌无法打开。

## 7. 独立 QA 执行记录

| 验证 | 结果 | 覆盖 | 证据 |
| --- | --- | --- | --- |
| Swift 定向测试 | PASS | 3 suites / 40 tests | `/tmp/xedit-roundtable-qa/Logs/Test/Test-Xedit-2026.07.25_02-05-07-+0800.xcresult` |
| Ruby 交互契约 | PASS | 18 / 18 checks | `build/roundtable_interaction_contract/report.md`、`report.json` |
| Swift 语法检查 | PASS | 3 个圆桌测试文件 | `swiftc -parse` |

定向命令：

```shell
xcodebuild -project Xedit.xcodeproj -scheme Xedit -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/xedit-roundtable-qa \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:XeditTests/AgentRoundtableTests \
  -only-testing:XeditTests/RoundtableSetupAndAnalysisTests \
  -only-testing:XeditTests/AgentSubagentStreamingTests test
```

自动化已覆盖的关键不变量：

- 旧报告缺少 `preparation`、`activeExpertDraft`、`activeExpertDraftIsComplete` 时仍可解码。
- 准备 payload 去重、清洗和 2～6 人模型边界；业务入口仅允许 `selectingExperts` 且拒绝第 7 位。
- provider 正文与 reasoning 分离；reasoning-only 响应拒绝；provider 错误和取消原样传播。
- 草稿首 token 立即呈现，80ms UI 刷新、1 秒检查点，finish 强制落盘，reset 清空中断草稿。
- 第二阶段分析绑定原始可见正文，不改写；分析失败路径保留正文并降级待定。
- 十位专家身份、头像资源和中英文 i18n，以及三行输入、引用、态势语义和文本布局循环由源码契约锁定。

## 8. 尚待主线验收

- Release 真实模型端到端：准备室、推荐理由、专家增删、多个真实 delta、分析态与 Markdown 保存。
- 重启恢复、迟到 provider 事件和 OSR 故障注入仍需 GUI/集成证据；当前证据为状态模型单测与源码契约。
- VoiceOver、键盘全路径与灰阶走查尚未执行。
