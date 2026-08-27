# WillDeep 插件系统与可扩展目的地设计

> 状态：v1 已实现
> 首发版本：WillDeep 1.280.0
> Schema：`.willdeep-plugin/plugin.json` schemaVersion 1

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

四个原生入口顺序固定，插件组只能位于其下方。最多固定 5 个插件目的地，支持拖拽排序；有插件时末尾显示“更多插件”，没有时显示“添加插件…”。默认、悬停和选中继续使用宿主灰度语义色，插件品牌色不参与选中表达。

第一方随 App 签名发行的内置插件可以在目的地清单声明 `defaultPinned: true`。宿主会把这类入口稳定放在插件分组顶部并计入 5 个固定名额，用户安装的同名更新仍可覆盖页面实现，但不能取消该入口；非 `bundled` 来源即使声明该字段也会被忽略，第三方插件不能借此抢占导航。

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
- `executeCommand(commandID, arguments)`
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
- `mcpTool`：调用已配置 MCP Tool；执行前显示插件名和命令名确认。

公开 Host Command v1：`plugin.refresh`、`destination.select`、`settings.mcp`、`plugins.open-center`。任意 selector、类名和脚本文本均被拒绝。

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

## 13. 验收标准

- 合法、非法、Codex-only 清单均有解析测试；安装副本优先级、来源绑定审批及插件 MCP 命名空间也有回归测试。
- 重复 ID、缺失引用、未知 Schema、非法版本、路径逃逸和符号链接逃逸被拒绝。
- 三种侧栏模式、最多 5 个固定入口及稳定排序有状态测试。
- 入口、侧栏、中央页和工具栏来自同一个 descriptor；五个菜单贡献点均有解析与停用隔离测试。
- MCP App URI/MIME、动态声明式 Resource 与完整卸载均有边界测试。
- 外部网络、导航、弹窗和包外资源不能由 Web 页面访问。
- AI 草案不能自行安装或启用。
- 300 个插件的发现与 snapshot 构造不在主线程执行。
- “项目概览”、“Issue 面板”和可游玩的“俄罗斯方块”样例可用于端到端开发与回归。
