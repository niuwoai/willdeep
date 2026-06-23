# 系统提示词调研与改进建议

> 调研对象：Anthropic Claude Code、OpenAI Codex CLI、OpenCode / Aider / Cline、NousResearch Hermes
> 调研时间：2026-06-23
> 对比基线：`Xedit/AgentContextBuilder.swift` 中 `stableSystemPromptPrefix()`（约 3K 字符）

---

## 一、调研结论一览

| 项目 | 最值钱的一招 | system prompt 长度 |
|---|---|---|
| **Claude Code（Anthropic 官方）** | Tone 段 + 并行工具调用 + `file_path:line_number` 引用规范 | 经典版 ~3K、新版 Opus 4.8 ~17K |
| **Codex CLI（OpenAI 官方）** | 长 prompt 教格式与红线，1 行模板做运行时状态注入；AGENTS.md 嵌套作用域 | gpt-5-codex 专用 **6.6KB** |
| **Aider** | **chat_chunks 八段切分**：动态信息全甩 user 末尾，保住 system 缓存前缀 + `warm_cache` 5min TTL 线程 | system ~1.5–2K tok |
| **Cline** | XML 伪 tool call 兼容多模型（缺点：肿） | **12K–60K**，不可借鉴 |
| **Hermes（NousResearch）** | `<think>` / `<scratch_pad>` GOAP 四段 + "Don't make assumptions about values" 反幻觉句 | 模型层模板，不直接适用 |

---

## 二、各项目核心摘录与出处

### 2.1 Claude Code

**经典版 tone 段**（出处：[x1xhlol/system-prompts-and-models-of-ai-tools](https://github.com/x1xhlol/system-prompts-and-models-of-ai-tools)）：

```
You MUST answer concisely with fewer than 4 lines (not including tool use or
code generation), unless user asks for detail.
IMPORTANT: You should minimize output tokens as much as possible while
maintaining helpfulness, quality, and accuracy.
After working on a file, just stop, rather than providing an explanation of
what you did.
Only use emojis if the user explicitly requests it.
```

**Code style 一行狠话**：

```
- IMPORTANT: DO NOT ADD ***ANY*** COMMENTS unless asked
```

**Tool usage policy**：

```
- You have the capability to call multiple tools in a single response. When
  multiple independent pieces of information are requested, batch your tool
  calls together for optimal performance.
```

**Skill 自动发现（新版 Opus 4.8）**：

```
- Available skills are listed in system-reminder messages in the conversation
- Only invoke a skill that appears in that list. Never guess or invent a skill
  name from training data
- When a skill matches the user's request, this is a BLOCKING REQUIREMENT:
  invoke the relevant Skill tool BEFORE generating any other response
```

**内置但 Xedit 大概率没有的机制**：TodoWrite、Plan mode、Skill 自动发现、Subagent fan-out（Explore/Plan/general 三档）、Hooks、spawn_task、Worktree 隔离、Deferred tools + ToolSearch、`<system-reminder>` 注入通道、context compaction。

### 2.2 Codex CLI

**gpt-5-codex 专用 prompt（仅 6.6KB）**（出处：`github.com/openai/codex` 路径 `codex-rs/core/gpt_5_codex_prompt.md`）：

```
## Personality
Your default personality and tone is concise, direct, and friendly. You
communicate efficiently, always keeping the user clearly informed about
ongoing actions without unnecessary detail.

## Editing constraints
- Try to use apply_patch for single file edits…
- NEVER revert existing changes you did not make unless explicitly requested.
- NEVER use destructive commands like `git reset --hard` or `git checkout --`
  unless specifically requested or approved by the user.
- Do not waste tokens by re-reading files after calling `apply_patch` on them.
  The tool call will fail if it didn't work.

## Plan tool
- Skip using the planning tool for straightforward tasks (roughly the easiest 25%).
- Do not make single-step plans.

## Output format
- Default: be very concise; friendly coding teammate tone.
- File References: Use inline code to make file paths clickable. Examples:
  `src/app.ts:42`. Do not use URIs. Do not provide range of lines.
```

**沙箱/审批模板（全部 1 行）**：

```
# sandbox_mode/read_only.md
Filesystem sandboxing defines which files can be read or written. `sandbox_mode`
is `read-only`: The sandbox only permits reading files. Network access is
`{{network_access}}`.

# approval_policy/never.md
Approval policy is currently never. Do not provide the `sandbox_permissions`
for any reason, commands will be rejected.
```

**AGENTS.md 嵌套作用域**：

```
- Repos often contain AGENTS.md files. These files can appear anywhere within
  the repository.
- The scope of an AGENTS.md file is the entire directory tree rooted at the
  folder that contains it.
- For every file you touch in the final patch, you must obey instructions in
  any AGENTS.md file whose scope includes that file.
- More-deeply-nested AGENTS.md files take precedence in the case of conflicting
  instructions.
```

**Codex 独有概念**：apply_patch envelope、update_plan tool、AGENTS.md 嵌套、Sandbox tier × Approval policy 矩阵、prefix_rule 提权学习、preamble messages、`/init` 生成 AGENTS.md、compact prompt、multi-agent v2 + spawn 工具。

### 2.3 Aider

**chat_chunks 八段切分**（出处：[aider/coders/chat_chunks.py L28-44](https://github.com/Aider-AI/aider/blob/main/aider/coders/chat_chunks.py)）：

```
system → examples → readonly → repo → done → chat_files → cur → reminder
                                ↑                  ↑               ↑
                          cache_control      cache_control    放末尾/转
                          ephemeral 断点    ephemeral 断点    user 消息
                                                              避免破坏前缀
```

外加 `warm_cache` 后台线程维持 5min TTL（Anthropic ephemeral cache 默认 5 分钟过期）。

**SEARCH/REPLACE 文本块**（不抄，仅记录）：

```
<<<<<<< SEARCH
old code
=======
new code
>>>>>>> REPLACE
```

### 2.4 Cline

**XML 伪 tool call**（不抄，仅记录）：

```xml
<read_file>
  <path>src/index.ts</path>
</read_file>
```

为兼容 OpenAI/Gemini/本地模型同一套 prompt，每次只准一个 tool。代价是 17K–60K 的 prompt。

### 2.5 Hermes

**Reasoning Mode**（出处：[Hermes-4-14B model card](https://huggingface.co/NousResearch/Hermes-4-14B)）：

```
You are a deep thinking AI. You should enclose your thoughts and internal
monologue inside <think></think> tags, and then provide your solution.
```

**Function Calling**（出处：[Hermes-Function-Calling](https://github.com/NousResearch/Hermes-Function-Calling)）：

```
You are a function calling AI model. You may call one or more functions to
assist with the user query. Don't make assumptions about what values to plug
into functions. Here are the available tools: <tools>[...JSON schema...]</tools>

For each function call return a json object with function name and arguments
within <tool_call></tool_call> XML tags.
```

**Hermes-3 GOAP `<scratch_pad>`**：四段 Goal / Actions / Observation / Reflection，再发 `<tool_call>`。

---

## 三、Xedit 当前的具体短板（按危害排序）

诊断 `Xedit/AgentContextBuilder.swift:187-225`：

1. **缺 Tone/Style 段** → 模型默认啰嗦。
2. **缺 Code style 一行狠话**：`DO NOT ADD ANY COMMENTS unless asked`。CLAUDE.md 已要求"默认不写注释"，但 prompt 里没说。
3. **缺 Following conventions 三条**：不假设库存在、看邻居文件、不 log secrets。
4. **缺 `file_path:line_number` 引用规范** —— 编辑器天生卖点没用上。
5. **缺并行工具调用鼓励**：模型默认串行调用，慢且贵。
6. **动态环境 vs 稳定前缀混在一起**：`AgentContextBuilder.systemPrompt()` 把 workspace path / approval mode / currentPlan / selection / file content 全拼成一个大字符串返回。`approval mode` 插在 stable 前缀和动态段之间，**会破坏 5 分钟缓存**。
7. **i18n / "禁止硬编码 UI 文案" 强约束未注入 prompt** —— CLAUDE.md 第 2 条 MUST，但 prompt 里没说。
8. **版本号铁律未注入** —— CLAUDE.md 第 5 条 MUST，但 prompt 里没说，全靠用户事后追。

---

## 四、可落地改进清单（按 ROI 排序）

### 🟢 立刻加（成本几乎为零）

#### A. Tone 段（约 +200 字符）

```
Tone:
- Be concise and direct. Default to ≤4 lines plus the diff/tool result.
- No preamble like "I'll do X" — just do it.
- After producing a diff, stop. Don't restate what changed.
- No emojis unless asked.
- Reference code as `path/to/file.swift:42` so the user can click.
```

#### B. Code/convention 三行铁律（约 +180 字符）

```
- Don't add comments unless asked.
- Don't assume a library is available — check the project's manifests first
  (Package.swift, package.json, etc.).
- Never log or echo secrets, tokens, or .env contents.
```

#### C. 并行工具调用一行

```
- When tool calls are independent, batch them into one assistant turn so they
  run in parallel.
```

#### D. 注入 CLAUDE.md 强约束摘要（≤200 字符）

```
Project hard rules (from CLAUDE.md):
- Reply in 简体中文; never hardcode user-visible strings in JSX/TSX — use i18n.
- Prefer yarn over npm/pnpm.
- After code changes: bump version (semver, rc# for bugfix), keep frontend/
  backend versions in sync.
- Don't generate/overwrite files via cat/echo/heredoc — use the edit tool.
- A single file shouldn't exceed 3000 lines.
```

> 当前 `projectRules()` 已读 CLAUDE.md 全文（≤6K 字符）但放在 prefix 之后，**没进缓存前缀**。建议把"用户全局 CLAUDE.md 摘要句"硬编码进 stable 前缀，详细原文继续走动态注入。

### 🟡 中期重构（**最关键，影响 cache hit rate**）

#### E. 重排 `systemPrompt()` 拼接顺序，模仿 Aider chat_chunks

当前实现把 `approval mode` / `workspace` / `file content` 全拼进 system 字符串，每轮都变 → cache 永远命中不到 ephemeral 边界后面。

建议结构：

```
[system part 1: stable prefix v2 + tone + conventions]   ← 缓存命中
[system part 2: 用户全局 CLAUDE.md 全文]                   ← 缓存命中（同会话）
[system part 3: 项目 CLAUDE.md/AGENTS.md/README 全文]      ← 缓存命中（同项目）
[system part 4: workspace root path + 当前 approval mode]  ← 易变，独立 part
---
[user messages...]
[最后一条 user message 末尾追加:
   当前打开文件路径 / selection / file content excerpt]    ← Aider 风格
```

Anthropic API 的 `cache_control: {"type": "ephemeral"}` 在 part 1/2/3 末尾各打一个断点。**预期：同会话 cache hit 从 ~30% → ~85%。**

#### F. 学 Codex 的"骨架 + 切片"分层

把 `AgentApprovalMode.systemPromptDescription`（每个 mode 一长段）改成 **每个 mode 一句话**，类似 Codex 的 `sandbox_mode/*.md` 各 1 行：

```
Approval policy: SMART. Read-only tools auto-run; writes need approval;
destructive cmds need typed confirm.
```

切换 mode 只让最后一个 system part 失效，前面 stable 段不受影响。

#### G. AGENTS.md 嵌套作用域

`projectRules()` 当前只在 root 找一次。建议从 root 到当前文件目录逐层收集 AGENTS.md / CLAUDE.md，子目录覆盖父目录。比单文件优雅，monorepo 场景特别有用。

### 🔵 长期可选（看产品形态）

| 项 | 出处 | 描述 |
|---|---|---|
| **H. Skill 自动发现** | Claude Code | 每轮 `<system-reminder>` 注入"当前可用 skill 名单"，强约束"只调列表里的" |
| **I. `<think>` / `<scratch_pad>` GOAP 标签** | Hermes | 复杂任务前置规划，UI 折叠展示；对 OpenAI/Gemini 客户端尤其有用 |
| **J. preamble messages 规约** | Codex | 每个 tool call 前 1-2 句 8-12 词的"接下来要做什么"，改善"沉默 30 秒"体验 |
| **K. update_plan 反例教学** | Codex | 在 prompt 里加 1-2 个"高质量 plan vs 低质量 plan"反例，比正例有效 |

---

## 五、明确**不该抄**的（避坑清单）

| 不抄 | 理由 |
|---|---|
| Cline 17K–60K 巨型 prompt | 为兼容 5 家模型的代价；Xedit 三家 SDK 各自原生 tool call 更稳更省 |
| Cline 的 XML 伪 tool call | 同上 |
| Aider SEARCH/REPLACE 文本块 | 2023 年没 tool calling 时代的产物，原生 tool 更可靠 |
| Aider 的 auto-commit | 违反"用户主导"原则，且和 CLAUDE.md "key 不上 git" 安全约束冲突 |
| Codex apply_patch envelope | macOS 原生有结构化 Edit/Write tool，没必要让模型生成自定义 diff 文本 |
| Codex `prefix_rule` 提权 DSL | CLI 沙箱专属，macOS 用系统权限对话框即可 |
| Hermes ChatML `<|im_start|>` 特殊 token | 接的是 SaaS API，三家自己处理 message 格式，强塞反污染 |
| Claude Code 新版 Opus 4.8 散文风 1700 行 | 散文风需要超强模型 + 海量工具撑场，撑不起也没必要 |
| Claude Code 完整 Workflow DSL / Worktree 隔离 / Hooks | 工程量爆炸，等用户量再说 |
| Hermes "function-calling AI model" 自我定位句 | 三家原生 tool use 自己会处理，重复声明让 Claude/GPT 行为变怪 |

---

## 六、Token 预算与缓存命中率估算

| 阶段 | stable prefix 字符 | 增量 | 预期缓存命中率 |
|---|---|---|---|
| 现状 | ~3000 | — | ~30%（拼接顺序导致） |
| 加 A+B+C+D 后 | ~3600 | +600 | ~30%（结构没改） |
| 完整重构 E+F+G 后 | ~3800 | +800 | **~85%** |

**净效果**：prefix 长 800 字符，但缓存命中翻 ~2.8 倍。**单轮 token 成本反而下降**（缓存命中部分只算 10% 价格）。

---

## 七、建议执行顺序

1. **今天**：加 A/B/C/D 四段（改一个文件，<50 行 diff）
2. **本周**：重构 E（拼接顺序）+ F（approval mode 压成一行）
3. **下周**：实现 G（AGENTS.md 嵌套）
4. **下个迭代**：H（skill 自动发现）+ J（preamble messages）

按 CLAUDE.md 规则：每完成一步同步 bump 版本号（A-D 算 bugfix → rc 递增；E-G 算功能新增 → 次版本递增），并更新 CHANGELOG 与 product-overview.md。

---

## 附录：调研原始资料索引

| 来源 | URL |
|---|---|
| Claude Code 经典版 prompt | https://github.com/x1xhlol/system-prompts-and-models-of-ai-tools |
| Claude Code Opus 4.8 prompt | https://github.com/asgeirtj/system_prompts_leaks |
| Codex 仓库 | https://github.com/openai/codex |
| Codex 主 prompt | `codex-rs/protocol/src/prompts/base_instructions/default.md` |
| Codex gpt-5-codex 简化版 | `codex-rs/core/gpt_5_codex_prompt.md` |
| OpenCode | https://github.com/sst/opencode |
| Aider chat_chunks | https://github.com/Aider-AI/aider/blob/main/aider/coders/chat_chunks.py |
| Cline rules.ts | https://github.com/cline/cline/blob/main/apps/vscode/src/core/prompts/system-prompt/components/rules.ts |
| Hermes 4 model card | https://huggingface.co/NousResearch/Hermes-4-14B |
| Hermes Function Calling | https://github.com/NousResearch/Hermes-Function-Calling |
| Hermes Agent docs | https://hermes-agent.nousresearch.com/docs/ |
