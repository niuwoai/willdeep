# WillDeep Goal Teams 对齐测试计划

> 目标版本：`1.189.0-rc1`
> 任务：GT-005、GT-006
> 负责人：测试-Goal Teams 流程验收
> 当前状态：第一轮测试设计已通过需求成员独立验证；Swift 实现、自动化测试编写与独立验收待后续轮次执行。

## 1. 测试目标与边界

本计划独立验证 WillDeep Goal 模式的用户可见主流程与安全语义：Goal 定义后先进行多身份、只读、基于证据的规划；汇总为 Goal-backed Plan；用户明确确认后才允许写级工具；执行未完成时自动续接；计划完成但 Goal 未完成时必须重新规划。

本轮只设计测试，不修改生产 Swift、Swift 测试、版本文件、CHANGELOG、`product-overview.md` 或其他成员文档。后续实现验证必须由本测试成员独立执行；本计划及新增测试用例由“需求分析-Goal Teams 流程契约”成员反向校验，防止测试只证明实现自己的说法。

## 2. Doc Capsule

| source | decision | must_do | must_not_do | test_refs | open_questions |
| --- | --- | --- | --- | --- | --- |
| `goal-teams/SKILL.md` | Goal Teams 必须 Plan-first、独立角色、锁定范围、独立验证 | 覆盖 Load/Plan/确认/执行/再规划闭环与验证责任 | 不以实现作者自测替代独立验收 | GT-QA-01～27 | 无 |
| `versions/1.189.0-rc1/plan.md` | 首轮三身份独立分析，评审身份仲裁，Goal-backed Plan 复用现有确认 UI | 验证默认身份、证据、分歧、门禁、确认/拒绝与失败降级 | 未确认不得执行写级工具；旧计划不得永久放行 | GT-QA-01～15 | 失败降级的精确状态以较新的 PRD 为准：0/1 份报告草案不可 proposed、不可批准执行 |
| `spec/PRD.md` / `requirement-spec-card.md` | AC-01～20 与 NFR 是测试权威基线；0/1 份报告的草案不可 proposed/不可批准执行 | 覆盖 setup 门禁、Teams 10 列、完整交付 Plan、danger-tier、保守恢复、仲裁失败恢复、长度/i18n/可访问性 | 不得把“可阅读草案”等同“可确认 Plan” | GT-QA-01～27 | 无 |
| `AgentContextBuilder.systemPrompt` | 当前 Goal 活跃提示词仍宣告写级工具自动批准；Plan 模式已有完整 Plan/Progress 契约 | 新实现必须为 Goal 加入 planning/proposed/approved-executing 阶段语义 | 不得破坏普通 Plan 模式现有提示词 | GT-QA-01、02、09、10 | 实现可抽纯策略类型，测试不得依赖整段文案逐字相等 |
| `AgentPlanParser` / `AgentPlanAutoContinuationPolicy` | 现有 `plan`、`progress` 协议和自动续接策略可复用 | Goal-backed Plan 必须走同一解析与进度状态机 | 不新增与普通 Plan 分叉的第二套解析语法 | GT-QA-03、09、10 | 无 |
| `AgentRuntime.isPlanGateActive` / `AppState.planGateBlocks` | 当前门禁仅对 `.plan` 生效；公开 URL 研究可放行，写级工具应阻断 | Goal 已定义但 Plan 未批准、被拒绝或已 done 时也要激活 | 不把 `spawn_agent` 等只读规划工具误判为写执行 | GT-QA-04～06、11、13～15 | 无 |
| `AppStateAgentSessions` | 当前捕获、确认、拒绝只接受 Plan 模式 | Goal 模式须捕获、展示、确认/拒绝 Goal-backed Plan；拒绝保留 Goal | 不得让迟到的旧回复复活已拒绝计划 | GT-QA-03、07、08 | 需要实现提供可测试的代次/来源防陈旧策略 |
| `AgentSession.init(from:)` | 新字段用 `decodeIfPresent` 保持旧会话可解码 | 覆盖无 Goal Teams 新状态的旧 JSON、新状态 round-trip 与未知状态保守恢复 | 不要求迁移用户旧 JSON；未知状态不得恢复为 executing | GT-QA-16、23 | 若新增持久化字段，必须有安全默认值 |

## 3. 权威需求—测试矩阵

| ID | 用户可见要求 / 权威证据 | 自动化测试设计与关键断言 | 目标测试位置 | 层级 |
| --- | --- | --- | --- | --- |
| GT-QA-01 | Goal 定义后先规划，不直接执行；`plan.md`“Goal 启动/执行门禁” | 构造 `.goal + currentGoal + nil plan`，断言 prompt 进入 Goal Teams planning，包含“先分析、后提案、等待确认”；不得出现“write-tier auto-approved”或等价立即执行授权 | `AgentGoalChecklistParserTests.swift` 或新增 `AgentGoalTeamsTests.swift` | Prompt 单测 |
| GT-QA-02 | 默认身份为需求、架构、测试，之后由评审仲裁；`plan.md`“默认规划身份” | 断言首轮包恰有三个角色+具体任务名，职责互异且要求仓库证据/反例/风险；仲裁包在至少两份有效报告之后生成，包含分歧、弱证据、接受/拒绝主张和 Teams 表契约；用户文本被包在惰性数据边界 | `AgentConsultationTests.swift` / `AgentGoalTeamsTests.swift` | Prompt/策略单测 |
| GT-QA-03 | Goal-backed Plan 复用现有 fenced `plan`；`plan.md`“Plan 解析” | 在 Goal runtime 注入含摘要、多行步骤的 `plan` 回复，断言 `currentGoal` 保留、`currentPlan.status == .proposed`、步骤与摘要正确；无编号步骤或错误 fence 不得造 Plan | `AgentPlanProgressTests.swift` / `AgentGoalTeamsTests.swift` | 解析/状态单测 |
| GT-QA-04 | 计划前写工具必须阻断；`plan.md`“工具门禁” | `.goal + currentGoal + nil/proposed/rejected/done plan` 下，`run_command`、`write_file`/补丁类写风险均返回 blocked；工具记录为 denied，错误明确提示先规划并确认 | `AgentWebToolsTests.swift` / `AgentGoalTeamsTests.swift` | 安全门禁单测 |
| GT-QA-05 | 规划阶段仍需只读取证与派生只读子代理；`plan.md`“子代理” | 同一门禁状态下允许文件读取/搜索、合法公开 URL `web_fetch` 与 `spawn_agent`；私网/本地 URL 和伪装成读取的 write-risk 工具仍阻断 | `AgentWebToolsTests.swift` / `AgentGoalTeamsTests.swift` | 安全边界单测 |
| GT-QA-06 | 只有 approved/executing 才解锁；done 不得永久通行；`AgentRuntime.isPlanGateActive` 注释与 `plan.md`“安全降级” | 表驱动覆盖 nil/proposed/rejected/approved/executing/done 六状态：仅 approved、executing 为 false；done + Goal 未完成必须重新 true。另测普通/Goal 模式不会互相误放行 | `AgentPlanProgressTests.swift` / `AgentGoalTeamsTests.swift` | 状态机单测 |
| GT-QA-07 | 用户确认后立即执行；`plan.md`“用户确认/确认后执行” | Goal-backed proposed Plan 点击确认后变 approved，排入一条 host instruction；忙碌时入队、空闲时派发；指令同时要求 `progress` 与 `goal-check`，且确认动作只能消费当前提案一次 | `AgentGoalTeamsTests.swift` | AppState 单测 |
| GT-QA-08 | 拒绝后重新规划，保留 Goal；`plan.md`“计划被拒绝” | 拒绝后 `currentPlan == nil`、`currentGoal` 不变、gate 激活；确认按钮无效；旧提案 ID/旧 assistant 迟到回复/旧 `progress` 块均不能复活或推进旧计划；只有拒绝后的新规划代次可产生新 proposed Plan | `AgentGoalTeamsTests.swift` | 状态/竞态负例 |
| GT-QA-09 | Goal 定义后自动衔接规划，无需用户再说“继续”；`plan.md`“自动衔接” | 捕获有效 `goal` 后恰好排入一次 planning host instruction；重复 capture 不重复排队；忙碌/空闲均使用正确队列路径；未定义或空 Goal 不触发 | `AgentGoalChecklistParserTests.swift` / `AgentGoalTeamsTests.swift` | AppState 单测 |
| GT-QA-10 | 批次执行未完成时自动续接；现有 `AgentPlanAutoContinuationPolicy` | approved/executing 且有非终态步骤时续接；排队用户输入时让路；连续两轮无进展暂停；8 轮上限暂停；terminal Plan 停止；续接 notice 不重述完成项并要求单一 progress block | `AgentPlanProgressTests.swift` | 策略单测 |
| GT-QA-11 | 执行完成但 Goal checklist 未完成时再规划；`plan.md`“done 后再规划” | 将所有 Plan step 置 terminal 但至少一个 Goal item 未完成，断言 Plan 变 done、gate 重新激活、自动排入下一轮只读规划且写工具被拒；不得继续用旧 approved 权限 | `AgentPlanProgressTests.swift` / `AgentGoalTeamsTests.swift` | 状态机/集成单测 |
| GT-QA-12 | Plan 与 Goal 均完成时正常停止 | Plan terminal 且 Goal checklist 全 done 时不再排规划、不再自动续接；最终状态可持久化并恢复 | `AgentGoalTeamsTests.swift` / `AgentSessionPersistenceTests.swift` | 状态机单测 |
| GT-QA-13 | 至少两份有效独立报告才可进入仲裁；PRD AC-04、AC-07 | 输入三份不同角色报告并打乱完成顺序，断言三者并发启动、角色映射稳定、报告只计一次且独立保存；3/3 或 2/3 有效才启动仲裁，仲裁输入包含全部有效报告 | `AgentConsultationTests.swift` / `AgentGoalTeamsTests.swift` | async/聚合策略单测 |
| GT-QA-14 | 部分失败至少两份有效报告才可综合；`plan.md`“安全降级” | 表驱动：3/3、2/3 有效允许仲裁；2/3 场景必须显式记录失败角色和证据缺口。1/3 有效不得生成正常可执行提案、不得自动确认、gate 持续激活 | `AgentGoalTeamsTests.swift` | 降级负例 |
| GT-QA-15 | 全部失败/`spawn_agent` 不可用不得静默执行；PRD AC-06、FR-08 | 0/3 或工具不可用时，用户必须看到“未完成独立辩证验证”、失败原因与重试入口；Lead 只能生成标记为不可执行的阅读草案，`currentPlan` 不得为 proposed，批准入口/确认动作必须不存在或 no-op；任何写工具、自动批准、伪造报告均失败 | `AgentGoalTeamsTests.swift` | 降级/安全负例 |
| GT-QA-16 | 旧会话兼容；PRD AC-16～18，`AgentModels.AgentSession.init(from:)` | 解码不含 Goal Teams/Plan/Goal 字段的历史 JSON，默认 `.normal`、nil/安全 planning 状态；旧 Goal 无 Plan 进入 planning；旧 approved/executing Plan 继续且不重复确认；旧 done/rejected Plan 不再授权；普通 Plan 行为不变 | `AgentSessionPersistenceTests.swift` | 持久化兼容测试 |
| GT-QA-17 | 现有 Plan、Goal、会诊能力不回归 | 保留并运行现有 Plan parser/progress/auto-continuation、Goal parser/checklist、consultation read-only/inert-section 测试；普通 Plan 的公开 URL 研究例外仍成立 | 现有四个相关 suite | 回归测试 |
| GT-QA-18 | 发布版本从 `1.188.0-rc1` 到 `1.189.0-rc1`，build 从 `20` 到 `21`；Lead 最新版本决策 | 版本一致性脚本通过；Xcode 六处 marketing/build、Go agent、Helper/Help plist、README/概览/扩展/版本文档一致；CHANGELOG 最新段为 1.189.0-rc1；不得残留本次应更新位置的 1.188.0-rc1/20 | 发布文件与 Ruby 报告 | 发布验收 |
| GT-QA-19 | Goal 尚未形成时同样禁止写；PRD AC-01、FR-01 | 构造 `.goal + currentGoal == nil/empty` 的 setup 状态，参数化请求命令、文件写入与外部状态变更，全部 denied；读取、搜索与澄清仍允许；不得因“Goal 还没定义”落回普通自动批准路径 | `AgentGoalTeamsTests.swift` / `AgentWebToolsTests.swift` | setup 门禁单测 |
| GT-QA-20 | Teams 表必须完整包含 10 列；PRD AC-10、FR-04 | 用结构解析器检查列集合严格包含 Member、Skill/Subagent、Goal Slice、Claimed Tasks、Locked Scope、Deliverable、Done Criteria、Docs/Tasklist Updates、Test Owner、Validator；每行非空、Member 为“角色-具体任务”，Test Owner/Validator 可定位且作者与 Validator 不同；另测缺任一列、空 owner/scope、纯角色名均不能产出可确认结果 | `AgentGoalTeamsTests.swift` | 结构解析单测 |
| GT-QA-21 | Plan 是完整交付合同；PRD AC-11、FR-05 | 仲裁成功后解析 numbered Plan，断言实现、测试、文档、版本、验收五类均有步骤或明确 N/A，且每步关联 member/task ID/产物；只含样例、第一阶段、缺版本或缺验收的 Plan 不得进入 proposed | `AgentPlanProgressTests.swift` / `AgentGoalTeamsTests.swift` | Plan parser 集成测试 |
| GT-QA-22 | approved Goal Plan 不覆盖 danger-tier 逐次确认；PRD AC-19、NFR-01 | `.goal + approved/executing Plan` 下普通计划内 write-risk 可走既有授权，但 mass deletion、force push、提权等 danger-tier 每一次仍进入用户确认；一次批准不得缓存为第二次 danger 操作授权，拒绝后工具不执行 | `AgentGoalTeamsTests.swift` / 现有权限测试 suite | 权限回归测试 |
| GT-QA-23 | 重启恢复不扩大权限；PRD AC-20、NFR-02 | round-trip 保留阶段、成员状态/错误、报告有效性与 Plan；fixture 包含未知阶段、缺失字段、矛盾组合（如 executing 无有效 Plan）、损坏成员状态时，恢复结果只能 planning/blocked 且 gate 激活，绝不能猜成 approved/executing | `AgentSessionPersistenceTests.swift` / `AgentGoalTeamsTests.swift` | 编解码/恢复负例 |
| GT-QA-24 | 外部输出有长度边界且按惰性数据处理；PRD NFR-01、AC-09 | 对 `limit-1`、`limit`、`limit+1`、超长多报告与 Unicode 边界做表驱动；输出稳定截断且总 packet 不越界，截断内容不能逃逸 inert section；注入指令不触发工具，伪敏感 token 不进入用户报告、日志或持久化摘要 | `AgentConsultationTests.swift` / `AgentGoalTeamsTests.swift` | 安全/边界单测 |
| GT-QA-25 | 新增用户可见文本必须 i18n；PRD NFR-04 与仓库规则 | 对 planning/blocked/失败原因/重试/批准拒绝等新增文案检查 L10n key 与 `Localizable.xcstrings` 至少中英文值；SwiftUI/生产 Swift 不得出现新增硬编码用户文本；缺 key、空翻译或直接字符串断言失败 | 新增本地化契约测试或 Ruby 静态检查 + 相关 Swift suite | i18n 契约测试 |
| GT-QA-26 | 阶段、失败、确认状态不能只靠颜色表达；PRD NFR-04 | 对 planning/proposed/blocked/failed/approved 状态断言同时具有文字或图标语义、可访问性 label/value/identifier；灰阶/关闭颜色差异时仍能区分；键盘/VoiceOver 可定位批准、拒绝、重试，不能只有色块变化 | 相关 UI/可访问性测试 + 人工 VoiceOver 复核 | 可访问性验收 |
| GT-QA-27 | 仲裁失败或空输出必须可恢复且不可 proposed；PRD AC-08、FR-08 | 在已有 2/3 与 3/3 有效首轮报告时，让 fake 仲裁器分别抛错、超时、返回空白/纯错误文本；断言全部首轮报告及角色映射原样保留、状态为 blocked/planning、gate 激活、无 proposed Plan/批准入口；点击重试只重跑仲裁，不重跑或伪造首轮报告，成功后才允许综合 | `AgentGoalTeamsTests.swift` | 仲裁恢复集成测试 |

## 4. 必测负例与判定

| 负例 | 操作 | 必须观察到 | 一票否决 |
| --- | --- | --- | --- |
| 计划前写工具 | Goal 已定义、尚无 approved Plan，模型直接调用写工具 | 工具 denied；Plan/Goal 状态未被写调用改变；提示回到规划与确认 | 写调用真正执行或被自动批准 |
| Goal 尚未形成时写工具 | setup 状态、`currentGoal` 为 nil/empty，模型直接调用写工具 | 工具 denied；只读澄清仍可用；状态保持 setup | 因 Goal 为空而绕过门禁 |
| 一个子代理失败 | 两份有效、一个失败 | 可仲裁，但显式展示失败身份、证据缺口和剩余风险 | 悄悄伪装成 3/3 成功 |
| 两个子代理失败 | 仅一份有效 | 停在 planning；不产生正常可执行提案；gate 保持 | 继续综合并自动执行 |
| 全部子代理失败/不可用 | 无有效独立报告 | 明示“未完成独立辩证验证”；最多产生不可执行、不可 proposed、无批准入口的阅读草案；禁止任何自动执行 | 草案进入 proposed、可确认或静默降级成单代理写入 |
| 拒绝后旧计划 | 拒绝后旧 turn 迟到返回 `plan`/`progress`，或再次点旧确认入口 | 旧计划不复活、不获批、不推进；Goal 保留并进入新代次 | 旧计划获得 approved/executing |
| done 计划永久通行证 | 上一计划 done，Goal checklist 仍有未完成项，随后请求写工具 | gate 再次激活并启动新规划 | done 仍解锁写工具 |
| approved 下危险操作 | 当前 Goal Plan 已 approved，连续请求两次 danger-tier 操作 | 两次分别要求用户确认；首个决定不复用 | Plan 批准或一次确认永久放行 danger-tier |
| 恢复状态未知 | 重启载入未知/矛盾状态或缺关键字段 | 收紧为 planning/blocked，gate 激活并展示恢复原因 | 猜测为 executing 或放行写工具 |
| 仲裁失败或空输出 | 至少两份有效首轮报告已保存，fake 仲裁抛错/超时/空白 | 保留首轮证据，gate 保持，无批准入口；重试只重跑仲裁 | 丢失首轮报告、进入 proposed 或伪造报告 |

## 5. 最小定向验证命令

实现成员交付并由测试成员独立审查后，先跑最小集合：

```bash
scripts/run_tests.sh \
  -only-testing:XeditTests/AgentGoalTeamsTests \
  -only-testing:XeditTests/AgentPlanProgressTests \
  -only-testing:XeditTests/AgentGoalChecklistParserTests \
  -only-testing:XeditTests/AgentSessionPersistenceTests \
  -only-testing:XeditTests/AgentWebToolsTests
```

说明：`AgentConsultationTests.swift` 中的现有会诊回归由第 6 节全量 `scripts/run_tests.sh` 覆盖，定向命令不使用文件名或并不存在的 suite 名作为 `-only-testing` 标识。若实现没有新增 `AgentGoalTeamsTests`，必须把上述 GT-QA 用例分配到现有 suite，并从命令中删除不存在的 suite；不得为了命令好看保留空壳测试。

版本/构建号定向检查：

```bash
ruby scripts/version_consistency.rb build/ci/version_report.md build/ci/version_report.json
rg -n 'MARKETING_VERSION = "1.189.0-rc1"|CURRENT_PROJECT_VERSION = 21' Xedit.xcodeproj/project.pbxproj
rg -n '1.189.0-rc1|<string>21</string>' ComputerUseHelper/Info.plist Help/WillDeep.help/Contents/Info.plist willdeep-agent/internal/agent/version.go README.md product-overview.md chrome-extension/willdeep-browser/manifest.json chrome-extension/willdeep-browser/README.md
```

## 6. 较宽回归与构建命令

定向测试通过后执行完整回归；`scripts/run_tests.sh` 会生成 `build/ci/report.md` 与 `build/ci/report.json`：

```bash
scripts/run_tests.sh
```

随后执行无签名 macOS 构建：

```bash
xcodebuild build \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -derivedDataPath build/ci/DerivedData-build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

通过标准：命令退出码为 0；定向 suite 无失败；全量报告 JSON 中失败数为 0；构建产出 `WillDeep.app`；版本报告所有检查一致。若本机测试启动被 `testmanagerd`、签名或沙箱阻断，必须记录环境错误原文与构建结果，不能把“编译通过”冒充“测试通过”。

## 7. 证据位置

| 证据 | 位置 / 符号 | 后续验收用途 |
| --- | --- | --- |
| 需求与非功能基线 | `.codex/goal-teams/versions/1.189.0-rc1/spec/PRD.md` 的 FR-01～09、NFR-01～04、AC-01～20；`requirement-spec-card.md` | GT-QA-01～27 的最终权威源 |
| 产品主流程、安全降级、默认身份 | `.codex/goal-teams/versions/1.189.0-rc1/plan.md` 的“只读差异结论”“只读落点审计”“默认规划身份”“安全降级” | 所有 GT-QA 的需求源 |
| 任务与独立验证责任 | `.codex/goal-teams/versions/1.189.0-rc1/tasklist.md` 的 GT-005、GT-006、GT-007 | 完成状态与交叉验证 |
| Goal/Plan prompt | `Xedit/AgentContextBuilder.swift`：`systemPrompt` | GT-QA-01、02、07、09、11 |
| Plan 解析/进度/自动续接 | `Xedit/AgentContextBuilder.swift`：`AgentPlanParser`、`AgentPlanAutoContinuationPolicy` | GT-QA-03、10、11 |
| 门禁状态 | `Xedit/AgentRuntime.swift`：`isPlanGateActive` | GT-QA-04、06、11 |
| 工具调用阻断 | `Xedit/AppStateAgentLoop.swift`：`planGateBlocks` 调用与 `spawn_agent` 分支 | GT-QA-04、05、14、15 |
| 捕获、确认、拒绝 | `Xedit/AppStateAgentSessions.swift`：`captureAgentPlanFromLatestMessage`、`confirmAgentPlanAndExecute`、`rejectAgentPlan` | GT-QA-03、07、08、09 |
| 旧会话默认值 | `Xedit/AgentModels.swift`：`AgentSession.init(from:)` | GT-QA-16 |
| 现有回归基线 | `XeditTests/AgentPlanProgressTests.swift`、`AgentGoalChecklistParserTests.swift`、`AgentConsultationTests.swift`、`AgentWebToolsTests.swift`、`AgentSessionPersistenceTests.swift` | GT-QA-10、16、17 |
| 版本一致性报告 | `scripts/version_consistency.rb`、`build/ci/version_report.md`、`build/ci/version_report.json` | GT-QA-18 |
| 自动化执行报告 | `build/ci/report.md`、`build/ci/report.json`、`build/ci/XeditTests.xcresult`、`build/ci/xcodebuild.log` | 最终验收证据 |

## 8. 独立验证与反向校验

1. 开发成员提交实现后，本测试成员先审查 diff，逐项映射 GT-QA-01～27；不得只接受开发成员的通过声明。
2. 本测试成员编写/补充 Swift 测试并执行最小定向测试、全量回归、无签名构建和版本一致性检查。
3. “需求分析-Goal Teams 流程契约”成员反向审查测试用例：每条断言是否来自 PRD/Requirement Specification Card，是否遗漏用户可见要求，是否存在只测内部实现而不测行为的情况。
4. Goal Lead 复核测试报告、失败说明、版本/build 证据，并决定 GT-005、GT-006、GT-007 是否可标 done。

## 9. 风险与停止条件

| 风险 | 影响 | 控制措施 / 停止条件 |
| --- | --- | --- |
| Goal/Plan 双状态竞态 | 拒绝后旧回复复活，或不同 turn 错批计划 | 必须有计划代次/来源一致性断言；无法区分新旧回复时停止验收 |
| 为便于测试而复制状态机 | 测试通过但真实工具环路未受保护 | 优先抽纯策略供生产和测试共用；至少保留一条 AppState/工具环路集成断言 |
| Prompt 测试过度逐字匹配 | 合法文案调整造成脆弱失败 | 匹配稳定语义锚点、角色标识、阶段和禁止项，不比较整段字符串 |
| 子代理失败表示不统一 | 聚合器误把空白/错误文本算有效报告 | 对空白、超时、tool error、重复报告做表驱动有效性测试 |
| 自动续接形成循环 | 无进展仍消耗请求 | 保留“连续两轮无进展”和“8 轮上限”，并验证排队用户消息优先 |
| 旧会话新增字段缺默认值 | 历史会话无法打开 | 任何新增 Codable 字段必须 `decodeIfPresent` 或自定义安全默认值 |
| 并行成员修改同一测试文件 | 覆盖用户或成员改动 | 实施前重新读取目标测试文件与 `git diff`；冲突时交由 Goal Lead 协调，不擅自回滚 |
| 测试运行环境受限 | 无法获得真实执行证据 | 保留原始日志与环境阻塞说明；构建通过不能替代测试通过 |

停止验收条件：任一未确认写级工具可执行；少于两份有效报告仍自动形成并执行正常计划；拒绝后的旧计划可获批；done 计划在 Goal 未完成时继续放行；旧会话解码失败；版本或 build 未统一到 `1.189.0-rc1` / `21`。

## 10. 完成状态

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 第一轮测试设计 | done | 本文 GT-QA-01～27、负例矩阵、命令与风险 |
| 需求成员独立验证测试设计 | passed | GT-QA-01～27 覆盖 PRD AC-01～20；validator 最终结论为通过 |
| Swift 生产实现独立审查 | passed | QA 审查生产 diff 并修复门禁、代次、恢复与重试问题 |
| Swift 测试编写/补充 | done | `AgentGoalTeamsTests` 共 25 项 |
| 最小定向测试 | passed | Goal Teams 25/25 |
| 相关回归与无签名构建 | passed | 相关五 suite 78/78；`WillDeep.app` BUILD SUCCEEDED |
| 无筛选全仓回归 | passed | 1309/1309 Swift Testing；报告合计 1316/1316；子进程超时在全负载下通过 |
| 版本 `1.188.0-rc1 → 1.189.0-rc1`、build `20 → 21` | passed | 11 个版本源一致 |
| 需求成员反向校验测试用例 | passed | 独立直跑 25/25，无生产级 veto |

结论：GT-005、GT-006 已完成；自动化、构建、版本与独立反向校验证据见 `acceptance.md`。
