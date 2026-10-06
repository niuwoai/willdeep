# 插件 MCP 工具进主会话：方案

> 状态（2026-10-06）：第 0 步「卸下宿主自带短剧工具」1.409.0-rc7 落地；第 1、2 步「真实参数表」「工具表预热」1.410.0-rc1 落地；其余待做。
> 目标场景：在 WillDeep 主会话里驱动 willdeep-video-studio 插件完成整部短剧（出图、审核、配音、出视频、合成），
> 并在对话里直接看图、看视频、听配音做人工检查，不再依赖 Claude Code。

## 现状（代码核对于 develop d7ce492f）

已经可用：

- 启用的插件，其 MCP 服务的每个工具以 `mcp__<server>__<tool>`（点换下划线）挂进主会话，不用打开插件页
  （`AgentPluginMCPToolCatalog.swift`、`AgentToolRegistry.tools(pluginMCPTools:)`、`AgentMCPBridge.callPluginToolForModel`）。
- 插件对宿主的反向请求（`willdeep/images/generate`、`willdeep/ai/complete`）在主会话发起的调用里照常可用，主会话、插件页、网关共用一条连接。
- 助手回复里单独一行 `![](</绝对路径.mp4>)`、`[x](</绝对路径.wav>)` 会渲染成播放器（`AgentTranscriptMedia.swift`）。

阻碍（按影响排序）：

| # | 问题 | 位置 |
| --- | --- | --- |
| 1 | 插件工具只给模型一个 `arguments_json` 字符串参数，`inputSchema` 被丢弃，参数全靠猜 | `AgentPluginMCPToolCatalog.swift` `parseTools`、条目 `:113-140` |
| 2 | 工具表是缓存，只在手动刷新 / 模型调 `list_mcp_tools` / 网关拉起后才有；启用插件后主会话看不到 | `AgentPluginRegistry`、`AgentMCPBridge` |
| 3 | 单次 stdio 请求等 `startupTimeout`，超时直接结束插件进程；进度通知不续期 | `AgentMCPBridge.swift` `waitForResponse :877-905` |
| 4 | 每个服务一条串行队列：长调用期间 `jobs.status`、插件页请求都排队；「停止」打断不了等待 | `MCPStdioConnection :450-490` |
| 5 | 工具结果里的视频 / 音频 / 文件路径不渲染，只有助手自己写的独立 Markdown 行才出播放器；图片缩略图藏在折叠的工具卡里 | `AgentMCPToolResultContent.swift`、`AgentToolCallViews.swift:167` |
| 6 | 插件技能只认带 `SKILL.md` 的目录，`read_skill` 只能读本目录 | `AgentSkillDirectory.swift:427-432` |
| 7 | 审批：`destructiveHint` 被忽略，插件工具一律登记为写操作；按服务器信任级别，不能按插件一次授权 | `AppStateAgentToolDecisions.swift:793-865` |

插件侧（video-studio 0.41.0-rc3）已先行缓解 3、5、6：`startup_timeout_sec` 调到 180；技能写明把产出按「单独一行 + 尖括号绝对路径」贴进对话；
`skills/creative/SKILL.md` 让写作指南能被发现。

## 方案

### 第 0 步（已做）：卸下宿主自带短剧工具

`AgentToolPackCatalog.unmountedPacks = [.shortDrama]`：不进工具表、不进 `load_tool_pack` 目录、专家激活不再自动加载；
模型按名字调用当未知工具，并指路到 `mcp__video-studio__*`。宿主页面按钮、小部件动作不经模型，照常可用。
恢复只需从集合里去掉 `.shortDrama`。

### 第 1 步：真实参数表（解决 1，收益最大）

- `AgentPluginMCPToolEntry` 存 `inputSchema`（原样 JSON），工具描述器增加 `rawJSONSchema` 可选字段；
  各模型客户端（Anthropic / OpenAI Chat / Responses / Gemini）构建工具定义时，有 `rawJSONSchema` 就直接用，不再走 `AgentToolParameter` 列表。
- 调用时参数对象原样转发给 `tools/call`；兼容期仍接受 `arguments_json`（旧会话历史里的调用）。
- schema 过大时（> 8 KB）截掉 `description` 里的长文本、保留结构；超过上限的工具退回 `arguments_json` 并在描述里写明。
- 风险：部分 provider 对 JSON Schema 子集有限制（`oneOf`、`$ref`）。做一次规范化：展开本地 `$ref`，`oneOf` 降级为宽松对象，并加快照测试。

### 第 2 步：工具表自动预热（解决 2）

- 插件启用、App 启动、插件升级后，在后台对其 MCP 服务发一次 `tools/list` 写缓存（不阻塞 UI，失败只记日志）。
- 处理 `notifications/tools/list_changed`：收到即刷新缓存，下一轮模型请求生效（复用 1.409.0-rc4 的免重启刷新路径）。

### 第 3 步：超时与并发（解决 3、4）

- 拆开两个超时：`startup_timeout_sec`（拉起与 `initialize`）与 `tool_timeout_sec`（单次 `tools/call`，默认 300，插件可在 `mcp.json` 声明，上限 900）。
- 收到 `notifications/progress` 时为对应请求续期；超时只让这一次调用失败、发 `notifications/cancelled`，**不结束进程**（进程挂死另由心跳判断）。
- `MCPStdioConnection` 改为按 JSON-RPC id 路由的多路复用：多个请求可同时在途，读线程按 id 分发响应；插件端（video-studio 是单线程）收到的并发请求自然排队，但宿主侧不再互相阻塞，`jobs.status` 可以插队给快速只读工具（按 `readOnlyHint` 走独立队列也行）。
- 「停止」时对在途调用发 `notifications/cancelled` 并立即结束等待。

### 第 4 步：工具结果里的媒体（解决 5，人工检查的关键）

- 结果解析增加三种来源：`resource_link`（file:// 或绝对路径）、`structuredContent` 与文本 JSON 里已知字段（`filePath`、`outputPath`、`playbackURL` 中的本地路径）、`data:` URL。
- 按扩展名归类为图片 / 视频 / 音频，挂到 `AgentToolResult.mediaAttachments`；工具卡**折叠时**也在卡片下方显示一条媒体条（图片缩略图、视频首帧 + 播放按钮、音频波形 + 播放），复用 `AgentTranscriptMediaAttachmentCell`。
- 每个结果最多显示 8 个，其余折叠为「还有 N 个」；只显示存在且可读的本地文件。
- 系统提示（`AgentContextBuilder.swift:676` 附近）补一句：给用户检查的媒体用单独一行 Markdown 贴出，绝对路径用尖括号包住。

### 第 5 步：技能与审批（解决 6、7）

- 插件技能根目录下没有 `SKILL.md` 的子目录，按目录名生成只读技能条目；`read_skill` 允许读同一插件 `skills/` 根下的文件。
- 插件工具调用时，主会话激活该插件的主技能（video-studio 的 `SKILL.md`）作为提示建议，而不是等用户点名。
- 审批：尊重 `readOnlyHint`（免审批）与 `destructiveHint`（总要确认）；插件页提供「信任这个插件的工具」开关，按插件持久化；计费工具（插件声明 `annotations.billable` 或带 `requestID` 参数）在智能审核下默认放行但在对话里标注「计费」。

## 顺序与验收

1. 第 1、2 步一起做（一个版本）：验收 = 新会话里不点任何刷新，直接说「看看《回村养鸭》第 9 集进度」，模型用正确参数调 `mcp__video-studio__drama_get_progress` 成功。
2. 第 3 步：验收 = 主会话里同步调 `image.generate`（约 90 秒）不被结束；同时插件页仍可翻页；按「停止」立刻返回。
3. 第 4 步：验收 = 出完第 9 集首帧后，对话里直接看到候选图；成片合成后对话里能播放 `第09集.mp4`、能播放一句配音。
4. 第 5 步按需。

willdeep-rs 对应改动（不需要媒体渲染）：拆分单次调用超时（`mcp.rs:653`、`plugin/package.rs:455`）、加载插件 `skills/` 为技能根、`readOnlyHint` 免审批，另起文档。
