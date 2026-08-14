# 代理档案统一（agent-profile.v2）与密钥管理器设计

> Last updated: 2026-08-14 | 状态：**§7 已确认**（2026-08-14 用户拍板）；P1 已落地（1.255.0-rc1），P2 并入 P3，P3 已落地（1.256.0-rc1），P4 待做
> 适用范围：Xedit（WillDeep macOS App）
> 关联文档：`docs/SUBAGENT_PROFILES_DESIGN.md`、`docs/GOAL_TEAMS_ROLES_DESIGN.md`、`docs/ORCHESTRATOR_DESIGN.md`

## 0. 需求来源

用户提出四件事：

1. Composer 输入框下方的锁形图标偏小（它没有外圈圆框），放大；
2. 锁形点开的密钥管理器要支持**分页**与**按名字模糊搜索**，并在「设置」里有独立入口；
3. 「设置」里要能管理**调度台 profile** 与**子代理**；
4. 子代理与 profile **是否合并成一套**；且每个档案要有自己的 **soul**：专属职能、提示词、自动加载的技能包。

## 1. 现状盘点（代码锚点）

| 概念 | 类型 | 文件 | 持久化 | 可编辑度 | 入口 |
|---|---|---|---|---|---|
| 子代理「工种」 | `AgentSubagentProfile` | `Xedit/AgentSubagentProfile.swift` | UserDefaults `com.willdeep.agent.subagent-profile-bindings.v1`（**只存模型绑定**） | 4 个内置写死（scout/reader/deep/editor），只有 provider/model 可改 | 设置 → AI → 子代理（`AgentSubagentProfileSettingsSection`） |
| 调度台执行档案 | `AgentExecutionProfile` | `Xedit/AgentExecutionProfile.swift` | UserDefaults `com.willdeep.agentDispatch.executionProfiles.v1` | 内置 6 条可覆写 + 用户可增删（managed）+ CLI 扫出来的只读（discovered） | 只在调度台页面（`AgentDispatchBoardPage.swift:151`），设置里**没有**入口 |
| 密钥 | `AgentSavedSecret` | `Xedit/AgentSecretStore.swift` | Keychain（值）+ Keychain 索引 `agent-secret-index-v1` | 只能**新增/插入占位符/验证后复制**，**无删除、无重命名、无搜索、无分页** | 仅 Composer 锁形 sheet（`AgentSecretInsertSheet`） |
| 技能 | `AgentSkillEntry` | `Xedit/AgentSkillDirectory.swift` | 目录扫描 + `AgentSkillSettingsStore` 全局启用/禁用 | 全局开关，**无按档案绑定** | 设置 → 工具 → 技能 |

两套 profile 的真实差别只有一条：**子代理是进程内的子 loop（工具白名单 + 预算 + 提示词是安全属性）**，**调度台档案是给 DAG 节点选执行器（可能是外部 CLI：codex / claude / hermes，自带 harness）**。其余字段（name / provider / model）完全重合，用户在两个地方配同样的东西，正是「两边不是一套」的痛点。

`docs/GOAL_TEAMS_ROLES_DESIGN.md` §2.3 已经定过分层：**工种回答「能用什么工具、什么预算」，角色回答「在这个 Goal 里负责什么、向谁交付」**。本设计不推翻它——合并的是「工种 ↔ 调度台档案」这两个**同层**概念，角色（member）仍在其上层引用档案。

## 2. 结论：合并，但保留「执行形态」这一维

**推荐方案 B（单一数据源 + 用途标记）**，不是方案 A（只统一 UI、数据仍两份），也不是方案 C（把外部 CLI 也塞进子代理运行路径）。

理由：
- 用户配置的心智单位就是「一个可复用的执行者」，两份存储必然长期漂移；
- 但「进程内子 loop」与「外部 CLI」在**工具白名单、提示词注入、预算**上不可通约：外部 CLI 有自己的 harness，我们注入不了工具集，也管不了它的轮数预算。所以合并成一张表可以，抹掉这一维不行 —— UI 上按执行形态灰掉不适用字段并给出说明，比假装能配更诚实。

### 2.1 统一模型 `agent-profile.v2`

```swift
nonisolated struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String                 // "builtin:scout" / "managed:<uuid>" / "discovered:<cli>:<name>"
    var name: String               // 展示名（内置走 L10n，自定义走用户输入）
    var origin: Origin             // builtIn / managed / discovered
    var usages: Set<Usage>         // [.subagent] / [.dispatch] / 两者
    var soul: Soul
    var runtime: Runtime
    var capability: Capability
}

struct Soul: Codable, Equatable, Sendable {
    var purposeModelFacing: String     // 英文、进 spawn_agent schema（模型读的）
    var purposeLocalized: String?      // 设置页给人读的（内置走 L10n key）
    var promptSection: String          // 「专属提示词」：只是 system prompt 的**可变半段**
    var skillIdentifiers: [String]     // 自动加载的技能包（AgentSkillEntry.identifier）
    var memoryFileRef: String?         // 预留：goal-teams 跨里程碑记忆文件
}

struct Runtime: Codable, Equatable, Sendable {
    var executor: AgentExecutionAgent  // .willDeep(进程内) / .codexCLI / .claudeCode / .hermesCLI / ...
    var nativeProfileName: String?     // 仅外部 CLI 有意义
    var modelBinding: ModelBinding     // 复用现有 preferredProviderEntryID / providerID / model / contextWindowTokens
}

struct Capability: Codable, Equatable, Sendable {   // 仅 executor == .willDeep 生效
    var toolNames: Set<String>
    var requiresWriteAccess: Bool
    var maxRounds: Int
    var toolPayloadCharacterLimit: Int
    var escalation: EscalationPolicy
}
```

### 2.2 不可让渡的安全不变量（合并后必须原样保留，且是执行路径拦截而非 UI 约束）

1. **工具只能收窄**：`effectiveToolNames = capability.toolNames ∩ AgentSubagentRunner.allowedToolNames`（`AgentSubagentProfile.swift:113`）。用户在 UI 里勾不出白名单以外的工具，即使改存储文件也无效。
2. **写口仍走审批 + 单文件锁**：`requiresWriteAccess` 只是打开 `apply_patch` 的那扇窄门，仍受 `AgentSubagentWriteAccess` / editor lock 约束。
3. **提示词只有半段可编辑**：runner 拥有的 invariant 段（只读边界、「你的最后一条消息就是交付物」、「你不能问用户」）**不进档案、不可覆盖**，用户编辑的 `soul.promptSection` 只做拼接。这几行的存在是因为模型违反过它们。
4. **外部 CLI 档案不承诺 capability**：`executor != .willDeep` 时 `capability` 不参与执行，UI 灰掉并标注「由该 CLI 自身的 harness 决定」。`soul.skillIdentifiers` 同理（见 §7-Q3）。
5. **discovered 档案只读**：磁盘扫描重建，不写回。

### 2.3 迁移

- 新键 `com.willdeep.agentProfiles.v2`；
- 迁移器读旧两键 → 生成统一列表：4 个工种 `usages=[.subagent]`（soul 从现有 `purpose` / `capabilityPromptSection` 填入，`skillIdentifiers` 为空）；execution profiles `usages=[.dispatch]`，soul 空、capability 取默认值；
- 旧键**保留只读一版**（不删），便于回滚；迁移只做一次，用 `...migrated.v2` 标记位；
- `AgentSubagentProfileCatalog.profile(id:)` 的「未知 id → deep」兜底行为不变，老会话/老 DAG 项目照常解析。

## 3. 密钥管理器

### 3.1 能力补齐

现状 store 只有 save / list / reveal。要做管理器就得补：

- `delete(identifier:)`：删 Keychain 条目 + 索引条目（`AgentCredentialStore` 已有 delete 底座，`WillDeepKeychainStore.swift:165`）；删除属破坏性操作，走二次确认；
- `rename(identifier:label:)`：**只改展示 label，不改 identifier**——identifier 是 `${secret:...}` 占位符的一部分，改了会让历史会话里的占位符失效。UI 要把这条讲清楚；
- 模糊搜索：对 `label` + `identifier` 做大小写/空白不敏感的子串匹配（中文标签不做拼音，见 §7-Q2）；
- 分页：默认每页 20 条，页码 + 上一页/下一页；搜索结果同样分页，切换关键词回到第 1 页。

### 3.2 UI 拆分

把现在挤在一个 sheet 里的东西拆成两层：

- `AgentSecretManagerView`（新，独立文件）：搜索框 + 分页列表 + 每行「插入占位符 / 复制(需 Touch ID) / 重命名 / 删除」+ 底部「新增密钥」。
- Composer 锁形 sheet 复用同一个视图（带 `mode: .insert`，多一列插入按钮）；设置页用 `mode: .manage`（无插入）。避免两份列表实现漂移。

### 3.3 设置入口

`EditorSettingsTab` 新增 `.secrets`，归入 `.agentTools` 组（与 skills / mcp / tools 同列，语义上都是「Agent 的资源」）。图标 `key.fill`。

## 4. 设置里的档案入口

- `EditorSettingsTab` 新增 `.profiles`（AI 组），承载统一后的「代理档案」页：左列表（可按用途过滤：全部 / 子代理 / 调度台）+ 右详情（灵魂 / 模型 / 工具与预算 / 用途开关）。
- 现有 `.subagents` 页保留 tab id（deep-link 兼容），内容替换为新页并按 `usages contains .subagent` 预过滤。
- 调度台页面里的「Profile 管理」按钮改为打开同一视图（预过滤 `.dispatch`），`AgentExecutionProfileManagerView` 退役为薄壳或直接删除。

## 5. 落地分期（每期独立可验收、可单独提交、按仓库规则跑单测后合回 develop）

| 期 | 内容 | 版本位 | 风险 |
|---|---|---|---|
| P1 ✅ | 锁形图标 16 → 18pt（配 24×24 热区）；密钥 store 补 delete/rename；`AgentSecretManagerView`（搜索+拼音+分页）；设置 `.secrets` 入口 | **1.255.0-rc1**（develop 当时已到 1.254.0-rc1，故 MINOR 顺延） | 低。删除是破坏性操作，已加二次确认 + 索引一致性单测 |
| ~~P2~~ | 并入 P3：先搬 UI 再重写等于把同一个页面做两遍 | — | — |
| P3 ✅ | `agent-profile.v2` 统一模型 + 迁移器 + soul 生效 + 统一设置页 | **1.256.0-rc1** | 中。迁移与安全不变量已有单测；技能预载封顶 12k 字符 |
| P4 | 调度台 DAG 节点直接选统一档案；goal-teams 角色（developer/tester/reviewer）绑定统一档案 | 待定 | 中，依赖 goal-teams §7 待确认项 |

明确**不做**（本轮排除）：子代理独立聊天会话、跨端 runtime 合并、把外部 CLI 纳入进程内工具白名单体系、密钥的云同步/导出。

## 6. 测试计划

- `XeditTests/AgentSubagentProfileTests.swift` 扩展：合并后 `effectiveToolNames` 仍是交集；用户写入超权限工具被丢弃；invariant 提示词段不可被 `soul.promptSection` 覆盖。
- 新增 `AgentProfileMigrationTests`：旧两键 → v2 的字段映射、幂等、旧键保留、未知 id 兜底。
- 新增 `AgentSecretStoreManagementTests`：删除后索引与 Keychain 均无残留；重命名不改 identifier；搜索匹配（大小写/空白/子串）；分页边界（0 条 / 恰好整页 / 末页不足）。
- 按 `project_test_defaults_hygiene`：新 suite 若用一次性 UserDefaults 前缀，必须登记到 `TestDefaultsHygiene`。

## 7. 已确认决策（2026-08-14）

- **Q1 合并深度**：✅ 方案 B —— 真合并。单一存储 `com.willdeep.agentProfiles.v2` + `usages` 标记，按执行形态灰字段。两个旧 store 降为门面。
- **Q2 搜索语义**：✅ label + identifier 子串模糊匹配，**并加中文拼音**（全拼与首字母，`CFStringTransform` 转写，见 `AgentSecretSearch.pinyinTerms`）。
- **Q3 外部 CLI 档案的 soul**：✅ 不生效。`AgentProfile.soulApplies == runtime.isInProcess`；UI 灰掉并写明「该档案跑在外部 CLI 上，人家自带 harness，这里配的送不进去」。
- **Q4 分页形态**：✅ 页码式，每页 20。
- **Q5 内置工种可编辑范围**：✅ 可改 soul 与模型，不可改工具集与写权限位。另加一条实现层拦截：**任何 managed 档案都拿不到写权限**（`asSubagentProfile()` 强制 `origin == .builtIn && ...`），改存储 JSON 也无效。

### 7.1 落地后补记的实现要点

- **内置档案存 override，不存全量拷贝**。全量拷贝会把今天的 `deep` 冻进用户配置，之后代码里改工具集/预算再也送不到老用户手上。`AgentProfileStore.override(for:base:)` 只写与代码不同的字段。
- **`deep` 的提示词段**此前因与通用开场重复而被 `systemPrompt` 跳过；现在只在用户没写 soul 时跳过，写了必须发出（`Xedit/AgentSubagents.swift`）。
- **技能预载**在 spawn 时直接内联进 system prompt（不给子代理加 `read_skill` 工具，省一轮往返与一个 schema 槽），封顶 `AgentSubagentRunner.skillPreloadCharacterLimit = 12_000`；找不到或已禁用的技能静默跳过——卸载一个技能不能让 spawn 失败。
- **调度台编辑器看不见 soul**，所以 `AgentExecutionProfileStore.saveManaged` 必须把既有档案的 soul / capability / `.subagent` 用途原样带过，否则在调度台改个模型就会把子代理那半边抹掉（已有单测钉住）。
- **测试进程重定向**：`AgentProfileStore` 照搬 `AgentDispatchStore` 的 XCTest 重定向（`willdeep-profiles-process-<pid>`，前缀已登记进 `TestDefaultsHygiene`）。两个门面遍布 AppState，任一测试碰到都会改写用户真实档案。
- **并发会话事故记录**：本轮开发中该 worktree 被另一个会话的操作清过一次未提交改动。教训写在这里而不是聊天里——**多会话仓库，写完一组文件就提交**，别让改动裸奔等测试。
