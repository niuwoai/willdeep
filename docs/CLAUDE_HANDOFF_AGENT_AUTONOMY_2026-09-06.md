# Claude Code 接手：Agent 自主执行优化

> 2026-09-06。用户因 Token 预算要求阶段收口并交接。先读本文件，不要重新全面审计一遍，也不要把未测试的 rc15 当作已完成。

## 1. 从哪里继续

- **工作目录**：`/Users/rocky/Sites/Xedit/.codex/worktrees/agent-autonomy-recovery`
- **分支**：`codex/agent-autonomy-recovery`
- **HEAD**：`049f05d3`，已验证版本 `1.334.0-rc14` / build 646。
- **未提交工作**：`1.334.0-rc15` / build 647，节点交付 UI + 媒体完成通知持久交接。请保留全部 tracked/untracked 改动。
- 基于 develop `5cbadabd` 开始的原优化分支为 `codex/agent-autonomy`；本副本从其 rc14 提交分出，不是重新从旧 develop 丢弃累计工作。
- 用户要求及时提交；项目 `CLAUDE.md` 要求测试通过才可提交。当前 rc15 **没有运行 App 定向/完整回归，不能提交为已验证功能**。
- 当前交付边界：仅本地提交；不要擅自合并、推送、打 tag、安装、发布或启动 Claude 的外部自动审阅服务。

## 2. 已有的阶段成功

已本地提交的 `049f05d3` 可以作为交接保存点，不需要为保存进度再提交未经测试的 rc15。

原工作树：`/Users/rocky/Sites/Xedit/.codex/worktrees/agent-autonomy`，交接时干净。

该提交最终完整 App 报告已实际读取核对：

- `build/goal-rc14-full-pass-20260906-33677-vjhouf/report.md`
- 3869 项：3868 passed、0 failed、1 条件 skipped，退出 0，xcresult 149.1 秒。
- 最终短烟测：`build/goal-soak-20260906-27493-ubyn3h/report.md`，请求 3 秒，报告 passed，退出 0。短烟测不是四小时证明。
- 更详细历史证据、Go race 和构建指纹见同树 `docs/AGENT_AUTONOMY_IMPLEMENTATION.md` 的 rc14 顶部条目。

已提交累计工作包括：Daemon 启动/终态持久回执和 Stop 恢复、预算/截止约束、恢复准入、节点交付证据代次、依赖变更失效、组合回归、单 Goal 长跑入口。**不等于原报告十项全部完成。**

## 3. 一个四小时测试仍在运行，先接管观察

不要修改原工作树源码/HEAD，不要复用或覆盖其测试目录，不要因暂时没有输出就重启测试。

- 命令：`ruby scripts/goal_soak.rb --seconds 14400`
- cwd：原 `agent-autonomy` 工作树，不是本 recovery 工作树。
- Codex 进程会话 handle：`81656`，交接时重新轮询确认仍 live。该 handle 不一定能在 Claude 中调用。
- 测试 host 曾核对 PID `34280`；PID 会变化/复用，操作前必须核对命令与启动时间，不能只认 PID。
- 当前输出日志：原树 `build/fast-tests/xcodebuild.log`。
- 终态归档：原树 `build/goal-soak-20260906-33882-ki252b/`，终态后应有 `report.json`、`report.md` 和 `tests/`。
- 单运行 ID：`3D14C3A8-DC8F-4807-8005-2E244360D19C`。
- 场景约 2026-09-06 19:16:21 开始，最早约 23:16:21 达到四小时；以真实终态报告为准。
- 交接最新检查点：elapsed 2843.36 秒、552 次已校验读取、8 次压缩、11 次空响应故障、failures=[]、pending_user_decisions=0、final=false。
- `ledger_attempts=-1` / `unfinished_requests=-1` 是运行中尚未收尾统计，不是零，也不是已经证明泄漏。
- 日志有缓冲；以最后一个 `goal_soak_evidence` 为准，不将迟到的旧检查点当作倒退。
- 这是隔离模型传输的真实主循环/文件工具/压缩长跑，**不调用实际模型，也不消耗模型 API Token**。不要把它当作实机远端执行器、语义验收或崩溃矩阵证明。

只读观察示例（在原工作树）：

```sh
rg 'goal_soak_evidence' build/fast-tests/xcodebuild.log | tail -1
```

必须先确认进程终止和最终报告，再启动新的 Xcode 测试。仓库共享 Xcode 构建槽，不要绕过锁或改 DerivedData 去与长跑竞争。用户需要节约的是 Agent 自动续跑 Token，不是重启这个无需模型请求的测试。

## 4. rc15 当前改了什么

### A. 节点交付 UI

- `Xedit/AgentDispatchModels.swift`：`deliveredTaskCount` / `hasDeliveredAllTasks` 只统计 `.merged`，空集合不算完成；现有 `isComplete` 语义未改变。
- 图和 inspector：`.accepted` 不再显示已交付，空集合不绿色；无障碍共用计数。
- 新 `Xedit/L10n+DispatchDelivery.swift`、`Xedit/DispatchDelivery.xcstrings`：五语言“节点交付”，明确仍需父 Goal 整体验证。
- `XeditTests/AgentDispatchDeliveryProgressTests.swift`：各状态、空集合、混合、全部交付、重新进入待交付状态。
- **父 Goal 整体语义验收仍未实现，不能用这次改名掩盖缺口。**

### B. 媒体原轮次与持久完成通知

- `AgentMediaTasks.swift`：新增可选 `ownerTurnID` 与 `completionDeliveryManaged`；13 个媒体/短剧工具创建入口传原始 `context.turnID`，不借用完成时的活动轮次。
- `AgentMediaCompletionStore.swift`（新增）：逐任务不可变 JSON 终态正文，独立 `.ack` / `.settled` 标记、校验和、NOFOLLOW 与文件/目录同步，冲突/损坏不覆盖。
- 旧历史缺 managed 标记不批量重放；新任务或新终态进入 managed 生命周期；未 settled 的任务不受历史 100 条裁剪。
- registry 成功保存终态后才通知 App；启动和原媒体 poller 每约 8 秒恢复待交付项；独立记录可恢复被其他窗口旧媒体列表覆盖的通知。
- `AppStateAgentMediaCompletionDelivery.swift`（新增）：原轮次 Stop 检查 → 内核 journal 去重 + 持久确认 → producer ACK → 调度；内核已 handled 才 settled。
- `AppStateAgentKernelRevocation.swift`：带 outbox 标记的事件必须查验正确任务/会话/轮次、有效 ACK；缺失/损坏则阻止消费；原轮次停止仍取消晚到交付。
- 新持久通知不走原内存兼容队列，以免绕过 ACK 门禁。会话清理保护待交付记录。
- `AppState` 新增可注入的媒体/后台任务注册表，供测试使用临时目录，避免写真实停止回执。

新增测试文件：

1. `AgentMediaOwnershipTests.swift`：轮次重载、旧记录兼容、兼容队列不绕过、停止标记重载。
2. `AgentMediaCompletionStoreTests.swift`：三阶段重载、幂等/冲突、ACK 写入失败、损坏保留、105 条历史保护、旧窗口列表覆盖后的独立恢复。
3. `AgentMediaCompletionDeliveryTests.swift`：5 项 App 路径测试：真实交接/消费、内核已保存但未 ACK、损坏 ACK 不唤醒、真实 Stop 后换轮次仍不复活、非持久内核不能 ACK。

App 测试使用唯一会话/临时注册表及拒绝网络传输；通常将 runtime 设为压缩中，检查交接边界而不发起实际模型调用。**没有运行这些用例，Swift 语法解析不代表类型检查或测试通过。**

## 5. 下一步，按顺序做，不再扩大批次

1. `git status` 核对当前脏改动；先 review 上述交接逻辑及新测试，发现错误就修复，不要盲目信任本文件。
2. 接管四小时测试观察；未终止前不启动 Xcode。可以做静态检查和代码审阅。
3. 测试终止后先核对最终 report 的时长、final、同运行 ID、failures、账本收尾和进程退出码；通过/失败分别记录，保留原证据。
4. 在 **recovery 工作树** 跑定向测试：

```sh
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/AgentDispatchDeliveryProgressTests -only-testing:XeditTests/AgentMediaOwnershipTests -only-testing:XeditTests/AgentMediaCompletionStoreTests -only-testing:XeditTests/AgentMediaCompletionDeliveryTests -only-testing:XeditTests/AgentRuntimeKernelTests -only-testing:XeditTests/AgentKernelDurableRetentionTests
```

5. 定向结束后归档本树 `build/fast-tests`，然后跑完整 `ruby scripts/run_tests_fast.rb`。新源码第一次不要用 `--without-building`；后续只有脚本确认指纹匹配才能复用。不要用 rc14 的构建/成绩替代 rc15。
6. `ruby scripts/version_consistency.rb`、`ruby scripts/complexity_guard.rb`、`git diff --check`。交接前已通过版本/复杂度（最近 1059 文件、18 soft/0 hard；最后新增 App 测试后需重跑）、新 Swift 文件语法解析及 diff 检查；**未跑 App 编译和单测**。
7. 若全部通过，更新 CHANGELOG / product-overview / 台账，把“未验证”改成真实结果，检查源码指纹，再精确 stage 本批文件并本地 commit。不要 `git add .` 混入用户文件，不合并/推送/发布。

## 6. 当前实现风险和未完成项

- **最优先：尚未类型检查。** 当前实现与测试可能有编译/行为错误；先让定向、完整回归全绿。
- 新 App 测试多数检查同步交接边界，并非杀进程/跨 App 真正重启全矩阵；需要补真实恢复证据。
- 已 settled 的媒体记录尚无长期回收策略；每次 poller 扫描/历史保护的磁盘开销需要控制。不要为了腾空间删除未交付正文或去重凭据。
- 媒体列表本身仍是各窗口整表保存，仍有更新覆盖风险；独立 outbox 只保护完成通知，不证明所有列表字段已并发安全。
- 损坏记录的故障隔离/公平扫描尚需完善；不能让一个坏记录永久挡住其他健康的无列表记录。
- 终态正文保留第一次完成观察；后续才到的 artifacts/statusMessage 是否需要可靠增量补充，需按实际 provider 顺序检查。
- 超大单条通知记录超过 8 MiB 会拒绝交接并保留任务，尚无分片/外部正文方案。
- 历史未记录原轮次的任务不能反推 Stop 归属；保留兼容边界，不伪造成功迁移。
- 当前媒体通知重放不代表 Worker、workflow、全部外部生产者都有持久 outbox。
- 原先主父 Goal 自动语义模型审阅涉及新增源码外发的权限曾被拒绝，**不要绕过或重新接回该模型外发路径**；当前实现不依赖它。

## 7. 全目标仍待完成的范围

原报告十项完整范围在 `docs/AGENT_AUTONOMY_IMPLEMENTATION.md` 的总表；较早过程记录有“待完成”后来已实现的描述，优先参考顶部最新提交证据和实际代码。

主要剩余：远端/非 Git/跨工作区交付；父整体验收与证据协议；全部主循环退出与后台恢复；全辅助/CLI 预算和费用闭环；全生产者副作用恢复与日志生命周期；附件/checkpoint/缓存生命周期；错误分类与自动修复；资源竞争/关键路径性能；全部执行器权限和最小必要询问；完整长期故障矩阵。

入口文档：`docs/AGENT_AUTONOMY_IMPLEMENTATION.md`、`docs/AGENT_PARENT_GOAL_VERIFICATION_PLAN.md`、`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`。先完成 rc15 验证和提交，再选下一批，不要一次重新翻遍仓库。

## 8. 不要碰的目录与状态

- 根 checkout `/Users/rocky/Sites/Xedit` 在 `feature/todo-image-preview`，有用户未跟踪 `docs/REVIEW_2026-09-02_RUNTIME_KERNEL_BRANCH_FIXES.md`，勿动。
- develop 在 `.codex/worktrees/video-studio`，勿切换/重置/合并它。
- `.claude/worktrees/*`、client-cancel-reasons、worker-latency-followup 等均不属于本批。
- 原 `agent-autonomy` 工作树仍承载长跑，源码保持 `049f05d3`。
- 不需要安装任何插件或新建用户任务；本交接未向 Claude 模型发送仓库材料，也未启动 Claude。

用户最关心：少消耗 Token，形成可验证的小阶段并及时提交，减少让用户替 Agent 排错/逐次审核。遇到可自动检查的技术问题先自己检查；只有真实权限、不可逆操作或缺失业务决定才交给用户。
