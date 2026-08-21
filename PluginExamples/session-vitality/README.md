# Session Vitality（会话体检中心）

WillDeep 样例插件：在插件中心选择本目录即可进入权限预览，批准后安装启用。

## 结构

- `.willdeep-plugin/plugin.json` — 目的地 `vitality`：声明式侧栏 + MCP App 页面 + 工具栏命令
- `.willdeep-plugin/schemas/vitality-sidebar.json` — 侧栏 fallback Schema（MCP 资源不可用时显示）
- `.willdeep-plugin/locales/` — en / zh-Hans 本地化
- `mcp.json` — 启动 `session-vitality` MCP 服务（`/usr/bin/ruby`）
- `server/session_vitality.rb` — stdio MCP server：侧栏资源、`ui://vitality/main` 页面资源、`vitality.snapshot` / `vitality.export` 两个工具
- `server/app.html` — MCP App 仪表盘（会话统计卡片 + 项目活跃度进度条）

## 权限

- `conversation.read` — 读取会话存储（会话 JSON 元数据）
- `process.execute` — 启动插件自带的 Ruby MCP 服务

## 数据来源

默认扫描 `~/Library/Application Support/WillDeep`（含一层子目录）下的会话 JSON，
逐个宽容解析：`title`、`updatedAt`、`workspaceRootPath`、`messages`、`tokenUsage`、
`agentArtifactPaths`、`didEditFiles`，camelCase 与 snake_case 均兼容，单文件超
8 MB 跳过。未找到会话存储时回退到带 `demo` 标记的演示数据（页面和侧栏都会标注）。

可用环境变量 `WD_VITALITY_SESSIONS_DIR` 覆盖扫描根目录（在 `mcp.json` 的 env 中配置）。

## 命令

- `vitality.refresh` — host `plugin.refresh`，重新读取侧栏与页面资源
- `vitality.snapshot` — 调用 `vitality.snapshot` 工具，返回聚合统计 JSON

## 后续可做

- 对照真实会话 JSON 校准字段映射（token 现在是消息数估算）
- 接入 WillDeep 通知 webhook，在仪表盘聚合通知流
- 增加"导出 Markdown 到剪贴板"命令（需声明 `clipboard.write` 权限）
