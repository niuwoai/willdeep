# WillDeep Plugin Examples

- `project-overview`：原生声明式侧栏 + 包内 React/TypeScript 页面；`ui/dist` 是已构建且可直接安装的产物。
- `issue-panel`：原生 Issue 侧栏 + MCP App 页面 + Ruby stdio MCP Resource/Tool 服务。
- `tetris`：可直接游玩的俄罗斯方块目的地；左侧原生侧栏切换难度，React 中央页支持键盘/按钮操作、幽灵落点、计分、等级、暂停和中英双语。macOS 发行构建会把它的运行时文件精简复制到 App 的 `BundledPlugins`，默认随 WillDeep 提供。
- `arcade`：内置经典游戏厅，包含 2048、打砖块、贪吃蛇、俄罗斯方块、Pong、扫雷、记忆翻牌、连连看、印加弹珠和图片拼图。发行构建只复制清单、本地化与 `ui/dist`，并以第一方 `defaultPinned` 目的地固定显示在左侧插件入口顶部。
- `favorites`：收藏夹。聊天正文选中文字点「收藏」存下来，左侧页面搜索、加标签、写备注、置顶、删除并支持撤销；收藏按页面可用宽度自动排成卡片网格。MCP stdio 服务端负责落盘（单个 JSON 文件，临时文件 + rename）。**随 App 发行**：发行构建会复制清单、本地化、`mcp.json`、`server/` 与静态页，并以第一方 `defaultPinned` 目的地默认出现在左侧插件分组。
- `todo`：跟项目长在一起的待办。聊天里选中一句就能记下；一句话说清「什么时候、多要紧」默认交给模型读（`window.willdeep.ai.complete`，默认用当前 provider 的 flash 档，也可以钉死本机 Ollama），模型不可用时回落到服务端的确定性解析器，绝不把待办弄丢。按到期分七组、可按项目过滤、也可以完全不属于任何项目；各分组按当前内容宽度自动排成卡片。**随 App 发行**。
- `session-vitality`：会话体检中心。原生声明式侧栏 + MCP App 仪表盘 + Ruby stdio MCP 服务，逐条累加会话里上报的真实 token 用量，给出四个主指标、输出/请求双维趋势、工作画像、项目与模型排行和最近会话；含 `vitality.snapshot` / `vitality.export` 工具、工具栏命令与中英本地化。**随 App 发行**：发行构建会复制清单、本地化、侧栏 Schema、`mcp.json` 与 `server/`，装机即已批准并启用；左侧入口由用户自己固定。

在 WillDeep 插件中心选择样例根目录即可进入权限预览。安装器不会运行依赖安装或构建命令；需要修改 Project Overview 源码时，在 `ui` 中使用 Yarn 和 Vite 自行构建，再提交 `ui/dist`。
