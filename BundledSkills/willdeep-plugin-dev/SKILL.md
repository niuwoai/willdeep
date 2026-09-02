---
name: willdeep-plugin-dev
description: WillDeep 宿主机理说明与插件开发指南。解释 WillDeep 自身如何运行（目的地导航、会话与 Agent 回合、工具与审批、MCP/Skill/Workflow 的分工），以及如何为它开发插件：包结构、`.willdeep-plugin/plugin.json` 清单字段、页面运行时（localWeb / mcpApp / declarative）、`window.willdeep.*` 页面 API、命令与菜单贡献点、权限模型、安装与审批流程、体积与安全上限。当用户要写/改/调试 WillDeep 插件，问某个清单字段、插件页面能调什么 API、插件为什么装不上或命令为什么被拒，或想了解 WillDeep 内部是怎么运转的时候使用。Use when developing, debugging, or explaining WillDeep plugins, the plugin manifest schema, the in-page bridge API, plugin permissions and install approval, or WillDeep's own runtime architecture.
---

# WillDeep 机理与插件开发

这份技能是 WillDeep 随 App 发行的开发者文档。正文只讲怎么用；字段级细节在 `references/` 里，按需读取，不要一次全读。

## 先判断问的是哪一层

| 问题 | 读哪份 |
| --- | --- |
| WillDeep 自己是怎么跑的（会话、回合、工具、审批、MCP、Skill、Workflow） | `references/architecture.md` |
| 我要从零做一个插件 | `references/quickstart.md` |
| 清单里这个字段是什么意思／为什么校验不过 | `references/manifest.md` |
| 插件页面里能调什么 JS API | `references/page-api.md` |
| 命令、菜单位置、设置项、权限 | `references/manifest.md` |
| 装不上、审批被拒、体积超限、路径被拒 | `references/packaging-security.md` |

## 三条不会变的前提

1. **插件的核心贡献是「目的地」（destination），不是一块 WebView。** 一个目的地把一级入口、配套侧栏、中央页面、工具栏和命令绑成同一个导航状态，要么整体切过去，要么不切。
2. **插件页面借宿主的手干事，自己什么都拿不到。** 页面跑在 `connect-src 'none'` 的隔离 WKWebView 里：没有网络、没有文件、没有进程、没有密钥、拿不到 AppState。所有真实动作必须映射成清单里声明过的命令。
3. **能力靠清单声明、按权限现场核。** 插件停用的那一刻，它的页面、命令、MCP 服务同时失效。

## 动手时的固定顺序

1. 先在 `.codex-plugin/plugin.json` 定下插件 ID 和版本——它决定身份；`.willdeep-plugin/plugin.json` 只声明宿主贡献。
2. 再写 `contributes.destinations`，然后补它引用的 `pages` / `sidebars` / `commands`。ID 引用不存在时整包拒载，不会只跳过一条。
3. 所有用户可见文案走 `titleKey` / `subtitleKey` / `descriptionKey`，并在 `locales/en.json` 里给出非空英文——**英文缺键直接拒载**，中文缺失才是回落。
4. 装之前用插件中心的安装预览核对权限差异；改了内容就是新 digest，需要重新批准。
5. 页面里不要写死颜色语义：宿主是灰阶交互规范，导航、开关、选中态一律不用系统蓝和品牌色。

## 常见误判

- **「我的命令没执行，也没报错」**：多半是 `handler.type` 写了 `host` 但 `action` 不在白名单里（只有 `plugin.refresh`、`destination.select`、`settings.mcp`、`plugins.open-center`、`session.open` 五条）。`session.open` 还要插件声明 `conversation.read`，否则加载能过、执行时报权限错。
- **「页面白屏」**：先看是不是 `entryPath` 指到了目录而不是文件，其次看资源有没有超过单文件 8 MiB 的页面上限。
- **「fetch 不通」**：这是设计，不是 bug。页面要联网只能经由 MCP 工具，或者用 `ai.chat` 问模型。
- **「插件想常驻后台 / 秒级定时」**：不提供，也不打算提供。到点唤醒（`schedule`）目前只有设计没有实现，见 `references/architecture.md` 末节。
