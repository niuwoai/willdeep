# 待办（Todo）

跟项目长在一起的待办：在聊天正文里选中一句就能记下来，一句话说清「什么时候、多要紧」
由模型来读，按项目归拢也可以完全不归拢。**随 App 发行**，装机即在左侧。

## 它由三块拼起来

| 文件 | 作用 |
| --- | --- |
| `.willdeep-plugin/plugin.json` | 目的地（`defaultPinned`）、页面、十一条命令，以及 `menus["chat.selection"] = ["todo.quick_add"]` |
| `server/todo.rb` | MCP stdio 服务端：add / quick_add / list / update / toggle / remove / restore / settings / stats |
| `ui/index.html` | 待办页面（localWeb 运行时），用 `window.willdeep.executeCommand` 调命令、用 `window.willdeep.ai.complete` 问模型 |

## 一句话怎么变成待办

**两条路，同一份存储，字段完全一致。**

1. **页面里的快速输入 → 先问模型**（默认）。把你写的那一句原样发给模型，只要它回一段
   JSON：`title` / `due` / `allDay` / `priority`。走的是宿主新开的 `window.willdeep.ai.complete`
   通道——插件拿不到任何一把 key，provider 与模型必须落在用户自己的库里，详见
   [docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md](../../docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md)。
   默认用**当前 provider 的 flash 档**（便宜、快）；在页面右上角「设置」里可以钉死别的
   provider，包括本机 Ollama——那样这句话根本不出机器。
2. **模型不可用就回落本地规则**。关掉了、没配 provider、超时、答非所问，都自动落到
   `server/todo.rb` 里的确定性解析器：认「明天下午三点」「今晚十点半」「下周五之前」
   「3 天后」「8月30日」「tomorrow 9am」，以及「很急 / 紧急 / 重要 / 不急」这类说法，
   并把这些词从标题里剥干净。不联网、不花 token，**待办绝不会因为断网而丢**。

页面会在输入框下面告诉你这次是谁读的：`8月28日 15:00 · 高 · Xedit · 由 xxx 理解`，
读错了当场改。

本地解析器刻意保守：认不出就什么都不填，宁可少认，也不要把「下周汇报的材料」猜成
下周一到期。它认了什么写在 `parsed.matched` 里，测试逐条钉着。

## 与项目的关系

- 页面从宿主上下文拿当前工作区（需要 `workspace.read`），新建的待办默认归到这个项目
- 聊天里选中一段文字点「加到待办」时，宿主会把当前工作区一起递过来（同一条权限门禁）
- 顶部可以在**全部项目 / 当前项目 / 未归项目**之间切——待办**可以不属于任何项目**
- 计划完成时间与优先级都是**可选项**，不填就落在「没定时间」里

## 页面

按到期把待办分成**已逾期 / 今天 / 明天 / 本周内 / 以后 / 没定时间 / 已完成**七组；
优先级用左侧色条表示（紧急红、高橙、中蓝、低灰）。标题点开就能改，时间和优先级
点 chip 展开原生控件改，删除后 6 秒内可撤销。⌘N 聚焦快速输入。

## 工具

| 工具 | 说明 |
| --- | --- |
| `todo.add` | 字段自己给全。**Agent 在聊天里记待办走这条**：模型自己算好时间与优先级再调 |
| `todo.quick_add` | 一句话新建，服务端本地解析时间与优先级，返回 `parsed` 告诉调用方它认了什么 |
| `todo.list` | 按 `scope`（all/project/inbox）、`status`（open/done/all）、`query` 过滤；附带分组计数、项目直方图与当前设置 |
| `todo.update` | 改标题 / 备注 / 计划时间 / 优先级 / 归属项目 |
| `todo.toggle` | 打勾、取消打勾 |
| `todo.remove` | 删一条并回传整条（撤销用） |
| `todo.restore` | 原样放回去 |
| `todo.settings` | 解析方式（ai / local）与 provider、模型 |
| `todo.stats` | 概览计数 |

## 数据存在哪

```
~/Library/Application Support/WillDeep/plugin-data/todos.json
```

`{"version": 1, "settings": {...}, "items": [...]}`，每条待办带 `id` / `text` / `note` /
`project` / `projectPath` / `due` / `allDay` / `priority` / `done` / `doneAt` / `source` /
`createdAt` / `updatedAt`。写盘走「临时文件 + rename」，文件被写坏时按空列表继续跑。
最多 1000 条。用 `WD_TODO_FILE` 可以改存储位置（测试与沙箱用）。

## 权限

- `process.execute` — 启动插件自带的 Ruby MCP 服务
- `workspace.read` — 知道当前是哪个项目
- `ai.chat` — 问模型（一句话拆出时间与优先级）
- `providers.read` — 列出可选的 provider 与模型，供设置抽屉渲染

## 回归

```bash
ruby scripts/todo_server_test.rb
```

48 项检查：一句话解析的每条规则（中文数字小时、时段提示、否定优先级、
「之前」剥离、认不出就不填）、CRUD 与撤销闭环、按项目/状态过滤、分组计数、
设置读写不误伤待办、落盘格式与损坏降级。
