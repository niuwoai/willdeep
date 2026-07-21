# 系统提示词审计：结构问题与 Prompt Cache 命中率

> 审计时间：2026-07-21
> 审计范围：主 Agent 系统提示词组装与发送全链路、路由裁判、L10n prompt 模板、BundledSkills
> 姊妹文档：[SYSTEM_PROMPT_RESEARCH.md](SYSTEM_PROMPT_RESEARCH.md)（2026-06 外部对标调研；本文的缓存修复方案与其 Aider chat_chunks 结论一致）
> 行号基于审计当日 main 分支，后续代码变动请以符号名为准。

---

## 一、提示词全链路地图

实际发出的 system message 是分层拼装的单字符串，在 `AppStateAgentLoop.swift` 的模型回合内组装（`AgentContextBuilder.systemPrompt(...)` 调用点约 754 行），最终在 `requestMessages`（约 842 行）作为第一条 message 发出。

| 层 | 内容 | 来源 | 稳定性 |
|---|---|---|---|
| 1 | Stable Agent Contract：身份、语气、编码约定、项目硬规则、profile 段、工具契约 | `AgentContextBuilder.stableSystemPromptPrefix()`（约 296 行），版本号 `willdeep-agent-system-v8` | 稳定 |
| 2 | 全局用户规则 | `AgentGlobalRulesStore.loadRules()`，作为 `systemPrompt(...)` 的默认参数每次调用读盘 | 半稳定 |
| 3 | 项目规则：README.md、product-overview.md、AGENTS.md、CLAUDE.md（按目录层级向下叠加），每文件截 6000 字符 | `projectRules(in:openedFileURL:)`（约 436 行） | 半稳定（README 易变） |
| 4 | `=== Dynamic Turn Context ===` 之后：委派 executor 策略、session 标题、Plan/Goal 模式块、审批模式、专家包、工作区、活动文件、选区（6K 上限）、当前文件内容摘录（12K 上限） | `systemPrompt(...)` 99–293 行 | 每轮变化 |
| 5 | 循环层追加：远程工作区块、短剧图片选择、图片编辑提交、媒体任务、widget 动作、memory 检索块 | `AppStateAgentLoop.swift` 772–821 行 | 每轮变化 |
| 6 | 本地模型语言偏好（仅本地模型） | `AgentLocalModelPrompting.applyLanguageInstruction`（`AgentLocalModelSupport.swift` 约 163 行） | 稳定 |

不进主 system prompt 的三类提示词：

- **路由裁判**：`SomeIMManagedRouting.judgeSystemPrompt()`（约 150 行），独立小模型调用，严格 JSON 输出。
- **用户 prompt 模板**：`L10n.swift` 中 automation 模板（Daily Brief / Project Monitor / Weekly Review）与 `designToCodePrompt`，作为 user message 发送，走 i18n。
- **BundledSkills**：39 个 `BundledSkills/*/SKILL.md`，经 `list_skills` / `read_skill` 按需加载，不常驻上下文。

Profile 机制（compact / standard / extended，按模型 ID 自动选择，`AgentSystemPromptProfile.automatic`）与"稳定前缀在前、动态在 marker 后"的分界设计，骨架是对的。问题在下面两章。

---

## 二、Prompt Cache 命中率：三个硬伤（最高优先级）

前缀缓存按**最长公共字节前缀**命中，请求结构为 `[tools, system, msg1, msg2, …]`。任何一处字节变化，其后全部内容缓存失效。长会话里会话历史占输入 token 的 90% 以上，因此缓存问题的成本量级**远大于**提示词冗长问题。

### 硬伤 1：Anthropic 主链路完全没打 cache_control（命中率 = 0%）

- 位置：`AgentClientAnthropic.swift` 主请求体构造（约 641–652 行）。
- 现状：`system` 是拼接后的纯字符串，`messages` / `tools` 上没有任何 `cache_control` 断点。Anthropic 的缓存必须显式打断点才生效，因此主 Agent 循环在 Anthropic 直连下**没有任何 token 被缓存过**。
- 对照：注入防御裁判（同文件约 181–187 行）反而正确使用了 block 数组 + `"cache_control": {"type": "ephemeral"}`，注释也写明了缓存意图——说明团队知道这个 API，只是主链路漏了。
- OpenAI / DeepSeek 走自动前缀缓存，不受此条影响，但受硬伤 2、3 影响。

### 硬伤 2：动态内容放在 system message（位置 0），每轮打穿整个 history 前缀

- system 的后半段（Dynamic Turn Context 起）包含：session 标题、Plan/Goal 状态、审批模式、活动文件、选区、12K 字符文件内容摘录、memory 检索块（`AppStateAgentLoop.swift` 约 819 行，按最新用户消息检索，几乎每轮必变）。
- 这些内容**只要变一个字节，system 之后的全部会话历史缓存失效**。自动前缀缓存的 provider（DeepSeek / OpenAI）命中上限就是稳定前缀那 4–8K token；几十万 token 的长会话历史每轮全价重算。
- 注意：`cacheDiagnostics`（`AgentContextBuilder.swift` 约 422 行）只度量 system 内部稳定前缀的长度与哈希，**测的不是命中率**，容易产生"已为缓存优化"的错觉。

### 硬伤 3：工具结果折叠边界随轮次移动，history 本身逐轮变字节

- 位置：`AppStateAgentContextCompression.collapseOldToolResults`（约 266 行）。
- 折叠决策依赖 `latestUserIndex` 与"保留最近 2 条"窗口，两者每轮移动：上一轮以完整形态发出的 tool 结果，本轮被折叠成摘要；`preferCompactSummary: isBeforeLatestUser` 使保留的结果也随新用户消息变换表示。
- 结果：即使 system 完全不变，history 也从最早被新折叠的消息处开始 divergence。缓存要求旧消息**字节级不变**，当前滑动窗口设计与缓存结构性冲突。

### 次要：工具列表变化整体清缓存

`AgentToolRegistry.tools(activeExperts:interactionMode:executionAgent:)`（调用点约 854 行）随专家激活 / 模式切换变化；`tools` 在缓存前缀最前面，变化一次即整体清缓存。属一次性代价，可接受，但需知情。

### 修复路线（按投入产出排）

1. **Anthropic 补断点**（约 1 小时）：system 改 block 数组（裁判已有现成写法），在 system 末尾与最后一条 message 打 `ephemeral`（上限 4 个断点）。直接把 Anthropic 从 0% 拉到正常水平。
2. **动态 turn context 移出 system**：system 只留 Stable Contract + 全局规则 + 项目规则（字节稳定）；每轮动态块附加到**最后一条 user message**（Claude Code 的 system-reminder 模式、Aider 的 chat_chunks 八段切分同理，见姊妹文档）。使 `[tools + system + 旧 history]` 整段可命中。
3. **折叠单调化**：一条 tool 结果一旦以某形态发出即持久化该形态，后续轮次不再重算；压缩只在显式 compaction 时发生（打穿一次，随后重新稳定），不做每轮滑动。
4. **量化验证**：`usageReported` 已落 `cachedPromptTokens` / `promptTokens` / `cacheWritePromptTokens` 到消息上（`AppStateAgentLoop.swift` 约 877–884 行），直接用现网数据算逐轮 `cached / prompt` 命中率，改造前后对比，无需新埋点。

成本量级：cache 读价通常为全价 0.1x（Anthropic、DeepSeek 均是）。100K token 上下文的长会话，现状每轮近全价；改造后 90%+ 走缓存价，输入侧成本差接近一个数量级。

> 改造 2、3 会改变发给模型的消息结构，建议单独 feature 分支，附命中率前后对比再合入。

---

## 三、提示词内容问题清单

### P0：compact profile 没省到该省的地方

- `Stable tool contract`（`stableSystemPromptPrefix` 内 `toolsEnabled` 分支，约 381–416 行，约 35 条超长 bullet，粗估 4000+ token）**不随 profile 裁剪**，全档位全量下发。
- compact 档只把 profile 说明段换成 4 行短文，省不到 100 token。给 deepseek-flash / haiku 级小模型灌 35 条密集指令，遵循率差——这正是 compact 档要解决却没解决的问题。
- 建议：tool contract 按档位分级。compact 只留工具语义必需项（edit_file / create_file 用法、审批模式、终端绑定）；ZMODEM、learning checkpoint、MCP 发现、专家激活等长尾仅 standard / extended 下发。

### P1：同一指导重复 2–3 处，措辞不一致，有漂移风险

| 主题 | 出现位置（`AgentContextBuilder.swift` 行号，另注明者除外） | 处数 |
|---|---|---|
| session 改名（suggest_session_title / rename_session） | 动态区 118–124；Extended map 367；Stable contract 385 | 3 |
| heredoc / shell 写文件禁令 | 硬规则 332；Stable contract 387；远程块 `AppStateAgentLoop.swift` 786 | 3（政策细节互有出入） |
| create_file / edit_file 用法 | 305；Extended map 368–369；Stable contract 389 | 3 |
| list_queued_tasks | 371；402 | 2 |
| add_memory / learning checkpoint | 393；413 | 2 |

建议：每条规则收敛到唯一权威位置，其余删除或只留一句指针。

### P1：语言指令三层叠加，会自相矛盾

- 硬规则写死 `Reply in Simplified Chinese`（约 331 行）；紧接 `AppLocale.systemPromptDirective`（`AppLocale.swift` 约 54 行）要求跟随用户偏好语言——用户 locale 为英文时两条直接冲突；本地模型再追加第三段 `LOCAL MODEL LANGUAGE PREFERENCE`。
- 建议：删硬规则那条，语言指令只留 AppLocale 单一来源；本地模型段可保留（对弱模型的强化措辞）。

### P2：稳定前缀开头与工具契约打架

- 约 306–307 行 "Only generate diffs for existing files… Avoid new files… unless the user explicitly asks" 是给**无工具模式**写的，但措辞无条件，与工具契约"建新文件永远用 create_file"（389 行）抵触。
- 建议：这两句加 "Without tools" 限定，或移入 `toolsEnabled == false` 分支。

### P2：README.md 被当"项目规则"整段注入

- `projectRules`（约 439 行）把 README.md 前 6000 字符注入稳定区。README 是面向人的介绍文档，非 agent 规则：占 token、稀释真规则权重，且 README 常变，一变即打穿缓存稳定区。
- 建议：只保留 AGENTS.md / CLAUDE.md / product-overview.md；README 降级为按需 read_file。

### P2：`stablePrefixVersion` 无守护

- `v8` 为手工字符串，改前缀文本忘 bump 无任何检测。
- 建议：加单元测试对 `stableSystemPromptPrefix` 输出做哈希快照断言，文本变化时强制同步改 version 与快照。

### P3：小问题

- `globalRules` 作为**默认参数**每次调用同步读盘（`systemPrompt` 签名约 75 行），在 MainActor 回合路径上，可缓存至设置变更。
- 路由裁判 prompt 指示永远输出 `"target_model":null`，但 `decodeVerdict` 保留 allowlist 校验——按指示该字段永不非空，属防御性死代码，建议在 `SOME_IM_MANAGED_ROUTING_DESIGN.md` 或代码注释明确"刻意保留"。裁判本体质量好：注入防护、严格 JSON、低置信度升档、384 token 预算均正确。
- "Default to no more than 4 lines"（约 312 行）与 Plan/Goal 模式必须输出的 progress / goal-check 块有张力，建议补一句"结构化汇报块不计入行数限制"。
- BundledSkills 中 `telegram`（349 行）、`self-management`（280 行）偏长，按需加载命中时上下文压力大，可瘦身。
- `designToCodePrompt`（L10n）中 "Keep correcting material differences until visual acceptance passes" 无终止条件措辞，有循环烧 token 风险，建议加轮数上限措辞。

---

## 四、建议动手顺序

1. **缓存修复 1**：Anthropic 客户端补 cache_control 断点（低垂果实，独立可发）。
2. **P0 + P1 内容修**：tool contract 按 profile 分级；三处重复去重；语言指令收敛。改动稳定前缀需 bump `stablePrefixVersion` 至 v9 并递增 rc 号。
3. **缓存修复 2 + 3**：动态 context 移出 system、折叠单调化（改变消息结构，单独分支 + 命中率前后对比）。
4. **P2 收尾**：README 移出规则注入、stable prefix 快照测试、无工具措辞限定。

每步用现有 `cachedPromptTokens` telemetry 验证命中率变化；内容修部分用小模型（deepseek-flash）做遵循率抽查。
