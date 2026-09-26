# WillDeep 插件系统与可扩展目的地设计

> 状态：v1 已实现
> 首发版本：WillDeep 1.280.0
> Schema：`.willdeep-plugin/plugin.json` schemaVersion 1

> 插件页面还能问模型、读 provider 清单（`ai.chat` / `providers.read`），以及（设计中）被宿主按 cron 叫醒执行命令：见 [PLUGIN_HOST_CAPABILITIES_DESIGN.md](PLUGIN_HOST_CAPABILITIES_DESIGN.md)。

## 1. 目标与边界

WillDeep 插件的核心贡献是 `PluginDestination`，不是孤立菜单或一块 WebView。一个目的地把一级入口、配套侧栏、中央页面、工具栏和命令绑定为同一个不可分割的导航状态。宿主已有的 Skill、MCP、Workflow 与 Widget 继续工作，并可由插件清单声明依赖或贡献点。

v1 支持：

- 左上一级入口，以及随入口同步切换的左下侧栏和中央页面。
- `sessionList`、原生声明式 `declarative`、`none` 三种侧栏。
- 原生声明式页面、隔离的包内 Web App、MCP App 页面。
- 命令面板、会话右键、Composer 更多菜单、页面工具栏和侧栏行菜单。
- 本地目录、ZIP、Git、Codex 缓存与 AI 草案来源。
- 安装前校验、权限预览、启停、固定排序、多版本回滚和卸载。
- JSON Schema、英/中文本地化、Keychain secret 设置和三个样例插件。

v1 明确不支持外部 SwiftUI View、Swift Package、dylib、任意 Swift selector、插件脚本、安装钩子、任意 CSS 侧栏、无提示 AI 启用及在线市场。第一方原生模块仍随 WillDeep 一起编译和签名。

## 2. 目的地与原子切换

```swift
struct AgentPluginDestinationDescriptor {
    let qualifiedID: String             // <plugin-id>:<destination-id>
    let pluginID: String
    let navigation: AgentPluginNavigationDescriptor
    let companionSidebar: AgentPluginSidebarContribution
    let mainPage: AgentPluginPageContribution
    let toolbarCommandIDs: [String]
}
```

```swift
enum AgentPrimaryDestination: Equatable {
    case conversation
    case scheduledTasks
    case dispatchBoard
    case roundtable
    case plugin(String)
    case pluginCenter
}
```

`AgentPrimaryDestination.plugin` 只存一个 qualified destination ID。侧栏和中央页都从 `AgentPluginRegistry` 的同一份不可变 snapshot 解析描述符，因此不会出现入口属于 A、侧栏属于 B、中央页属于 C 的半切换状态。插件在选中时被停用或卸载，宿主切到插件中心并说明原因。

## 3. 导航与配套侧栏

四个原生入口顺序固定，插件组只能位于其下方。最多固定 10 个插件目的地，支持拖拽排序；有插件时末尾显示“更多插件”，没有时显示“添加插件…”。默认、悬停和选中继续使用宿主灰度语义色，插件品牌色不参与选中表达。

第一方随 App 签名发行的内置插件（构建阶段复制进 `BundledPlugins/<plugin-id>`，目前是经典游戏厅、俄罗斯方块、收藏夹、会话体检中心与待办）可以在目的地清单声明 `defaultPinned: true`。宿主会把这类入口稳定放在插件分组顶部并计入 5 个固定名额，用户安装的同名更新仍可覆盖页面实现，但不能取消该入口；非 `bundled` 来源即使声明该字段也会被忽略，第三方插件不能借此抢占导航。

插件界面必须遵循宿主的单色交互规范：导航、开关、菜单、链接式操作和选中状态不得使用 macOS 系统蓝色或插件品牌色，统一通过不同灰度表达默认、hover、按下和选中状态。安装、批准并启用、检查安装源等推动安装流程的主要操作使用黑底白字，确保其在灰度界面中保持明确的视觉优先级；次要和取消操作继续使用灰度文字或描边。该规则是项目级长期视觉约束，新增插件宿主界面时默认适用。

侧栏模式：

| 模式 | 行为 |
| --- | --- |
| `sessionList` | 复用会话与工作区列表，也是未声明侧栏时的默认值 |
| `declarative` | 读取包内 Schema 和/或 MCP Resource，由 SwiftUI 原生渲染 |
| `none` | 不显示配套侧栏 |

声明式组件包括 `section`、`list`、`row`、`label`、`icon`、`badge`、`status`、`progress`、`button`、`disclosure`、`separator`、`emptyState`、`loadingState` 与 `errorState`。文档最多 1000 个组件、20 层嵌套；ID 必须唯一，命令引用必须存在，进度只能为 0…1。

MCP Resource 在进入目的地、宿主刷新 generation 或用户手动刷新时读取；服务支持订阅时，宿主订阅 `resources/subscribe`，收到 `notifications/resources/updated` 或列表变化通知后只刷新对应目的地。失败时保留包内 fallback Schema，并显示原生错误及 MCP 设置入口；v1 不做高频轮询。

## 4. 页面技术方案

| 区域 | 定义 | 渲染 |
| --- | --- | --- |
| 一级入口 | Manifest | SwiftUI |
| 配套侧栏 | JSON Schema / MCP Resource | SwiftUI |
| 插件设置 | Manifest | SwiftUI；secret 写 Keychain |
| 简单页面 | JSON Schema | SwiftUI |
| 复杂页面 | 包内 Web App / MCP App | 隔离 WKWebView |
| 业务能力 | MCP Tools / Resources | 已配置 MCP 服务 |

包内 Web 页面使用非持久化 `WKWebsiteDataStore`，资源只通过 `willdeep-plugin://bundle/` 自定义只读协议加载。协议处理器逐项做规范化路径、符号链接与包根校验，限制单资源大小；外部导航、弹窗、iframe、表单、WebSocket 和 fetch 被导航策略与 CSP 双重阻断。

宿主 Bridge 只暴露：

- `getContext()`
- `selectItem(itemID)`
- `refresh()`
- `executeCommand(commandID, arguments)` —— **resolve 的是 JSON 字符串，不是对象**
  （`sendCommandResult(requestID:result:error:)` 的 `result` 就是 `String?`）。这一条
  属于跨宿主契约：共享插件包一律 `JSON.parse(raw)`，另一端若回对象，页面拿到的是
  `"[object Object]"`，每条命令都在解析那一步炸掉。willdeep-rs 2026-09-14 正是踩了这一条。
- MCP Apps 标准 `ui/initialize` / `ui/notifications/initialized` 握手、上下文通知、`tools/call` 与同服务 `resources/read`

MCP App 资源必须使用与清单一致的 `ui://` URI，并返回 `text/html;profile=mcp-app`；资源与 Bridge 消息均有体积上限。页面不能直接访问文件、网络、进程、Keychain 或 AppState。所有真实动作都必须映射到清单中声明的命令。

## 5. 统一上下文

```swift
struct AgentPluginDestinationContext: Codable {
    let destinationID: String
    let selectedItemID: String?
    let workspaceReference: String?
    let sessionReference: String?
    let locale: String
    let colorScheme: String
}
```

侧栏选中项由宿主持有，并通过 `willdeep:context-changed` 事件推送到页面。工作区与会话仅在插件声明对应权限时提供引用，不传聊天正文或文件内容；真实数据读取继续经过 MCP 与工具权限。

## 6. 包结构与清单

```text
plugin-root/
├── .codex-plugin/plugin.json
├── .willdeep-plugin/
│   ├── plugin.json
│   ├── locales/zh-Hans.json
│   ├── locales/en.json
│   └── schemas/
├── skills/
├── mcp.json
├── ui/dist/
└── assets/
```

`.codex-plugin/plugin.json` 决定插件 ID、版本及 Codex 兼容元数据；`.willdeep-plugin/plugin.json` 只声明宿主贡献。只有 Codex 清单的包仍可被发现并提供 Skill/MCP，但不会自动生成一级入口。对于没有 WillDeep 清单的兼容包，安装预览会根据 `mcp.json` 的 transport 自动推断 `process.execute` 或 `network.access`；用户批准包 digest 后才允许加载 MCP。

```json
{
  "$schema": "../../docs/plugin-schema/willdeep-plugin.schema.json",
  "schemaVersion": 1,
  "minimumWillDeepVersion": "1.280.0",
  "contributes": {
    "destinations": [{
      "id": "issues",
      "titleKey": "destination.issues",
      "icon": "sf:checklist",
      "mainPage": "issues.main",
      "companionSidebar": "issues.sidebar",
      "toolbarCommandIDs": ["issues.refresh"]
    }],
    "sidebars": [{
      "id": "issues.sidebar",
      "mode": "declarative",
      "schema": ".willdeep-plugin/schemas/issues-sidebar.json",
      "resource": {"type":"mcpResource","server":"issue-manager","uri":"willdeep-plugin://issues/sidebar"}
    }],
    "pages": [{
      "id": "issues.main",
      "runtime": "mcpApp",
      "server": "issue-manager",
      "resourceURI": "ui://issues/main"
    }],
    "commands": [],
    "menus": {},
    "settings": []
  },
  "permissions": [],
  "dependencies": {"mcpServers": [], "skills": []}
}
```

所有可见文案必须使用 `titleKey`、`subtitleKey`、`descriptionKey` 等键，并在插件 locale 文件中提供。官方 Web 模板采用 React、TypeScript、Vite、Yarn 与 i18n；协议本身不强制 React。

## 7. 命令与菜单

v1 菜单位置：

- `commandPalette`
- `session.context`
- `composer.more`
- `plugin.page.toolbar`
- `plugin.sidebar.row.context`
- `chat.selection`（1.299.0-rc3 起）：聊天正文选中文字后的气泡与右键菜单。宿主执行这里的命令时固定传两个参数：
  `text`（选中的原文，已按聊天导出的净化规则处理）与 `source`（固定 `"chat.selection"`，供插件区分入口）。
  内置的「添加到任务」永远排在第一位，插件项按安装顺序接在后面。参考实现见 `PluginExamples/favorites`。

菜单位置的白名单在 `AgentPluginMenuLocation.all` 一处定义，加载器校验、`docs/plugin-schema` 的枚举都从它来；
`AgentPluginSystemTests.chatSelectionMenuLocationIsRegisteredInTheSchema` 盯着两边不许劈叉。

命令 handler 仅可为：

- `host`：公开白名单 Host Command。
- `navigate`：跳转到已安装并启用的插件目的地。
- `mcpTool`：调用已配置 MCP Tool；执行前显示插件名和命令名确认。随 App 签名发行的第一方内置插件（`bundled` 来源）例外，不再逐条确认——它们与宿主是同一份签名产物，也没有第三方来源可核对，而收藏夹这类默认入口每翻一次页面就要点一次确认根本无法使用；本地安装与 Codex 缓存来源仍然每次执行都要用户点头。

公开 Host Command v1：`plugin.refresh`、`destination.select`、`settings.mcp`、`plugins.open-center`、`session.open`。任意 selector、类名和脚本文本均被拒绝。

其中 `session.open`（参数 `sessionID`，UUID 字符串）切换并打开指定 Agent 会话，是唯一带权限门的 host action——执行时要求插件声明 `conversation.read`，未声明直接报错。会话目录尚未装载完成与会话不存在是两条不同的错误，便于页面区分提示。

## 7.5 跨宿主兼容（认不出就降级，不拒装）

插件包在 macOS 版（Xedit）与 willdeep-rs（CLI + Web）之间共享，同一份
`schemaVersion: 1` 契约，两端各自实现校验。麻烦出在三张封闭词汇表：权限、
host action、菜单挂载点。一侧先支持了某一项，另一侧原本会把**整个包**判非法，
用户看到的是「装不上」，而真相只是这个宿主还没实现其中一项能力。

2026-09-07 实测：rs 侧因此装不上本仓库自带的三个插件——待办的
`conversation.write`、短剧工坊的 `ai.image`、历史回溯的 `session.open`。

**约定（两端同时生效）**：在 `schemaVersion` 不变的前提下，认不出的词汇与
字段一律记下来并降级，不再中断安装。

| 认不出的东西 | 处理 |
|---|---|
| 权限 | 照收照显示，但授不出任何能力——宿主的每道门问的都是「有没有这一项已知权限」 |
| host action | 命令保留（菜单引用因此不悬空），执行时拒绝并说明原因 |
| 菜单挂载点 | 这一条菜单不显示，插件其余部分照常 |
| 清单字段 | 忽略并记录 |

仍然判非法的只有结构性错误：`schemaVersion` 不认识、引用悬空、重复 ID、
页面缺必填字段、`mcpApp` 的 `resourceURI` 不是 `ui://`、secret 设置没有
`credentials.use`、`networkDomains` 写法不合 schema 的 pattern。

最后一条是刻意不降级的：那份名单是 `window.willdeep.net.fetch` 唯一的门，
不是可选的展示项。`https://example.com`、`example.com:443` 这类写法装得上却
**永远匹配不中任何主机**，插件作者只会拿到一个解释不了的
`networkHostNotDeclared`——一条写法含糊的规则等于一扇关不上的门。
落点 `AgentPluginPackageLoader.isValidNetworkDomain`，rs 侧同名规则在
`plugin/manifest.rs` 的 `is_valid_domain`。

### 包内容的边界：哪些东西不算包的一部分

`.git`、`node_modules`、`.cache` **任意层级、任意类型**都不进 digest，安装时
也一并剪掉。两条约束缺一不可：

1. **排除按路径段判定，不看深度、不看类型。** 插件前端通常在 `ui/node_modules`，
   只在顶层跳过等于没跳：那 5000 个依赖文件既不是插件内容，又要在每次列插件时
   被哈希一遍，还会被复制进两端共用的安装目录。git worktree 在包里留下的 `.git`
   是一个普通**文件**而不是目录，只按目录跳同样漏掉。
2. **指纹与安装剪枝必须认同一份名单。** 一侧跳过、另一侧留下（或反过来），同一个
   包在「装之前」与「装之后」就有两个指纹，安装报 proposalChanged，而错误信息
   看着像并发改写。rs 正是栽在这一条上：那边复制按名字剪任意类型、指纹只跳目录，
   结果带 worktree 的短剧工坊整个包装不上。本仓此前两侧都只处理顶层 `.git`，
   是对称的，没有这个故障——但名单一旦扩大，对称性就要一起维护。

两端还必须用**同一份名单**，否则同一个包在两个宿主里有两个 digest，
「包内容变了」会在两端之间来回误报。落点 `AgentPluginPackageLoader
.digestExcludedPathComponents` 与 rs `plugin/package.rs` 的 `collect_files`。

记录下来的条目在插件中心显示为「本宿主不支持」（rs 侧是 `plugin install` /
`info` / `approve` 的 `unsupported here` 一行）。不显示的话，用户只会看到某个
菜单项不见了或点了没反应，然后以为插件坏了。

落点：`AgentPluginPackageLoader.unsupportedItems(in:)`、
`XeditTests/AgentPluginCrossHostCompatibilityTests.swift`；rs 侧
`plugin/manifest.rs` 的 `UnsupportedItems`。

**页面能力用 `window.willdeep.capabilities` 探测，不要靠宿主名判断。**
判据是能力清单，不是 `version`，两端的号段互不比较大小。

rs 2026-09-14（0.73.0-rc1）把 Web 宿主补到了桥 2.5.0，此前只有 `context`、
`commands`、`ai.complete`、`ai.providers` 四项。现在两端的差集只剩一项：
**rs 没有 `ai.reasoning`**（它的 `ai.complete` 不流式，不发思考增量），
所以那一项不出现在 rs 的 `capabilities` 里——宿主不该声明自己不发的事件，
否则页面会白等一个永远不来的 `willdeep:ai-reasoning`。

桥 2.6.0（本仓 1.377.0-rc1）新增 `ai.images` / `ai.videos`：`ai.complete` 的 user 消息可带
插件生成目录里的图片、视频路径。rs 同步声明 `ai.images`，**不声明 `ai.videos`**——它没有
视频解码器抽帧，带 `videoPaths` 的请求当场拒。两端差集因此是 `ai.reasoning` 与 `ai.videos`。

还有一处差别不体现在能力清单里，但插件作者要知道：**「弹个文件选择框」不是
跨宿主可移植的动作**。本仓的做法是插件自己在 MCP 服务里弹原生框；rs 的界面在
浏览器、服务可能在另一台机器上，那个框会弹在没人看的屏幕上然后超时，所以 rs
宿主把这类命令接管为「浏览器选文件 + 上传」，再把落地的服务端路径按原工具的
形状交回插件。插件两端都不用改，但**新写选文件能力时不要假设原生框可用**。

## 8. 注册、安装与生命周期

```text
发现 → 严格校验 → 权限差异预览 → 用户批准 → 不可变版本安装 → 启用
                                               ↓
                                      停用 / 回滚 / 卸载
```

安装版本位于 `~/.willdeep/plugins/<plugin-id>/<version>/`，运行状态位于 `~/Library/Application Support/WillDeep/plugin-registry.json`。更新不覆盖旧版本；同版本内容 digest 不同会被拒绝。批准记录同时绑定插件 ID、版本、内容 digest 与来源；来源变化、新增权限或未批准 digest 均须重新确认，原版本在安装或更新失败时不受影响。插件中心可按已记录来源检查更新，卸载会移除该插件的所有已安装版本及授权/设置状态。

来源：

- 本地目录或 ZIP。
- HTTPS、SSH 或 `git@host:path` Git 仓库，可指定 branch、tag 或 commit。
- `~/.codex/plugins/cache` 只读发现。
- `~/.willdeep/plugin-drafts` AI 草案。
- App 内置样例/第一方包。

安装器不执行 `postinstall`、npm/yarn install、构建命令或包内脚本。Git 元数据不会复制到安装版本。

### 8.1 插件 MCP 进程：按需拉起与外部客户端网关（1.405.0-rc1）

启用插件只把它的 MCP 服务注册进总列表，不起进程。stdio 进程在第一个请求到来时由宿主的
MCP 客户端（`AgentMCPBridge` 的连接池）拉起：页面 `executeCommand`、模型调插件工具、
设置页「刷新工具」，以及下面的插件 MCP 网关。进程被结束后，下一条请求会再拉起它。

插件 MCP 网关让 Claude Code、Codex 等外部 MCP 客户端不打开插件页也能调插件工具：

- 宿主启动时开一个只绑 `127.0.0.1` 的 Streamable HTTP 入口，地址与 token 写进
  `~/Library/Application Support/WillDeep/mcp-gateway.json`（0600）。端口和 token 首次随机
  生成后沿用；插件启用、停用、安装、卸载后重写其中的 `servers`。
- 端点 `POST /plugins/<pluginID>/<server>/mcp`：Bearer 鉴权、Host / Origin 只认本机；
  `initialize`、`ping`、通知由网关自己应答；其余请求先经宿主 MCP 客户端发一次
  `tools/list` 确保插件已起（顺手刷新聊天用的插件工具目录），再转发到插件自己公布的
  `plugin-data/<pluginID>/mcp-http.json` 入口；插件没公布入口时经 stdio 中转。
- 插件侧无需任何改动。设置 → MCP 的插件服务行提供「复制 Claude Code 连接命令」。

契约与 macOS 实现备注见 [decisions/0001-plugin-mcp-gateway.md](decisions/0001-plugin-mcp-gateway.md)。

## 9. AI 草案

AI 只能调用 `create_plugin_draft`、`write_plugin_draft_file` 与 `inspect_plugin_draft` 在草案根内写入并验证包。路径穿越、符号链接逃逸、超大文件及草案根外路径会被拒绝。工具永远不会安装、批准或启用插件；用户必须在插件中心检查权限和目的地后手动批准。

## 10. 安全不变量

- Manifest、日志和 UserDefaults 不保存 secret；secret 使用 Keychain。
- 插件 `mcp.json` 中的敏感环境变量/请求头只能使用 Keychain 引用或 `${setting:<id>}`，发现明文 token、password、secret 时拒载该服务。
- 所有资源路径经标准化、真实符号链接解析和包根前缀校验。
- WebView 使用独立非持久化数据存储，不共享 Cookie/LocalStorage。
- Bridge 校验插件、当前启用版本、命令 ID、参数键值和大小。
- 声明式侧栏不执行脚本，不接受 CSS、Canvas 或任意坐标布局；包内 Schema 与 MCP 动态 Resource 使用同一套 1 MiB、1000 组件、20 层嵌套、命令引用及本地化校验。
- 每个插件的 MCP 服务使用宿主命名空间隔离，同名 server 不会串到另一个插件；MCP App 只可调用本插件已声明命令及同服务 Resource。
- 插件包限制为最多 20000 个文件、总计 256 MiB、单文件 32 MiB；清单与动态声明式 UI 限制为 1 MiB，Web/MCP App 资源限制为 8 MiB。
- 所有用户可见本地化键必须在英文 locale 中存在且非空，设置默认值需符合数字、布尔或枚举类型。
- MCP 本地进程能力在配置与命令执行时继续显式提示。
- 扫描、hash 与安装 staging 在后台执行，UI 只接收不可变 snapshot。

## 11. 失败与恢复

- 侧栏 Resource 失败：显示 fallback/错误，不影响中央页面。
- 页面加载失败：侧栏继续可用，页面可重载。
- Web 内容进程连续崩溃三次：停止自动重载，并引导用户停用或回滚插件。
- MCP 缺失：显示配置依赖入口。
- 当前插件停用或卸载：回到插件中心。
- Schema 过高、最低版本不满足、资源缺失或 digest 改变：保留记录但拒绝启用。
- 更新失败：继续使用旧版本；用户可手动选择已批准版本回滚。

## 12. 代码落点

- 数据契约：`AgentPluginModels.swift`
- 清单、Schema 与路径校验：`AgentPluginPackageLoader.swift`
- 注册表与目的地上下文：`AgentPluginRegistry.swift`
- staging、安装、卸载与草案：`AgentPluginInstaller.swift`
- 插件中心：`AgentPluginCenterPage.swift`
- 原生导航/侧栏：`AgentPluginSidebarViews.swift`
- 页面与 Web 沙箱：`AgentPluginPageHost.swift`
- 命令和菜单：`AgentPluginCommandExecutor.swift`
- AI 草案工具：`AgentPluginTools.swift`
- Keychain 设置：`AgentPluginSettingsStore.swift`
- 插件 MCP 网关：`AgentPluginMCPGateway.swift`、`AgentPluginMCPGatewayRouter.swift`、`AgentPluginMCPGatewayHTTP.swift`、`AgentPluginMCPGatewayDiscovery.swift`

## 13. 验收标准

- 合法、非法、Codex-only 清单均有解析测试；安装副本优先级、来源绑定审批及插件 MCP 命名空间也有回归测试。
- 重复 ID、缺失引用、未知 Schema、非法版本、路径逃逸和符号链接逃逸被拒绝。
- 三种侧栏模式、最多 10 个固定入口及稳定排序有状态测试。
- 入口、侧栏、中央页和工具栏来自同一个 descriptor；五个菜单贡献点均有解析与停用隔离测试。
- MCP App URI/MIME、动态声明式 Resource 与完整卸载均有边界测试。
- 外部网络、导航、弹窗和包外资源不能由 Web 页面访问。
- AI 草案不能自行安装或启用。
- 插件 MCP 网关的请求解析、鉴权 / Host / Origin、404 / 405 / 411 / 413、`initialize` 形状、通知 202、转发与中转的选择、发现文件内容与 0600 权限、端口与 token 沿用均有单测（`AgentPluginMCPGatewayTests`、`AgentPluginMCPGatewayDiscoveryTests`），测试注入临时目录与假宿主，不拉起插件进程。
- 300 个插件的发现与 snapshot 构造不在主线程执行。
- “项目概览”、“Issue 面板”和可游玩的“俄罗斯方块”样例可用于端到端开发与回归。
