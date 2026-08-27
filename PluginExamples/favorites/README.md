# 收藏夹（Favorites）

在聊天正文里选中一段文字，气泡上就多一个「收藏」；点一下这段文字进收藏夹，
随时在左侧「收藏夹」页面回看、复制、删除。

这是 `chat.selection` 菜单挂载点的参考实现——插件往聊天选区气泡与右键菜单里加动作，
宿主把选中的原文交给插件命令执行。

## 它由三块拼起来

| 文件 | 作用 |
| --- | --- |
| `.willdeep-plugin/plugin.json` | 声明目的地、页面、四条命令，以及 `menus["chat.selection"] = ["favorites.add"]` |
| `server/favorites.rb` | MCP stdio 服务端：`favorites.add` / `favorites.list` / `favorites.remove` 三个工具 |
| `ui/index.html` | 收藏夹页面（localWeb 运行时），用 `window.willdeep.executeCommand` 调上面的命令 |

## 数据存在哪

单个 JSON 文件，默认：

```
~/Library/Application Support/WillDeep/plugin-data/favorites.json
```

结构是 `{"version": 1, "items": [...]}`，每条收藏带 `id` / `text` / `note` / `source` / `createdAt`。
写盘走「临时文件 + rename」，中途被杀不会留下半截文件；文件被写坏时服务端按空列表继续跑，
不会把插件页面拖死。最多保留 500 条，单条文本上限 20KB。

用 `WD_FAVORITES_FILE` 可以改存储位置（测试与沙箱用）。

## 选区动作的契约

宿主执行 `chat.selection` 里的命令时，固定传两个参数：

- `text`：选中的原文（已按聊天导出的净化规则处理）
- `source`：`"chat.selection"`，插件据此区分入口

命令的 handler 是 `mcpTool` 时，这两个参数原样进工具调用的 `arguments`。

## 装它

插件中心 →「从本地安装」→ 选这个目录。它依赖一个 stdio MCP 服务端（系统 Ruby 启动），
所以清单里声明了 `process.execute` 权限，安装时会让你确认。

## 回归

```bash
ruby scripts/favorites_server_test.rb
```

覆盖：initialize / tools/list 契约、收藏 → 列出 → 删除闭环、空文本拒绝、
存储文件格式与临时文件清理，以及存储损坏时的降级。
