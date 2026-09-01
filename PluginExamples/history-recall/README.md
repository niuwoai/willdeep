# 历史回溯（history-recall）

按**聊过的内容**跨项目找回旧会话，而不是只能按标题找。找到之后点一下直接跳过去。

解决的是这么个场景：记得跟 Agent 聊过某件事，但想不起来是在哪个项目、哪个会话里。

## 为什么需要它

宿主已有的两个手段都够不着：

| 手段 | 缺口 |
| --- | --- |
| 侧栏搜索（⌘⇧P） | 只搜标题，源码注释写明 `no message full-text indexing here` |
| `search_sessions` 工具 | 跨项目全文，但每次只打开**最近 40 个**会话，答案落在第 41 个之后就静默返回空 |

「静默返回空」最伤：用户分不清是「确实没聊过」还是「聊过但超出了扫描窗口」。本插件每次都扫全部会话，并如实报告扫了多少、命中多少、有没有截断。

## 两个入口

MCP 服务一旦装上，它的工具会自动并入宿主的全局工具清单，所以同一套能力有两个入口：

1. **插件页面** —— 专门的翻旧账界面，命中结果可展开上下文、可跳转。
2. **主 Agent** —— 在任意普通会话里直接问「我之前在哪聊过 frp 穿透」，Agent 调工具就答了，不受页面单轮问答的限制。

## 工具

| 工具 | 用途 |
| --- | --- |
| `history.search` | 跨项目检索。参数：`query`、`scope`(all/project)、`group`、`since`/`until`、`include_archived`、`limit` |
| `history.excerpt` | 取某条命中前后的原文 |
| `history.projects` | 列出全部归属分组、会话数、最近活动时间 |
| `history.settings` | 读写跨项目检索开关 |

### 查询规范化

真实用户打的是整句话，不会先替你分好词。而**中文没有空格，只按空白拆词等于不拆**——「我有提到过frp吗?」会被当成一整个词去做子串匹配，必然 0 命中，哪怕 frp 明明搜得到。

所以检索前先规范化：标点转空格 → 在 ASCII 与汉字的边界处断开 → 剥掉中文虚词。

```
我有提到过frp吗?          → frp
上次聊 SSH 穿透那次        → ssh 穿透
我们之前讨论过xcstrings的问题吗 → xcstrings 问题
```

单字虚词只能**切分**不能当子串剥掉，而且表要收得很紧（只留「的了吗呢么吧啊呀哦嘛」）。早先把「对/和/给/要/会/在/有」也算进去，结果「对话」被咬成「话」、**「会话」被咬成「话」**——而「会话」正是这个插件最核心的词。

**渐进放宽**：全词 AND 落空时，自动用信号最强的那个词（ASCII 技术名词 > 长中文词）再搜一次，结果里 `relaxed_from` 记下原本那组词，页面会明说「『X 和 Y』全中的没有，放宽了」。没有分词器，中文查询难免拆出噪声词，一个噪声词就能让 AND 全灭；与其让用户对着「没找到」猜是自己没聊过还是查询被拆坏了，不如给候选并说清楚。

结果里的 `terms` 永远是**实际拿去匹配的词**，页面会显示「搜的是：…」。命中 0 时这一行是用户判断原因的唯一依据。

### 匹配规则

规范化后的词逐个匹配，命中分三档（结果里的 `match_kind`）：

- `message` —— 单条消息里所有词都出现，最强
- `session` —— 词分散在会话的不同消息里（用户记得的常是「那次既聊了 A 又聊了 B」，未必在同一句话里）
- `title` —— 只有标题命中（标题往往是最容易记住的线索）

中文不需要分词，连续子串天然可搜。排序按匹配强度加权新鲜度，而不是纯按时间倒序——纯时间序正是宿主那个 40 条窗口的病根。

## 隐私

跨项目检索**默认关闭**，第一次用会在页面上出现一张说明卡，由用户当场决定是否打开。

宿主的 `search_sessions` 把跨项目检索归为写风险要走审批卡，而本插件直接读磁盘，绕过了那道门，所以自带这个开关作为替代。开关状态存在 `~/Library/Application Support/WillDeep/plugin-data/history-recall/settings.json`。

检索与摘录全在本机完成，服务端不声明 `network.access`，不会把会话内容发到任何外部服务。

## 数据来源与口径

读 `~/Library/Application Support/WillDeep/agent-sessions/*.json`（可用 `WD_HISTORY_SESSIONS_DIR` 覆盖）。

- **只读 user / assistant 正文**，工具调用的 payload 不进索引（与宿主 `AgentSessionSearch` 同口径）
- **剥掉宿主注入块**。本机实测 916 条 user 消息里有 171 条（18.7%）混进了宿主追加的内容，其中 skill 路由候选列表最毒——它把每个已安装 skill 的完整描述都塞进正文，不剥的话检索「SwiftUI 卡死」会命中 27 个根本没聊过这话题的会话（剥掉后是 1 个真命中）
- **空壳会话直接丢弃**。本机 474 个会话里有 221 个是 0 消息的「新对话」
- **归属键复刻宿主的 `workspaceSidebarGroupKey` 优先级**（projectID → sidebarWorkspaceRootPath → workspaceLocation → workspaceRootPath），否则 worktree 里的会话会被算成独立项目
- 同名分组会自动加后缀区分（本机有两个不同归属键都叫 `muchtoken`）
- 单文件超过 32 MB 跳过；坏文件跳过不影响整次检索
- camelCase 与 snake_case 字段都认；时间戳兼容 Apple 纪元与 Unix 纪元

### 性能

不建持久索引，也不落盘缓存。本机实测（474 个会话、79 MB）：

| | |
| --- | --- |
| 冷启动全扫 | 约 1.0 秒 |
| 热态检索 | 6–10 毫秒 |

进程内按 `(mtime, size)` 增量，新增/删除的会话下次检索立刻可见。检索必须扫正文，而正文缓存的体积就等于原始数据，落盘只省下一次解析却要换来一致性、占用和损坏降级三份复杂度，不划算。

## 模型的位置

页面用 `window.willdeep.ai.complete`（flash 档）把「上次聊 SSH 穿透那次」转成检索词。**模型只是锦上添花**：拿不到就退回服务端的查询规范化，定位功能照常可用——上面那三个例子全是纯规则跑出来的。

调用带 8 秒超时。`ai.complete` 没有流式也没有取消，宿主那边模型不可用时它可能既不 resolve 也不 reject；没有这道闸，整个检索会永远停在「正在归纳…」，用户看到的就是一个什么也不发生的页面。

## 开发

插件系统没有开发模式：不认软链接，安装是复制而非引用，且同版本号内容变了会被拒装。所以每次改包内容做 GUI 安装前都得先 bump `.codex-plugin/plugin.json` 的 `version`。

日常验证走这两个脱离 App 的入口：

```bash
ruby scripts/history_recall_server_test.rb
```

```bash
node scripts/history_recall_preview_server.cjs --port 4173
```

预览服务器会拉起真实的 Ruby MCP 子进程并注入一个假的 `window.willdeep`，浏览器里就能验收页面。它默认让 `ai.complete` 必定失败，用来验证降级路径；传 `--ai` 启用一个假模型验证另一条分支。

**改了 `server/*.rb` 必须重启预览服务器。** 页面 HTML 每次请求都重读文件，但 Ruby 子进程在启动时就把脚本载入内存了，改文件不会热重载——于是页面是新的、检索逻辑是旧的，看起来就像「改了没生效」。而且它的端口不会自己让出来，重启前先确认杀干净：

```bash
pkill -f history_recall_preview_server; pkill -f history_recall.rb
```

服务端测试刻意删掉 `LANG` / `LC_ALL` 来复现宿主的启动环境——Ruby 默认外部编码在没有 locale 时会退成 US-ASCII，读中文会话直接抛 `Encoding::InvalidByteSequenceError`，这是必须钉住的回归。

宿主用的是 `/usr/bin/ruby`（macOS 系统 Ruby **2.6**），`filter_map` 之类 2.7+ 的方法不能用。改完用 `/usr/bin/ruby -c` 过一遍语法。

## 依赖的宿主能力

需要 WillDeep **1.316.0-rc1** 及以上——「打开那个会话」依赖本版本新增的 `session.open` host action。宿主执行它时要求插件声明 `conversation.read`。
