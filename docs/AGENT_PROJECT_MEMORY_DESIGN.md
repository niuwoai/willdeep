# Agent Project Memory Design

> Last updated: 2026-08-20（1.275.0-rc10 起「Markdown 投影 + 每轮索引 + read_memory」已落地，见文末「实现现状」）

## 背景

WillDeep 的 Agent 已经有项目规则、会话持久化、turn recall、自学习事件和 memory review 队列。下一步如果要做“项目级 memory”，核心问题不是“存更多东西”，而是分清哪些内容是强规则、哪些是可召回经验、哪些只是代码库检索结果。

同类产品的经验大体一致：可靠的项目级上下文通常不是单一 memory，而是多层系统。

## 同类产品做法

### Claude Code

Claude Code 明确分成两套机制：

- `CLAUDE.md`：人写的持久项目/用户/组织规则。适合放构建命令、代码约定、项目架构、固定工作流。
- Auto memory：Claude 自己从纠正、偏好、调试经验里提炼 notes。适合放“以后可能还会用到”的经验，而不是强制规则。

Claude Code 的 Auto memory 按仓库隔离，典型位置是：

```text
~/.claude/projects/<project>/memory/
├── MEMORY.md
├── debugging.md
├── api-conventions.md
└── ...
```

`MEMORY.md` 是索引，启动时只加载前 200 行或 25KB；详细主题文件不在启动时全量注入，而是需要时通过文件工具读取。同一 Git 仓库的多个 worktree 共享项目 memory。Claude 文档也强调：`CLAUDE.md` 和 Auto memory 都是上下文，不是硬约束；真正要禁止某些行为，应使用 hook 或权限机制。

### Codex

Codex 也分为确定性项目规则和本地自动 memory：

- `AGENTS.md`：项目规则。Codex 会按全局、项目根、当前目录的顺序拼出 instruction chain。越靠近当前工作目录的规则越晚出现，优先级更高。
- Memories：默认关闭，开启后 Codex 会从合格的历史 thread 中后台提炼可复用上下文，存到 `~/.codex/memories/`。

Codex 官方文档特别提醒：团队必须遵守的规则应该放在 `AGENTS.md` 或 checked-in 文档里，memories 只是本地 recall layer，不应作为唯一规则来源。

### Cursor

Cursor 更偏 IDE 形态。公开可观察的核心是：

- 项目规则：通常是 `.cursor/rules` 或同类 rule 文件。
- 代码库索引：通过 semantic / agentic search 让 Agent 按需找代码、符号、文件。
- 用户偏好/习惯：作为辅助上下文，而不是强约束。

Cursor 的项目 memory 更像“rules + codebase index + 编辑器状态”的组合。它的优势在于 IDE 内能天然知道当前文件、选区、打开 tab、诊断和代码索引；但强项目约束仍更适合落在可审阅的 rules 或仓库文档中。

### Trae / Qoder

Trae Agent 的公开研究资料强调 repository-level understanding 和多 Agent 搜索/生成/筛选，用 test-time scaling 提升 SWE-bench 类任务表现。这更像“仓库理解 + 推理扩展 + 候选方案筛选”，不是清晰公开的 per-repo auto-memory 存储系统。

Qoder 目前没有足够可靠的公开资料说明其项目 memory 的存储、召回、审计和隔离机制。设计 WillDeep 时不应基于不可验证的实现细节做假设。

## 设计结论

WillDeep 的项目级 memory 应该拆成四层，而不是做一个万能记忆池。

### 1. 强规则层

用途：必须稳定遵守的项目规范。

来源：

- 仓库内 `AGENTS.md`
- `CLAUDE.md` / `.cursor/rules` 等兼容导入
- `product-overview.md`
- WillDeep 全局规则
- 组织/用户级规则

特性：

- 可 review、可 diff、可进 Git。
- 启动或构建 prompt 时确定性加载。
- 适合放代码风格、测试命令、安全边界、版本规则、发布流程。
- 不应由 Agent 自动悄悄改写。

### 2. 项目自动 memory 层

用途：跨会话保留“以后可能还会用到”的项目经验。

适合内容：

- 某个测试经常失败的根因和修法。
- 本仓库特定模块的坑。
- 用户反复纠正过的偏好。
- 某个外部系统、本地脚本或运行环境的注意事项。
- 已验证的排障路径。

不适合内容：

- 密钥、token、webhook、私人数据。
- 临时任务状态。
- 未验证的猜测。
- 强制安全规则。
- 大段代码、完整日志、长 diff。

建议存储：

```text
~/Library/Application Support/WillDeep/AgentMemory/Projects/<project-id>/
├── MEMORY.md
├── topics/
│   ├── debugging.md
│   ├── test-workflows.md
│   └── architecture-notes.md
└── metadata.json
```

`project-id` 建议由 Git remote、Git root 文件身份、workspace path fallback 共同生成，避免目录改名后完全失联。已有 `AgentMemoryStore` 的 Project scope 可以继续承担结构化记录；文件层可以作为面向模型的可读投影。

### 3. 检索层

用途：按当前任务找相关资料，而不是永久注入。

来源：

- 当前代码库文件搜索。
- 最近编辑文件。
- symbol / LSP 结果。
- workflow 输出。
- docs / README / changelog。
- 项目 memory topic 文件。

策略：

- 每轮只取 top N 条高相关结果。
- 明确展示 recall 来源和命中原因。
- 不把全部 memory 或全部文档塞进 prompt。
- 对 near-miss 也记录原因，方便改进召回。

### 4. 会话连续性层

用途：当前 thread 的上下文压缩和续航。

来源：

- 当前会话摘要。
- 最近用户请求。
- 当前 plan / goal。
- 未完成工具调用和待审批状态。

边界：

- 它解决的是当前会话过长，不等于项目长期 memory。
- 会话摘要不应自动晋升为项目 memory，除非通过候选提取和审核。

## 推荐实现

### 数据模型

项目 memory 记录建议包含：

```text
id
project_id
scope: project
kind: convention | debugging | workflow | architecture | preference | pitfall
title
summary
details
source_session_id
source_message_ids
source_tool_names
confidence
created_at
updated_at
last_used_at
use_count
status: candidate | approved | ignored | stale
sensitivity: normal | possible_secret | private
```

这里最重要的是 `status` 和 `source_*`。没有来源的 memory，后面很难审计；未经审核的 memory，不应该像规则一样强势注入。

### 写入流程

建议采用候选制：

1. 回合结束后提取候选 memory。
2. 过滤短期状态、敏感信息和低置信度内容。
3. 合并相似候选，避免同一条经验反复堆叠。
4. 写入 review 队列，状态为 `candidate`。
5. 用户批准后进入 `approved`。
6. 后台生成或更新 `MEMORY.md` 索引和 topic 文件投影。

对于高置信、低风险的偏好可以允许“自动保存但可撤销”，但默认应保守。别让 Agent 一边犯错一边给自己写传记。

### 召回流程

每轮开始时：

1. 识别 active project。
2. 加载短索引，例如 `MEMORY.md` 前若干行或结构化 top-level summary。
3. 根据用户请求、打开文件、工作树变更和工具调用历史检索相关 memory。
4. 注入少量高相关条目，并带上来源标题。
5. 在 turn report 中展示 `Recall`：命中了什么、为什么命中、哪些 near-miss 没用上。

### 冲突处理

优先级建议：

1. 系统/安全规则。
2. 用户当前明确指令。
3. 仓库 `AGENTS.md` / checked-in 文档。
4. 项目 approved memory。
5. 自动 candidate memory。
6. 当前会话摘要。

如果 memory 与 checked-in 规则冲突，必须服从 checked-in 规则，并把该 memory 标记为 stale 或冲突候选，等待用户处理。

## UI 建议

Settings -> Memory 可以增加 Project tab：

- 当前项目 memory 列表。
- `approved / candidate / ignored / stale` 过滤。
- 每条显示来源会话、最近使用、命中次数、置信度。
- 支持编辑、批准、忽略、删除、标记过期。
- 支持“导出为 AGENTS.md 建议”。

Agent transcript 底部可以继续沿用 turn report：

- `Recall: 3 linked · 1 near-miss · 2 unused`
- 每条显示命中原因。
- 对自动写入的 memory 显示“候选，待审核”。

## 安全边界

- memory 写入前必须做 secret redaction。
- 命中疑似密钥、token、cookie、私钥、手机号、邮箱等内容时，默认不写入。
- memory 不应成为工具授权依据；授权仍由 approval mode、sandbox、tool risk、LLM judge 和用户确认决定。
- memory 不能覆盖项目规则、用户当前指令或安全策略。
- 本机 memory 默认不进 Git，不跨机器同步；如果以后做云同步，需要单独的可见开关、加密和审计。

## WillDeep 近期落地路径

### Phase 1：只读项目 memory 投影

- 复用现有 Project scope memory。
- 增加 project id 稳定识别。
- 生成短 `MEMORY.md` 风格索引。
- turn report 显示项目 memory recall。

### Phase 2：候选写入和审核

- 回合结束提取 project memory candidate。
- 接入现有 learning review 队列。
- 用户批准后进入 approved。
- 支持编辑和删除。

### Phase 3：topic 文件和按需读取

- 将详细 notes 拆到 topic 文件。
- prompt 启动只带短索引。
- 需要细节时通过工具读取 topic。

### Phase 4：治理和冲突检测

- 检测 memory 与 `AGENTS.md` / `product-overview.md` 冲突。
- 标记 stale。
- 支持把稳定 memory 提议迁移到 checked-in docs。

## 判断标准

一个项目 memory 系统算健康，不是看它存了多少，而是看：

- 下次是否少问重复问题。
- 是否少走已知失败路径。
- 是否能解释“为什么召回这条”。
- 是否能删除、改正、审计。
- 是否不泄露敏感信息。
- 是否不把自动生成的经验误当成团队强规则。

## 实现现状（1.275.0-rc10）

本节记录已落地的部分，以及**刻意没有**照搬 Claude Code 的地方和原因。

### 已落地

**1. Markdown 投影（`AgentMemoryProjection`）**

记录本身仍存在 `UserDefaults`（`AgentMemorySettingsStore`）里——它是权威来源，但不可 grep、不可 diff、不可 review。现在每次 `saveRecords` 都会把同一批记录镜像到磁盘：

```text
~/Library/Application Support/WillDeep/AgentMemory/
├── global/
│   ├── MEMORY.md
│   └── topics/<slug>.md
└── projects/<fingerprint>/
    ├── MEMORY.md
    └── topics/<slug>.md
```

- **单向投影**。两份可写副本需要一套没人要求过的冲突解决，所以文件头写明「Generated … Edits here are overwritten」，store 保持唯一真源。
- 写入走串行后台队列、且只写内容真正变化的文件——记忆保存是 `@Published` didSet 触发的，一轮可能触发多次，无条件重写会把 mtime 搅烂，目录就失去「Agent 什么时候学到这条」的记录价值。
- 归档记忆不投影（召回本来也跳过），删除/归档会同步删掉对应文件——留在那儿的文件等于还在主张一件 Agent 已经不信的事。
- slug 由关键词 + 短 id 组成。**id 后缀不是装饰**：关键词词干极易碰撞（三条关于 release 的记忆会归到同一个词干），碰撞就意味着一条文件覆盖另一条。

**2. 每轮索引块（`AgentMemoryEngine.indexBlock`）**

原来只有打分召回：宿主选 top-N 塞进 prompt，模型没有选择权。现在在它之后追加一段索引——每条剩余记忆一行钩子 + 短 id，带预算上限（默认 24 条 / 1800 字符）。

**3. `read_memory` 工具**

模型按索引里的短 id 拉取全文。读的是 store 不是投影文件：投影是单向镜像，漂移过的文件绝不能反过来喂给模型一个 store 已经不认的答案。

### 与 Claude Code 的差异（刻意的）

Claude Code 的 auto memory 是**纯模型驱动**：索引进 context，详情靠模型自觉去读。WillDeep 没有照搬，因为两边的模型假设不同——WillDeep 的会话模型可以是省心托管路由到的小模型（`deepseek-v4-flash`、`glm-5` 这类），定时任务尤其常跑在这上面。**「看索引、自己判断该读哪条」对小模型的执行度是不稳定的**，它很可能直接跳过，那条本来靠打分能保底拿到的上下文就丢了。

所以这里是**两层并存**，不是替换：

| 层 | 谁决定 | 保证 |
| --- | --- | --- |
| 打分召回（`contextBlock`） | 宿主 | 不管什么模型，top-N 一定送到 |
| 索引 + `read_memory` | 模型 | 打分漏掉的条目至少**可见**，有能力的模型可以挖深 |

同理，索引行写的是**钩子而不是标题**。标题式索引（只写「数据库迁移」）对不肯花一次工具调用的小模型等于零信息；钩子行即使模型永远不去读详情，本身已经可用。

### 待办

- 反向导入：目前编辑投影出来的 md 不会回写 store，下次保存就被覆盖。要做的话需要文件监听 + 冲突策略。
- 跨仓库项目组：Xedit 与 willdeep-rs 是同一产品的两个仓库，`projectFingerprint` 由路径派生，两边各算一个项目，记忆不共享。需要显式的「项目组」概念才能合并。
- 候选制（`status: candidate | approved`）与来源审计字段仍未实现，当前 `add_memory` 走的是「批准即写入」。

## 参考资料

- Claude Code Docs: How Claude remembers your project  
  https://docs.anthropic.com/en/docs/claude-code/memory
- OpenAI Codex Docs: Custom instructions with AGENTS.md  
  https://developers.openai.com/codex/guides/agents-md
- OpenAI Codex Docs: Memories  
  https://developers.openai.com/codex/memories
- Trae Agent paper: Trae Agent: An LLM-based Agent for Software Engineering with Test-time Scaling  
  https://arxiv.org/abs/2507.23370
