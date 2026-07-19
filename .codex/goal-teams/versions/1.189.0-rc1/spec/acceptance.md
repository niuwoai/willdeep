# WillDeep Goal Teams 独立验收

> 验收日期：2026-07-19
> 目标版本：`1.189.0-rc1` / build `21`
> 验收任务：GT-005、GT-006
> 结论：**核心流程、安全语义、版本、发布文档与无筛选全仓回归全部通过。**

## 1. 验收结论

Goal Teams 的受控三成员规划、2/3 降级仲裁、少于两份报告时安全阻断、Goal-backed Plan 显式确认、拒绝/修订换代、执行后 Goal 自检、会话保守恢复及 danger-tier 门禁均已有自动化证据。独立审查发现的权限、竞态、恢复和重试缺陷均已修复，最终定向与相关回归无失败。

GT-007 的集成、版本与文档签收已完成。真实模型/真实网络的端到端三成员规划与 VoiceOver 人工走查未在本轮执行，不能写成已验证。

## 2. 发现并修复的问题

| 优先级 | 问题 | 修复与验证 |
| --- | --- | --- |
| P0 | planning gate 的公开 `web_fetch` 例外可能让 danger 风险绕过门禁 | 例外仅允许 `.write` 级合法公开抓取，danger 始终阻断；生产门禁与连续 danger 反例通过 |
| P1 | 拒绝/修订换代未可靠取消旧 run，旧三成员会占满并发槽并可能迟到污染新代次 | 同步取消旧代次、释放槽位、按 generation/run ID 丢弃迟到结果；竞态测试通过 |
| P1 | 新代次可能捕获旧 synthesis 的 Plan | synthesis 带不可见 generation marker，捕获时严格匹配；陈旧提案反例通过 |
| P1 | 恢复 `readyForProposal`、未知/损坏 ledger 或 Plan/phase/Goal 指纹矛盾时可能静默卡住或保留写权限 | 一律收紧为 blocked；矛盾 approved/executing Plan 清空；旧合法 proposed ledger 可安全恢复 |
| P1 | 仲裁失败后的 Retry 重跑三名首轮成员，破坏已有独立证据 | 有至少两份有效报告时只重跑仲裁并保留首轮报告；反向校验通过 |
| P1 | Teams 表分隔行可被误当成数据行 | 必须存在合法 Markdown separator 与恰好十列的真实数据行；缺行/坏分隔负例通过 |
| P2 | blocked/成员失败缺少用户可见状态与重试入口 | 新增 Goal Planning 卡片、阶段/成员/仲裁文字与图标、Retry，并补中英文资源 |

## 3. 自动化与构建证据

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| Goal Teams 最终直跑 | 25/25 passed | `build/ci/GoalTeamsFinal25.xcresult` |
| 相关五个 suite | 78/78 passed | `build/ci/report.md`、`build/ci/report.json`、`build/ci/XeditTests.xcresult` |
| 无筛选全仓回归 | 1309/1309 passed；报告合计 1316/1316 | `build/ci/report.md`、`build/ci/report.json`、`build/ci/XeditTests.xcresult` |
| 子进程超时定向与全负载回归 | 2/2 passed，且无筛选全仓通过 | `build/ci/AgentSubprocessRerun.xcresult`、`build/ci/XeditTests.xcresult` |
| 无签名 macOS 构建 | `BUILD SUCCEEDED`，产出 `WillDeep.app` | `build/ci/DerivedData-goal-teams-build/Build/Products/Debug/WillDeep.app` |
| 版本一致性 | PASS，11 个来源一致为 `1.189.0-rc1` | `build/ci/version_report.md`、`build/ci/version_report.json` |
| 构建号 | Xcode 六处与构建产物均为 `21` | `Xedit.xcodeproj/project.pbxproj`、构建产物 Info.plist |
| 复杂度守卫 | PASS，hard limit 0 | `build/ci/complexity_report.md`、`build/ci/complexity_report.json` |
| 差异格式 | `git diff --check` 通过 | 本轮命令记录 |

测试执行过程中曾有两类真实失败，并均保留在验收事实中：首轮恢复期望与新的保守恢复语义不一致；需求成员新增反向校验后暴露 Retry 重跑首轮的生产缺陷。前者修正 fixture，后者修生产逻辑；JSON 报告比较也改为解码后的语义比较，避免字段顺序导致假阴性。

## 4. 覆盖映射

| 状态 | GT-QA | 说明 |
| --- | --- | --- |
| 自动化通过 | 01～23、27 | Prompt、三成员编排、Plan 捕获/确认/拒绝、门禁、降级、竞态、恢复、普通 Plan 回归、danger、仲裁恢复均有断言 |
| 代码审查 + 构建通过 | 25 | 新增可见文案由 `L10n+GoalPlanning.swift` 与 `Localizable.xcstrings` 提供中英文资源 |
| 部分验证 | 24 | 生产路径已统一 sanitize 并设定报告/packet 长度上限；本轮未补齐 `limit-1/limit/limit+1`、Unicode 边界的完整参数化测试 |
| 人工验证待办 | 26 | 卡片状态同时使用文字与图标，Retry 为原生 Button；未执行 VoiceOver、键盘导航与灰阶人工验收 |

## 5. 未执行与剩余风险

- 已运行无筛选的 `scripts/run_tests.sh`。发布整理阶段同步了并行“已安排”页面的陈旧语义断言，并修复高负载下子进程超时调度饥饿；最终 1309/1309 Swift Testing 与报告合计 1316/1316 全部通过。
- 未使用真实远端模型和真实网络跑三成员端到端流程。Fake runner 已覆盖并发、失败、空输出、重试和迟到竞态，但无法证明特定模型始终遵循结构化输出。
- 未执行 VoiceOver/键盘/灰阶人工验收，也未完成外部输出长度的完整 Unicode 边界矩阵。
- 发布整理阶段将并行既有功能改动统一纳入 `1.189.0-rc1`；明显生成垃圾未纳入提交。

上述剩余项不改变“Goal Teams 核心流程、安全语义与发布门禁通过”的结论；它们作为后续验收债务保留。
