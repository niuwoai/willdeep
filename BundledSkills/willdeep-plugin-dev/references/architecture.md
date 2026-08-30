# WillDeep 运行机理

面向插件开发者和 AI 助手的宿主说明。只写与扩展相关、且当前已经实现的部分；设计中未落地的会标注出来。

## 1. 窗口与目的地

主窗口左上是固定的四个原生入口，插件入口只能排在它们下面：

```
conversation      会话（默认）
scheduledTasks    已安排
dispatchBoard     调度台
roundtable        专家圆桌
plugin(<id>)      插件目的地
pluginCenter      插件中心
```

对应 `AgentPrimaryDestination`。插件那一项只存一个 qualified destination ID（`<plugin-id>:<destination-id>`）。左下侧栏和中央页面都从 `AgentPluginRegistry` 的同一份不可变快照解析描述符，所以不会出现"入口属于 A、侧栏属于 B"的半切换状态。插件在选中时被停用或卸载，宿主切回插件中心并说明原因。

最多 5 个插件目的地可以固定在导航里，支持拖拽排序。随 App 签名发行的第一方插件（`BundledPlugins/`）可以声明 `defaultPinned: true` 占据固定位；非 `bundled` 来源声明这个字段会被忽略，第三方插件抢不到导航。

## 2. 会话与 Agent 回合

- 一个 `AgentSession` 配一个 `AgentRuntime`。runtime 独占自己的消息列表、当前流式任务、待审批工具的 continuation、输入草稿、模式与目标状态。
- 切换会话不取消正在流的请求，其它 runtime 继续在后台跑，回来还能看到完整 transcript。
- `AppState` 是 `@MainActor`，所有 `@Published` 修改都在主线程；网络回调跨线程后要回到主线程再改状态。
- 同一个 provider 的并发请求按设置里的并发上限 FIFO 排队（默认 3），不同 provider 互不阻塞。

一个回合大致是：用户消息 → 组装 system prompt（全局规则 + 项目规则 + 记忆检索 + 能力说明）→ 流式请求 → 模型要调工具 → 审批 → 执行 → 结果回灌模型 → 继续，直到模型给出最终回复。

## 3. 工作区与运行位置

会话的 workspace 可以是本地路径，也可以是远端 runtime（SSH 或 `willdeep-agent` daemon）加远端路径。`read_file`、`list_directory`、`search_files`、`grep_files`、`git_status`、`run_command` 这些工具按会话的 workspace 路由到本地、SSH 或 daemon 执行。

插件拿不到路径本身。声明了 `workspace.read` 或 `workspace.write` 的插件，页面上下文里只会多一个 `workspaceReference` 字符串引用；真正的读写仍要走 MCP 工具或宿主命令。

## 4. 审批与沙箱

工具执行分档：只读、workspace 写、danger。会话级审批模式有四档（每次询问、智能审批、Workspace 访问、静默）。判定顺序是确定性优先：

1. 恶意命令黑名单——任何档位都拦。
2. 静态安全白名单（`cat`、`ls`、`git status`、`rg` 之类）自动放行。
3. 记住过的 Always Allow 记录。
4. 都不命中且档位允许时，才交给 AI 裁判（走 flash 档模型，不是当前回合的模型）。
5. 裁判缺席或拒绝，回落人工授权卡。danger 档仍要求键入确认。

只读命令默认在脱敏环境和临时 HOME 下执行，macOS 上通过 `sandbox-exec` 禁网、禁越权写。执行记录落 `~/Library/Application Support/WillDeep/AgentAudit/sandbox.jsonl`，裁判记录落同目录的 `judge.jsonl`，token 与 secret 已脱敏。

排查"为什么还要我点确认"，先看 `judge.jsonl` 里有没有这条命令：查不到说明裁判根本没上场，是被前面的确定性门禁拦下的。

## 5. 四种扩展方式的分工

| 机制 | 是什么 | 什么时候选它 |
| --- | --- | --- |
| Skill | 一段 Markdown 指令包，按需注入模型上下文 | 想改变 AI 的做事方法、提供流程和知识 |
| MCP Server | 外部进程或 HTTP 服务，提供 tools 和 resources | 想让 AI 具备新的真实能力（查库、调 API、控设备） |
| Workflow | 声明式的多步编排 | 固定套路要可重复执行 |
| Plugin | 目的地 + 页面 + 侧栏 + 命令，可以捆绑上面三者 | 想要一块**用户直接操作的界面**，而不只是 AI 的能力 |

插件是唯一能往主导航里加东西的机制。它可以在包内同时携带 `skills/` 和 `mcp.json`，安装后这些技能和 MCP 服务跟着插件的启停一起生效。

## 6. 插件页面的隔离边界

包内 Web 页面跑在独立的、非持久化的 `WKWebsiteDataStore` 里，资源只经 `willdeep-plugin://bundle/` 这个只读自定义协议加载。协议处理器逐项做路径规范化、符号链接解析和包根前缀校验，并限制单个资源大小。

页面上的这些能力被导航策略和 CSP 双重关掉：外部导航、弹窗、iframe、表单提交、WebSocket、`fetch`。页面访问不到文件、网络、进程、Keychain 和 AppState。

所以插件页面要干任何真实的事，只有三条通道：

1. 调用清单里声明过的**命令**（`window.willdeep.executeCommand`）。
2. 走 MCP App 协议调用**本插件声明过的 MCP 工具**，或读同一个 server 的 resource。
3. 借宿主问一次模型（`window.willdeep.ai.complete`，需要 `ai.chat` 权限）。

## 7. 页面的生命周期

进入目的地时宿主读取页面源码（本地文件或 MCP resource），注入 bootstrap 脚本，用 `loadHTMLString` 灌进 WebView。

- 用户点工具栏刷新、宿主刷新 generation 变化、订阅的 MCP resource 发来更新通知时，页面重新加载。
- 网页内容进程被系统回收时，宿主重灌同一份 HTML；连续崩溃三次后停止自动重载，提示用户停用或回滚插件。
- 导航失败会先自动重灌一次，仍失败则在页面上显示错误，而不是留一张白页。
- 离开目的地时宿主发 `ui/resource-teardown`（MCP App）并解绑消息通道。

## 8. 上下文对象

宿主通过 `window.__WILLDEEP_CONTEXT__` 和 `willdeep:context-changed` 事件推送：

```ts
{
  destinationID: string,        // "<plugin-id>:<destination-id>"
  selectedItemID: string | null, // 侧栏当前选中项，由宿主持有
  workspaceReference: string | null, // 仅在声明 workspace.read/write 时给
  sessionReference: string | null,   // 仅在声明 conversation.read 时给
  locale: string,
  colorScheme: "light" | "dark"
}
```

不传聊天正文，也不传文件内容。

## 9. 尚未实现

- **`schedule`（到点唤醒插件）**：设计已写在 `docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md`，包含 `mode: command` 与 `mode: agentTurn` 两档、补跑策略和并发约束，目前**没有实现**。插件现在无法被定时触发，也拿不到后台常驻线程。
- **流式的 `ai.complete`**：当前是非流式单轮，要么给全文要么抛错。
- **在线插件市场**：不存在。分发靠本地目录、ZIP、Git 仓库或随 App 内置。

## 10. 代码落点

| 关注点 | 文件 |
| --- | --- |
| 数据契约 | `Xedit/AgentPluginModels.swift` |
| 清单解析与路径校验 | `Xedit/AgentPluginPackageLoader.swift` |
| 注册表与目的地上下文 | `Xedit/AgentPluginRegistry.swift` |
| 安装、卸载、AI 草案 staging | `Xedit/AgentPluginInstaller.swift` |
| 插件中心界面 | `Xedit/AgentPluginCenterPage.swift` |
| 页面宿主与 Web 沙箱 | `Xedit/AgentPluginPageHost.swift` |
| 命令与菜单 | `Xedit/AgentPluginCommandExecutor.swift` |
| 问模型 / provider 清单 | `Xedit/AgentPluginAIBridge.swift` |
| Keychain 设置 | `Xedit/AgentPluginSettingsStore.swift` |

上位设计文档：`docs/WILLDEEP_PLUGIN_SYSTEM_DESIGN.md`、`docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md`。
