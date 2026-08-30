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

字段级真相以 `plugin-schema/willdeep-plugin.schema.json` 和 `Xedit/AgentPluginModels.swift` 为准。
