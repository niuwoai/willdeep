# 上下文压缩增量复用验证

- 日期：2026-11-16
- 源码版本：1.428.0-rc4，Build 947
- 基线：`cc42b0ac83976d07230737f9f727db95261f7761`（develop）
- 工作分支：`refs/heads/fix/context-compression-reuse`
- 状态：Mac 修复及相关回归验证完成。最终九组原生套件 107 项全部通过，0 失败、0 跳过，退出码 0；原始日志、xcresult 报告与脚本退出码一致。

## 行为与边界

Worker 的重建 transcript 是旧摘要的唯一来源；移除旁路的 `priorSummary` 和 `lastCompressionSummary`，后续摘要输入不再重复加入同一摘要。保留 system、原始任务、最近完整工具批次；摘要分段保留工具调用 ID、名称、参数及对应结果。模型摘要中的闭合标签被转义，普通用户正文不会因包含摘要标签而被删除。

主会话普通自动压缩与升档优化在有效摘要已覆盖全部待压消息时跳过。计划生成和执行前均检查；未执行摘要请求时不安装新摘要。手动压缩、发送前容量硬闸、Provider 溢出恢复及 runway 恢复允许继续缩短已有摘要。无效 checkpoint 使用完整原文重建，保留原有覆盖边界。

本次没有改变分块预算、并发上限、摘要模型选择或实际网络重试策略。修复不能直接证明客户的具体等待原因，也没有对客户现场耗时作测量。

## 回归范围

- `AgentWorkerCompressionTests`：生产 plan → rebuild → 新工具批次 → plan → rebuild；旧摘要恰好一次，旧原文不回传，新证据和多工具参数/结果保留；用户正文包含摘要标签仍保留；摘要正文闭合标签转义后仅有一个宿主闭合标签。
- `AgentCompressionReuseTests`：首次与真实增量、自动空增量的触发及执行端跳过、晚到计划省略旧摘要参数时仍复用、持久摘要不被覆盖、stale checkpoint 重建（含 3/6 条短会话）、手动/发送硬闸/overflow/runway 继续重压、排队消息消费后正常回复、真实回合完成入口触发 runway 压缩及正常回复后只续跑一次、真实 Goal 唤醒入口无增量重压。fixture 构造及执行均以 task-local defaults 隔离。
- 既有套件：`AgentContextCheckpointTests`、`AgentInTurnCompressionTests`、`AgentPreSendContextGateTests`、`AgentContextCompressionSplitTests`、`AgentGoalCompressionRetryTests`、`AgentGoalMainLoopTests`、`AgentGoalOvernightResilienceTests`。

Worker 回归直接使用生产 plan/rebuild 和分段函数，尚未通过完整 Worker runner 的请求桩连续发送两次压缩。模型输入通过生产函数及摘要操作回调核对；未调用真实模型。

## 原生执行记录

首次构建通过，Swift Testing 实际执行 104 个测试、9 个套件；最终退出码为 65，出现 4 处 issue。全部 issue 来自新增参数化用例 `explicitReclamationCanShortenAnExistingSummary(reason:)`：预期原始摘要带末尾空格，而生产安装逻辑已去掉首尾空白。

回归已改为先断言安装后的摘要等于规范化输入，再检查第二次摘要请求确实包含这份已安装摘要。没有修改生产逻辑来迁就断言。相同 9 组原生套件重跑通过：104 项、0 失败、0 跳过，退出码 0，原始日志为 `Test run with 104 tests in 9 suites passed`，报告统计一致。脚本总耗时 210.44 秒，测试执行耗时 34.337 秒。

随后补充摘要正文闭合标签、3/6 条短会话失效 checkpoint、Goal 唤醒入口无增量重压的回归；队列与 runway 回归现以任务局部 defaults 隔离构造和执行，正常回合收尾的 runway 用例经过真实 provider 回复及回合完成入口。

补充后的运行实际执行 107 项、9 个套件：105 通过、2 失败、0 跳过，退出 65；日志与报告一致。新增闭合标签、短会话及 Goal 唤醒用例通过，失败集中在改成正常回复的两例：队列用例观测到 3 次 HTTP 请求（预期 1），runway 用例观测到 6 次（预期 2）且摘要输入为 4 段（预期仅旧摘要 1 段）。摘要调用次数及恢复次数没有额外增加。独立诊断与源码核对确认，复用的 Goal 夹具仍保留 `currentPlan.status = .executing`，普通模式回复会触发 `AgentPlanAutoContinuationPolicy` 的执行补问及进度核对，增加同回合 HTTP 请求和进入摘要的消息。两项普通模式回归在执行前将 `currentPlan` 清为 nil，生产代码及严格次数/分段断言未改。修正后压缩复用套件实际 9 项全部通过，退出码 0。

最终使用上述已构建且源码指纹匹配的测试产物，经 `--without-building` 复验全部九组套件：**107 项全部通过，0 失败、0 跳过，退出码 0**。原始日志为 `Test run with 107 tests in 9 suites passed` / `TEST EXECUTE SUCCEEDED`，report.json 的 xcresult 统计及日志统计均为 107/107，`total_mismatch=false`。脚本总耗时 33.52 秒，测试执行耗时 31.593 秒；不是新的完整 App 编译耗时。

执行入口为 `scripts/run_tests_fast.rb`，明确选择上述 9 个 suite。通过 `WILLDEEP_BUILD_ENV_FILE=/dev/null` 及空构建凭据环境运行，使用本地测试桩；未安装或发布 App。

报告位于本工作树：

- `build/fast-tests/report.json`
- `build/fast-tests/report.md`
- `build/fast-tests/xcodebuild.log`

## 独立复核与静态检查

- 压缩行为独立只读复核已完成，未报告可确认缺陷。
- 恢复与回归的首轮独立复核因上下文过长失败；缩小阅读范围后的重审已完成，未发现可确认的生产缺陷。
- 恢复审查指出的真实触发入口、正常回复收尾及偏好隔离覆盖已补充；新增测试的定向只读复核已完成。原生执行发现两项夹具遗留计划问题，独立诊断与主会话源码复查定位后，仅修正 fixture；随后定向及九组回归均通过。静态复核没有替代执行结果。
- 版本一致性检查通过，所有登记位点为 `1.428.0-rc4`。
- 空凭据构建配置契约检查 2 项通过。
- `git diff --check` 通过。

提交前只读复核（2026-11-16）：当前源码、未跟踪的新测试文件、工程配置及工具链共 10 项指纹字段与已测试的构建记录一致，保存的指纹内部校验通过；原始测试日志与报告仍为九组 107/107 通过、0 跳过、退出码 0。未探测本地凭据文件。此次复核没有重跑测试，也没有更改生产代码或测试代码。

两端修复在各自工作分支验证；Rust 专项结果由独立 willdeep-cli 会话提供。本记录在 Mac 提交前形成，后续提交状态以 Git 记录为准。此次操作只获准提交 Mac 压缩修复，未执行合并、推送、打 tag、安装或发布。
