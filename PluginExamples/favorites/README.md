# 收藏夹（Favorites）

在聊天正文里选中一段文字，气泡上就多一个「收藏」；点一下这段文字进收藏夹，
左侧「收藏夹」页面里可以搜索、加标签、写备注、置顶、删除，删错了还能撤销。

这是 `chat.selection` 菜单挂载点的参考实现——插件往聊天选区气泡与右键菜单里加动作，
宿主把选中的原文交给插件命令执行。**它随 App 一起发行**（`BundledPlugins/favorites`），
默认出现在左侧插件分组里，不需要用户手工安装。

## 它由三块拼起来

| 文件 | 作用 |
| --- | --- |
| `.willdeep-plugin/plugin.json` | 声明目的地（`defaultPinned`）、页面、命令，以及 `menus["chat.selection"] = ["favorites.add"]` |
| `server/favorites.rb` | MCP stdio 服务端：add / list / update / remove / restore / clear 六个工具 |
| `ui/index.html` | 收藏夹页面（localWeb 运行时），用 `window.willdeep.executeCommand` 调上面的命令 |

页面没有构建步骤，改完直接生效；也不引任何外部资源——插件页跑在 CSP 收紧的
WKWebView 里（`connect-src 'none'`）。配色从宿主注入的 `--willdeep-*` 变量派生，
深浅色自动跟随；收藏列表使用 `auto-fill + minmax(400px, 1fr)` 按页面当前可用宽度排卡，
单条收藏不会横向拉满。布局只认插件内容区，`vw` 在插件分栏里会算错。

## 工具

| 工具 | 参数 | 说明 |
| --- | --- | --- |
| `favorites.add` | `text` / `note` / `tags` / `source` | 收藏一段文字。同一段文字重复收藏会合并到已有那条并顶到最前，返回 `duplicate: true` |
| `favorites.list` | `query` / `tag` / `limit` | 置顶优先、其余按更新时间倒序；附带标签直方图与存储路径 |
| `favorites.update` | `id` + `note` / `tags` / `pinned` | 只改传进来的字段 |
| `favorites.remove` | `id` | 删一条，并把删掉的整条原样回传（页面据此做撤销） |
| `favorites.restore` | `item` | 把整条塞回去，保留原 id 与创建时间 |
| `favorites.clear` | `confirm: true` | 清空。不带 `confirm` 直接拒绝，免得被 Agent 顺手调掉 |

标签会被规范化：去空白、忽略大小写去重、单个最长 24 字、每条最多 8 个。

## 数据存在哪

单个 JSON 文件，默认：

```
~/Library/Application Support/WillDeep/plugin-data/favorites.json
```

结构是 `{"version": 2, "items": [...]}`，每条收藏带
`id` / `text` / `note` / `tags` / `source` / `pinned` / `createdAt` / `updatedAt`。
v1 的老文件读进来会自动补齐新字段，不需要单独迁移。写盘走「临时文件 + rename」，
中途被杀不会留下半截文件；文件被写坏时服务端按空列表继续跑，不会把插件页面拖死。
最多保留 500 条，单条文本上限 20KB。

用 `WD_FAVORITES_FILE` 可以改存储位置（测试与沙箱用）。

## 选区动作的契约

宿主执行 `chat.selection` 里的命令时，固定传两个参数：

- `text`：选中的原文（已按聊天导出的净化规则处理）
- `source`：`"chat.selection"`，插件据此区分入口

命令的 handler 是 `mcpTool` 时，这两个参数原样进工具调用的 `arguments`。
执行完气泡会就地变成「✓ 收藏」或「⚠︎ 收藏」停一下再收起，所以点完不会毫无反应。

## 随 App 发行

`Xedit.xcodeproj` 的 **Bundle built-in plugins** 构建阶段把 `.codex-plugin`、
`.willdeep-plugin`、`mcp.json`、`server/` 与 `ui/index.html` 复制进
`WillDeep.app/Contents/Resources/BundledPlugins/favorites`。`bundled` 来源的插件
自动获批，目的地清单里的 `defaultPinned` 也只对这类第一方插件生效；它们执行自己的
MCP 工具时不再逐条弹确认框（第三方插件仍然每次都要点头）。

改了插件里的任何文件都要重新构建 App，`BundledPlugins` 才会更新。

## 回归

```bash
ruby scripts/favorites_server_test.rb
```

覆盖：initialize / tools/list 契约、收藏 → 列出 → 改 → 删 → 撤销闭环、空文本拒绝、
重复收藏合并、标签规范化与直方图、关键词过滤、置顶排序、清空要显式确认、
v1 存储向后兼容、落盘格式与临时文件清理、响应式卡片网格，以及存储损坏时的降级。
