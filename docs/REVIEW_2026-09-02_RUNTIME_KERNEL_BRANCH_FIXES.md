# 2026-09-02 `feature/bundled-rule-reader` 分支审查与修复清单

> 交接对象：接手修复的 AI 编程助手（Codex 等）。
> 审查范围：本分支今天的四个提交 `f8410b00`、`47749a02`、`2bb877c2`、`26d68287`（版本 1.315.0-rc9 → rc17，约 5300 行）。
> 分支状态：未推远端、未合 `develop`。本文列出的问题在修完之前**不要**合并。

## 0. 先读这些约束

- 仓库规则见根目录 `CLAUDE.md`：改完必须先跑单测、再 commit、再合 `develop`；不得 `git add -A`（仓库常有并发会话）。
- 每次改代码同步 bump 版本号和 `CHANGELOG.md`，用 `ruby scripts/bump_version.rb`，跑完必看 `git diff`（它对 `product-overview.md` 和 `README.md` 是整文件盲替换）。
- 所有用户可见文案走 `L10n` + `xcstrings`，加 key 用文本级插入，不得用 JSON 序列化回写整个 xcstrings。
- 单文件不得超过 3000 行。`Xedit/AppStateAgentLoop.swift` 当前 2957 行，修 P0-4 时不要往里加行数，优先抽到别的扩展文件。
- 验证命令（全部要过）：

```bash
ruby scripts/version_consistency.rb
ruby scripts/run_tests_fast.rb \
  -only-testing:XeditTests/AgentRuntimeKernelTests \
  -only-testing:XeditTests/AgentApprovalLifecycleTests \
  -only-testing:XeditTests/AgentChatHistoryRendererGoalTests \
  -only-testing:XeditTests/AgentSubagentLiveActivityTests \
  -only-testing:XeditTests/AgentSubagentProfileTests \
  -only-testing:XeditTests/AgentHybridWorkerRoutingTests \
  -only-testing:XeditTests/WorkflowWorkerBindingTests \
  -only-testing:XeditTests/AgentSessionStoreTests \
  -only-testing:XeditTests/AgentPluginSystemTests
cd willdeep-agent && go test ./internal/agent/ -run 'Relay|Collab' -count=1 -race
ruby scripts/favorites_server_test.rb
ruby scripts/bundled_agent_rules_contract_test.rb
ruby scripts/chrome_extension_contract_test.rb
```

判定标准：退出码 0 + 日志里 `Test run with N tests in M suites passed` + `build/fast-tests/report.md` 的 `status: passed` 三者一致。`-only-testing` 对某些聚合 suite 会跑 0 个却报成功，看到 `Executed 0 tests` 要警惕（Swift Testing 的结果在 `✔ Test run with ...` 那行）。

审查时的基线：上面这套命令全部通过（Swift 296 项、Go 通过、favorites 40 项）。所以下面的问题**都不是测试红了**，而是测试没覆盖到。每条都要求补测试。

---

## 1. 分支与版本（合并前必须处理）

### 1.1 分支基点错了

分支从 `main` 的 release merge（`64299fb9`）切出，不是从 `develop`。`develop` 已经到 **1.316.0-rc3**（历史回溯插件 + 空会话清理），本分支却在 1.315.0 上从 rc9 走到 rc17。

**处理：**
1. 修完本文的问题后，`git merge develop` 进本分支（不要 rebase，已有多个提交）。
2. `git merge-tree --write-tree develop HEAD` 预演有 12 个文件冲突：`CHANGELOG.md`、`product-overview.md`、`README.md`、`Xedit.xcodeproj/project.pbxproj`、`ComputerUseHelper/Info.plist`、`Help/WillDeep.help/Contents/Info.plist`、`chrome-extension/willdeep-browser/manifest.json` 与 `README.md`、`willdeep-agent/internal/agent/version.go`、`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`、`docs/MOBILE_GATEWAY_REQUIREMENTS.md`、`Xedit/AppState.swift`。
3. 版本冲突的解法：本分支是 feat，合并后让号到 **1.317.0-rc1**（`develop` 的 1.316.0 已被占用）。用 `bump_version.rb` 统一改，别手改八处。
4. `CHANGELOG.md`：两边条目都保留，本分支 rc10–rc17 的条目改挂到 1.317.0-rc1 下（可合并成一个版本块，按 Added / Changed / Fixed / Security / Tests 归类）。
5. `Xedit/AppState.swift` 的冲突是相邻属性各自新增（本分支加 `agentRuntimeKernel` 等三个属性，`develop` 加 `sweptAbandonedEmptySessionCount`），两边都留。

### 1.2 rc14 有 bump 没 CHANGELOG

构建号 584 → 592 走了 8 步，`CHANGELOG.md` 只有 rc10、11、12、13、15、16、17 七条。合并让号时把 rc14 这一步并进去即可，不用单独补一条空条目。

### 1.3 合并后与 `develop` 的交互 bug（必须一起修）

`develop` 新增 `AppStateAgentSessionManagement.swift` 的 `sweepAbandonedEmptySessions`，启动时删除"没有消息、无 workspace、未 pin"的会话（判据在 `AgentSessionStore.deleteIfStillEmptyAndUnattached`，只看 `hasAnyMessage / workspaceRootPath / workspaceLocation / pinnedAt / presentationScope`）。

本分支的"事件调度中心"会话由 `Xedit/AppStateAgentRuntimeKernel.swift:159` `eventOrchestratorRuntime()` 用 `startNewAgentSession(inWorkspaceAt: nil, makeActive: false)` 创建，只设了标题，没有消息。合并后下次启动它会被扫掉，`AgentRuntimeEventSettingsStore.orchestratorSessionID` 指向死会话，排队中的事件成孤儿。

**修法（二选一，推荐 A）：**
- A. `deleteIfStillEmptyAndUnattached` 增加保护：`titleIsUserSet == true` 或 id 等于 `orchestratorSessionID` 的会话不删。
- B. 创建调度会话时立刻写入一条 `isLocalTranscriptEvent` 的占位消息。
- 测试：在 `AgentSessionStoreTests` 加一条"调度中心会话不会被空会话清理扫掉"。

---

## 2. P0：合并阻断级 bug

### P0-1 后台 Worker 拿不到终端控制器和审批回调

**位置：** `Xedit/AgentSubagents.swift:179-192`（`runOperation` 闭包）和 `:270-282`（`startBackground` 签名）；调用方 `Xedit/AppStateAgentToolMessages.swift:433-443`。

**事实：** `AgentSubagentRunner.run` 接受 `terminalController`、`commandReviewer`、`toolReviewer`、`approvedCommand`、`patchProposalSink`（`AgentSubagents.swift:1049-1051`、`:1898-1900`），但 `startBackground` 没有这些参数，`runOperation` 一个都不传，全部落到 nil 默认值。

**后果：**
- 后台 `ops_runner` / `generalist` / `terminal_operator` 的工具表里有 4 个终端工具，但每次调用都抛 "Agent Terminal is not available in this context."（`AgentTerminalTools.swift:52/71/95/119/286`）。rc11 声称修掉的"空耗一轮后报没有终端工具"只是搬到了后台路径。
- 后台 `generalist` 的 Chrome 写操作和 `call_mcp_tool`：`toolReviewer == nil` → `isParentApprovedGeneralistTool` 恒 false（`AgentSubagents.swift:1997-2002`）→ 一律 Denied。rc13 的"子 Worker 通过父会话上报终端/浏览器/MCP 确认"只对前台成立。
- 后台 `ops_runner` + `target_command`：用户在 spawn 卡上批了那条命令，`approvedCommand` 没传下去，执行时被拒。
- rc13 把主提示词改成"2–5 个独立任务一起 `run_in_background: true`"（`Xedit/AgentContextBuilder.swift:640`），等于把主流量导向这条残废路径。

**修法：**
1. `startBackground` 和 `RunOperation` 闭包补齐这几个参数，从 `AppStateAgentToolMessages.swift` 的后台分支传入与前台分支相同的值（前台分支在同文件 `:489` 附近，照抄它怎么构造 reviewer 和 controller）。
2. 注意 reviewer 闭包持有 `runtime`，后台 run 可以活过父回合；用 `[weak self]` + runtimeID 重新解析，别强持 runtime。
3. 测试：`AgentHybridWorkerRoutingTests` / `WorkflowWorkerBindingTests` 目前只断言前台 `effectiveToolNames`。补一条走 `startBackground` 的用例：注入假 runner，断言收到的 `terminalController` 和 `toolReviewer` 非 nil；再补一条后台 `ops_runner` 带 `approvedCommand` 时命令被放行。

### P0-2 用户在侧栏终端手敲命令会拉起模型

**位置：**
- `Xedit/AgentInteractiveTerminal.swift:1463` `publishSemanticTerminalTransitions()`，由 `:2026` 起的 `inputStateTimer` 每 0.5s 轮询所有 tab 的前台进程组，`foregroundTask → shellReady` 转成 `commandCompleted`，`→ exited` 转成 `exited`，不区分命令是谁敲的。
- `Xedit/AgentSidePanelTerminalView.swift:613` 与 `:632`：用户手动新建本地 tab 也带 `originAgentSessionID: panelScope.sessionID`，所以用户自己的 shell 挂在会话上。
- `Xedit/AppStateAgentRuntimeKernel.swift:329` `publishTerminalKernelEvent`：发布为 `trust: .host, interruptPolicy: .yieldAtBoundary`，`exited` 还是 `.urgent`。
- `Xedit/AppStateAgentRuntimeKernel.swift:48` `AgentAutomaticWakePolicy`：只要有 `.host` 信任的 pending 事件就唤醒，**不计额度**。

**后果：** 用户在会话终端里连敲 `ls`、`git status`、`cd`（间隔超过 5 秒合并窗口），每条都触发一次"Terminal Shell 1 returned to a ready shell." 的模型回合；`exit` 触发 urgent 唤醒。App 退出时若 `exited` 落了盘，下次启动 `resumePersistedAgentKernelEvents`（`:211`）给每个开过终端的会话各跑一轮。这是 provider 请求级别的 runaway。

**修法：**
1. 终端状态事件只对**Agent 发起的命令**发布：`AgentInteractiveTerminalController` 记录哪些 tab / 哪次前台任务是 `terminal_send` 之类工具写入的，用户键入的不产生 `commandCompleted`。`exited` 事件也只对 Agent 创建的 tab 发。
2. 即便是 Agent 发起的，`commandCompleted` 也不应该唤醒**空闲**会话：Agent 发命令时回合本来就在跑，`yieldAtBoundary` 在边界投递就够了。建议把终端事件的 `trust` 降为 `.authenticated`（走额度），或在 `AgentAutomaticWakePolicy` 里把 `source == .terminal` 排除出免额度名单。
3. 测试：`AgentRuntimeKernelTests` 加"用户手敲命令产生的终端转换不会发布 kernel 事件"和"terminal 事件不唤醒空闲 runtime"。

### P0-3 Relay 有积压时每次启动多建一个"事件调度中心"会话

**位置：** `Xedit/AppState.swift:806` 在 `init` 里调 `configureAgentRuntimeKernel()` → `CollaborationRelayEventPump.shared.attach` → 立刻起 poll Task；会话目录在 `:965` 之后的异步 Task 才加载。`Xedit/AppStateAgentRuntimeKernel.swift:159-176` `eventOrchestratorRuntime()` 用 `agentSessions.contains(where:)` 判断旧调度会话是否存在，目录未加载时恒为 false → 新建会话并覆盖 `orchestratorSessionID`。整个内核文件没有引用 `hasLoadedAgentSessionCatalog`（`AppState.swift:307`）。

**后果：** 旧调度会话仍在磁盘，目录加载后 `resumePersistedAgentKernelEvents` 把它的 pending 事件也唤醒，两个调度会话并行；每次带积压启动就多一个。

**修法：**
1. Pump 的 `attach` 等 `hasLoadedAgentSessionCatalog == true` 再开始 poll（订阅这个 `@Published`，或在 `AppState.swift:1015` `retainEvents` 之后再 `attach`）。
2. `eventOrchestratorRuntime()` 加 `guard hasLoadedAgentSessionCatalog`，未加载时把事件留在 kernel 队列里，不创建会话。
3. 测试：`AgentRuntimeKernelTests` 加"目录未加载时外部事件不创建调度会话；加载后复用已有 orchestratorSessionID"。

### P0-4 工具执行阶段按 Stop，回合被自动重启

**位置：** `Xedit/AppStateAgentLoop.swift:2744-2768` 工具阶段的 `catch is CancellationError` 直接 `return`，没有像 provider 阶段（`:1252`、`:1265`）那样置 `shouldResumePendingEventsAtTurnEnd = false`。`:534-538` 的 defer 于是执行 `resumeAgentLoopForPendingBackgroundCompletions`。

**后果：** 用户因为 Worker 跑偏按 Stop，恰好有 host 事件 pending（Worker 完成、Job 完成、P0-2 的终端事件）→ 立刻开新 turn，"Stop 没停"。`stopAgentResponse` 也不清理 kernel 里的 pending。

**修法：**
1. 工具阶段的 `CancellationError` 分支置 `shouldResumePendingEventsAtTurnEnd = false`。检查 `:663` 那条和其他 `return` 路径是否也漏了。
2. 更稳的做法：把"用户主动 Stop"记成 runtime 上的一个标志，defer 里统一看这个标志，不依赖每个分支手动置位。
3. 测试：`AgentRuntimeKernelTests` 已有 `appStateCancelsCurrentStepForTrustedCriticalEvent`，照它的方式加"工具阶段取消 + pending host 事件 → 不自动重启"。

### P0-5 外部事件正文以 `system` 角色进模型

**位置：** `Xedit/AppStateAgentLoop.swift:766` 事件通知以 `AgentMessage(role: .system, content: agentRuntimeKernel.modelNotice(for: event))` 进 transcript。`Xedit/AgentClientAnthropic.swift:583`、`Xedit/AgentClientGemini.swift:555` 把非本地事件的 `.system` 消息 `systemBlobs.append` 拼进 system prompt；`Xedit/AgentClientOpenAIChat.swift:703` 用 `role.rawValue` 直接发 `role: system`。

**后果：** webhook / 邮件 / Relay 正文以系统身份出现，`modelNotice` 的转义和标记中和只挡了帧闭合，没挡角色提升。`docs/AGENT_RUNTIME_KERNEL.md` 里"正文只作为数据交给主 Agent"在角色层面不成立。副作用：Anthropic 每投递一次事件 system prompt 就变一次，前缀缓存全失效。

**修法：**
1. 事件通知改用 `.user` 角色 + `isHostInstruction`（`AgentContextBuilder.swift:843` 附近的注释本来就假定"surfaces that notice as the newest user message"），或者走 tool-result 载体。
2. 三个 client 适配器确认这类消息不再进 `systemBlobs`。
3. 测试：加一条断言"外部事件通知在发给 provider 的请求里不是 system 角色"（可以对 `AgentClientAnthropic` 的请求体构造函数做纯函数断言）。

### P0-6 搜索展开被可见消息缓存吃掉

**位置：** `Xedit/AgentChatTranscript.swift:900-921` `visibleMessagesFingerprint` 不含 `isConversationSearchActive`，而 `:959` `rebuildVisibleMessages()` 用它决定 `revealsIntermediateMessages`。`AgentTranscriptVisibleMessagesCache`（`:199`）按指纹返回旧列表。同文件 `:825` 的 `minimapInputFingerprint` 已经把它 hash 进去了，两处不一致。

**后果：** 打开搜索仍是折叠列表，CHANGELOG 里"搜索仍能命中完整过程"不成立；反过来，搜索期间有消息变化就展开，关掉搜索后卡在展开态直到下次指纹变化。

**修法：** `visibleMessagesFingerprint` 加 `hasher.combine(isConversationSearchActive)`。测试：`AgentChatHistoryRendererGoalTests` 目前只测纯函数 `projectedMessages`，补一条走 `visibleMessages` 属性的用例，翻转搜索状态断言列表长度变化。

---

## 3. P1：风险，建议本轮一起修

### P1-1 无人值守派发任务里 Worker 的特权调用无条件放行

`Xedit/AppStateAgentToolDecisions.swift:170-172` `resolveSubagentToolApproval`：`if runtime.isUnattendedDispatchTask { return true }`，不看 risk、不看 MCP 信任级别、不查黑名单。覆盖 `.danger` 终端命令、`chrome_debugger_command`、标记 untrusted 的 MCP 服务器。Worker 的终端命令发到用户真实 shell，seatbelt 管不到。

**修法：** 至少让 `.danger` 和 untrusted MCP 走确定性黑名单（`AgentSandboxPolicy` 已有），与父会话在同场景下的 `.dispatchTask` 分支（`AppStateAgentLoop.swift:1865`）对齐。

### P1-2 多窗口同会话：唤醒与 ACK 无 owner 门禁，额度按窗口翻倍

- `Xedit/AppStateAgentRuntimeWakeups.swift:104` `resumeAgentLoopsWithPendingBackgroundCompletions` 遍历本 AppState 的 `agentRuntimes`，读的却是进程共享 kernel；`AppStateAgentRuntimeKernel.swift:452` `scheduleAgentKernelEvent` 同样不查 owner。只有 `resumePersistedAgentKernelEvents`（`:211`）查了 registry。
- `AppStateAgentLoop.swift:1245` `acknowledge(leasedModelEventIDs(for:))` 按 runtimeID 全量 ACK，另一窗口 lease 的事件会被提前标 handled。
- `agentExternalWakeHistoryByRuntime` 是 AppState 实例变量（`AppState.swift:442`），N 个窗口 = 6N 次 / 5 分钟。

**修法：** 唤醒与 ACK 都经 `existingEventOrchestratorOwner`（`AppStateAgentRuntimeKernel.swift:146`）那样的 owner 判定；额度历史挪到 `AgentRuntimeKernel` 上按 runtimeID 存。

### P1-3 额度耗尽后的已认证事件没有重触发

`AppStateAgentRuntimeWakeups.swift:37-51`：额度不足返回 nil 就地放弃，5 分钟窗口滑过后没有 timer 再查。事件要等下一次无关触发。文档写"继续安全排队"，实际可能排几小时。

**修法：** 额度拒绝时用 `reservation` 里的下一次可用时间安排一个一次性 `Task.sleep` 重查（去重，每 runtime 一个）。

### P1-4 冷启动主线程同步读全部事件日志；坏文件永久滞留

`Xedit/AgentRuntimeKernel.swift:509` `AgentRuntimeKernel.shared` 首次访问在 `AppState.init`（主线程）同步 `loadAll()`（`:403-424`），逐文件读 + 解码。解码失败 / 超 64MiB / schema 超前的文件被 `try?` 静默跳过但不删除；`retainEvents`（`:756`）只按内存中事件算 removed 集合，孤儿文件永不清理。

**修法：** `loadAll` 移到后台队列，加载完成后再 publish；无法解码的文件 rename 成 `.corrupt-<timestamp>` 并记日志。

### P1-5 `retainEvents` 依据单个窗口刚加载的目录，缺失即删日志

`Xedit/AppState.swift:1015` 每个 `loadSessionCatalog: true` 的 AppState 加载完都执行 `retainEvents`。`AgentSessionStore.loadAllWithMetadata` 目录枚举失败 `try?` → 空列表 → `retainEvents(for: [])` 删光所有日志（含已 ACK 的 Relay 事件，不可恢复）。

**修法：** 目录加载失败或结果为空时跳过 `retainEvents`；只在加载成功且非空时执行。

### P1-6 Go Relay：有界日志会挤掉队头未 ACK 事件

`willdeep-agent/internal/agent/collab_relay.go:460` `enqueue` 满时丢**最旧**的未 ACK 事件（正是 poller 在处理的队头）；`:573` `encodeJournalWithinLimitLocked` 64MiB 上限同样裁旧事件，实际容量可能远小于 `MaxEvents=500`（文档未提）。`handleAckEvents`（`:400`）对已被淘汰的 ID 静默跳过，客户端分不清"已 ACK"与"已丢失"。飞书长连接进来的事件是 `AuthenticatedIngress` 不需要 relay token，任何能给机器人发消息的人发 500 条就能挤掉合法事件。

**修法：** 满时拒收新事件（回 429 / 503，计 Dropped）而不是淘汰旧的；ACK 响应里把"未找到的 ID"单独列出；文档 `docs/COLLABORATION_CONNECTORS.md` 补 64MiB 上限。

### P1-7 Go Relay：持久化默认开启改变了失败模式

`willdeep-agent/cmd/willdeep-agent/main.go:209-213` 默认路径 `UserConfigDir/WillDeep/collab-relay-events.json`，`os.UserConfigDir` 出错时静默退成纯内存；路径不可写时每个回调都 503，`NewCollaborationRelay` 启动时探不出来。`loadPersistedEvents`（`:490`）遇损坏文件直接拒绝启动；rename 后无目录 fsync；`CreateTemp` 与 `Rename` 之间崩溃留下的临时文件永不清理。

**修法：** 启动时试写一次并 fail-fast 报路径；损坏文件 rename-aside 后继续启动；启动清理 `.collab-relay-events-*` 临时文件。

### P1-8 收藏"查看原文"匹配不到带格式的选区

`Xedit/AppStateAgentComposer.swift:2505` 用 `message.copyableContent.contains(text)` 匹配，选区文本是渲染后的字符串，原文是 markdown；跨粗体、标题、代码块的选区匹配失败 → 不写 `source_*` → 没有"查看原文"按钮，无提示。`:2509` `prefix(while:)` 排除了选中消息本身，选在用户气泡里时 turnID 指向上一轮。

**修法：** 从 TextKit 选区拿到所在段落对应的 `messageID`（渲染层已有 message → range 映射），不要靠文本反查。

### P1-9 `RuntimeEvents.xcstrings` 只有 zh-Hans

`Xedit/RuntimeEvents.xcstrings` 全部 42 条只有 `zh-Hans`，英文靠 `defaultValue`，`Localizable.xcstrings` 里有的 es / fr / ja / zh-Hant 全缺。用文本级插入补齐四种语言。

---

## 4. P2：小问题，顺手修

- 硬编码文案未走 L10n：`Xedit/AgentToolCallGrouping.swift:227` 与 `Xedit/AgentToolDisplayNames.swift:185` 的 `"读取内置规则"`；`Xedit/AppStateAgentToolDecisions.swift:235`、`:240` 的 `"Worker tool request approved"` / `"User denied Worker tool request"`（进工具卡，用户可见）；`Xedit/AgentTaskMonitorRail.swift:1212`、`:1214` 的 `"R\(round)/\(max)"`。
- `Xedit/AppStateAgentToolMessages.swift:427` 拒绝后台写 Worker 的文案仍写 "`editor` trade cannot run in the background"，对 generalist / implementer 是错的。
- 舰队面板 `"\(runningCount)/\(maxConcurrentPerRuntime)"`：`activeCount` 只数后台注册表，前台 Worker 不占位，面板可显示 "6/5"。要么把前台算进上限，要么文案改成只说后台。
- `Xedit/AgentSubagents.swift:1955-1958` 注释"危险与敏感命令绝不能交给模型越权"已过期（rc13 把 `.danger` 改成父会话出卡由用户裁决），`subagentCommandMayBeReviewedByParent` 疑似死代码，确认后删。
- `AgentRuntimeKernel.swift:346` 非 Relay 适配器无 `externalID` 时 dedupeKey 退化为 `sender:kind:title` 且 scope 是 `.journal`，同发件人第二封同标题邮件会被永久吞掉。目前只有 Relay 传 externalID，下一个接入者会踩。加时间窗或改 scope。
- `CollaborationRelayEventPump.swift:251-257` 每个 `AppState.init` 都 cancel 并重启 poll；`:289-292` Relay 未回 `received` 时重投会重复计数。
- Go `go vet ./...` 在 `willdeep-agent/internal/agent/jobs.go:186-189` 报复制含 `sync.Mutex` 的结构体。这是 7 月的存量问题，不属本分支，但 `vet && test` 链会因此短路，CI 里如果这么串就一直没跑测试。单独开一个 fix 分支处理。

---

## 5. 测试与 CHANGELOG 声明的差距

以下是 CHANGELOG 写了、测试没覆盖的，修完对应问题时一并补：

- "取消、传输失败把 lease 恢复为 pending"：只有 `deliveryLeaseCanBeReleasedWithoutRestart` 直接调 kernel 方法，没有经 `runAgentLoop` 失败路径的用例。
- "所有空闲恢复路径统一走同一策略"：`automaticWakePolicyCoversEveryIdleResumePath` 只测纯函数，未覆盖 slot 释放 / 压缩结束 / turn 结束三条实际调用点。
- "旧 rc14/rc15 日志兼容读取"：无旧格式 fixture。
- Go：无损坏 journal、未知 ID ack、poll 期间淘汰、并发 poll/ack/callback 的用例。

---

## 6. 审查时确认没问题的（不用再查）

- `read_bundled_rule` 白名单、软链接边界、迁移只在与旧模板逐字相等时发生。
- 各工种终端工具可见性由代码决定，用户存档无法伪造。
- 前台 Worker 的 Chrome / MCP 写调用经 `toolReviewer` 复用父会话审批档位、MCP 信任级别与裁判。
- 写集合路径锁按 `(parentRuntimeID, 规范化相对路径)` 精确键，冲突即拒不等待，无死锁。
- Dock 徽标按记录计数、跨窗口取 max、归档排除、批准/拒绝/取消后归零。
- `runAgentLoop` 所有退出路径经 defer 释放 lease，ACK 仅在流式请求成功后。
- 事件日志串行写队列、原子写、0600/0700、退出前等待队列。
- 非 host 事件的 `.preempt` 双重降级；payload / metadata / 标题上限生效；帧无法被闭合。
- Go Relay 鉴权：header 与 query 都用 `subtle.ConstantTimeCompare`，poll/ack 拒绝 query token，token 不进日志和 journal。
- 折叠谓词只藏已完成回合中非最终的 `.assistant` 消息，`.user` / workflow / widget / scheduledTask / 错误卡 / 计划卡不受影响；统计从完整消息列表算。
- favorites 旧数据可读、无 dist 步骤、无 `vw` 单位；xcstrings 改动是文本级替换。

---

## 7. 2026-09-06 复核：本文已被执行，分支早已合并

写这份文档时分支还挂在本地。四天后回看，事情按第 1 节的路线走完了：

| 时间 | 提交 | 事件 |
| --- | --- | --- |
| 09-02 21:52 | `d090b3c8` `fix(runtime): harden shared event delivery` | 一次性修掉本文绝大部分条目，51 个文件、+1063/-365 |
| 09-02 | `47fa9a45` | `git merge develop` 进本分支（按 1.1 的 merge 而非 rebase） |
| 09-02 | 让号 | 1.315.0-rc17 → **1.317.0-rc1**，构建号 593，CHANGELOG 归到一个版本块 |
| 09-02 | `f08d655d` | 合回 `develop` |
| 09-06 | — | `develop` 已走到 1.334.0-rc1，`go vet ./...` 干净 |

所以本文第 0-6 节请当历史读，别再当待办用。下面是逐条复核结论，基线是当前 `develop`。

### 7.1 已修（不用再看）

- **1.1 / 1.2 分支与版本**：让号到 1.317.0-rc1，rc14 的空 bump 并入同一版本块。
- **1.3 空会话清理误删调度会话**：走了推荐的 A 方案。`AgentSessionStore.deleteIfStillEmptyAndUnattached` 加了 `protectedSessionIDs` 参数并在入口直接短路。
- **P0-1 后台 Worker 缺执行上下文**：新增 `AgentSubagentRegistry.BackgroundExecutionContext`，把 `terminalController`、`approvedCommand`、`commandReviewer`、`toolReviewer` 打成一个结构体透传给 `startBackground`。比本文建议的"逐个补参数"干净。
- **P0-2 用户手敲命令拉起模型**：两层都堵了。`semanticTransition` 变成纯函数并接受 `hasPendingAgentCommand` / `isAgentCreatedTab`，用户自己的命令产生不了 transition；`AgentAutomaticWakePolicy` 又把 `terminalCommandCompleted` 和 `terminalExited` 排除出免额度的 host 唤醒集合。
- **P0-3 重复调度会话**：`AppStateAgentRuntimeKernel.swift` 两处 `guard hasLoadedAgentSessionCatalog else { return nil }`，`receiveCollaborationRelayEvent` 也在门内。
- **P0-4 Stop 后自动重启**：采纳了更稳的第 2 种改法，runtime 上记 `userStoppedTurnID`，工具阶段的取消分支也置了 `shouldResumePendingEventsAtTurnEnd = false`。
- **P0-5 事件正文以 system 角色进模型**：改成 `role: .user` + `source: .hostInstruction`。
- **P0-6 搜索展开被缓存吃掉**：`visibleMessagesFingerprint` 里加了 `hasher.combine(isConversationSearchActive)`。
- **P1-1 无人值守派发无条件放行**：现在 `.danger` / `.userInput` / `.read` 一律不给 `dispatchTask` 来源，只有 `.write` 且过 `AgentSandboxPolicy`、不需要打字确认、`call_mcp_tool` 的服务器不是 untrusted 才放行。
- **P1-2 多窗口 owner 门禁**：唤醒路径开头就是 `guard ownsAgentRuntimeKernelDelivery(for: runtime.id)`。
- **P1-3 额度耗尽不重触发**：`reserveAutomaticWake` 返回 `retryAt`，配 `scheduleExternalAgentWakeRetry` 与 `agentExternalWakeRetryTasks` 按 runtime 去重。
- **P1-4 冷启动同步读日志**：`Task.detached(priority: .utility)` 后台加载，坏文件 rename 成 `.corrupt-<suffix>`。
- **P1-5 空目录删光日志**：`retainEvents` 由 `loaded.catalogReadSucceeded` 把门。
- **P1-6 Go Relay 挤掉队头**：满时回 429 `event queue is full; retry after events are acknowledged`，ACK 响应报未知 ID，`docs/COLLABORATION_CONNECTORS.md` 补了上限说明。
- **P1-7 Go Relay 持久化失败模式**：启动 `os.CreateTemp` 试写探针并 fail-fast，坏 journal quarantine 后继续启动，启动清理 `.collab-relay-events-*` 残留。
- **P1-8 收藏"查看原文"**：改成从渲染层传 `messageID`，文本反查只留作兜底。
- **P1-9 `RuntimeEvents.xcstrings`**：42 条 × 5 种语言（es / fr / ja / zh-Hans / zh-Hant）齐了。
- **P2 大部分**：`read_bundled_rule` 与 Worker 审批文案走了 `L10n`，轮次显示走 `L10n.AgentDelegation.roundProgress`，后台拒绝文案改成按 `profile.id` 说话，`subagentCommandMayBeReviewedByParent` 已删，无 `externalID` 时 `dedupeScope` 退成 `.window`（不再永久吞掉同标题邮件），`go vet ./...` 干净。

### 7.2 仍然没修（本文剩下的全部欠账）

只剩一条 P2：

- **舰队面板可以显示 "6/5"。** `Xedit/AgentTaskMonitorRail.swift:1136` 仍是 `Text("\(fleet.runningCount)/\(AgentSubagentRegistry.maxConcurrentPerRuntime)")`。分母 `maxConcurrentPerRuntime = 5` 只约束后台注册表，分子 `AgentSubagentFleetStatus.make` 数的是所有 `subagentIsWorking` 的 `spawn_agent` 调用（`Xedit/AgentSubagentLiveActivity.swift:449`），前台 Worker 也算进去。改法二选一：分子只数后台，或者文案不再暗示这是配额。

### 7.3 修复动作本身带出的新问题

- **`XeditTests/AgentSubagentApprovalLadderTests.swift` 被整个删掉了**（`d090b3c8`，88 行），`AgentSubagentProfileTests` 也少了 16 行。紧接着 1.317.0-rc7 就修了一个回归：Worker 的只读终端命令在**所有审批档位**下反复弹审批卡，CHANGELOG 自己写明"是 1.317.0-rc1 五工种舰队引入的"。审批阶梯的断言在同一个提交里被删、回归在五天内出现，这个顺序不像巧合。现在相关断言散在 `AgentApprovalLifecycleTests`，建议把阶梯用例按新签名恢复成独立套件。
- rc7 的描述在 rc8 又被修正过一次（影响范围写窄了），说明当时对回归边界的判断也不牢。

### 7.4 第 5 节测试缺口的现状

- **已补**：Go 侧加了 `TestCollaborationRelayRejectsNewEventsWithoutEvictingDurableQueue`、`TestCollaborationRelayAckReportsUnknownEventIDs`、`TestCollaborationRelayQuarantinesCorruptJournalAndStartsEmpty`。
- **仍缺**：Go 侧没有并发 poll / ack / callback 的竞态用例（建议 `-race` 下开 goroutine 打）。Swift 侧 `deliveryLeaseCanBeReleasedWithoutRestart` 和 `automaticWakePolicyCoversEveryIdleResumePath` 还是只测纯函数，没有经 `runAgentLoop` 实际失败路径与三个调用点的用例。旧 rc14/rc15 日志格式仍无 fixture，`AgentRuntimeKernelTests` 里搜不到相关引用。

---

## 8. 若要继续，按这个顺序

1. 补 Go Relay 的并发竞态用例——最便宜，且 `-race` 能立刻给结论。
2. 恢复 Worker 审批阶梯的独立测试套件，覆盖只读 / 写入 / danger / untrusted MCP 四档，把 rc7 那个回归钉死。
3. 修舰队面板的 "6/5"。
4. 第 5 节剩下的两条 Swift 覆盖（lease 恢复的真实失败路径、旧日志 fixture）视精力再说。

这几条都不再是合并阻断级，可以各自开一个 `fix/` 分支单独走，别攒成一个 PR。
