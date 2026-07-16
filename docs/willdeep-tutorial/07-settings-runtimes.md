---
title: 设置、账号、远端 Runtime 与安全配置
order: 7
description: 配置编辑器、AI、some.im、Skill、MCP、SSH、daemon、终端、语音和移动网关。
---

# 第 7 章：设置、账号、远端 Runtime 与安全配置

[上一章：内置编辑器](06-editor.md) · [返回索引](README.md) · [下一章：快捷键与排错](08-shortcuts-troubleshooting.md)

## 1. 打开设置

点击 Agent 窗口右下角齿轮，或按 `Command+,`。设置按顶层分组组织：

- Editor
- Desktop Pet
- AI Agents
- some.im
- Mobile Gateway
- Runtimes
- Integrations
- Terminal
- Voice

含多个子页的分组会在内容区顶部显示分段选择器。

## 2. Editor

Editor 分组包括：

- Typography：编辑器与文件树字体、字号、行高。
- Appearance：界面皮肤、主题、工作区壁纸、透明度和材质。
- Workspace：检查器默认视图、保存时清理行尾空格、确保文件末尾换行。

调整外观不会改变文件内容；保存行为会影响写盘结果，团队项目应与格式化规则保持一致。

## 3. AI Agents

AI Agents 分组包括 Agent、Memory、Rules、Skills、MCP 和 Tools。

### Agent

- 管理 provider、Base URL、模型和 API Key。
- 配置图片理解模型与视觉 fallback。
- 设置会话标题模型。
- 控制安全工具自动审批和计划执行风险扫描。
- 配置网页搜索 provider 与并发数量。

API Key 只在明确点击保存后提交到本地安全存储。不要把 Key 写进截图、聊天、示例代码或 Git。

### Memory 与 Rules

- Memory：管理 Agent 可复用的项目记忆和知识目录。
- Rules：管理全局规则；项目内更具体的 `AGENTS.md` 等规则仍应优先。

规则应写清边界和验收，不要堆砌互相冲突的口号。

### Skills、MCP 与 Tools

- Skills：浏览、启用、创建或打开用户 Skill 目录。
- MCP：配置外部 MCP server，并确认可用工具。
- Tools：控制 Agent 可使用的工具和行为选项。

第三方 Skill 或 MCP 启用前，应查看来源、需要的权限和会接触的数据。

## 4. some.im

推荐使用浏览器登录：

1. 进入设置的 some.im 页面。
2. 点击“在浏览器打开”。
3. 在 some.im 页面完成登录。
4. 按页面提示回到 WillDeep。
5. 等待 App 自动同步账号、模型路由和图片理解配置。

浏览器登录可跳过；也可以手动配置 provider。手动模式下，如果主模型不支持图片输入，还需要配置视觉 provider、Base URL、API Key 和模型。

## 5. Runtimes：本地 Agent

Runtimes 的 Local Agents 子页用于发现本机 Claude Code、Codex CLI、Cursor Agent 等执行器。若未发现：

- 确认 CLI 已安装且可在普通 shell 中运行。
- 检查 PATH 与 App 启动环境是否一致。
- 点击重新扫描。
- 在终端中运行对应的 `--version` 验证。

## 6. Runtimes：SSH

新增 SSH runtime 时填写：

- 显示名称。
- 主机、用户名和端口。
- SSH 私钥路径。
- 默认远端工作区路径。
- 可选的终端启动目录、启动命令、跳转命令和服务名。

保存后先使用探测功能确认平台、架构、工具链和能力。推荐使用独立普通用户和最小权限密钥，生产环境不要允许 root 密码登录。

## 7. Runtimes：willdeep-agent daemon

daemon 模式适合通过 HTTP 服务连接远端工作区：

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

设置中填写 daemon Base URL、Token 和默认工作区。Token 文件必须限制权限，不应进入仓库或日志。

## 8. Mobile Gateway

Mobile Gateway 用于把手机端与 Mac 会话配对。配置时：

1. 选择连接方式。
2. 启动或确认网关状态。
3. 使用手机扫描二维码。
4. 在手机端选择模型、Skill、专家或插件后发送任务。

二维码可能携带连接信息，不要把生产配对码放进公开教程或工单。

## 9. Integrations、Terminal 与 Voice

- Integrations：Replicate 和协作连接器等第三方服务。
- Terminal：默认 shell、终端行为和相关工具配置。
- Voice：语音模型、转写和 AI 后处理策略。

第三方服务的 webhook、Token 和 secret 应写入 `.env`、Keychain 或专用 secret store，并确保相关文件被 `.gitignore` 排除。

## 10. 安全基线

- API Key 不进入普通聊天、源码和截图。
- Access Token 使用最小权限并定期轮换。
- SSH 私钥设置正确文件权限，不把私钥复制到项目目录。
- 自动化默认只读，写入与发布单独审批。
- 生产数据、个人信息和客户文件上传前必须确认目的地与必要性。
- 启用新插件、MCP 或连接器前先审查权限。
