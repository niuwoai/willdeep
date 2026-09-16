# 面板现状提醒：让 AI 知道侧边栏此刻是什么状态

> Last updated: 2026-09-16 | 状态：**已实现（1.376.0-rc1）**
> 关联版本：基于 1.375.0-rc11（develop @ 99245908）
> 适用范围：Xedit（WillDeep macOS App）composer 与提示词上下文
> 一句话：给用户一个轻量入口，把「侧边栏终端此刻连在哪台机器 / 浏览器此刻停在哪个页面」这类**事实**塞进这一轮上下文，供 AI 自行判断能否加以利用——**只是告知，不指定落点、不改路由、不碰审批**；入口以 `+` 菜单为主、`@` 打字为辅，两者共用同一份候选源。

## 0. 需求来源

2026-09-16，用户先问能不能用 `@` 或 `#{...}` 指定「在侧边栏终端里运行」，随后在看过初版设计（按「执行目标路由」写的）后纠正了量级：

> 我想轻一点，就表达一个提醒一下 AI 的意思，比如侧边栏终端现在连在 xxx 主机上；或是 侧边栏当前在 some.im/admin ，等等，让 AI 注意是否可以加以利用。和那个运行位置不能比。尤其那个是在本地执行，还是 ssh 到某个主机上去改代码的相比，轻太多了。完全没有到"执行位置"的阶段。

**这条纠正定义了本设计的边界**：

| | 告知（本设计） | 指定（明确不做） |
| --- | --- | --- |
| 做什么 | 把面板此刻的状态作为事实交给 AI | 强制命令落到某个执行面 |
| AI 的自由度 | 自行判断用不用 | 无 |
| 触碰的层 | prompt 上下文 | 工具集裁剪、派发路由、审批 |
| 类比 | `@file`（引用一段内容） | `@worker`（改变派发路由） |

初版设计（`COMMAND_EXECUTION_TARGET_DESIGN.md`，已删除）整篇按「指定」写，包括粘性落点 pill、工具集单向裁剪、拒绝兜底、QTerm 安全分级呈现——**全部超出需求量级，作废**。其中唯一值得留存的是 QTerm 安全边界的复核结论，见 §5。

## 1. 现状盘点

### 1.1 终端 host：已经在注入，但刻意保守

`Xedit/AgentTerminalHostContext.swift`，注入点 `Xedit/AppStateAgentLoop.swift:619`。

三条既有取舍，都写在源码注释里，本设计不得推翻：

1. **只在「可能改变结论」时才说**（`AgentTerminalHostContext.swift:53` `isWorthReporting`）：仅当存在**已知远程**或**状态不确定**的 tab 才注入。原文理由：确信是本地的 tab「tells the model nothing it does not already assume」——说了纯属浪费 token。
2. **不主动探测**（`AppStateAgentLoop.swift:615` 注释）："probing here would type into the user's live PTY on every turn"。只报宿主已观测到的状态；从没探过就是 `unknown`。
3. **不进缓存稳定前缀**：放在 dynamic context marker 之后，因为「一条 `ssh` 就会改变它」。

配套限制（上一轮调查所得）：探针只在**活动 tab 且 shell 空闲**时打一次（`AgentTerminalTools.swift:123`），`listTabs` 刻意只探活动 tab，其余一律报 `unknown`（`:485`）；`tab.kind` 只说明创建方式，手敲 `ssh` 之后仍是 `local`；`.changed` / `.disconnected` / `.unknown` **刻意不回落 local**（`:523-550`）。

**推论**：终端这一半不是「没有机制」，而是机制保守 + 观测受限。用户的痛点落在保守的那一侧——宿主判断不出「这一轮用不用得上」，只有用户知道。

### 1.2 浏览器当前页：完全没有进过 prompt

`AgentContextBuilder.swift:16-18` 只有 `browserUI` 这类**工具使用指南**（chrome_* / embedded_browser_* 在 expert 激活时才出现），没有任何一处把「侧边栏浏览器此刻停在哪个 URL」作为事实注入。面板自己持有 `loadedURL`（`AgentSidePanel.swift:1559`），但只用于界面显示。

所以用户说的两个例子，一个是「机制保守」，另一个是**彻底空白**。

### 1.3 `@` 的现有形态

统一探测 `ComposerTextInput.swift:586`；候选构造 `AgentModeComposerView.swift:750` `filteredAtEntries`，三类：worker / workspace / file；提交 `AgentModeComposerView.swift:1394` `commitSelectedAtEntry()`。

两条落点截然不同：

- `@file` / `@workspace` → 内容拼进 prompt（`AppStateAgentComposer.swift:1932` `composeAttachedPrompt`），**这是引用**。
- `@worker` → 不进 prompt，转成 `pinnedDecision` 改这一轮派发路由，消费即清空（`AppStateAgentLoopDispatch.swift:48`），**这是路由**。

本设计要加的属于**前者**：拼一句事实进 prompt，跟 `@file` 同一条路。

## 2. 设计方案

### 2.0 入口：`+` 菜单为主，`@` 为辅

2026-09-16 用户补充（附 Claude Code 与 Claude 桌面版的 `+` 菜单截图）：

> 我更期望在这个加号点击之后，像 codex 或者 cloud code 一样，直接附加。比如说附加文件或者是附加目录，或者改为目标模式，或是附加侧边终端。这样更好吧？用户也不用打字了

**现状**：WillDeep 的 `+` 不是菜单，是单动作按钮——`AttachButton(action: attachFilesFromPanel)`（`AgentModeComposerView.swift:1071`，按钮本体 `AgentComposerAttachments.swift:32`），点下去直接弹文件选择面板。

**两个入口解决的是不同问题，都要留**：

| 入口 | 服务的场景 | 代价 |
| --- | --- | --- |
| `+` 菜单 | **还不知道有什么能用**——点开看见清单 | 两次点击 |
| `@` 打字 | 已经知道要什么，直接打 | 要记得住名字 |

**硬性要求：同一份候选源。** `+` 菜单与 `@` 菜单必须由同一个数据源生成（现有 `filteredAtEntries`，`AgentModeComposerView.swift:750`），否则两份清单会各自演化，最后互相不认识——这个仓库已经吃过同类亏（`ComposerOverflowPill` 传的是 `controls: []`，导致溢出弹层里本该出现的两行实际不出现，`AgentComposerPickers.swift:399`）。

**菜单分组**，因为这些条目的性质并不相同，混在一张平铺列表里会误导：

```
附加到这一轮
  📎 文件和文件夹…              ← 现有能力 + 新增"文件夹"（见 §2.0.1）
  🖥 侧边栏终端现状              ← 本设计新增
  🌐 侧边栏浏览器现状            ← 本设计新增
  📁 工作区概览
这一轮的做法
  👷 点名 Worker…               ← 注意：这是路由，不是附加
  🧩 挂载技能…
会话设置
  🎯 目标模式                    ← 与下排 AgentModePickerPill 同一状态
```

第三组（会话设置）是否纳入见「待确认 6」——它跟前两组的语义不同：前两组作用于**这一轮**，它作用于**整个会话**。Claude 桌面版把「目标 / 计划模式」放进同一张「添加」菜单，是可参照的先例，但 WillDeep 已有 `AgentModePickerPill` 常驻在下排，重复入口要确保两者读写同一个状态。

#### 2.0.1 顺带发现的缺口：没有「附加文件夹」

用户截图里 Claude Code 的菜单有 `Add folder`。WillDeep 现在只有两档：单个文件（`@file`，上限 30）和整个工作区概览（`@workspace`），**中间没有「就这一个目录」**。大仓库里这是真实缺口——想让 AI 只看 `docs/` 或 `Xedit/AgentTerminal*`，现在只能一个个挑文件或者把整个工作区概览塞进去。

本设计**不包含**该能力的实现（它属于附件体系，不属于面板状态），但建议同批考虑，因为入口菜单化之后这一档的缺失会变得显眼。见「待确认 7」。

### 2.1 `@` 新增一类候选：面板现状

在 `filteredAtEntries` 中加入第四类 `panelState`，候选随当前可用面板动态生成：

| 候选 | 插入的事实（示例） | 数据来源 |
| --- | --- | --- |
| `@终端` | `侧边栏终端「niuwo」当前连在 root@h1.niuwoai.com` | `tab.hostLine`（已有，`AgentInteractiveTerminal` 的诚实渲染，含两种「拒绝报出主机」的状态） |
| `@终端`（本地） | `侧边栏终端当前是本机 shell` | 同上 |
| `@终端`（未探过） | `侧边栏终端当前主机未知（未探测过或连接已变）` | 同上 |
| `@浏览器` | `侧边栏浏览器当前停在 https://some.im/admin` | `AgentSidePanel` 的 `loadedURL`（需新暴露到 AppState） |

**取值是快照，不是实时探测**：沿用 §1.1 第 2 条——`@` 触发时只读宿主已观测到的状态，不向用户的 live PTY 打字。未知就如实说未知，**不猜成本机**。

#### 2.1.1 候选的命名与匹配：英文 id + 本地化显示名

2026-09-16 用户提出「不要用『终端』『浏览器』，用英文名会不会好一点」。**真实成本不在审美，在输入法**：`@` 触发后要打字筛选，中文候选名意味着用户得先切一次输入法。

仓库里已有现成范式，**照抄即可**——`@worker` 的匹配是双路的（`AgentModeComposerView.swift:792` 附近）：

```swift
return profile.id.lowercased().contains(q)
    || profile.localizedDisplayName.lowercased().contains(q)
```

另一侧的 `/` 命令则是清一色英文 id（`/no-sandbox` / `/compress` / `/subagent`，`AgentComposerPaletteViews.swift:105-150`），只有副标题走 L10n。

**本设计采用双路方案**：

| 面板 | id（匹配键，也是英文用户看到的名） | 本地化显示名（zh-Hans 示例） |
| --- | --- | --- |
| 侧边栏终端 | `terminal` | 侧边栏终端 |
| 侧边栏浏览器 | `browser` | 侧边栏浏览器 |

- 打 `@ter` 命中，**不用切输入法**；打 `@终端` 同样命中。
- 菜单里显示本地化名，中文用户读得懂。
- **不硬编码任一语言**：硬编码英文会让日 / 韩用户看见孤立英文词；硬编码中文会让英文用户完全看不懂。WillDeep 有五种语言的 xcstrings，双路匹配两边都不牺牲。
- 插入 prompt 的事实文本本身**用中文还是英文另议**——它是给模型看的，不是给用户看的，倾向跟随会话语言，见「待确认 9」。

### 2.2 它如何进入请求

走 `composeAttachedPrompt` 现成的那条路，作为一个独立小节，与 `### Workspace` / `### File:` 并列：

```
### Panel state
- 侧边栏终端「niuwo」当前连在 root@h1.niuwoai.com
- 侧边栏浏览器当前停在 https://some.im/admin
```

**刻意不写任何指令性文字**。不写「请在该终端执行」，不写「你可以使用它」——那会把告知偷偷变成指定。事实摆在那里，用不用是 AI 的判断。

### 2.3 与自动注入的关系

手动 `@终端` 与 §1.1 的自动注入**可能重复**（当活动 tab 确实是远程时，自动注入本就会说）。处理：

- 允许重复，但去重：`composeAttachedPrompt` 生成的 Panel state 小节与 `AgentTerminalHostContext.promptBlock` 内容相同时，**只保留自动注入那份**（它位置更靠后、更接近模型注意力，且每轮都在）。
- 手动提及的真正价值在自动注入**不会说**的那些情况：确信本地的 tab、浏览器 URL、以及用户认为「这一轮该看一眼」的时刻。

### 2.4 单轮语义

与 `agentPendingFiles` / `agentPendingSkills` 一致：**只作用于这一轮，发送后清空**（`AppStateAgentComposer.swift:161-166` 是现成的清理点）。

不做粘性。理由：面板状态本身在变（一条 `ssh`、一次导航就变了），粘性引用会把过期事实反复塞进后续每一轮，比不说更糟。

## 3. 明确不做

- **不做执行落点选择器**（粘性 pill、工具集裁剪、派发重定向）。用户已明确这超出量级。
- **不碰审批、沙箱、路由**。本设计只往 prompt 里加一段文本，不改变任何工具的可用性或审批结果。
- **不新增触发符号**。`@` 足够，且语义正好落在它已有的「引用」那一半。
- **不主动探测面板状态**。见 §2.1。
- **不写指令性措辞**。见 §2.2。
- **不做粘性**。见 §2.4。

## 4. 失败与边缘路径

| 场景 | 行为 |
| --- | --- |
| 没有开侧边栏终端 | `@终端` 候选不出现 |
| 有终端但从未探测过主机 | 候选出现，事实写作「主机未知」，**不猜成本机** |
| 活动 tab 刚被 `ssh` 改过（`.changed`） | 如实写「连接已变，主机未知」——沿用 `hostLine` 对五种状态的诚实渲染 |
| 浏览器面板未打开 / 空白页 | `@浏览器` 候选不出现 |
| 用户 `@终端` 之后又切了 tab 才发送 | 取**发送时刻**的快照，不是选中时刻——否则摆给 AI 的是一条过期事实 |
| 同一轮既手动 `@终端` 又触发了自动注入 | 去重，保留自动注入那份（§2.3） |

## 5. 留存结论：QTerm 的安全边界（与本设计无关，但已复核）

初版设计调查时顺带复核了 QTerm（`~/Sites/museterm/museterm`，v1.243.0-rc3）的三个已知缺口，两条确认仍在，记在此处备查：

1. **MCP 写入绕过危险命令拦截**：`sendToolInput`（`museterm/TerminalHostView.swift:394`）只检查进程存活即直通 `sendProcessInput`；`SafetyInputAnalyzer` 只挂人类输入/粘贴回调。
2. **审计不记命令内容**：`~/Library/Application Support/QTerm/Tools/access-audit.jsonl` 实际样本（2026-09-14）仅 `{action:"input", clientID, result, timestamp}`。
3. 读接口鉴权与脱敏：未复核。

另：WillDeep 侧 `call_mcp_tool` 被固定归为 `workspaceWrite + requiresUserApproval`（`AgentToolAuthorization.swift:514-521`），**命令文本从不过命令分类器**——这条路上 `rm -rf /` 与 `ls` 对宿主无差别。

**与本设计的关系**：本设计不把 QTerm 作为可提及的面板。它不是 WillDeep 的侧边栏面板，宿主也读不到它的状态（仓库内无任何 QTerm 专有代码，`grep -i qterm` 只命中「关于」窗口的产品推荐）。要提及 QTerm 状态需要先经 MCP 读取，那已经是另一件事。

## 6. 验收标准

1. `@终端` / `@浏览器` 出现在 `@` 菜单中，与 worker / workspace / file 并列，仅在对应面板可用时出现。
2. 选中后发送，请求里出现 `### Panel state` 小节，内容为发送时刻的快照。
3. 主机未知时如实写未知，不出现「本机」字样——可由单测钉住（`.changed` / `.disconnected` / `.unknown` 三种状态各一条）。
4. 该小节不含任何指令性措辞（不出现「请」「应当」「使用该终端」）。
5. 只作用于一轮，下一轮不再出现。
6. 审批档位、沙箱档位、工具可见性均不受影响——正反例成对钉住。

## 已确认决策（2026-09-16）

| # | 决策 | 影响 |
| --- | --- | --- |
| 6 | **`+` 菜单放「会话设置」这一组** | 菜单三组齐全；须确保「目标模式」与下排 `AgentModePickerPill` 读写同一状态，不得各存一份 |
| 7 | **不做「附加文件夹」** | §2.0.1 记录的缺口保留为待办，本批不实现；`+` 菜单第一项维持现有的「文件…」语义 |
| 9 | **插入 prompt 的事实文本固定英文** | 与既有的 `AgentTerminalHostContext.promptBlock`、工具描述、系统提示词同语言；两份内容讲同一件事却一中一英，会让 §2.3 的去重更别扭 |
| 8 | **`+` 复用 `@` 那套自绘弹层**（`AtPickerMenu`，`AgentComposerPaletteViews.swift:577`），不用系统 `Menu` | 外观与候选源天然统一，代价是要处理「非文本触发」的弹层定位与键盘导航——`@` 现在靠 caret 位置定位，`+` 得改成锚在按钮上 |

### 按倾向默认执行的条目（1–5，无异议即照此实施）

| # | 默认 | 理由 |
| --- | --- | --- |
| 1 | 首版只做**侧边栏终端 + 侧边栏浏览器** | 正是需求里举的两例；编辑器当前文件、diff、任务面板留待后续 |
| 2 | `@终端` **只报活动 tab** | 非活动 tab 的主机一律 `unknown`（§1.1），列全部等于列一串「未知」，信息量低还占 token |
| 3 | 浏览器 URL **复用既有脱敏口径**（`AgentSecretStore.redactPlaceholders`） | URL 可能带 token / 查询参数；与命令脱敏同一套口径，不另造 |
| 4 | **自动注入维持现状**（确信本地的 tab 仍不报） | 省 token 的取舍是源码里写明的既有判断；既然用户能手动补，不必推翻它 |
| 5 | **英文 id + 本地化显示名，双路匹配**（见下） | 见 §2.1.1 |

## 验收补充（入口部分）

7. `+` 点击后出现分组菜单，其条目与 `@` 菜单来自同一数据源——可由单测钉住：同一状态下两者候选集合相等（排除纯 UI 差异）。
8. 「附加到这一轮」的条目选中后，行为与 `@` 同名候选完全一致（同一提交路径 `commitSelectedAtEntry`）。

## 落地后补记的实现要点

### 与设计一致的部分

- `AgentPanelStateMention`（新文件）承担全部纯函数：面板种类、快照、prompt 块、双路匹配。渲染脱开终端控制器与 WebView，12 条单测覆盖。
- `@` 候选新增 `panelState`；`+` 由单动作按钮改为菜单，复用 `AtPickerMenu`、共用 `filteredAtEntries`。
- 快照在**发送时刻**取（`AppState.panelStateMentionBlock(for:)`），非点选时刻。
- 与 `AgentTerminalHostContext` 去重：自动注入会讲终端时抑制手动那份。
- 单轮语义：`runtime.pendingPanelStateMentions`，发送后清空。
- prompt 文本固定英文，带 `<untrusted-panel-state>` 围栏与「视为数据」声明；浏览器 URL 过 `AgentSecretStore.redactPlaceholders`。

### 与设计不同 / 收窄的部分

1. **`+` 菜单没有「挂载技能」**。设计 §2.0 的草图列了它，实现时未做：skill 走另一套候选类型（`SkillPickerEntry`，`$` 的入口），并入需要一个联合类型，改动量大于本批其余部分之和。`$` 仍是挂技能的唯一入口，现有用法不受影响。**留作后续**。
2. **`+` 与 `@` 的候选集不完全相同**：会话设置组（目前只有「目标模式」）只在 `+` 出现。`@` 的语义是「这一轮」，设置作用于整个会话，混进 `@` 会让人以为它也是一次性的。二者仍共用同一个 `filteredAtEntries`，差异由 `atMenuSource` 控制。
3. **菜单来源需要区分善后**：`@` 触发时缓冲区有 `@token` 需在选中后抹掉，`+` 触发时没有——照抹会删掉用户正在写的字。为此引入 `AtMenuSource`。
4. **浏览器数据源**是 `AgentEmbeddedBrowserController.shared.currentURL`（内置浏览器），不是设计初稿以为的 `AgentSidePanel.loadedURL`（那个是文件预览的 URL，与网页无关）。
5. **分组渲染不改数据结构**：`entries` 保持平铺，组标题在「本行与上一行不同组」时插入。selection 与键盘导航都按索引走，引入嵌套会把那套逻辑一起复杂化。

### 验收对照

全量 4250 tests / 390 suites 通过；i18n 覆盖 100%。设计 §6 的 1–6 条与「验收补充」7–8 条中，除「`+` 与 `@` 候选集合相等」一条按上述第 2 点**有意放宽为「共用同一数据源，差异仅在会话设置组」**外，其余均已覆盖。
