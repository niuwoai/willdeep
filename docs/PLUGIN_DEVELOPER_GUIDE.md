# 插件开发者文档在哪

面向插件开发者和 AI 的完整文档是 **`BundledSkills/willdeep-plugin-dev/`**，它随 App 一起发行（打包进 `WillDeep.app/Contents/Resources/BundledSkills/`），因此 AI 在用户机器上也能读到，用户不必回到仓库。

| 文件 | 内容 |
| --- | --- |
| `SKILL.md` | 入口与路由：什么问题读哪一份 |
| `references/architecture.md` | WillDeep 运行机理：目的地导航、会话与回合、工作区、审批与沙箱、四种扩展方式的分工、页面隔离边界 |
| `references/quickstart.md` | 从零做一个插件 |
| `references/manifest.md` | `.willdeep-plugin/plugin.json` 字段参考，含命令、菜单、设置、权限 |
| `references/page-api.md` | `window.willdeep.*` 页面 API 与 MCP App 协议 |
| `references/packaging-security.md` | 打包、安装、审批、上限与安全不变量 |

改动那份文档时，同步检查这两份上位设计文档是否需要一起更新：

- `WILLDEEP_PLUGIN_SYSTEM_DESIGN.md` —— 插件系统的设计与验收标准
- `PLUGIN_HOST_CAPABILITIES_DESIGN.md` —— `ai.chat` / `providers.read` 已实现，`schedule` 仍是设计

## 外部 MCP 客户端怎么连插件

插件不用为外部客户端做任何事。WillDeep 自带一个只绑本机的插件 MCP 网关，Claude Code、Codex 等客户端连网关地址即可，第一条请求会让宿主按需拉起插件，不必先打开插件页。网关地址和 token 在 `~/Library/Application Support/WillDeep/mcp-gateway.json`，设置 → MCP 的插件服务行可以直接复制 Claude Code 连接命令。插件照常在自己的数据目录写 `mcp-http.json`（长耗时调用走它，避开宿主 stdio 的超时），但面向用户的文档应指向网关，不再让用户去读 `mcp-http.json`。同一个插件可能同时被 WillDeep 和 willdeep-rs 各拉起一个进程，建议在文件里一并写上 `parentPID`（拉起本进程的宿主进程号）：WillDeep 1.405.0-rc7 起，网关遇到 `parentPID` 不是自己的文件会跳过，改走 stdio。契约见 [decisions/0001-plugin-mcp-gateway.md](decisions/0001-plugin-mcp-gateway.md)。

字段级真相以 `plugin-schema/willdeep-plugin.schema.json` 和 `Xedit/AgentPluginModels.swift` 为准。
