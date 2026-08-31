# Session Vitality（会话体检中心）

WillDeep 样例插件：在插件中心选择本目录即可进入权限预览，批准后安装启用。
仪表盘用的是**会话里真实上报的用量**，不是按消息数估算的。

## 结构

- `.willdeep-plugin/plugin.json` — 目的地 `vitality`：声明式侧栏 + MCP App 页面 + 工具栏命令
- `.willdeep-plugin/schemas/vitality-sidebar.json` — 侧栏 fallback Schema（MCP 资源不可用时显示）
- `.willdeep-plugin/locales/` — en / zh-Hans 本地化
- `mcp.json` — 启动 `session-vitality` MCP 服务（`/usr/bin/ruby`）
- `server/session_vitality.rb` — stdio MCP server：侧栏资源、`ui://vitality/main` 页面资源、`willdeep-plugin://vitality/stats` 统计资源、`vitality.snapshot` / `vitality.export` 两个工具
- `server/app.html` — MCP App 仪表盘：四个主指标、近 14 天输出/请求双维趋势、工作画像、项目与模型排行、最近会话、Markdown 导出

## 权限

- `conversation.read` — 读取会话存储（会话 JSON 元数据）
- `process.execute` — 启动插件自带的 Ruby MCP 服务

## 数据来源与口径

默认扫描 `~/Library/Application Support/WillDeep/agent-sessions`（以及根目录与一层子目录，
兼容旧版落盘与测试夹具）下的会话 JSON，逐个宽容解析，camelCase 与 snake_case 均兼容，
单文件超 32 MB 跳过，坏文件跳过不影响整次扫描。

每条助手消息都带着这次请求的真实用量，指标据此累加：

| 指标 | 口径 |
| --- | --- |
| 输出 Token | Σ `completionTokens`，模型真正生成的量 |
| prompt Token | Σ `promptTokens`，每轮都含全部历史，所以是「累计送进去的」 |
| 缓存命中 | Σ `cachedPromptTokens` ÷ Σ `promptTokens` |
| 计费 Token | Σ `usageTokens`（缺失时退回 prompt + completion），同一段上下文在多轮里会被重复计费 |
| 平均响应 | Σ `elapsedSeconds` ÷ 带用量的请求数 |
| 近 14 天走势 | 按消息 `createdAt` 的**本地日期**落桶 |

会话级的 `workspaceRootPath` / `workspaceLocation.path` 决定项目归属，`modelID` 决定模型归属
（老会话没记 modelID 时退回 `providerDisplayName`）。空壳会话（没有任何消息）计入会话总数，
但不算「有对话的会话」，也不进模型分布与最近会话。时间戳同时支持 ISO8601 与 Apple 纪元秒数。

**性能**：每个文件的摘要按 `(mtime, size)` 缓存在服务端进程里，只有变动过的会话才重新解析。
本机 578 个会话文件（约 130 MB）首次扫描约 1.9 秒，之后刷新 6 毫秒。

未找到会话存储时回退到带 `demo` 标记的演示数据（页面和侧栏都会标注）。
可用环境变量 `WD_VITALITY_SESSIONS_DIR` 覆盖扫描根目录（在 `mcp.json` 的 env 中配置）。

## 命令

- `vitality.refresh` — host `plugin.refresh`，重新读取侧栏与页面资源
- `vitality.snapshot` — 调用 `vitality.snapshot` 工具，返回聚合统计 JSON
- `vitality.export` — 调用 `vitality.export` 工具，返回 Markdown 报告（页面上的「导出 Markdown」按钮会把它复制到剪贴板）

## 页面握手的两条坑

MCP App 页面在 WillDeep 里是 **WKWebView 的顶层文档**，`parent === window`。于是：

1. 页面 `parent.postMessage(...)` 发出去的请求会**原样回到自己的 message 监听器**。
   只按 id 匹配的话，每个请求都会被自己的回声「解决」成 `undefined`——
   这正是此前点「刷新」报 `undefined is not an object (evaluating 'res.contents')` 的病根。
   所以带 `method` 的消息一律不能当响应处理。
2. 宿主在收到 `ui/notifications/initialized` 之前，会用 `-32002` 顶回 `resources/read` 与
   `tools/call`。握手顺序必须是：`ui/initialize` 拿到 hostContext → 发 initialized → 再取数。

`scripts/session_vitality_server_test.rb` 里有这两条的守卫。

## 随 App 发行

`Xedit.xcodeproj` 的 **Bundle built-in plugins** 构建阶段把 `.codex-plugin`、
`.willdeep-plugin`（含侧栏 Schema 与本地化）、`mcp.json` 与 `server/` 复制进
`WillDeep.app/Contents/Resources/BundledPlugins/session-vitality`。页面是服务端发的
MCP 资源（`ui://vitality/main`），所以不需要额外带前端产物。

`bundled` 来源的插件自动获批、默认启用，也不会为自己的 MCP 工具逐条弹确认框；
左侧入口没有声明 `defaultPinned`，要不要固定在侧栏由用户自己决定。

改了插件里的任何文件都要重新构建 App，`BundledPlugins` 才会更新。**注意**：如果
本机还留着一份「从本地安装」的同名插件，注册表里的 `activeVersions` 会继续把它钉在
旧版本上——在插件中心卸载那份，或切到随 App 发行的版本。

## 回归

```bash
ruby scripts/session_vitality_server_test.rb
```

43 项检查覆盖：工具清单、统计资源的 JSON 契约、真实 token 口径、趋势落桶、项目与模型分组、
双维趋势与工作画像页面契约、响应式信息分区、Apple 纪元时间戳、缓存失效、坏文件降级、
演示数据回退、Markdown 报告，以及上面两条页面不变量。
