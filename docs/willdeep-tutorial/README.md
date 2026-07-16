---
title: WillDeep 图文教程
order: 0
description: 从首次配置到 Agent、工作区、自动化、媒体侧栏和内置编辑器的完整使用指南。
---

# WillDeep 图文教程

> 适用版本：WillDeep 1.175.0-rc4（macOS 13.7 及以上）<br>
> 截图日期：2026-07-16<br>
> 截图来源：1.175.0-rc2 源码构建的真实 App；编写期间仓库已更新到 rc4，并按 rc4 源码复核入口与配置分组。账号、余额、既有会话与服务器信息均已裁掉。<br>
> 界面差异：模型列表、插件、专家和集成项会随账号权限及安装情况变化。

WillDeep 是以任务、工作区、会话和交付物为中心的 macOS 原生 Agent 工作台。它可以读取项目、调用终端与浏览器、修改文件、运行测试、操作远端 runtime，并把改动、工具输出和媒体产物放回同一个会话中供你检查。

![任务输入区与常用控制](assets/interface/composer-controls.png)

## 阅读索引

1. [快速开始与界面认识](01-quick-start.md)
2. [工作区、会话与运行位置](02-workspaces-sessions.md)
3. [模型、任务模式与审批](03-models-modes-approvals.md)
4. [文件、终端、Diff 与侧栏](04-side-panels-review.md)
5. [自动化、媒体任务、插件与专家](05-automation-media-extensions.md)
6. [内置编辑器与 Markdown 预览](06-editor.md)
7. [设置、账号、远端 Runtime 与安全配置](07-settings-runtimes.md)
8. [快捷键、排错与最佳实践](08-shortcuts-troubleshooting.md)

## 推荐学习路线

- 第一次使用：按第 1 → 2 → 3 章完成账号、工作区、模型和审批配置。
- 日常开发：重点看第 2、3、4、6 章。
- 内容与媒体生产：重点看第 3、4、5 章。
- 服务器和远端项目：重点看第 2、4、7、8 章。
- 团队内部上线：先读第 7 章的安全边界，再配置自动化和远端 runtime。

## 功能速查

| 目标 | 入口 | 章节 |
|---|---|---|
| 建立新任务 | 左侧“新聊天”或 `Command+N` | [第 1 章](01-quick-start.md) |
| 绑定本地项目 | 输入框上方的工作区菜单 | [第 2 章](02-workspaces-sessions.md) |
| 使用远端服务器 | 工作区菜单 → 远程运行环境 | [第 2 章](02-workspaces-sessions.md) |
| 切换模型 | 输入框下方的模型按钮 | [第 3 章](03-models-modes-approvals.md) |
| 先规划再执行 | 模式菜单 → 计划 | [第 3 章](03-models-modes-approvals.md) |
| 控制工具授权 | 审批菜单 | [第 3 章](03-models-modes-approvals.md) |
| 浏览工作区文件 | 顶部“文件” | [第 4 章](04-side-panels-review.md) |
| 使用可见终端 | 顶部“终端” | [第 4 章](04-side-panels-review.md) |
| 查看改动 | 顶部“Diff” | [第 4 章](04-side-panels-review.md) |
| 创建定时任务 | 左侧“自动化”旁的 `+` | [第 5 章](05-automation-media-extensions.md) |
| 查看图片和视频产物 | 顶部“媒体任务” | [第 5 章](05-automation-media-extensions.md) |
| 打开内置编辑器 | 显示 → 显示 Editor | [第 6 章](06-editor.md) |
| 配置模型、Skill、MCP | 设置 → AI Agents | [第 7 章](07-settings-runtimes.md) |
| 配置 SSH/daemon | 设置 → Runtimes | [第 7 章](07-settings-runtimes.md) |

## 教程约定

- `Command`、`Option`、`Shift` 分别对应 macOS 的 `⌘`、`⌥`、`⇧`。
- “工作区”指任务允许读取和操作的项目根目录，不等同于单个文件。
- “运行位置”指工具究竟在本机、SSH 主机还是远端 daemon 中执行。
- “交付物”指代码、文档、图片、视频、报告或其他可验证结果。
- 涉及删除、发布、发消息、付款、生产数据库和密钥的操作，应保持人工确认。

## 文档站接入说明

所有页面均为标准 Markdown，图片使用相对路径，页面顶部包含 `title`、`order` 和 `description`。未来接入文档站时，可直接把本目录作为内容源：

- VitePress：根据本页“阅读索引”生成 `themeConfig.sidebar`。
- Docusaurus：保留 front matter，并将本目录映射为一个 docs category。
- MkDocs：把阅读索引顺序写入 `mkdocs.yml` 的 `nav`。
- 其他生成器：按文件名前缀 `01`—`08` 排序即可。
