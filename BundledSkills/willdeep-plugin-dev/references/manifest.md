# 清单参考：`.willdeep-plugin/plugin.json`

JSON Schema 在仓库的 `docs/plugin-schema/willdeep-plugin.schema.json`，本文是它的说明版。字段名区分大小写，未知字段会被拒绝。

## 两份清单的分工

| 文件 | 决定什么 | 缺了会怎样 |
| --- | --- | --- |
| `.codex-plugin/plugin.json` | 插件 ID、版本、Codex 兼容元数据 | 包不成立 |
| `.willdeep-plugin/plugin.json` | 宿主贡献（目的地、页面、侧栏、命令、菜单、设置、权限、依赖） | 仍可被发现并提供 Skill/MCP，但不会有一级入口 |

## 顶层

```json
{
  "$schema": "../../docs/plugin-schema/willdeep-plugin.schema.json",
  "schemaVersion": 1,
  "minimumWillDeepVersion": "1.280.0",
  "contributes": { },
  "permissions": [],
  "networkDomains": [],
  "dependencies": { "mcpServers": [], "skills": [] }
}
```

- `schemaVersion` **必填**，当前只接受常量 `1`。更高的值会被拒载（不是忽略）。
- `contributes` **必填**。
- `networkDomains`：`net.fetch` 的主机白名单，见下面同名一节。
- `minimumWillDeepVersion`：不满足时保留记录但拒绝启用。
- ID 的格式是 `^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$`；本地化 key 不能含空白字符。

## contributes.destinations

必填：`id`、`titleKey`、`mainPage`。

| 字段 | 说明 |
| --- | --- |
| `id` | 目的地 ID，宿主内的完整身份是 `<plugin-id>:<id>` |
| `titleKey` | 一级入口标题的本地化 key |
| `icon` | `sf:<SF Symbol 名>`，例 `sf:checklist` |
| `mainPage` | 引用 `pages[].id` |
| `companionSidebar` | 引用 `sidebars[].id`；不写等于 `sessionList` |
| `toolbarCommandIDs` | 页面工具栏上的命令 ID 数组 |
| `defaultPinned` | 仅 `bundled` 来源有效，其它来源被忽略 |

## contributes.pages

必填：`id`、`runtime`。

| runtime | 还要给 | 渲染方式 |
| --- | --- | --- |
| `localWeb` | `entryPath`（包内 HTML 文件的相对路径） | 隔离 WKWebView |
| `mcpApp` | `server` + `resourceURI`（必须是 `ui://` 开头，且与 MCP 端一致） | 隔离 WKWebView |
| `declarative` | `schema`（包内 JSON 路径） | SwiftUI 原生 |

`mcpApp` 的资源必须返回 `text/html;profile=mcp-app`。`entryPath` 要指到具体文件，指到目录会加载失败。

## contributes.sidebars

必填：`id`。

| 字段 | 说明 |
| --- | --- |
| `mode` | `sessionList`（默认）、`declarative`、`none` |
| `schema` | `declarative` 模式的包内 Schema 路径 |
| `resource` | `{ "type": "mcpResource", "server": "<id>", "uri": "<uri>" }`，两个字段都必填 |

同时给了 `schema` 和 `resource` 时，resource 是主源、schema 是失败时的兜底。resource 读取时机：进入目的地、宿主刷新 generation 变化、用户手动刷新，以及订阅到 `notifications/resources/updated`。没有高频轮询。

声明式组件：`section`、`list`、`row`、`label`、`icon`、`badge`、`status`、`progress`、`button`、`disclosure`、`separator`、`emptyState`、`loadingState`、`errorState`。文档上限 1000 个组件、20 层嵌套、1 MiB；ID 必须唯一；引用的命令必须存在；`progress` 只能取 0…1。声明式 UI 不执行脚本，也不接受 CSS 和任意坐标布局。

## contributes.commands

必填：`id`、`titleKey`、`handler`。`handler.type` 三选一：

```json
{ "type": "host",     "action": "plugin.refresh" }
{ "type": "mcpTool",  "server": "issue-manager", "tool": "list_issues" }
{ "type": "navigate", "destination": "issues" }
```

`host` 的 `action` 只有五个合法值，其它一律拒绝：

| action | 效果 |
| --- | --- |
| `plugin.refresh` | 刷新当前目的地 |
| `destination.select` | 设置侧栏选中项，参数取 `itemID` 或 `id` |
| `settings.mcp` | 打开设置里的 MCP 分区 |
| `plugins.open-center` | 跳到插件中心 |
| `session.open` | 切换并打开指定 Agent 会话，参数 `sessionID`（UUID 字符串）；**要求插件声明 `conversation.read`** |

任意 selector、类名、脚本文本都会被拒绝——这里不是执行任意代码的地方。

`session.open` 是目前唯一带权限门的 host action：其它四个是零权限的导航动作，它要读会话所以复用 `conversation.read`。四种失败会给出可区分的错误：没声明权限、`sessionID` 缺失或不是合法 UUID、会话目录尚未装载完成（App 刚启动那几秒）、会话不存在或已损坏。跳转成功后主区会切到聊天，插件页被顶掉——这正是「打开会话」的语义。

`mcpTool` 命令在执行前会弹确认，显示插件名和命令名。**例外**：随 App 签名发行的 `bundled` 插件不逐条确认（它们和宿主是同一份签名产物）。本地安装与 Codex 缓存来源每次执行都要用户点头。

## contributes.menus

对象，键必须是这六个位置之一，值是命令 ID 数组：

| 位置 | 出现在哪 |
| --- | --- |
| `commandPalette` | 命令面板 |
| `session.context` | 会话右键菜单 |
| `composer.more` | 输入区「更多」菜单 |
| `plugin.page.toolbar` | 插件页面工具栏 |
| `plugin.sidebar.row.context` | 插件侧栏行右键菜单 |
| `chat.selection` | 聊天正文选中文字后的气泡与右键菜单 |

`chat.selection` 的命令被点中时，宿主固定传两个参数：`text`（选中的原文，已按聊天导出的净化规则处理）和 `source`（固定 `"chat.selection"`）。内置的「添加到任务」永远排第一，插件项按安装顺序接在后面。参考实现见 `PluginExamples/favorites`。

## contributes.settings

必填：`id`、`type`、`titleKey`。`type` 取 `string`、`number`、`boolean`、`enum`、`secret`。

- `enum` 要给 `options`。
- `defaultValue` 必须与类型相符（数字、布尔或枚举成员），否则拒载。
- `secret` 写 macOS Keychain，不进清单、日志和 UserDefaults。
- 在 `mcp.json` 里引用设置值用 `${setting:<id>}`。

## networkDomains

数组，可选。`window.willdeep.net.fetch` 能访问的主机白名单，要与 `network.access` 权限一起用：

```json
{ "networkDomains": ["api.example.com", "*.cdn.example.org"] }
```

`network.access` 只回答「这插件要不要联网」，用户在安装面板上还有权知道**联的是谁**。所以空着（或不写）等于页面一个请求都发不出去，声明了权限不等于随便连。`*.example.com` 匹配子域但不匹配裸域名，两个都要就写两条。回环与内网地址写进来也没用，宿主一律拒。

## permissions

数组，可选值：

| 权限 | 给什么 | 状态 |
| --- | --- | --- |
| `conversation.read` | 页面上下文里多一个 `sessionReference`；`events.on` 订阅会话与回合事件 | 已实现 |
| `conversation.write` | `window.willdeep.chat.insert` / `chat.send`：把一句话递给主 Agent | 1.326.0-rc1 |
| `workspace.read` | 页面上下文里多一个 `workspaceReference`；`window.willdeep.fs.list/read/search` | 已实现 |
| `workspace.write` | 页面上下文里多一个 `workspaceReference`；`window.willdeep.fs.write` | 已实现 |
| `process.execute` | 允许加载会起本地进程的 MCP 服务；`window.willdeep.process.run`（非只读命令一律弹确认框） | 已实现 |
| `network.access` | 允许加载会联网的 MCP 服务；`window.willdeep.net.fetch`，**能连谁由 `networkDomains` 决定** | 已实现 |
| `credentials.use` | 使用 Keychain 中的凭据引用 | 已实现 |
| `ai.chat` | `window.willdeep.ai.complete` | 1.300.0-rc5 |
| `ai.image` | `window.willdeep.ai.generateImage`（some.im 白名单模型） | 1.321.0-rc1 |
| `providers.read` | `window.willdeep.ai.providers` | 1.300.0-rc5 |
| `skills.read` | `window.willdeep.skills.list`，以及在 `ai.complete` 里按 identifier 引用技能 | 1.322.0-rc1 |
| `clipboard.write` | 写剪贴板；`window.willdeep.clipboard.write` | 已实现 |
| `notifications` | 发通知 | 已实现 |

权限是**现场核**的：页面调用时按当前启用状态检查，插件被停用即刻失效。安装预览会显示与上一版的权限差异，新增权限需要重新批准。

## dependencies

```json
{ "mcpServers": ["issue-manager"], "skills": ["issue-triage"] }
```

只是声明，宿主据此在插件中心提示缺失的依赖，不会替你安装。

## 本地化

所有 `titleKey` / `subtitleKey` / `descriptionKey` 都要在 `.willdeep-plugin/locales/<locale>.json` 里给值。**英文 locale 缺键或为空直接拒载**；其它语言缺失时回落英文。

## 一份最小可用清单

```json
{
  "schemaVersion": 1,
  "minimumWillDeepVersion": "1.280.0",
  "contributes": {
    "destinations": [
      { "id": "main", "titleKey": "destination.main", "icon": "sf:square.grid.2x2", "mainPage": "main.page" }
    ],
    "pages": [
      { "id": "main.page", "runtime": "localWeb", "entryPath": "ui/dist/index.html" }
    ],
    "sidebars": [
      { "id": "main.sidebar", "mode": "none" }
    ]
  },
  "permissions": [],
  "dependencies": { "mcpServers": [], "skills": [] }
}
```
