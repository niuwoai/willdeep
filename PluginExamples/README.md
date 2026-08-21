# WillDeep Plugin Examples

- `project-overview`：原生声明式侧栏 + 包内 React/TypeScript 页面；`ui/dist` 是已构建且可直接安装的产物。
- `issue-panel`：原生 Issue 侧栏 + MCP App 页面 + Ruby stdio MCP Resource/Tool 服务。
- `tetris`：可直接游玩的俄罗斯方块目的地；左侧原生侧栏切换难度，React 中央页支持键盘/按钮操作、幽灵落点、计分、等级、暂停和中英双语。macOS 发行构建会把它的运行时文件精简复制到 App 的 `BundledPlugins`，默认随 WillDeep 提供。
- `arcade`：由 WillDeep 调度台并行开发并完成端到端验收的经典游戏厅，包含贪吃蛇、俄罗斯方块、Pong、扫雷和记忆翻牌。发行构建只复制清单、本地化与 `ui/dist`，并以第一方 `defaultPinned` 目的地固定显示在左侧插件入口顶部。
- `session-vitality`：会话体检中心。原生声明式侧栏 + MCP App 仪表盘 + Ruby stdio MCP 服务，扫描本地会话 JSON 生成会话统计与项目活跃度；含 `vitality.snapshot` / `vitality.export` 工具、工具栏命令与中英本地化。

在 WillDeep 插件中心选择样例根目录即可进入权限预览。安装器不会运行依赖安装或构建命令；需要修改 Project Overview 源码时，在 `ui` 中使用 Yarn 和 Vite 自行构建，再提交 `ui/dist`。
