# 跨项目聊天历史回溯插件（history-recall）设计

> 状态：已实现（1.316.0-rc1）
> 落点：插件 `PluginExamples/history-recall/`；宿主 `session.open` host action；
> 测试 `scripts/history_recall_server_test.rb`、`XeditTests/AgentPluginSystemTests`；
> 预览 `scripts/history_recall_preview_server.cjs`
> 插件 ID：`willdeep-history-recall`　显示名：历史回溯 / History Recall
> 相关文档：[WILLDEEP_PLUGIN_SYSTEM_DESIGN.md](WILLDEEP_PLUGIN_SYSTEM_DESIGN.md)、[PLUGIN_HOST_CAPABILITIES_DESIGN.md](PLUGIN_HOST_CAPABILITIES_DESIGN.md)、[PLUGIN_DEVELOPER_GUIDE.md](PLUGIN_DEVELOPER_GUIDE.md)

## 1. 要解决的问题

用户的原话是「有时记不清在哪个会话里聊过天了」。本机实测：五周内积累 474 个会话，其中有内容的 253 个，分布在 20 个工作区/项目下。跨项目找回一段旧对话目前没有可用手段。

现状的三个缺口：

| 手段 | 覆盖 | 缺什么 |
| --- | --- | --- |
| 侧栏搜索（⌘⇧P，`AgentSessionSearchView`） | 全部会话 | **只搜标题**，源码注释写明 `no message full-text indexing here` |
| `search_sessions` 工具（`AgentSessionTools.swift:22`） | 跨项目全文 | **每次只打开最近 40 个会话**（`AgentSessionSearch.Limits.sessionsScanned`），答案落在第 41 个之后就静默返回空 |
| 语义检索 | — | 全 App 无 embedding / 向量 / FTS 设施；`AgentMemoryStore.embeddingModelID` 是没有任何读取方的死设置 |

「静默返回空」是最伤的一条：用户无法区分「确实没聊过」和「聊过但超出扫描窗口」。

## 2. 产品定位：偏定位，不偏代答

已确认的产品口径是**帮用户找回是哪一段对话**，而不是综合历史直接给答案。因此界面主体是「提问 → 命中列表 → 摘录 → 跳过去」，模型只承担两件轻活：把自然语言问题转成检索词，以及给命中结果写一句话的归纳。找到之后的深聊，交回宿主的正常会话。

这条定位决定了几处取舍：不做多轮追问式 RAG，不追求答案完整性，宁可多列几条候选让用户自己认。

## 3. 数据事实（2026-09-01 本机实测）

会话落盘位置 `~/Library/Application Support/WillDeep/agent-sessions/`，定义见 `Xedit/AgentSessionStore.swift:705-712`。

```
474 个会话 JSON        79 MB（目录含侧车共 104 MB，最大单文件 7.2 MB）
catalog-v1/  4.9 MB    sidebar 元数据侧车（不含消息正文）
usage-v1/    20 MB     用量侧车
```

实测口径（脚本全量解析 + 内存匹配，warm cache）：

| 指标 | 实测值 |
| --- | --- |
| 全量解析 474 个文件 | **494 ms** |
| 内存内全文子串检索一次 | **38 ms** |
| 总消息数 / 总字符数 | 26 702 条 / 38.4 M 字符（平均 1 437 字符每条） |
| 字段命名风格 | camelCase **474**，snake_case **0** |
| 已归档会话 | 102 个 |
| 时间跨度 | 2026-07-25 .. 2026-09-01（五周） |

**这组数字直接决定了架构：不建索引。** 冷启动全扫按 session-vitality 的实测口径约 2 秒，之后靠 `(mtime, size)` 签名增量，检索本身是毫秒级。引入 SQLite FTS5 或向量库在这个体量上只增加维护面，不换来体验差异。

### 3.1 必须处理的数据坑

**近一半会话是空壳。** 474 个里有 235 个无任何工作区归属，其中 **221 个是 0 消息、标题「新对话」的空文件**。检索时按「消息数为 0」直接跳过即可，但这意味着：

- UI 上不能假设每个会话都有项目名，需要「未归属」分组；
- 真正可检索的会话是 253 个，不是 474 个。

（空壳堆积本身是独立的数据卫生问题，已另开任务排查，不在本插件范围内。）

**读盘必须显式 UTF-8。** 宿主拉起 MCP server 时不保证带 locale，Ruby 默认外部编码会退成 US-ASCII，读中文会话直接抛 `Encoding::InvalidByteSequenceError`。server 起手必须钉死：

```ruby
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
File.read(path, encoding: "UTF-8")
```

这与 qterm MCP 早前踩过的强制 UTF-8 是同一类坑。

**项目归属靠字段不靠目录。** 全部会话平铺在一个目录，归属键按宿主 `workspaceSidebarGroupKey`（`Xedit/AgentModels.swift:427-449`）的优先级复刻：

```
projectID → "project:<uuid>"
sidebarWorkspaceRootPath（worktree 会话归到主项目）
workspaceLocation（.local(path) / "remote:<uuid>:<path>"）
workspaceRootPath
兜底 "_no_workspace_"
```

必须复刻这个优先级而不是简单取 `workspaceRootPath`，否则 worktree 里的会话会被算成独立项目。本机 `workspaceLocation.kind` 目前只有 `local` 一种形态，但代码要能容下 `remote`。

**projectID 只是 UUID，拿不到项目名。** 项目名在宿主的 `AgentProject` 里，插件 server 读不到。第一版显示工作区路径的末段作为人类可读标签，UUID 作为分组键。

## 4. 架构：一个插件，两张脸

```
willdeep-history-recall/
├── .codex-plugin/plugin.json        身份
├── .willdeep-plugin/
│   ├── plugin.json                  宿主贡献（destination / page / commands / settings）
│   └── locales/{en,zh-Hans}.json    en 缺键直接拒载
├── mcp.json                         stdio server 声明
├── server/                          Ruby stdio MCP server —— 真正干活的一侧
└── ui/index.html                    聊天式检索页面（单文件，零构建）
```

权限：`conversation.read`、`process.execute`、`ai.chat`、`providers.read`。

**「两张脸」是这个方案最划算的地方。** MCP server 一旦存在，它的工具会被 `AgentMCPServerDirectory.loadPluginServers()`（`Xedit/AgentMCPServerDirectory.swift:343-378`）并入全局清单，主 Agent 在任何普通会话里都能直接调用——不需要额外声明，边际成本为零。于是同一套检索能力有两个入口：

1. **插件页面**：专门的「翻旧账」界面，聊天式交互，命中结果可点击跳转。
2. **主 Agent**：用户在任意会话里问「我之前在哪聊过 frp 穿透」，Agent 调工具直接答，不受页面那套单轮 / 32k 字符的限制。

页面侧的能力边界（`Xedit/AgentPluginPageHost.swift`）必须记牢：CSP 写死 `connect-src 'none'`，页面**不能联网、不能读文件**；所有磁盘和网络动作只能由 server 代劳，页面通过 `executeCommand` 调本插件的 MCP 工具。

### 4.1 MCP 工具集

| 工具 | 入参 | 用途 |
| --- | --- | --- |
| `history.search` | `query`、`scope`(all/project)、`group`、`since`/`until`、`include_archived`、`limit` | 全量跨项目检索，返回命中会话 + 摘录 + 归属 + 时间 |
| `history.excerpt` | `session_id`、`message_id` 或 `index`、`radius` | 取某条命中的上下文原文，供「展开看看」 |
| `history.projects` | — | 列出全部归属分组及会话数，供筛选下拉 |
| `history.settings` | `allow_cross_project`（省略则只读） | 读写跨项目检索开关，见第 6 节 |

命中排序按「匹配强度 × 新鲜度」加权，而不是纯按时间倒序——纯时间序正是宿主 `search_sessions` 那个 40 条窗口的病根。

匹配分三档，结果里用 `match_kind` 标出：

- `message` —— 单条消息里所有词都出现，最强
- `session` —— 词分散在会话的不同消息里。**只认单条消息内 AND 会漏掉一大类真实需求**：用户记得的是「那次既聊了审批又聊了裁判」，而不是某一句话里同时出现两个词。评分权重压到三分之一，排序保证强匹配仍在前
- `title` —— 只有标题命中。标题往往是最容易记住的线索（宿主侧栏搜的也正是标题），所以它是独立的一路命中来源，不只是加分项

### 4.1.1 必须剥掉宿主注入块

宿主会把若干上下文块追加进 user 消息的正文。本机实测 **916 条 user 消息里有 171 条（18.7%）** 含这类内容，其中 skill 路由候选列表最毒——它把每个已安装 skill 的完整描述都塞进正文。不剥的话检索「SwiftUI 卡死」命中 27 个会话且**全是假阳性**（剥掉后是 1 个真命中）。

按固定标记截断即可，这些都是宿主生成的文案：`The user attached the following context for this turn`、`[周期任务 · 无人值守执行边界]`，以及成对的 `<system-reminder>` / `<local-command-caveat>` 块。

### 4.2 索引与缓存

不建持久索引，也不落盘缓存。stdio server 是常驻进程，缓存放进程内即可：

- 首次检索全量扫盘建内存索引（warm 494 ms，cold 约 2 秒）；
- 之后每次检索先 `stat` 全目录，按 `(mtime, size)` 签名只重解变化的文件，删除的文件同步逐出；
- 单文件超过 32 MB 跳过，与 session-vitality 同口径；
- 0 消息的空壳会话解析后直接丢弃，不进索引。

**刻意不做落盘缓存。** 检索必须扫正文，而正文缓存的体积就等于原始数据（38.4 M 字符），落盘只省下 494 ms 的解析，却换来缓存一致性、磁盘占用和损坏降级三份复杂度。内存索引常驻期间成本为零，进程重启后重建也只是一次冷扫。若日后实测冷启动确实碍事，再补落盘不迟——那是个局部改动。

**没有定时任务可用**——插件系统的 `contributes.schedules` 只有设计稿没实现（`PLUGIN_HOST_CAPABILITIES_DESIGN.md` 第三节明写「设计中，未实现」），所以索引只能在工具被调用时惰性增量。实测 494 ms 的全扫成本让这个限制无关紧要。

### 4.3 模型的位置

页面用 `window.willdeep.ai.complete` 做两件事，都走宿主压缩档的 flash 模型（默认，页面提供 provider/model 下拉可覆盖）：

1. **提问 → 检索词**：把「上周聊 SSH 穿透那次」转成检索关键词 + 时间范围；
2. **命中 → 一句话归纳**：给每条命中写一句「这次聊的是什么」。

硬约束（`Xedit/AgentPluginAIBridge.swift:30-33`）：最多 24 条消息、总计 32 000 字符、输出上限 4 096 token。摘录喂给模型前必须先截断。**模型不可用时必须完整降级**——检索词退回原始 query 分词，归纳退回首条命中摘录，照抄 todo 插件 `ai.complete().catch(() => null)` 的回落写法。定位功能在没有模型时依然可用，这是产品口径「偏定位」的直接好处。

## 5. 跳转：给宿主加了一个 host action

第一版要求命中结果可点击跳转到对应会话。动手时 host action 只有写死的四个（`Xedit/AgentPluginCommandExecutor.swift`）：`plugin.refresh`、`destination.select`、`settings.mcp`、`plugins.open-center`，没有打开会话的通道。

因此本方案包含一处宿主改动：新增 `session.open` host action，接受 `{ sessionID }`，切换到该会话。具体改动点、权限归属、schema 与文档同步见第 7 节。

## 6. 隐私口径

宿主的 `search_sessions` 把跨项目检索（`scope: "all"`）归为 `.write` 风险档，要走审批卡（`Xedit/AgentToolRegistry.swift:2014-2019`）。插件 server 直接读磁盘，等于绕过这道门。已确认接受这个口径，但插件侧自己补一道：

- 「允许跨项目检索」总开关，**默认关闭**；
- 关闭时 `scope` 只能是当前项目，请求 `all` 返回带可操作提示的错误；
- 页面把这个错误渲染成一张说明卡（而不是一句红字），当场告诉用户开启后会读什么、不会发到哪里，由用户点按钮开启。

**开关刻意不走 manifest 的 `settings` + `${setting:}` 通道。** 那条路只在 mcp.json 的 `env` / `headers` 里展开，而仓库里 7 个插件的 `settings` 全是空数组、没有任何在用的先例；一旦展开不出来，**整条 MCP 服务会被拒载**（`AgentMCPServerDirectory.swift:455`），插件直接哑掉。改由服务端自持久化到 `~/Library/Application Support/WillDeep/plugin-data/history-recall/settings.json`，页面通过 `history.settings` 工具读写。

优先级：环境变量 `WD_HISTORY_ALLOW_CROSS_PROJECT`（测试与高级用户）> 持久化设置 > 默认关闭。环境变量在场时页面开关无效，`current_settings` 会返回 `locked_by_env: true` 如实告诉页面——否则用户会对着一个点了没反应的开关发火。

server 不向任何外部网络发送会话内容，检索与摘录全在本机完成；模型调用走宿主 `ai.complete` 通道，由宿主的 provider 配置决定去向，插件不自带网络出口（不声明 `network.access`）。

## 7. 宿主改动清单（`session.open`）

### 7.1 三个决策

**权限挂 `conversation.read`，不新增权限。** 能拿到 sessionID 的插件才有理由打开它，语义自洽；新增独立权限要多改 schema、白名单、权限表、文档共 4 处，不值。注意现状：`executeHost` **完全没有权限校验**（`Xedit/AgentPluginCommandExecutor.swift:91-118`），另外三个导航类 action 都是零权限的，所以这道门是本次新加的。

**走 `selectAndRevealAgentSessionInSidebar(id:)`（`Xedit/AppStateAgentSessions.swift:2148-2153`），不是裸的 `selectAgentSession`。** 两个理由：本机有 102 个归档会话，而归档会话虽然能被 `selectAgentSession` 打开（该方法不看 `isArchived`），但侧栏行会藏在折叠的归档组里——reveal 版会自动展开（`AgentSessionsSidebar.swift:1427-1434` 的 `prepareWorkspaceForReveal`）；且它返回 `Bool`，便于给页面抛出可区分的错误。

**默认跳到聊天，不保留插件页。** `selectAgentSession` 会置 `agentPrimaryDestination = .conversation`，把插件页顶掉。对「打开会话」这个语义，跳过去正是用户要的。

跨窗口暂不处理（`AgentNotificationResponder.reveal(runtimeID:)` 能跨 AppState，但没有返回值、找不到时静默）。第一版只操作承载插件页的那个 AppState，失败给明确错误。

### 7.2 代码改动（5 处）

| # | 文件 | 改动 |
| --- | --- | --- |
| 1 | `Xedit/AgentPluginPackageLoader.swift:67-72` | `allowedHostCommands` 加 `"session.open"` |
| 2 | `Xedit/AgentPluginCommandExecutor.swift:91-96` | `executeHost` 签名加 `pluginID: AgentPluginID` |
| 3 | `Xedit/AgentPluginCommandExecutor.swift:50-55` | 调用点补传 `pluginID`（已在作用域内） |
| 4 | `Xedit/AgentPluginCommandExecutor.swift:97-117` | 新增 `case "session.open"` |
| 5 | `XeditTests/AgentPluginSystemTests.swift` | 新增用例，见 7.4 |

第 4 处的执行顺序：`hasPermission(.conversationRead, pluginID:)` 不过 → throw；`UUID(uuidString:)` 解析 `sessionID` 失败 → throw；`hasLoadedAgentSessionCatalog` 为假 → throw「目录尚未装载」（App 刚启动时会撞上，必须与「会话不存在」区分开）；`selectAndRevealAgentSessionInSidebar` 返回 false → throw「会话不存在或已损坏」。

参数取值注意：`executeJSON` 的 `.host` 分支把 JSON 参数 `compactMapValues` 成 `[String: String]`，非字符串值会被丢弃——`sessionID` 传字符串 UUID 是安全的。

### 7.3 不用改的

`docs/plugin-schema/willdeep-plugin.schema.json` **一行都不用动**：`handler.action` 是自由字符串（`:126-137`），白名单只在 Swift 侧。`scripts/` 下也没有任何针对插件系统的守卫脚本——代码与文档的一致性守卫写在 Swift 测试里。

### 7.4 测试

照 `AgentPluginSystemTests.swift` 现有模板加三条：白名单接受 `session.open`（照 `:459` 的 loader 全流程写法）、未声明 `conversation.read` 的插件调用被拒（照 `:577` 的 `#expect(throws:)` 写法）、源码守卫钉住「`executeHost` 里有 `case "session.open"` 且调了 `hasPermission`」（照 `:1130` 的 `source.contains` 写法）。

**另有一处必改**：`:659 repositoryExamplesPassTheProductionLoader` 硬编码了 PluginExamples 名单，新插件必须加进那个数组，否则新插件不过生产加载器校验。

### 7.5 文档同步（4 处硬编码了「四个 action」）

| 文件 | 行 |
| --- | --- |
| `docs/WILLDEEP_PLUGIN_SYSTEM_DESIGN.md` | 186（Host Command v1 列表） |
| `BundledSkills/willdeep-plugin-dev/references/manifest.md` | 82-88（「只有四个合法值」＋表格） |
| `BundledSkills/willdeep-plugin-dev/SKILL.md` | 37（「只有…四条」） |
| `BundledSkills/willdeep-plugin-dev/references/page-api.md` | 31（conversation.read 能力描述）、44-58（executeCommand 一节） |

## 8. 实施计划

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **M1** | Ruby MCP server + 四个工具 + 进程内缓存 | 已完成，92 项服务端测试全绿 |
| **M2** | 插件 manifest + 聊天式页面 + 跨项目门禁 | 已完成，预览服务器里走通全流程 |
| **M3** | 宿主 `session.open` host action + 页面跳转按钮 | 已完成，`AgentPluginSystemTests` 全绿 |

### 8.2 实现期间在真实数据上改掉的三件事

夹具测不出来、只有拿 474 个真实会话跑才暴露的问题：

1. **注入块噪声** —— 见 4.1.1。「SwiftUI 卡死」原本命中 27 条全是假阳性。
2. **单条消息内 AND 太严** —— 「审批 裁判」命中 0，而用户记忆里这两件事确实在同一次对话里聊过，只是不在同一句话。加了会话级覆盖这一档。
3. **同名分组无法区分** —— 本机有两个不同归属键都显示成 `muchtoken`（一个按 projectID 分组、一个按路径分组）。加了消歧后缀，并用不变的 `group_label_base` 重算以保证幂等。

另有一处页面缺陷是在浏览器里验收时发现的：展开「看上下文」后容器默认停在顶部，而命中那条在 665px 处——用户点开看到的是命中之前的无关内容。现在展开即把命中滚进视野。

### 8.1 开发与验证回路

插件系统**没有开发模式**：不认软链接（`AgentPluginSystemTests.swift:286` 明确拒绝），安装是复制而非引用，且同版本号内容变了会被 `sameVersionDifferentContents` 直接拒装。也就是说每次改包内容做 GUI 安装都得先 bump `.codex-plugin/plugin.json` 的 `version`。

因此主验证手段是**脱离 App 的 Ruby 测试脚本**，照 `scripts/session_vitality_server_test.rb` 的骨架写：用 `Open3.popen3` 拉起真实 server 子进程走 stdio，并**刻意删掉 `LANG` / `LC_ALL`** 以复现宿主不带 locale 的启动环境（这正是 UTF-8 那个坑的回归测试）。仓库现有三个同类脚本（session-vitality 43 项、todo 81 项、favorites 38 项），都是不依赖 gem 的「check 计数 + 退出码」风格，手工跑，未接入 CI。

页面侧可参照 `scripts/todo_preview_server.cjs`：起真实 Ruby 子进程 + 注入假的 `window.willdeep` bridge，浏览器里直接验收，且它把 `ai.complete` 写成必定 reject，用来验证模型不可用时的降级路径。

## 9. 明确不做

- 不建 SQLite FTS / 向量索引（体量不需要，见第 3 节实测）
- 不做语义检索（宿主无 embedding 通道；如二期要做，server 自带 `network.access` + `${setting:}` 引用 key，不明文）
- 不做流式回答（`ai.complete` 无流式，设计上刻意）
- 不做定时重建索引（插件系统无 schedule 能力）
- 不改宿主的 `search_sessions`（40 条窗口的问题由本插件绕开，不动既有工具的语义与审批档）
