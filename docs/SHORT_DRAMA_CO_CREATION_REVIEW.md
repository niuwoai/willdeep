# 短剧工坊 AI 共创方案评审

日期：2026-09-09  
评审对象：`docs/SHORT_DRAMA_CO_CREATION_HARNESS_PLAN.md`  
代码基线：`main`，`6d1176b0`，`1.342.0-rc25`  
本轮只读核对，未修改业务代码、未提交、未调用付费模型。

## 一、结论先行

方案方向成立：**复用现有 `ai.complete` 做固定步骤共创，足以覆盖首版需求**。当前通道根本不支持工具循环（`tools` 走默认空数组），所以「要不要上 harness」在首版不是取舍题，而是需要额外宿主改造才谈得上的事，暂不需要论证。

但方案文档里有两处判断与源码不符，会直接影响排期与设计：

1. **输出预算 4096 不是真的约束，因为这个字段压根没生效。** 插件传的 `maxOutputTokens` 被解析、被 clamp，然后被丢弃。好消息是长文本输出不受 4096 限制；坏消息是这是一个骗人的 API，文档还在教插件作者用它。
2. **「取消」不是待核实项，是确定不存在，且比文档设想的严重。** 关页面不会中止请求，只会让请求变成孤儿继续跑完、继续烧 token。

另外文档没写但会硌到实现的三件事：插件 KV 存储只有 1MB（聊天记录放不下）、插件 AI 通道没有任何并发上限（批量生成会直接打爆）、内嵌副本与独立仓库已分叉两个 minor。

## 二、已验证事实

### 宿主桥接（Swift）

| 事实 | 证据 |
| --- | --- |
| 输入上限 24 条消息、合计 32,000 字符，且 **system 消息也计入这 32,000 字** | `Xedit/AgentPluginAIBridge.swift:36-37`，累加逻辑 `:197-198` |
| 技能正文另算预算，最多 3 个、每个 8,000 字，由宿主读盘注入 | `AgentPluginAIBridge.swift:40-43`、`:366-370` |
| `maxOutputTokens` 解析并 clamp 到 `[16, 4096]` | `AgentPluginAIBridge.swift:207-212` |
| **该值之后再无消费点**，`runPluginAICompletion` 调 `streamChat(messages:)` 不带它 | `AgentPluginAIBridge.swift:373`；`AgentClient.swift:148-154` 签名无 max tokens 形参 |
| 真实 `max_tokens` 来自 adapter 全局设置，与插件请求无关 | `AgentClientAnthropic.swift:738` ← `AgentSettingsStore.loadAnthropicMaxOutputTokens()`（`:44-48`） |
| 宿主文档明示该字段生效，属于错误描述 | `BundledSkills/willdeep-plugin-dev/references/page-api.md:80`、`docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md:34` |
| 现有测试只断言 clamp 结果，不覆盖是否落到请求里 | `XeditTests/AgentPluginSystemTests.swift:975` |
| 无取消：无 Task 句柄、无 streamID 到请求的映射、无 cancel 命令 | `AgentPluginAIBridge.swift:352-386`；`AgentPluginPageHost.swift` 命令清单 `:345-446` 与 `didReceive` `:861-900` |
| `tearDown` 只发一条 MCP teardown 并移除 message handler，不中止任何请求 | `AgentPluginPageHost.swift:663-677` |
| 页面关闭后 Task 未被持有仍继续跑，`self` 为 nil 时增量与结果静默丢弃 | `AgentPluginPageHost.swift:1056-1057`、`:1122` |
| 无并发上限，尽管文件头注释声称有 | `AgentPluginAIBridge.swift:12-13` 与实现不符；未找到任何 semaphore/inflight 计数 |
| 无工具循环，只消费 `.textDelta`，其余事件丢弃 | `AgentPluginAIBridge.swift:373-374` |
| 无流结束/错误事件，页面只能靠 promise resolve 判断结束 | `sendAIDelta` 是全仓唯一 dispatch 点，`AgentPluginPageHost.swift:1120-1131` |
| 每个 token 一次 MainActor 跳板加一次 `evaluateJavaScript`，无节流 | `AgentPluginPageHost.swift:1057` |
| Provider 路由三分支：默认走压缩档 flash、用户 provider 库、本地 Ollama；页面传的 baseURL 完全不参与 | `AgentPluginAIBridge.swift:417-459`；validator `:200-229` 不读 baseURL |
| 插件 KV 存储：单值 64KB、单插件合计 1MB，超限报错不静默丢 | `Xedit/AgentPluginHostCapabilities.swift:229-234` |
| `defaultOutputTokens = 512` 是死常量，全仓无引用 | `AgentPluginAIBridge.swift:39` |

### 插件前端

- `App.tsx` 全文 470 行，`bridge.ts` 57 行。整个插件页比方案文档暗示的规模小得多，这是好消息：改造面小。
- `askPlanner`（`App.tsx:196-238`）已经是多轮 `messages` 加流式，且已经在传 `maxOutputTokens: 3000`（无效）。它**不落库**，落库在 `confirmPlan()`（`:240-251`）。
- 策划聊天是纯 React state（`:71-72`），`openPlanning()`（`:186-193`）每次进入直接清空。刷新即丢。
- 角色、分集、分镜三区**零 AI 入口**。全文 `ai?.complete` 只命中 `askPlanner` 一处；另外三处 AI 调用都在图像与视频侧。
- 台词已经是结构化的 `DialogueLine[]`（`types.ts:2`），`Episode.script` 是自由字符串（`:9`），两者之间没有任何转换或同步代码。
- `parseDramaPlan`（`bridge.ts:40-57`）唯一硬校验是 `title` 非空，`episodes` 数组元素内部完全不校验。
- `ui/dist` 已提交进 git，改 UI 必须 `yarn build` 并把产物一起提交。
- 前端已有 vitest 三个测试文件共 288 行，`yarn test` 运行。

### 插件后端

- **所有短剧装在一个 `dramas.json` 里**，`MAX_DRAMAS = 100` 超出静默截断（`drama_store.rb:10`、`:98`）。落盘在 `~/Library/Application Support/WillDeep/plugin-data/willdeep-video-studio/dramas.json`。
- 写路径 `flock(LOCK_EX)` 加临时文件 `rename`，无 `fsync`；读失败一律 `raise Unavailable`，拒绝按空档覆盖（`:87-93`、`:95-103`、`:142-156`）。这一层是可靠的。
- **每部剧内无任何修订号**，只有 `createdAt` / `updatedAt`（`:41-60`）。跨调用（先 `drama.get` 再 `drama.save_*`）是后写覆盖，无乐观锁。
- `save_*` 是局部合并不是全量覆盖，`assign` 遇 nil 跳过（`drama_service.rb:244-247`）。这一点对保护手改很有利，可以直接复用。
- 唯一幂等机制是 `confirm_plan` 的 `requestID` 去重（`:61-65`）。
- `drama_store.rb:86` 那条「并发保存会丢更新」的注释与当前代码不符，读已经在锁内，注释是陈旧残留，建议顺手删掉。
- 10 个 drama MCP 工具**没有端到端测试**，`scripts/video_studio_server_test.rb` 全文零命中 drama。存储层测试是 `scripts/video_studio_drama_test.rb`，钉死跑在 `/usr/bin/ruby` 2.6 上。

### 两套插件已分叉

内嵌副本 `PluginExamples/video-studio` 版本 0.3.2，独立仓库 `/Users/rocky/Sites/willdeep-video-studio` 停在 0.2.1（最后提交 2026-09-04）。差异覆盖 `App.tsx`、`bridge.ts`、`types.ts`、`drama_service.rb`、`drama_store.rb`、`plugin.json`、locales。独立仓库独有 GitHub Actions 发布流水线、`schema/`、`scripts/`、`PRODUCT_OVERVIEW.md`；内嵌副本独有 `Dropdown.tsx` 与更新的功能。**开工前必须先定唯一维护源**，否则每一项改动都要做两遍且必然再分叉。

## 三、对方案的取舍建议

### 可以砍掉的（过度设计）

- **不要建独立的草稿存储层。** 给每个对象加一个同结构的 `draft` 字段加一个 `rev` 整数即可，复用现有 `save_*` 的局部合并语义。文档第 5 节那套「请求 ID、依据草稿修订号、上游资料版本」的完整追踪，首版只保留三件：对象 `rev`、请求发出时携带的 `rev`、回来时比对 `rev`。
- **不要先定义完整的候选状态机。** 前端一个 `pending | ready | failed` 足够，状态集不必落进存储契约。
- **不要做上游变更提示。** 文档第 6 节的依赖版本记录与「设定已更新请复核」延后到分集阶段再评估。
- **不要碰台词跨资料同步。** 现状是剧本与分镜台词之间零联系，不存在「无提示地失去联系」的风险，因为本来就没有联系。到分镜阶段再选方案，首版明确写「不同步」即可。
- **不要做上下文压缩。** 32,000 字符撞墙时直接报错并提示缩小范围，比先造一套压缩管线便宜得多。

### 必须补上的（文档遗漏）

- **并发闸。** 每个页面同时在跑的 `ai.complete` 上限（建议 2）。批量生成角色是用户迟早会点的按钮，现在没有任何东西拦着它发 20 个并发请求。
- **孤儿请求。** 关页面必须真取消，否则用户关掉插件页后还在被计费。
- **聊天记录的落点。** 插件 KV 只有 1MB 且单值 64KB，多轮共创聊天几轮就顶到单值上限。聊天必须进 Ruby 侧，且**建议独立文件**（如 `chats.json`），不要塞进 `dramas.json`：那个文件每次保存都是全量重写全部短剧，把聊天写进去等于每发一条消息重写整库。
- **输入预算器。** 32,000 字符是含 system 的总量，撞上是 validator 直接抛错不是截断。前端要在发请求前估算并给出可读提示。
- **drama MCP 层的测试。** 加 `rev` 与 `expectedRev` 会改 10 个工具的 schema，而这一层现在零回归保护。

### 完整对象还是字段级：建议「完整对象 + 白名单裁剪」

模型返回当前对象的完整候选，但应用只把 `fieldScope` 白名单内的字段合并进草稿，白名单外的一律丢弃。这样既不用写 JSON Patch 执行器，也不靠提示词保证其他字段不变，而且差异预览天然可算。用户没有指定局部时，`fieldScope` 就是全字段。

## 四、建议首版范围

### X 阶段：宿主三项小改（Swift）

1. **X1 取消通道。** `streamID` 到 Task 的映射表，新增 `aiCancel` 桥接命令，`tearDown` 时取消该页面全部在跑请求。同时把 `runAICompletion` 的 Task 持有起来。
2. **X2 每页面并发上限。** 超限时明确报错，不排队。
3. **X3 `maxOutputTokens` 二选一。** 要么真接到 adapter，要么删掉字段并订正 `page-api.md:80` 与 `PLUGIN_HOST_CAPABILITIES_DESIGN.md:34`。留着一个骗人的参数是最差选项。顺带修正 `AgentPluginAIBridge.swift:12-13` 那条与实现不符的注释。

可选加项：`willdeep:ai-done` / `willdeep:ai-error` 事件，让页面不必只靠 promise 判断结束。首版可不做。

### R 阶段：后端最小改造（Ruby）

4. **R1** 给 character / episode / shot 加 `rev`（整数，每次保存自增）与 `draft`（同结构对象，可为 null）。
5. **R2** `save_*` 接 `expectedRev`，不匹配返回明确的冲突错误码，不静默覆盖。旧的直接保存路径一并纳入。
6. **R3** 新增 `drama.saveDraft` / `drama.commitDraft`，采用即把 draft 合并进正式内容并清空 draft、自增 rev。
7. **R4** 聊天独立文件与读写工具（`chat.append` / `chat.list`），范围键为「项目 + 阶段」，消息体带对象 ID。
8. **R5** 迁移：旧数据缺 `rev` 视为 0，缺 `draft` 视为 null，保留原文件与现有 ID，不默认为已定稿。
9. **R6** 给 drama 的 MCP 工具补端到端测试，纳入 `scripts/run_tests.sh`。

### U 阶段：角色共创闭环（前端）

10. **U1** 角色区加对象选中态与聊天区，聊天走 R4 持久化。
11. **U2** 角色 AI 请求：构造 system 加当前草稿加相关策划资料加近期对话，带 `fieldScope`，带 `rev`。
12. **U3** 结果解析与校验，复用并加固 `parseDramaPlan` 的思路，失败保留已写内容。
13. **U4** 差异预览与采用，差异由前端计算，不采信模型自述。
14. **U5** 停止按钮接 X1，迟到增量按 `streamID` 丢弃。
15. **U6** 输入预算器与超限提示。

角色闭环跑通后再抽公共层，不要先建通用插件开发框架。方案文档第 3 节那四个抽象（对话流程、上下文装配、草稿流程、阅读界面）方向对，但应当是从角色代码里抽出来的，不是先写好再往里填。

## 五、角色闭环验收

方案文档第 8 步的六条验收清单合理，建议按原样执行，并补两条：

7. 关闭插件页后确认底层请求真的停止（看宿主日志或 provider 侧无后续消费）。
8. 同时发起超过并发上限的请求，确认被明确拒绝而不是全部发出。

推广顺序建议不变：策划迁入同机制、分集剧本、分镜、首尾帧描述。每接一个阶段跑真实对话流程，不只测 Schema 解析。

## 六、关键风险

- **计费风险最高的是孤儿请求加无并发闸**，这两条在 X 阶段解决前不要做任何批量生成入口。
- **`dramas.json` 单文件加 100 部上限**，草稿字段会让文件明显变大，每次保存是全量重写。首版可接受，但要在文档里记下这是已知的写放大点。
- **两仓分叉**，不先定唯一源，X/R/U 三阶段的产出会立刻再分叉一次。
- **`ui/dist` 提交纪律**，忘了 `yarn build` 就是装了旧产物且没有任何报错。

## 七、待确认问题

1. 唯一维护源选内嵌副本还是独立仓库？独立仓库有发布流水线但落后两个 minor，内嵌副本有更新功能但无 CI。
2. 聊天存独立文件还是塞进 `dramas.json`？本文建议独立文件。
3. `maxOutputTokens` 接通还是删除？
4. 首版是否接受「完整对象加白名单裁剪」，不做字段级协议？
5. `MAX_DRAMAS = 100` 的静默截断是否需要在这一轮改成显式报错？
