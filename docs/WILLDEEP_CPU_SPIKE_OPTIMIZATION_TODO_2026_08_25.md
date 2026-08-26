# WillDeep CPU 瞬时升高：诊断记录与优化 TODO（2026-08-25）

> 记录时间：2026-08-25 17:29–17:31（Asia/Shanghai）
> 采样对象：WillDeep `1.290.0-rc1`（Build 493，PID 18271）
> 运行环境：macOS 26.5.2（25F84），Apple Silicon，8 个逻辑 CPU
> 采样报告：`/private/tmp/WillDeep-18271-20260825-1730.sample.txt`（本机临时文件，未纳入仓库）
> 2026-08-26 滚动复现：WillDeep `1.293.0-rc5`（Build 502，PID 43901），报告 `/private/tmp/WillDeep-1.293.0-rc5-43901-20260826.sample.txt`
> 本文状态：已进入 `1.293.0-rc6` 第一阶段修复；侧栏派生快照缓存与长会话增量指纹仍待量化

---

## 1. 背景与用户反馈

用户观察到整机 CPU “刚才还有点高”，希望确认 WillDeep 是否仍在持续消耗 CPU，以及是否需要修复或优化。

本轮只做了只读诊断：查看系统负载和进程排名、对 WillDeep 做 5 秒 `sample`、连续观察 CPU 回落情况，并核对采样中出现的源码位置。没有终止进程，也没有修改运行状态。

### 1.1 2026-08-26 补充复现与定性

用户补充明确复现动作是滚动左侧会话列表。对 `1.293.0-rc5` 的高负载阶段再次采样后，主线程 3886 个样本中有 2615 个（约 67.3%）落在 `NSHostingView.layout`，其中 1707 个（约 43.9%）继续进入 `AccessibilityNode.updateFocus → MultiViewResponder.visit`。停止活动后，进程 CPU 回落到约 7.7%；低负载基线报告保存在 `/private/tmp/WillDeep-1.293.0-rc5-43901-20260826-baseline.sample.txt`。

源码核对排除了“滚动时反复从磁盘加载会话”的假设：目录已经驻留在 `AppState.agentSessions`，会话标题自然宽度也有有界缓存。更直接的放大器是父侧栏持有 `hoveredSessionID` / `hoveredWorkspaceGroup`：指针不动、行随滚动经过时，每次 hover 进入/离开都让整个侧栏失效，并使悬停按钮反复加入、移出无障碍树。`1.293.0-rc6` 将 hover 状态下沉到行/工作区局部作用域，并把视觉悬停按钮替换为稳定的自定义无障碍动作；派生列表缓存仍是后续可做的第二层优化，不是本次滚动尖峰的首要根因。

## 2. 现场时间线

### 2.1 第一轮进程快照

17:29 左右，整机 load average 为 `8.68 / 11.69 / 15.93`。当时 CPU 排名前列如下：

| 进程 | CPU |
|---|---:|
| WindowServer | 约 52.5% |
| WillDeep | 约 38.8% |
| Codex app-server | 约 23.3% |
| Chrome GPU Helper | 约 20.1% |
| VeilLink | 约 14.2% |

这说明现场并非只有 WillDeep 在工作；WindowServer、Codex/ChatGPT、Chrome 和其他常驻应用共同构成了整机负载。

### 2.2 5 秒调用栈采样

对 PID 18271 执行了 5 秒、1ms 间隔的 `sample`。报告识别到：

- 进程仍存活，未崩溃；
- 主线程没有长期停在互斥锁、同步网络或磁盘读取上；
- 热点主要集中在 SwiftUI / SwiftUICore 的布局、视图图谱更新与响应者遍历；
- 进程物理内存约 439MB，峰值约 479MB；单次报告不足以证明存在内存泄漏。

### 2.3 连续 CPU 观察

采样完成后，对 WillDeep 连续观察四轮。除第一轮 `top` 的预热值外，CPU 为：

`4.3% → 8.5% → 6.0%`

随后再次查看全系统进程排名，WillDeep 约 6.6%，而 WindowServer 约 40.4%、VeilLink 约 21.0%、Codex Renderer 约 17.8%。

因此，本次 WillDeep 的约 39% 占用已经自行回落，表现为短时尖峰，而不是持续占满单核的忙循环。

## 3. 采样证据

### 3.1 已证实：主要热点在 SwiftUI 布局链

报告中递归累计较多的调用包括：

| 调用 | 样本计数 | 含义 |
|---|---:|---|
| `LayoutEngineBox.sizeThatFits(_:)` | 789 | 子视图尺寸反复协商 |
| `UnaryLayoutEngine.sizeThatFits(_:)` | 485 | 单子视图布局测量 |
| `LayoutProxy.size(in:)` | 481 | 布局代理尺寸计算 |
| `ViewLayoutEngine.sizeThatFits(_:)` | 364 | SwiftUI 视图尺寸计算 |
| `StackLayout...placeChildren(in:)` | 357 | Stack 子视图放置 |
| `AttributeGraph` 更新链 | 多处出现 | 状态变化驱动视图图谱重算 |

这些证据支持“短时间内发生了较密集的 SwiftUI 布局与更新”，不支持“主线程死锁”或“同步 I/O 永久阻塞”。

### 3.2 已证实：会话侧栏参与了本次更新

采样中出现了以下应用代码：

- `AgentSessionsSidebar.body`；
- `AgentSidebarSessionVisibility.visibleSessions(...)`；
- `AgentSessionsSidebar.groupedSessions(from:)`；
- `AgentSessionsSidebar.sessionRow(...)`。

当前实现已经避免把动态分组直接交给 `ForEach`，也刻意使用有上限的 eager `VStack`，规避 macOS 26 上 `LazyVStack` 动态分组可能持续 invalidation 的问题。但以下工作仍会在每次 `body` 求值时执行：

- [`AgentSessionsSidebar.swift:336`](../Xedit/AgentSessionsSidebar.swift#L336)：生成 `visibleSessions`；
- [`AgentSessionsSidebar.swift:343`](../Xedit/AgentSessionsSidebar.swift#L343)：生成 `workspaceGroups`；
- [`AgentSessionsSidebar.swift:1328`](../Xedit/AgentSessionsSidebar.swift#L1328)：分组后的映射、排序与新数组构造；
- [`AgentSessionsSidebar.swift:1367`](../Xedit/AgentSessionsSidebar.swift#L1367)：为 workspace 状态生成、去重并排序 key。

因此，“每次 body 只算一次”已经比多处重复计算更好，但如果流式回复或其他状态频繁使侧栏失效，仍可能重复执行全量过滤、分组、排序和复制。

### 3.3 已证实：聊天视图和滚动到底部参与了本次更新

采样中 `AgentChatTranscript.scrollToBottom(using:)` 的闭包累计出现约 33 个样本，同时出现：

- `AgentChatTranscript.body`；
- `minimapInputFingerprint`；
- `visibleMessages`；
- `visibleMessagesFingerprint`。

相关源码：

- [`AgentChatTranscript.swift:709`](../Xedit/AgentChatTranscript.swift#L709)：聊天视图更新链；
- [`AgentChatTranscript.swift:815`](../Xedit/AgentChatTranscript.swift#L815)：小地图输入指纹；
- [`AgentChatTranscript.swift:873`](../Xedit/AgentChatTranscript.swift#L873)：可见消息缓存入口；
- [`AgentChatTranscript.swift:895`](../Xedit/AgentChatTranscript.swift#L895)：遍历 tool calls 和全部消息生成指纹。

现有缓存避免了每次都重建完整可见消息列表，但“为了判断缓存是否可用而生成指纹”本身仍是 O(n)。流式回复会持续改变内容长度并触发更新；长会话中，这段遍历可能成为布局尖峰的助推器。

### 3.4 次要观察：Git 状态探测在采样中出现，但不是主要热点

报告中 `AppState.runGitCommandOnce(...)` / `Process.waitUntilExit()` 累计约 16 个样本，对应 [`AppStateGitStatus.swift:455`](../Xedit/AppStateGitStatus.swift#L455)。其占比远低于 SwiftUI 布局链，当前没有证据应优先重写 Git 状态探测。

## 4. 当前判断

### 4.1 已证实

1. WillDeep 当时确实出现过约 39% CPU 的短时升高。
2. 本次采样的主要工作发生在 SwiftUI 布局和视图更新链。
3. 会话侧栏、聊天记录指纹和自动滚动链都参与了这轮更新。
4. WillDeep 随后回落到约 4%–8%，没有形成持续忙循环。
5. 整机同时有多个高 CPU 进程，不能把全部系统负载归因于 WillDeep。

### 4.2 合理推断，尚待验证

1. 流式消息、会话状态更新或滚动到底部请求可能在短时间内共同触发多轮视图失效和布局。
2. 侧栏每次 `body` 求值时的全量分组/排序，会放大高频状态更新的成本。
3. 长会话的全量指纹遍历会随消息数量线性增长，并可能与 SwiftUI 布局发生叠加。
4. WindowServer 的高占用可能部分来自多个应用的动画、透明材质或频繁重绘；现有采样不能证明它主要由 WillDeep 引起。

### 4.3 当前不应下的结论

- 不能认定存在永久死循环；
- 不能认定存在死锁；
- 不能仅凭一次物理内存快照认定内存泄漏；
- 不能直接把 eager `VStack` 改回 `LazyVStack`，因为现有注释记录了 macOS 26 动态分组下的持续 invalidation 风险；
- 不应优先优化 Git 命令路径，因为它不是本次主要热点。

## 5. 优化 TODO

### P0：先补可重复、可量化的性能证据

- [ ] 固定复现场景：至少覆盖“长会话流式输出”“快速切换会话”“展开较多 workspace”“自动跟随底部”四种操作。
- [ ] 记录复现时的数据规模：会话数、workspace 数、当前消息数、tool call 数、正在展示的行数。
- [ ] 在尖峰仍持续时再次执行 5 秒 `sample`；若 CPU 持续超过 50% 达 5 秒，再补一份 `spindump`。
- [ ] 使用 `os_signpost` 或等价轻量指标记录以下阶段耗时，不记录消息正文、路径、Token 或其他敏感信息：
  - `visibleSessions`；
  - `groupedSessions`；
  - `visibleMessagesFingerprint`；
  - `minimapInputFingerprint`；
  - `scrollToBottom` 请求与真正执行次数。
- [ ] 区分“状态更新次数”和“实际布局次数”，确认是否存在一次流式 token 导致多次相同布局的情况。

### P1：缓存会话侧栏派生数据

- [x] 将会话行与工作区 hover 状态下沉到局部作用域，滚动跨行不再使整个侧栏失效；悬停按钮不再动态改变无障碍树，VoiceOver 操作由固定自定义动作承接（`1.293.0-rc6`）。
- [ ] 设计 `SidebarSnapshot`（或等价模型），只在以下输入真正变化时重建：会话集合、项目集合、隐藏 workspace、metadata-only 状态及影响分组的配置。
- [ ] 将过滤、分组、排序从 SwiftUI `body` 移至可测试的派生状态层；`body` 只读取稳定快照。
- [ ] 保证 session、workspace group 和 row 的 ID 稳定，避免缓存后仍因 identity 抖动触发全量 diff。
- [ ] 保留当前 eager stack 策略，先验证缓存收益；不要在没有 macOS 26 回归数据时改回 lazy stack。
- [ ] 为快照构建补充表驱动测试：输入未变时不重建；新增、删除、隐藏、移动会话时只产生预期差异。

### P1：把聊天指纹从全量扫描改为增量失效

- [ ] 评估在 `AppState` 的消息/tool-call 变更入口维护单调递增 revision，避免每次 `body` 求值遍历全部历史。
- [ ] 将“影响可见消息”“影响小地图”“只影响状态展示”的 revision 分开，避免无关变化清空所有缓存。
- [ ] 验证同长度文本编辑、图片替换、tool call 状态变化仍能正确失效，不能仅依赖 `content.count`。
- [ ] 为长会话建立性能测试数据：至少 1,000 条消息和持续流式增量；比较优化前后指纹生成次数与耗时。

### P1：合并自动滚动请求

- [ ] 统计一次流式回复中 `scrollToBottom` 的请求次数和实际执行次数。
- [ ] 仅在用户仍处于“跟随底部”状态时执行自动滚动。
- [ ] 将同一渲染帧或极短时间窗内的多个请求合并为一次；新请求到来时取消尚未执行的旧请求。
- [ ] 会话切换、右侧面板开关、加载更早历史和用户主动上滚必须分别回归，避免修 CPU 时重新引入跳顶/抢滚动问题。

### P2：控制绘制与系统级放大因素

- [ ] 在 Instruments 中对比“WillDeep 前台静止”“流式回复”“侧栏滚动”三种场景的 Core Animation commits 和 WindowServer CPU。
- [ ] 检查是否有无意义的常驻动画、hover 更新、透明材质或阴影在静止时持续重绘。
- [ ] 在相同 WillDeep 场景下关闭其他高负载应用重测，用于区分应用自身成本与整机资源竞争。
- [ ] 单独观察内存压力和压缩内存；只有在多次样本持续增长且不回落时，才进入泄漏诊断。

## 6. 建议验收标准

以下阈值是第一版工程目标，完成基线测量后可以调整：

1. **前台静止 5 分钟**：WillDeep CPU 中位数不高于 3%，P95 不高于 8%。
2. **长会话流式输出**：允许短时尖峰，但不应连续 5 秒高于 50%，且界面无明显输入、滚动或切换卡顿。
3. **侧栏压力场景**：300 个会话、多 workspace 展开时，单次派生快照重建可测、次数与输入变更一致，不随无关 token 更新重复执行。
4. **聊天压力场景**：1,000 条消息下，新增一个流式增量不再扫描全部历史来计算所有缓存指纹。
5. **滚动行为无回归**：跟随底部、用户上滚阅读、切换会话、开关面板和加载更早历史全部通过现有手动 smoke 测试。
6. **空闲稳定性**：优化后无新的常驻 timer、动画或后台轮询导致 CPU 周期性升高。

## 7. 是否进入 bugfix 的决策门槛

满足任一条件，应作为 bugfix 进入 `rc` 递增流程，并同步版本号、CHANGELOG 与相关测试文档：

- 用户可稳定复现输入、滚动或切换会话卡顿；
- WillDeep 在没有前台交互时持续超过 20% CPU 达 30 秒；
- 同一操作可重复触发超过 50% CPU 达 5 秒；
- 数据规模增长后 CPU 或布局耗时呈明显非线性增长；
- 采样再次稳定命中同一应用代码热点。

若以上条件均不满足，本事项保留为性能优化任务，不必作为阻断发布的问题。

## 8. 实施顺序建议

1. 先完成 P0 埋点和可重复基线；
2. 优先做侧栏派生快照缓存；
3. 再做聊天 revision / 增量失效；
4. 最后合并滚动请求并做完整行为回归；
5. 每一步分别对比 CPU、主线程耗时和布局次数，避免多项改动混在一起后无法归因。

一句话结论：**滚动尖峰的第一根因是父级 hover 失效与动态无障碍树放大布局，不是会话目录未缓存；`1.293.0-rc6` 已先切断这条热路径，派生快照缓存与长会话增量指纹继续按独立指标推进。**
