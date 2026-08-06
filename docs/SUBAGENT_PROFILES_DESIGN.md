# 子代理 Profile 设计（Subagent Profiles）

> 状态：**草案，待 review**。Review 通过后按「分期实施」落地。
> 关联版本：基于 1.229.0-rc1（`/subagent`、`/no-subagent` 委派开关与子代理检视器已合入 develop）。
> 关联文档：`docs/SOME_IM_MANAGED_ROUTING_DESIGN.md`（升级阶梯心智模型的出处）。

## 1. 动机

一句话：**主聊天和子代理分模型跑，子代理按「工种」预定义，综合成本大幅下降。**

三个观察叠出来的结论：

1. **子代理不需要主模型。** 现在 `spawn_agent` 子代理继承父会话的模型与 provider。定位代码、读文档、总结这类只读工作，GLM-5 / deepseek-v4-flash 级别的模型足够胜任，而 some.im 登录用户手里有大量 GLM-5 配额。
2. **每轮固定开销是小模型的生死线。** 子代理循环每一轮都重发 system prompt + 工具 schema + 全部历史。工具 schema 是大头——主循环全量注册表约 37K token（`XeditTests.swift` 的 `testAgentTokenEstimateIncludesTools` 常年盯着这个数）。子代理现在的只读子集小一些，但仍是「一套通吃」。按工种裁剪到 3-5 个工具后，一个 12 轮的子代理运行可以省下数十万 prompt token——这才是 128K 小上下文模型能活下来的前提。
3. **窄职能对小模型是适配而不只是省钱。** 面对 5 个工具的 GLM 比面对 20 个工具的 GLM 调用准确率高得多。职能窄化同时买到了成本和质量。

## 2. 目标 / 非目标

**目标**

- 预定义 3-5 个子代理 profile（工种），每个 profile 绑定：模型 + provider + 工具白名单 + 职能 prompt 段 + 上下文窗口预算。
- `spawn_agent` 暴露 `profile` 参数，主模型选**工种**，不选模型。
- 小模型失败时有升级兜底，不把省下的钱以「报告质量差 → 父代理重做」的形式加倍还回去。
- profile 的 prompt + 工具表字节稳定，吃满 provider 前缀缓存。
- 用户可在设置里改每个 profile 的模型/provider 绑定（默认值开箱可用）。

**非目标（本期不做）**

- 子代理嵌套（现有「no nesting」约束不变）。
- 主聊天模型的选择策略（1M 上下文主模型是独立议题，见 §10 备注）。
- 把 `claude_code` / `codex_cli` 等外部 CLI 委派工具改造成 profile（它们有独立的审批与验收体系）。
- 服务端路由。全部裁决在客户端完成，与省心托管「客户端自控裁判」的既有决策一致。

## 3. 现状盘点（代码锚点）

| 现状 | 位置 |
| --- | --- |
| 子代理工具白名单（9 个只读工具，单一集合） | `AgentSubagents.swift` `allowedToolNames` |
| 子代理 system prompt（已较短，约十几行） | `AgentSubagents.swift` `systemPrompt(workspaceURL:outputSchema:)` |
| `spawn_agent` 已接受 `model` 覆写（只换模型字符串，不换 provider） | `AppStateAgentToolMessages.swift` `executeSpawnAgentToolCall` |
| 子代理运行时执行拦截（白名单外一律 Denied） | `AgentSubagents.swift` `executeToolCall` |
| 并发上限（每父会话 3 个） | `AgentSubagentRegistry.maxConcurrentPerRuntime` |
| 会话级 provider 隔离机制（可复用于 profile 绑定） | `AgentRuntime.sessionProviderEntryID` |
| 升级阶梯先例（只升不降） | 省心托管 `AgentManagedRoutingState` |
| 逐轮 transcript 落盘（检视器可审计 profile 实际表现） | `AgentSubagentTranscript` / sidecar |

关键差距：

1. `model` 覆写不换 provider——把 `glm-5` 发到父会话的 Anthropic endpoint 上会直接失败。
2. 工具白名单、prompt、模型三者没有绑定关系，无法按工种整体切换。
3. 没有失败升级：小模型爆窗或产出垃圾时，只能靠父模型察觉后重 spawn。

## 4. Profile 数据模型

```swift
/// 一个「工种」：模型、provider、工具、prompt、预算的绑定包。
/// Codable —— 用户在设置里改绑定后随 preferences 持久化。
nonisolated struct AgentSubagentProfile: Codable, Equatable, Identifiable {
    let id: String                    // "scout" / "reader" / "editor" / "deep"
    var displayName: String           // 走 L10n，此处存 key
    var purpose: String               // 给 spawn_agent schema 里的一句话职能描述（英文，模型读）

    // MARK: 模型绑定
    var modelBinding: ModelBinding
    struct ModelBinding: Codable, Equatable {
        /// nil = 继承父会话（deep profile 的默认）。
        var providerEntryID: UUID?
        var model: String?
        /// 该模型的上下文窗口（token）。用于工具输出截断预算与爆窗判断。
        var contextWindowTokens: Int?
    }

    // MARK: 能力绑定
    /// 工具白名单。运行时拦截取 profile 集合与全局
    /// `AgentSubagentRunner.allowedToolNames` 的交集 —— profile 只能收窄，
    /// 永远不能放宽全局只读边界（editor 例外，见 §7）。
    var toolNames: Set<String>
    /// system prompt 的「职能段」。不变量段（只读边界、最终消息即交付物、
    /// 不能问用户）由 runner 拼接，profile 不可覆盖。
    var capabilityPromptSection: String

    // MARK: 预算与兜底
    var maxRounds: Int                // scout 8 轮足够；deep 保持现有 12
    /// 单条工具输出截断上限。小上下文 profile 收紧到 8K 字符。
    var toolPayloadCharacterLimit: Int
    var escalation: EscalationPolicy
    enum EscalationPolicy: String, Codable {
        case none                     // 失败就失败，报告给父模型
        case retryWithParentModel     // 换父会话模型整体重跑一次（只升不降）
    }
}
```

设计决策（含理由）：

- **profile 只能收窄工具集**：交集而非并集。防止用户（或将来的自定义 profile）无意间给子代理开出白名单外的工具，绕过 `executeToolCall` 的只读承诺。
- **prompt 分「不变量段 + 职能段」**：只读边界、「你的最终消息就是交付物」、「不能问用户」这三四行是被模型违反出来的教训，任何 profile 不得删改；profile 只提供职能描述。这保证小模型省掉的是无关能力描述，不是安全规则。
- **`contextWindowTokens` 进 profile**：截断预算按模型窗口算，而不是全局一刀切。128K 的 GLM 和 1M 的父模型不该用同一个 24K 截断值。

## 5. 内置工种（第一批 4 个）

| profile | 职能 | 工具 | 默认模型绑定 | maxRounds | 升级 |
| --- | --- | --- | --- | --- | --- |
| `scout` | 定位：找文件、找符号、答「X 在哪/有没有」 | `grep_files` `search_files` `list_directory` `read_file` | some.im GLM-5（未登录 → 继承父模型） | 8 | retryWithParentModel |
| `reader` | 阅读与总结：读大文件/文档，回答内容性问题 | `read_file` `list_directory` `web_search` | some.im GLM-5（同上） | 8 | retryWithParentModel |
| `deep` | 复杂调查：跨文件推理、需要 shell 的分析 | 现有全部 9 个只读工具 | **继承父会话**（行为 = 今天的子代理） | 12 | none |
| `editor` | 单文件编辑（§7 单独设计，二期落地） | `read_file` `apply_patch` | some.im GLM-5 | 6 | retryWithParentModel |

要点：

- **`deep` 就是现状**。这保证 profile 机制上线时行为完全向后兼容：不认识 profile 参数的旧提示词、旧会话回放，落到 `deep` 上和今天一模一样。
- `scout`/`reader` 不给 `run_command` 和 `git_status`。定位和阅读不需要 shell；这两个工种是小模型主场，工具越少调用越准。
- 数量刻意压在 4 个。工种太多 → 主模型选错工种的概率上升，选错一次浪费一整个子代理运行，比多发几 K schema 贵得多。

## 6. `spawn_agent` schema 变化

```
spawn_agent(
  prompt: string,          // 不变
  label?: string,          // 不变
  profile?: "scout" | "reader" | "deep" | "editor",   // 新增，默认 "deep"
  run_in_background?: bool // 不变
)
```

- 工具 description 里给每个 profile 一句话职能 + 一条选择指引（"prefer the narrowest profile that fits; use deep only when the task needs shell access or spans many files"）。
- **`model` 参数废弃**：schema 中移除，运行时对传入值忽略并在 tool result 里附一句提示（不报错，旧提示词平滑过渡）。模型直接点名模型字符串的路从此关死——成本策略归用户配置，不依赖模型自觉。
- 主模型选错工种时的纠偏：profile 工具被拒的 Denied 消息里带上「如需 X 工具请改用 profile=deep 重新 spawn」，让父模型下一轮自行纠正。

## 7. `editor` 写通道（二期，单独审批边界）

`spawn_agent` 的只读承诺是现有审批体系的地基（子代理无审批 UI、取消无副作用、并发不撞文件）。`editor` 不能简单在白名单里加 `apply_patch` 了事：

1. **spawn 即审批**。带 `profile=editor` 的 `spawn_agent` 调用本身升为 write-tier 工具调用，走父会话现有的审批卡（复用 `AgentToolRisk.write` 通路）。审批的对象是「允许子代理编辑 <目标文件>」，而不是每一条 patch——单文件粒度用户可以一眼判断。
2. **单文件锁**。spawn 参数强制 `target_file`（相对路径，白名单校验）。运行时拦截层校验每条 `apply_patch` 只落在该文件上，越界一律 Denied。同一父会话内同一文件同时只允许一个 editor 子代理（防并发互踩，与「并行会话撞车」的既有教训一致）。
3. **产出走现有 patch 管线**。补丁通过 `AppStateAgentPatches` 的既有应用与回滚路径，`didEditFiles` / `agentEditedPaths` 照常记账，worktree 变更卡照常显示。
4. **失败即放锁**。取消/失败/爆窗时释放文件锁；升级重试（换父模型）视为新的运行，重新拿锁但**不**重新审批（用户批的是「编辑该文件」这件事）。

一期不实现 editor，但数据模型、schema、审批位都按上述预留，避免二期改接口。

## 8. 升级兜底（只升不降）

触发条件（任一）：

- 子代理请求被 provider 以上下文超限拒绝（爆窗）；
- 循环打满 `maxRounds` 仍无最终报告（现有「round cap 部分产出」路径升级为触发器）；
- provider 连续错误耗尽重试。

动作：`escalation == .retryWithParentModel` 时，用父会话模型 + `deep` 工具集整体重跑一次原 prompt（不是续跑——小模型的残局历史对大模型是噪音，重跑更干净）。重跑仍失败则按现状把失败报告给父模型。

记账：升级事件写进 `AgentSubagentTranscript`（新增 `escalatedFrom: String?` 字段），检视器里可见「glm-5 爆窗 → 已升级到 claude-opus-5 重跑」。省心托管的审计教训（裁判 0 次生效却全程静默）在这里的对应做法：**升级必须可见**。

## 9. 缓存与成本模型

- profile 的 system prompt 不变量段 + 职能段 + 工具 schema 全部是编译期常量，同 profile 的每次运行请求前缀字节一致 → provider 前缀缓存跨运行命中。现有按 `workspaceURL` 插值的行移到 prompt 尾部（user message 前），不污染稳定前缀。
- 粗账（以 12 轮 deep 运行为参照）：全量只读工具集 schema 约 6-8K token/轮；scout 裁到 4 个工具后约 2K/轮，叠加轮数上限从 12 → 8，固定开销约降 60-70%；再叠加 GLM-5 与主模型的单价差，单次 scout 运行成本预计降一个数量级。上线后用 transcript 的 `usageTokens` 实测校准，数字写回本节。

## 10. 配置与 UI

- 设置 → Agent 新增「子代理工种」区：每个 profile 一行，可改模型 + provider（复用现有 provider entry 选择器）、查看工具清单（只读展示，不可编辑——见 §4 的收窄原则）。
- some.im 登录状态变化时的默认值解析：`scout`/`reader`/`editor` 的默认绑定写成「some.im GLM-5，若不可用回退继承父模型」，解析发生在 spawn 时而不是配置时，登录/登出无需迁移配置。
- 子代理检视器头部已显示模型，补一行 profile 名与升级标记。
- 文案全部走 `L10n+AgentDelegation.swift` 扩展。

## 11. 兼容与迁移

- 旧会话回放：`AgentSubagentTranscript` 新字段（`profile`、`escalatedFrom`）全部 optional decode，旧 sidecar 文件照常打开。
- 无 `profile` 参数的 spawn → `deep`，行为与今天逐字节一致。
- `model` 参数：忽略 + 提示，不报错（§6）。
- 工作流引擎（`WorkflowRegistry`）现走 `runOperation` 注入的同一 runner，本期不改其行为；`structured_output` 虚拟工具与 profile 正交，不受影响。

## 12. 风险

| 风险 | 缓解 |
| --- | --- |
| 主模型选错工种（用 scout 干 deep 的活） | Denied 消息带纠偏指引（§6）；检视器可审计错选频率，必要时调 description |
| GLM-5 在窄工具集下仍产出低质量报告 | 升级阶梯兜底；transcript 留证据供人工判断是否调整默认绑定 |
| some.im 配额/登录态波动 | spawn 时解析回退（§10），任何时刻不可用即静默走父模型，不失败 |
| editor 通道破坏只读地基 | 独立审批 + 单文件锁 + 越界 Denied（§7）；一期不上线 |
| profile 泛滥 | 硬编码 4 个内置，不开放自定义 profile（本期） |

## 13. 分期实施

**一期（profile 骨架 + 只读工种）**

1. `AgentSubagentProfile` 数据模型 + 4 个内置定义（editor 仅占位，spawn 时拒绝并提示二期）。
2. runner 按 profile 取工具集/prompt/轮数/截断值；`spawn_agent` schema 加 `profile`、废弃 `model`。
3. provider 绑定解析（some.im 可用性回退）+ 设置 UI。
4. 升级兜底 + transcript 新字段 + 检视器展示。
5. 单测：profile 收窄交集、默认 deep 等价现状、model 参数忽略、升级触发与记账、旧 sidecar 兼容。

**二期（editor 写通道）**

6. spawn 即审批、单文件锁、patch 管线接入、失败放锁（§7 全部）。

每期照常：全量单测绿 → bump 版本 + CHANGELOG → 合回 develop。
