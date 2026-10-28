# 双模式发送（立即发送 / 排队）设计

> Last updated: 2026-10-28 | 状态：**已确认，实施中**
> 关联版本：基于 1.424.0-rc1（develop @ 8580ebc3）
> 适用范围：Xedit（WillDeep macOS App）；对照 `willdeep-rs` 的现状，不改 rs
> 关联文档：[AGENT_RUNTIME_KERNEL.md](AGENT_RUNTIME_KERNEL.md)、[DEFERRED_HUMAN_GATES.md](DEFERRED_HUMAN_GATES.md)
> 一句话：发送当下让用户手选「立即发送」还是「排队」；rs 那种不取消当前步的插话首版不做。

## 0. 需求来源

用户拿 Claude 输入框的截图问：我们能不能也支持两种发送，一种立即发出去，一种排队稍后发。并补充：我们本来就是一套学操作系统的中断思维，一个个小 turn，然后在边界上接收新消息，而且 willdeep-rs 里已经用上了。

截图里的交互是：普通回车立刻发送，⌘↩ 把这条消息排进队列、稍后再发。占位文案写的是 "↩ to send, ⌘↩ to queue for later"。

调查结论（本文档第 1 节）：两种语义的后端在 Mac 端都已经存在，缺的是发送那一刻的手选。rs 多出来的那种「不取消当前步、下一圈模型调用前注入」的插话，Mac 端没有，但轮次开头的注入点已经在，今天只接宿主事件。

## 1. 现状盘点（代码锚点）

### 1.1 Mac 端

| 位置 | 现在干什么 | 问题 |
| --- | --- | --- |
| `Xedit/ComposerTextInput.swift:525` | `insertNewline` 里 Shift / Option / Control 加回车交给 NSTextView 换行，其余（裸回车，以及 ⌘↩，因为没有单独判断 Command）都走 `onSubmit()` | 只有一种提交，没有第二套键用来选发送方式 |
| `Xedit/SubmitOnReturnTextView.swift:113` | `SubmitOnReturnKeyPolicy.submits` 是同一条规则的可测抽取；输入法有 marked text 时不提交 | 新键位必须改这两处，否则两个输入框行为不一致 |
| `Xedit/AgentComposerAttachments.swift:86` | 右侧只有一个按钮：`showsStop` 为真（正在回复或正在等 provider 槽）时画成方块并调 `stopAgentResponse`，否则画成上箭头并调 `sendAgentMessage()` | 按钮本身不提供两种发送 |
| `Xedit/AppStateAgentComposer.swift:198` | `runtime.isResponding` 或 `hasDeferredHumanWait` 为真时，正文、图片、附件、技能、执行器、delegation 和面板引用一起 append 进 `queuedMessages`，随后 `persistAgentSession` 落盘。有人工等待时不关闭那个决策，改为 `scheduleDeferredHumanGateWork`；关掉了阻塞式工具决策时才置 `shouldConsumeQueueAfterStop` 并取消 `requestTask` | 入队条件比「正在回复」多了人工等待，但忙碌与否仍完全由运行时决定，用户选不了 |
| `Xedit/AgentMessageModels.swift:1274` | `AgentQueuedMessage` 是 `Codable`，存正文、图片、文本附件、技能、执行器、来源、delegation、面板引用，以及 `independentOfHumanWait`（这条消息能否在人工等待期间独立执行） | 字段够用，不用加列 |
| `Xedit/AgentRuntime.swift:170` | `queuedMessages` 的 `didSet` 把值写进 `session.pendingMessages`，初始化时从那里读回 | 1.424.0-rc1 起队列随会话落盘，进程退出不再丢。本文档初稿写「不落盘」是基于 1.423.0-rc4，已过时 |
| `Xedit/AppStateAgentRuntimeWakeups.swift:12` | `consumeNextQueuedMessageIfNeeded` 只在既不在回复也不在压缩上下文时取队首，把 delegation 和面板偏好摆回运行时再走普通派发 | 消费时机已经对，不用改 |
| `Xedit/AppStateAgentLoopLifecycle.swift:220` | 每个回合收尾都试一次消费队列 | 同上 |
| `Xedit/AppStateAgentSessions.swift:1437` | 手动停止时若队列非空，置 `shouldConsumeQueueAfterStop`，让被取消的回合跳过收尾压缩，并由 1452 行的兜底轮询在回合退出后消费队列 | 停止不丢操作员排队消息 |
| `Xedit/AppStateAgentSessions.swift:1584` | `sendQueuedAgentMessageNow` 把指定消息挪到队首。若有人工等待，不取消回合，而是把它放进 `expeditedIndependentMessages` 交给延迟门调度；否则回合仍在跑就关掉阻塞式工具决策、取消 `requestTask`，等取消完成后消费队首 | 这就是「立即发送」的后端，但它是已排队消息的操作，不是发送当下的选项。人工等待这条分支是本次必须接住的，见 6.1 |
| `Xedit/AppStateAgentSessions.swift:1517` | 排队消息可删除、拖拽重排、拿回输入框编辑、移到新开的侧边会话（先摆进 composer，不自动发送） | 队列管理已经齐全，本次不动 |
| `Xedit/AgentChatTranscript.swift:596` | `QueuedMessagesList` 钉在 transcript 最底部 | 用户看得到队列 |
| `Xedit/AgentMessageSupportViews.swift:855` | 队列行上的「立即发送」按钮，可见文案是 `L10n.QueuedMessage.adjustDirection`（"Adjust direction"），无障碍名称才是 "Send queued message now" | 文案与实际行为（取消当前回合）不一致，见 10.3 |
| `Xedit/AppStateAgentLoop.swift:336` | 每个模型或工具轮次开头租约待投递的内核事件，以 `hostInstruction` 消息追加进 transcript，再发下一次 provider 请求 | 这个注入点今天只读宿主事件，不读操作员的话 |
| `Xedit/AgentRuntimeKernel.swift:60` | 三档中断：`enqueue` 只记账，`yieldAtBoundary` 在下一个模型或工具边界投递，`preempt` 取消当前 provider 步骤并保留 transcript。只有宿主信任的 critical 事件能保留 `preempt` | 管的是宿主事件，不是输入框消息 |
| `Xedit/AgentMessageModels.swift:65` | `AgentMessageSource` 只有 `operatorInput` 与 `hostInstruction` 两档 | 插话不需要新的来源枚举，见 6.2 |
| `Xedit/AppStateAgentDispatchOrchestration.swift:594` | 调度台指令已经是三档投递，而且走的就是这条队列：`queuedForSafePoint` 直接 append；`appliedImmediately` 在回复中或压缩中时 append，否则立刻派发；`confirmDispatchGoalInterrupt`（615 行）插到队首再 `stopAgentResponse` | 三档语义在仓库里已有先例，但它们是调度台的，不是输入框的 |
| `Xedit/AppStateMobileGatewayController.swift:1004` | 手机网关 `queue.update` 的 `send_now` 走 `sendQueuedAgentMessageNow`，`run_independently` 走 `runQueuedAgentMessageIndependently`（`Xedit/AppStateDeferredHumanGates.swift:213`：插到队首、标记 `independentOfHumanWait`、不取消当前回合）。add（978 行）只入队 | 缺 add 时的「立即发送」标记，见 9.2。`run_independently` 就是 rs 的同名动作，本文档初稿说 Mac 端没有它，已过时 |

### 1.2 willdeep-rs（只作对照，本次不改）

| 位置 | 现在干什么 |
| --- | --- |
| `willdeep-rs/crates/willdeep-core/src/agent.rs:1052` | 一次用户提交跑在 `for turn in 1..=max_turns` 里。每一圈开头先 `append_pending_instructions`，再 `append_kernel_events`，然后才发 provider 请求。边界是「当前模型或工具步骤已经结束」，不插在一批工具调用和它们的结果之间 |
| `willdeep-rs/crates/willdeep-core/src/agent.rs:1327` | 模型只回文字、没有工具调用时，若收件箱还有插话就 `continue` 再开一圈。用户插话以 `Message::user` 进对话，不取消正在跑的那一次 provider 请求 |
| `willdeep-rs/crates/willdeep-cli/src/daemon/steering.rs:48` | `turn.steer` 把正文塞进在途任务的 `AgentInstructionInbox`，上限 16KiB，空白拒绝。没有在途任务时 `delivered=false`，不算错误，也不取消当前轮次 |
| `willdeep-rs/crates/willdeep-cli/src/tui.rs:582` | 忙碌时 Enter 不是两个键。`BusyInput` 分三类：白名单斜杠命令当场执行，普通文字入队，其余会改会话或 Runtime 的命令拒绝。Shift / Alt / Ctrl 加回车只插换行 |
| `willdeep-rs/crates/willdeep-cli/src/tui/runtime_queue.rs:89` | 默认 Runtime 轮次忙碌时 Enter 走 `submit_input`，持久化成下一个 Runtime 轮次，不会被自动插话。插话只留给显式 `/local`、本地队列和 `turn.steer` |
| `willdeep-rs/crates/willdeep-cli/src/daemon/session_store/turn_queue.rs:117` | 队列里的 `send_now` 把条目排到未认领队列最前，若当前轮次不在等审批或回答，再 `turn.stop` 取消它，靠串行调度消费。这是取消外层轮次再跑下一条，不是往当前模型步里注入 |
| `willdeep-rs/PRODUCT_OVERVIEW.md:41` | 新口径：默认 Runtime TUI 与 Web 忙碌时把输入持久进 Runtime 队列 | 同一份文档第 257 行和 `docs/TUI_GUIDE.md` 仍写「运行中回车自动送入当前轮次」，与代码不一致，已过时 |

两边的内核三档是同一套，都写在各自的 `docs/AGENT_RUNTIME_KERNEL.md` 里。仓库里没有「agent os」这个字面量，用的比喻是宿主当内核、主 Agent 当 init/systemd 加调度器。

## 2. 结论：发送当下加手选，插话首版不做

「排队发出去」已经在跑：忙碌时回车就是入队。「立即发送」的后端也在：`sendQueuedAgentMessageNow` 就是取消当前回合再发。缺的只是发送那一刻的分流，让用户在回合进行中时能选「这条排队」还是「这条马上发，并打断当前回合」。

rs 那种不取消当前步的插话，首版不做。理由在第 6 节：它触的不是键位，是一条新的消息通道，而 rs 自己的默认交互也已经从插话改成了持久化队列。本文档把它的接入点和代价写清楚，留给后面单独做。

### 2.1 设计原则

1. 不新造调度。两种发送都落到已有的 `queuedMessages` 和 `sendQueuedAgentMessageNow` 上，不引入第三条发送路径。
2. 默认行为不变。裸回车仍是「空闲立刻发、忙碌入队」，新键位只是显式覆盖。
3. 打断必须是显式动作。取消正在跑的回合会丢掉它没写完的那段，不能变成回车的默认结果。
4. 键位判定抽成纯函数。沿用 `SubmitOnReturnKeyPolicy` 的做法，让两个输入框共用同一个判定，并且可以不启动 App 就测。
5. 跨端同一个动作。桌面端的「立即发送」和手机网关的 `send_now` 必须落到同一个函数，不能各写一套。

## 3. 已拍板的决策

还没有。候选决策都在第 15 节，等用户拍板后搬到这里。

## 4. 总体架构

发送路径不变，只在入口处分流。

```
输入框
  裸回车 / 发送按钮
      空闲  -> dispatchAgentMessageUsingSelectedExecutor        (现状，不变)
      忙碌  -> queuedMessages.append                            (现状，不变)
  ⌘↩（新）
      空闲  -> 与裸回车相同，立刻派发
      忙碌  -> append，然后走 sendQueuedAgentMessageNow 的后半段：
               关掉阻塞式工具决策、取消 requestTask、取消完成后消费队首
  ⌥↩（新）
      不论忙闲 -> queuedMessages.append，不取消任何东西
```

消费侧一个字不改：`consumeNextQueuedMessageIfNeeded` 仍是唯一的出队口，回合收尾和停止后的兜底轮询仍是仅有的两个调用时机。

```
回合收尾 (AppStateAgentLoopLifecycle.swift:219)
    -> consumeNextQueuedMessageIfNeeded
手动停止 / 立即发送 (AppStateAgentSessions.swift:1436, 1580)
    -> shouldConsumeQueueAfterStop = true
    -> requestTask.cancel()
    -> scheduleQueuedMessageConsumptionAfterCancellation   (兜底轮询，1452)
        -> 回合退出后 consumeNextQueuedMessageIfNeeded
```

## 5. 数据模型

不加字段，不加持久化格式。

`AgentQueuedMessage` 现有字段已经覆盖一次提交的全部内容（正文、图片、文本附件、技能、执行器、来源、delegation、面板引用、`independentOfHumanWait`），「立即发送」与「排队」的差别只在入队之后走哪条路径，不需要在队列项上再加字段。

队列从 1.424.0-rc1 起随会话落盘：`queuedMessages` 的 `didSet` 写进 `session.pendingMessages`，加载时读回。本次不碰这条路径，也不改落盘格式。

## 6. 关键流程

### 6.1 立即发送（⌘↩，忙碌时）

1. 走 `sendAgentMessage` 现有的组包：正文、图片、附件、技能、执行器、delegation、面板引用，一个不落。
2. append 到 `queuedMessages` 的**队尾**，不是队首。前面排着的消息是用户更早排好的，不能被这条新消息插队。
3. 调一个新的入口，语义等于「把刚入队的这条挪到队首，再走 `sendQueuedAgentMessageNow`」。这个函数在 1.424.0-rc1 有两条路，新入口必须都接住，不能只接取消那条：
   - 有人工等待（`hasDeferredHumanWait`）时不取消回合，把这条放进 `expeditedIndependentMessages`，交给 `scheduleDeferredHumanGateWork`。这是 `Xedit/AppStateAgentSessions.swift:1592` 的现有行为。
   - 否则回合仍在跑就关掉阻塞式工具决策、置 `shouldConsumeQueueAfterStop`、取消 `requestTask`，由 `scheduleQueuedMessageConsumptionAfterCancellation` 在取消完成后消费队首。
4. 没有人工等待、也没有在跑的回合时，直接 `consumeNextQueuedMessageIfNeeded`。

第 3 步不直接复用 `sendQueuedAgentMessageNow(id:)`，因为它按 id 查找再挪到队首，而此刻这条消息还没有被视图持有。抽出「给定一条已在队列里的消息，按上面三条路让它成为下一条」这段，两个调用方共用。直接复用整个函数会把消息挪两次队首，所以抽的是挪队首之后的部分。

空闲时 ⌘↩ 没有回合可取消，行为与裸回车相同，立刻派发。不给用户一个「空闲时排队」的状态：没有正在跑的回合，排队没有意义，只会让消息平白多等一轮。

### 6.2 显式排队（⌥↩）

不论当前忙不忙，都 append 到队尾，不取消任何东西。

空闲时这是唯一一个「现在不发」的入口，所以它必须在 `isResponding` 为假时也能入队。这是本次对 `sendAgentMessage` 唯一的行为分支新增：今天这条函数在空闲时没有入队这条路。

忙碌时 ⌥↩ 与今天的裸回车行为相同。保留它是为了让两个键的含义稳定，不随回合状态变：⌘↩ 永远是「我要它现在生效」，⌥↩ 永远是「先排着」。

### 6.3 为什么不把 ⌘↩ 做成 rs 的插话

rs 的 `turn.steer` 是另一回事。它不取消正在跑的 provider 请求，也不取消正在执行的工具；文字进 `AgentInstructionInbox`，下一圈 turn 开头、发下一次 provider 请求之前读出来，以普通用户消息进对话。Mac 端对应的注入点在 `AppStateAgentLoop.swift:331`，今天只读内核事件。

要做插话，得在那个注入点旁边加一个操作员收件箱，并且解决 rs 没碰到的问题：Mac 端的一次提交带着图片、附件和技能，rs 的 steer 只收 1–16KiB 纯文本。带附件的插话要么降级成纯文本（丢东西），要么把附件推迟到下一圈（语义不清）。

更关键的是 rs 自己的取舍。它的默认交互已经从「忙碌时回车即插话」改成了「持久化进 Runtime 队列」，插话只留在显式 `/local`、本地队列和 `turn.steer`。`PRODUCT_OVERVIEW.md` 第 257 行和 `docs/TUI_GUIDE.md` 里「运行中回车自动送入当前轮次」的说法已经过时。所以 Mac 端没有一个正在被用户使用的、需要对齐的插话交互。

插话有它的价值：用户想补一句「另外把日志也带上」，不值得掐掉已经跑了一半的回合。但它是一条新的消息通道，有自己的上限、失败提示和与附件的关系，不该夹在这次键位改动里。接入点已经在，单独做时从 `AppStateAgentLoop.swift:331` 旁边加起，消息来源用现成的 `operatorInput`，不新增枚举值。

### 6.4 与调度台三档的关系

`AgentDispatchCommandEffect` 已经是三档，而且走同一条队列：

| effect | 行为 | 对应本次的哪个键 |
| --- | --- | --- |
| `queuedForSafePoint` | 直接 append，等回合自己结束 | ⌥↩ |
| `appliedImmediately` | 回复中或压缩中则 append，否则立刻派发 | 裸回车（现状） |
| `requiresInterruptConfirmation` 经 `confirmDispatchGoalInterrupt` | 插到队首再 `stopAgentResponse` | ⌘↩ |

本次不改调度台。列在这里是为了说明「取消当前回合再发」这个语义在仓库里已有第二个调用方（`AppStateAgentDispatchOrchestration.swift:632`），抽公共入口时把这一处也算进去，避免三处各写一份取消逻辑。

## 7. 不可让渡的不变量

1. 取消只发生在用户显式要求的时候。裸回车、发送按钮、⌥↩ 都不得取消 `requestTask`。拦截点在发送路径（`AppStateAgentComposer.swift` 的组包函数），不在按钮的 enable 状态上。
2. 新消息不插进正在流式输出的那一次 provider 请求。立即发送的实现是取消后重发，不是把文字拼进当前请求体。这是现状（`AppStateAgentSessions.swift:1314` 一带的停止路径已经保证），本次不得改掉。
3. 入队顺序不被新消息打乱。立即发送是「入队尾，再把这一条挪到队首」，不是「插入队首把别人往后挤」。前面的消息仍按原顺序排在它后面。
4. 停止不丢操作员的排队消息。现状是停止只丢 `source` 为 `hostInstruction` 的排队项，保留操作员的。立即发送走的是同一条取消路径，必须继续保留。
5. 输入法组字期间的回车仍属于候选词上屏。`SubmitOnReturnKeyPolicy` 在 `hasMarkedText` 时返回 false 的规则不变，两个新键位同样受它约束。

## 8. 失败与边缘状态

| 状态 | 用户看到什么 |
| --- | --- |
| 空闲时按 ⌘↩ | 与裸回车相同，立刻发送。不提示「没有可打断的回合」，因为结果就是他想要的 |
| 空闲时按 ⌥↩ | 消息进入队列卡片，停在那里，直到下一次发送或他在卡片上点「立即发送」。composer 清空，和普通发送一样 |
| 忙碌时按 ⌘↩ | 当前回合被取消，transcript 里出现现有的「已停止」事件（`L10n.Composer.stopped`），这条消息成为下一条被消费的。队列卡片里它排在最前 |
| 正在等 provider 槽时按 ⌘↩ | 与忙碌相同。`showsStop` 为真的两个条件（`isResponding`、`isAwaitingProviderSlot`）都算「有回合可取消」 |
| 正在压缩上下文时按 ⌘↩ | 不取消压缩。压缩是回合收尾的一部分，`consumeNextQueuedMessageIfNeeded` 本来就等它结束。此时按立即发送只入队，等压缩完成后再走取消路径 |
| 有人工等待（待确认或待输入）时按 ⌘↩ | 不取消那个等待，也不把它当成已回答。这条消息按 `sendQueuedAgentMessageNow` 的现有分支放进 `expeditedIndependentMessages`，由延迟门调度决定何时独立执行。原卡片保持原样 |
| 附件还在解析时 | 与今天一样发不出去。`canSend` 为假时两个新键位也不生效，沿用 `L10n.Composer.waitForAttachmentParsing` |
| 输入为空 | 两个新键位都不生效，和裸回车一样 |
| 排队后进程退出 | 队列还在。1.424.0-rc1 起 `queuedMessages` 随 `session.pendingMessages` 落盘，重新打开会话时恢复。本次不改这条路径 |
| 立即发送时队列里已有别的消息 | 那些消息保持原顺序，排在这条之后，不被挤掉也不被提前 |

## 9. 兼容与迁移

### 9.1 老数据

不涉及。本次不加字段、不改 `AgentQueuedMessage` 的编码，会话 JSON 的格式不变。1.424.0-rc1 已经把队列落进 `session.pendingMessages`，旧会话读回来是空队列，这个行为保持不变。

### 9.2 手机网关

`queue.update` 现有的 `send_now` 作用在**已排队**的消息上，继续走 `sendQueuedAgentMessageNow`，语义不变。

缺的是「发送当下」这一侧。手机端今天的 add 只有入队一条路。建议给 `queue.update` 的 add 增加一个可选字段 `deliver`，取值 `queue`（默认，等于今天）或 `now`。`now` 走第 6.1 节抽出的那个公共入口。字段可选且默认 `queue`，旧客户端不传时行为不变。

这一条是否纳入首版，见第 15 节第 3 条。

### 9.3 跨端对齐

本次不对齐 rs 的键位。rs 的 TUI 没有第二个发送键，它的「马上处理」是队列面板里的 `S`，对应 Mac 端队列卡片上已有的「立即发送」按钮，两边已经对齐。Mac 端新增的是 rs 没有的东西（发送当下的手选），不存在对齐目标。

## 10. UI 设计

### 10.1 键位

| 键 | 含义 | 备注 |
| --- | --- | --- |
| 裸回车 | 空闲立刻发，忙碌入队 | 不变 |
| ⌘↩ | 立即发送。忙碌时取消当前回合再发 | 今天这个键被裸回车的分支吞掉了，改成显式分支 |
| ⌥↩ | 排队，不论忙闲 | 今天 ⌥↩ 是换行。换行仍由 Shift↩ 和 Control↩ 承担 |
| Shift↩、Control↩ | 换行 | 不变 |

⌥↩ 从「换行」改成「排队」是一个破坏性的手感变化，中文输入法用户尤其依赖 Option 组合。这是第 15 节第 1 条要拍板的事，上表是我的默认假设。如果否掉，备选是只加 ⌘↩，排队继续靠「忙碌时裸回车」这一个隐式入口，不提供「空闲时排队」。

### 10.2 占位文案

只在回合进行中时把占位文案换成键位提示，空闲时保持现在的 `composer.input.placeholder`（"Ask anything... / commands, @ files/workspace, $ skills & plugins"）。进行中的文案说明两个键分别干什么，不照搬英文截图的句式。

文案走 `L10n.Composer`，新增 key，不硬编码在视图里。具体措辞等键位拍板后再写，避免先写一套然后改键位再改文案。

### 10.3 顺手修的文案错位

队列行上那个按钮的可见文字是 "Adjust direction"（`queued-message.adjust-direction`），无障碍名称却是 "Send queued message now"。它的实际行为是取消当前回合并立刻发送这条。可见文字应与无障碍名称统一成「立即发送」。这是一处独立的小修正，不依赖本次键位方案，可以随首版一起提交。

### 10.4 发送按钮

右侧那个圆形按钮不变：忙碌时仍是停止，空闲时仍是发送。不在按钮上加长按菜单或第二种形态。两种发送方式只通过键盘给出，按钮保持单义。

## 11. 分期落地

| 期 | 内容 | 可独立验收 | 预计版本 |
| --- | --- | --- | --- |
| P1 | 键位分流：抽出「取消当前回合并消费指定队列项」的公共入口，⌘↩ 走立即发送，⌥↩ 走显式排队 | 是 | 1.426.0-rc1 |
| P1 | 占位文案与队列按钮文案修正（10.2、10.3） | 随上面一起 | 1.426.0-rc1 |
| P2 | 手机网关 `queue.update` add 的 `deliver` 字段（9.2），仅当第 15 节第 3 条确认纳入 | 是 | 待定 |

P1 的两行是同一次提交，不是两个版本。测试按仓库规则跑完再合回 develop。

## 12. 测试计划与验收

### 12.1 单元测试

键位判定沿用 `SubmitOnReturnKeyPolicy` 的纯函数做法，扩展而非另起：

- `submits` 的现有用例保持全绿：Shift / Option / Control 加回车不提交，裸回车提交，有 marked text 不提交。
- 新增一个返回「提交方式」的函数，三档：`send`、`sendNow`、`enqueue`、`newline`。用例覆盖裸回车、⌘↩、⌥↩、Shift↩、Control↩，以及每种组合叠加 marked text（一律不提交）。
- 立即发送的公共入口：给定队列 `[a, b]` 和一条新消息 `c`，调用后队列顺序为 `[c, a, b]`，且 `requestTask` 被取消、`shouldConsumeQueueAfterStop` 为真。
- 空闲时 ⌘↩：不入队，直接派发，`queuedMessages` 仍为空。
- 空闲时 ⌥↩：入队，不派发，`isResponding` 保持假。
- 立即发送不丢前面的队列项，也不改变它们的相对顺序。

测试类名沿用现有的 composer 与 queue 测试所在的 suite，不新开 suite。具体类名实施时按当时的测试文件确定，写进这一节的落地补记。

### 12.2 手工验证

1. 让一个回合跑起来（让它调用一个慢工具），按 ⌘↩ 发送第二条。预期：当前回合停止，transcript 出现「已停止」，第二条开始执行，中间没有第三条被插进来。
2. 同样的场景按 ⌥↩。预期：当前回合继续跑，第二条出现在底部队列卡片里，回合结束后才自动发出。
3. 空闲时按 ⌥↩。预期：消息进队列卡片而不是立刻执行。
4. 中文输入法组字状态下按回车、⌘↩、⌥↩。预期：三个都是上屏，没有任何一条被发送或入队。
5. 队列里已有两条时按 ⌘↩ 发送第三条。预期：第三条最先执行，原来的两条按原顺序排在后面。

### 12.3 验收

- 上述单测全绿，且 `SubmitOnReturnKeyPolicy` 原有用例没有倒退。
- 手工验证 5 步的实际结果与预期一致。
- 两个输入框（composer 与使用 `SubmitOnReturnTextView` 的那一个）行为一致。

## 13. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| ⌥↩ 今天是换行，改成排队会打断一部分用户的手感 | 中文输入和习惯用 Option 换行的用户误入队 | 第 15 节第 1 条先拍板。若改，占位文案在回合进行中明确写出两个键的含义 |
| 立即发送取消的是整个回合，用户可能只想补一句话 | 跑了一半的工具调用被掐掉，已产生的副作用（写了一半的文件、起了一半的任务）留在原地 | 这是现状 `stopAgentResponse` 的语义，本次不扩大也不缩小。真正「补一句」的需求由插话解决，而插话明确推迟，见 6.3 |
| 抽出公共入口时漏掉调度台那个调用方 | 三处取消逻辑再次分叉，下次改一处忘两处 | 6.4 已点名 `confirmDispatchGoalInterrupt`，实施时一起改 |
| 立即发送在人工等待期间被理解成「替我回答那个确认」 | 用户以为按 ⌘↩ 会关闭待确认卡片，实际卡片保持原样 | 接住 `sendQueuedAgentMessageNow` 的现有分支：有人工等待时不关闭决策，只把这条消息交给延迟门调度。见 6.1 和 8 |

## 14. Non-goals

- **不做插话。** 不在 `AppStateAgentLoop.swift:331` 的注入点加操作员收件箱，不新增「不取消当前步、下一圈注入」的发送方式。理由见 6.3。
- **不改队列的落盘。** 1.424.0-rc1 起 `queuedMessages` 经 `session.pendingMessages` 随会话保存，本次不碰编码格式，也不改恢复逻辑。
- **不改 rs。** 包括不修正 `PRODUCT_OVERVIEW.md:257` 和 `docs/TUI_GUIDE.md` 里与代码不符的旧描述。那是 rs 仓库的文档，不在这个仓库改。
- **不动 `run_independently`。** 它在 Mac 端已经存在（`Xedit/AppStateDeferredHumanGates.swift:213`），语义与 rs 的同名动作一致：插到队首、标记 `independentOfHumanWait`、不取消当前回合。本文档初稿说 Mac 端没有它，是看 1.423.0-rc4 时的误判。本次的「立即发送」不复用它，因为它恰恰不取消回合。
- **不改右侧发送按钮的形态。** 不加长按、不加下拉、不加第二种图标。
- **不改队列卡片已有的操作。** 删除、拖拽重排、拿回编辑、移到侧边会话，都保持原样。唯一的改动是 10.3 的可见文案。
- **不改内核三档。** `enqueue` / `yieldAtBoundary` / `preempt` 继续只作用于宿主事件，用户消息不进 `AgentKernelEvent`。

## 15. 待确认问题

（空。2026-10-28 拍板，条目已搬到第 16 节。）

## 16. 已确认决策（2026-10-28 拍板）

五条都按文档原列的默认假设确认。

| # | 决策 | 推论 |
| --- | --- | --- |
| 1 | ⌥↩ 从「换行」改为「排队」 | 换行仍由 Shift↩ 和 Control↩ 承担。这是本次唯一一处改变既有键位含义的地方 |
| 2 | 立即发送用 ⌘↩ | 这是今天被裸回车分支吞掉的那个键，也是用户截图里的那个键 |
| 3 | 手机网关 `queue.update` 的 add 首版不加 `deliver=now` | 放 P2。桌面端先跑通，手机端的 add 保持只入队 |
| 4 | 队列按钮的可见文案 "Adjust direction" 改为「立即发送」 | 随 P1 一起提交。它与实际行为不符，且不依赖键位方案 |
| 5 | 插话不单独立项 | 首版明确不做。接入点记在 6.3，等有真实需求再开 |

拍板之后、开工之前核对了 develop（8580ebc3，1.424.0-rc1），发现初稿基于 1.423.0-rc4 有三处已经不成立，已改入正文而不是留在这里：队列从该版本起随 `session.pendingMessages` 落盘；`sendQueuedAgentMessageNow` 在人工等待期间不取消回合，而是交给延迟门调度；`run_independently` 在 Mac 端已经存在。第 6.1 节因此要求新的立即发送入口接住人工等待这条分支。

### 16.1 落地后补记的实现要点

落在 1.426.0-rc1，分支 `feat/dual-mode-send`。与设计的差异：

- 公共入口叫 `deliverQueuedMessageNow(id:in:)`，抽的是「挪到队首之后」的部分。`sendQueuedAgentMessageNow` 和输入框的 ⌘↩ 都先把消息放进队列再调它，所以人工等待、取消回合、直接消费这三条路只有一份实现。
- composer 的输入框历史上在回车时不看 `hasMarkedText`，组字回车由文本视图自己消化。`SubmitOnReturnKeyPolicy.action` 因此加了 `treatsMarkedTextAsComposition` 参数，composer 传 `false`，另一个输入框保持默认的 `true`。没有借这次改动统一两者的组字行为。
- `SubmitOnReturnTextView` 只有一种提交，没有排队和立即发送的去处，所以在那里 ⌘↩ 和 ⌥↩ 仍是换行，只有裸回车提交。
- 斜杠命令不受发送方式影响。`submitComposer(action:)` 只在真正发消息的那条分支把 `action` 传下去，命令链和单条命令仍是立刻执行。
- 单测落在 `XeditTests/AgentDualModeSendTests.swift`（四个用例：空闲排队、忙碌时立即发送挪到队首并取消、忙碌时裸回车仍追加、空闲时立即发送直接派发）和 `XeditTests/AgentDispatchTaskTakeoverTests.swift` 的 `returnKeyChoosesSendQueueOrNewline`。队列按钮的源码字符串断言在 `AgentHeaderEditorEntryTests.queuedRowsExposeCodexActions`，随文案一起改了。
- 空闲时立即发送的测试最初断言「派发会在解析运行参数时停下来、`isResponding` 仍为假」，实测这台机器的测试宿主能解析出运行参数，派发真的把回合跑了起来。断言改为「队列为空、消息进 transcript、`isResponding` 为真」，并在用例结束时 `stopAgentResponse`。

## 附：相关文档

- [AGENT_RUNTIME_KERNEL.md](AGENT_RUNTIME_KERNEL.md)：宿主内核与三档中断的现行说明。本文档不改它覆盖的范围，用户消息不进内核事件。
- `willdeep-rs/docs/AGENT_RUNTIME_KERNEL.md`：同一套内核在 rs 侧的说明，插话与队列的对照依据。
- `willdeep-rs/PRODUCT_OVERVIEW.md:41`：rs 现行的「忙碌时入 Runtime 队列」口径。同文件第 257 行的旧描述已与代码不符。
