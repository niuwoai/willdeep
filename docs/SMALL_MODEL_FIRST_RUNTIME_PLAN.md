# Small-model-first 进 Runtime：从建议到强制（Xedit 侧规划）

> 状态：第 1–4 步已于 1.273.0-rc1 落地（见 §4 各步的「实现」行）；自动预检的**执行**部分
> 仍未接线，只有分类与资格判定（见 §4 第 4 步）。
> 日期：2026-08-19
> 来源：willdeep-rs `0.37.0-rc1` / `0.38.0-rc1`（2026-08-19 上午）的回流。
> 关联：`docs/SMALL_MODEL_SKILL_WORKERS_DESIGN.md`（主设计）、willdeep-rs
> `docs/MODEL_TIERS.md`（两端共用的档位语义）、`docs/SOMEIM_WORKER_VIRTUAL_MODELS.md`。

---

## 0. 一句话

rs 侧把「优先用小模型」从系统提示词里的劝告，搬进了 Runtime 的准入控制：
**模型可以帮忙编 Task Packet，但「稀缺的 1M 上下文是不是免费的」不再由模型决定。**
本文档是这套机制在 Xedit（Swift/macOS）侧的落地规划。

主设计 §7 当时写的是「不强制、但把派工成本降到一句话」。实测结论推翻了它——
提示一发出去，父模型读完照样自己动手，因为文件已经打开、编 packet 感觉是绕远路。
派工率上不去，小模型体系就只是账面上的省钱方案。

---

## 1. rs 侧到底改了什么（六条机制）

| # | 机制 | rs 落点 |
|---|---|---|
| 1 | **请求级确定性分类**。用户消息先过 `classify()`；高置信只读活（定位/阅读/日志/Git 追溯）在 Root 看到仓库之前自动派给 worker，报告以 `<worker-report>` 注入；改动类活注入 `<runtime-route>` 引导段 | `willdeep-core/src/routing.rs`、`agent.rs::apply_runtime_route` |
| 2 | **Deep 改申请制**。`profile="deep"` 必须带票据（`reason` / `attempted_profiles` / `context_evidence` / `why_not_decompose`），Runtime 用**本 harness 实际观测到的**低档尝试或 ≥2 次成功仓库检查交叉验证，再扣预算 | `RoutingGuard::authorize_deep` |
| 3 | **未知 profile 不再静默回落 deep**；外部 spawn deep 直接禁止 | `subagent.rs::profile()` |
| 4 | **Task Packet 拆 `read_files` / `write_files`**——「让 worker 看见文件」不再顺手给写权限；老 `relevant_files` 保留兼容语义 | `TaskPacket` |
| 5 | **模型绑定纠偏**：Root `deepseek-v4-flash` → `glm-5`；七个托管窄工种删掉显式 `glm-5` 覆盖，真正命中 `someim-32b-<trade>`；deep 显式钉 1M | `config.example.toml` |
| 6 | **Deep Share 指标**进 `agent-metrics`，持续盯 ≤5% | `daemon` |

配套的 `0.38.0-rc1` 是 UI（TUI `/routing` 面板 + Web 设置矩阵）。Xedit 已有工种设置界面，
只需在其中补开关，不需要新面板。

---

## 2. Xedit 现状对照

| rs 机制 | Xedit 现状 | 判定 |
|---|---|---|
| 请求级确定性路由 | **无**。只有失败驱动的 `AgentWorkerAutoDispatch`（`run_command` 测试/构建失败时派 fixer） | 缺口 |
| Deep 准入票据 + 预算 | **无**。`AgentSubagentEscalation` 名字撞车但语义相反——它是「小模型失败后向上兜底重试」 | 缺口 |
| 未知 profile 不回落 deep | `AgentSubagentProfileStore.resolvedProfile(id:)` 明确回落 deep（`AgentSubagentProfile.swift:657`） | 小改 |
| read/write 分离 | `AgentSubagentTaskPacket.relevantFiles` 读写合一；无 `target_files` 时它就是写集 | 中等 |
| 窄工种真跑小模型 | 七个工种 `modelBinding` 全是显式 `glm-5`；`someim-32b-*` 只在「父会话用 some.im **且**已登录」时由 `resolvedHostedConfiguration` 钉上 | 需实测核对 |
| **Root 默认模型** | some.im preset `defaultModel = "deepseek-v4-flash"`（`AgentProviderPresetModels.swift`）——主会话默认就坐在 L 档 1M 上 | 与「默认 M、向上申请」直接冲突 |
| 技能索引 / MCP 上下文税 | 已是 `list_skills` / `list_mcp_tools` 按需加载 | **已具备，不搬** |
| 派工 KPI | `AgentSkillWorkerKPIs` 已有 `skillCoverage` / `verifiedSuccessRate` / `escalationRate` / `citationAccuracy`，且已统计 `deepRunCount` | 补一个展示口径即可 |

**结论**：地基比预期厚，但最关键的两块（请求级路由、Deep 准入）正好没有；
而且现在的 Xedit 里 **L 档不稀缺——它是默认值**，这让「向上申请」在默认路径上无从谈起。

---

## 3. 已定决策（2026-08-19）

| 决策 | 结论 | 理由 |
|---|---|---|
| Root 默认模型 | **改为 M 档（`glm-5`），但只影响新会话** | 整套「L 稀缺、向上申请」的前提；已有会话保留用户已选模型，不做迁移，避免存量用户被静默改窗口 |
| Deep 预算 | **每会话 3 次，设置里可配 0–16**，0 表示彻底禁用 deep | rs 取 1 次/harness；Xedit 一次会话显著更长，1 次会频繁误挡。0–16 与 rs 的校验区间对齐 |
| 请求级路由第一版 | **只做引导注入；自动预检写好但默认关闭** | rs 是 TUI，先跑 scout 再答可接受；Xedit 是 GUI，自动预检让首字延迟翻倍，且 `classify()` 是关键词匹配、中文误判代价可见。先用数据说话 |

---

## 4. 分步落地

四步按「收益 / 风险比」排序，每步独立成一个 PR（不混 feat + fix）。

### 第 1 步：模型绑定纠偏（不改架构，收益最大）

- some.im preset `defaultModel` 改为 M 档模型；`defaultProModel` 维持。
  **只改新会话的默认解析路径**，已有会话的显式模型选择不动。
- `deep` 的 `automaticProviderBinding`（`model: nil`）改为显式钉 1M 模型，
  并给出 `contextWindowTokens`，让 L 档在设置界面上是可见的、有名字的东西。
- **核对七个托管窄工种是否真的命中 `someim-32b-*`**：目前它们的 `modelBinding`
  是显式 `glm-5`，而 `resolvedHostedConfiguration`（`AppStateSubagentProfiles.swift:112`）
  只在「父会话 provider == some.im && 已登录」时才覆盖成 `hostedVirtualModel`。
  这两条路径的优先级要有测试钉住，否则「窄工种跑在小模型上」只是配置表上的说法。

验收：新建会话的 Root 落在 M 档；`deep` 在设置界面显示 1M 绑定；
七个托管工种在已登录状态下实际请求模型为 `someim-32b-<trade>`（用请求日志或契约测试断言）。

**实现（1.273.0-rc1）**：`SomeIMIntegrationSettings.defaultTextModel` 与 some.im preset 的
`defaultModel` 均改为 `glm-5`；`deepBinding` 显式钉 `deepseek-v4-flash` + `deepContextWindowTokens`
(1M)；preset 的 `defaultVisionModel` 加 some.im 分支，避免文本档位下调把图像模型带歪。

**「谁赢」的答案（1.273.0-rc2）**：**托管覆盖赢，而且用户完全没得选**。
`resolvedSubagentConfiguration` 的第一件事就是查 `resolvedHostedConfiguration`，命中即 return，
用户的 `modelBinding` 根本走不到——七个工种写死的 `glm-5` 在登录状态下是死代码，
设置界面还把这一行 `disabled` 掉，理由是「服务端职能提示词与模型是一对，换一半会破坏另一半」。

这个理由站不住：`jobPromptIsHosted` 本来就是**从实际调用的模型推导**的
（`profile.hostedVirtualModel != nil && configuration.model == profile.hostedVirtualModel`，
注释原话是 "the flag cannot drift from reality"）。指向别的模型时，客户端会自动改发自己那份
职能提示词镜像。两半根本拆不开，锁只是白锁。

**因此改为可配置**（对齐 rs 0.38.0-rc1「允许覆盖 some.im 托管模型 + 提供恢复推荐值入口」）：
- 语义：`modelBinding.model` 为空 = 采纳推荐（登录时解析为 `someim-32b-<trade>`）；
  非空 = 用户已选择，用户赢。抽成 `usesRecommendedHostedModel(someIMAuthenticated:)` 以便测试。
- 七个托管工种的内置 binding 的 `model` 由 `"glm-5"` 改为 **nil**——非 nil 与「用户显式选择」
  无法区分，"推荐" 就无法成为一个可表达的状态。因 `AgentProfileStore` 的 override 是**差异化**
  写入（只存与内置默认不同的字段），没动过设置的用户不会有存量记录，改默认是干净的。
- 设置界面解锁：文本框 + 菜单，菜单首项是「推荐：someim-32b-xxx」（点选即清空 = 恢复推荐），
  下方文案说明留空与覆盖各自的含义；列表摘要行在被覆盖时不再谎报托管模型名。

### 第 2 步：Deep 准入（`AgentDeepAdmission`，新文件）

- `spawn_agent` schema（`AgentToolRegistry.swift:1753`）新增 `escalation` 对象，
  四个字段照搬 rs：`reason` / `attempted_profiles` / `context_evidence` / `why_not_decompose`。
- 新增纯函数 `AgentDeepAdmission`：持有本会话已尝试 profile 集合与成功只读工具计数，
  提供 `authorize(ticket:) -> Result<Void, Refusal>`。判定顺序与 rs 一致：
  字段非空且不敷衍（最小长度）→ 交叉验证观测证据 → 扣预算。
- **命名边界**：不要复用 `AgentSubagentEscalation`。那个是「向上兜底」（小模型失败后换父模型重试），
  这个是「向上准入」（能不能动用 L 档）。两者会在同一段代码里同时出现，重名一定会误读。
- `AgentSubagentProfileStore.resolvedProfile(id:)` 的未知 profile 回落改为报错。
  **注意**：这是行为破坏性变更，先确认没有内部调用方依赖「传 nil 拿 deep」这个语义
  （`profileID` 默认值就是 `deep`，见 `AgentSubagents.swift:56`）。
- 预算耗尽 / 证据不足时的拒绝要**讲清楚**，走错误文案而不是新 UI
  （参见既有结论：正规通道已存在时只把错误讲明白）。

验收：无票据的 deep spawn 被拒；票据齐全但本会话没有任何低档尝试也被拒；
第 4 次 deep 被预算挡下；每一种拒绝在 transcript 上都有可读原因。

### 第 3 步：Task Packet 拆读写

- `AgentSubagentTaskPacket` 新增 `readFiles` / `writeFiles`；
  `relevantFiles` 保留**原语义**（读写合一）供老调用方使用，与 rs 的兼容策略一致。
- 内联预算按 `readFiles + writeFiles + relevantFiles` 去重后计算；
  写集只取 `writeFiles`（为空时回落 `relevantFiles`）。
- `spawn_agent` schema 与 `AgentSubagentJobPrompts` 里的工种 prompt 同步措辞。

验收：给 worker 一个只读上下文文件不会让它获得该文件的写权限；老 packet 行为逐字节不变。

### 第 4 步：请求级路由（引导注入）

- 新增纯函数 `AgentRequestRouter.classify(_:) -> RouteDecision`，移植 rs 的分类器与中英关键词表。
  分类结果只用于把 `<runtime-route>` 段拼进用户消息，**不替模型跑 worker**。
- 自动预检（高置信只读活先跑 worker、报告作为证据注入）一并实现，
  但开关默认关闭，位置与 `autoDispatchWorkersEnabled`（`AppStateAgentWorkerAutoDispatch.swift:61`）同层。
- **与 `/subagent`、`/no-subagent` 协调**：`AgentDelegationPolicy.forbidden` 时不注入任何路由段
  （该策略的语义是「这一轮全部自己干」），`required` 时注入更强的措辞。

验收：中文「这个函数在哪」被分类为 `scout` 且只注入引导；「修复登录失败」被分类为 mutating
且不注入只读引导；`/no-subagent` 轮次里没有任何 `<runtime-route>` 段。

**实现（1.273.0-rc1）**：`AgentRequestRouter`（纯函数）+ `runtime.currentTurnRouteSteering`，
注入走**当轮系统提示**而不是用户消息——rs 拼进 `user_message.content` 的做法在 GUI 里会
把 `<runtime-route>` 标记直接显示给用户，Xedit 走 `AgentDelegationPolicy.systemPromptInstruction`
同一条通路。
**执行侧（1.273.0-rc5）**：`AppStateAgentReadOnlyPreflight` 在首次 provider 调用之前、
工具循环之外跑一个只读 worker，报告折进同一个 steering 段。默认关闭，由共享
`agent.auto_dispatch_read_only` 开启（一次开两端）。

只读是构造性的，不是约定：不传 `writeAccess`、不传 `verifier`、不取编辑锁、不接 patch sink，
并且只有 `autoDispatchEligible` 的分类才会走到这里——而该标志对任何含改动意图的请求都为 false
（有测试锁住）。远端工作区直接跳过（这批工种是本地文件/Git 类）。派工前先在 WillDeep 自己的
账本里落一条可见记录：让用户说不清缘由地等，比等本身更糟。预检失败对模型**静默**——预检跑不起来
不构成「这活很难」的证据，把 WillDeep 的管道故障讲给根模型只会引它去推理错误的东西。

**注入位置与成本（1.273.0-rc6 更正）**：先前这里写过「rs 注入用户消息所以只出现一次，
我们走系统提示所以每轮重复，是一项代价」——**这个说法是错的**。每次请求都是
「系统提示 + 完整历史」：报告放系统提示是 `[系统提示+报告] + [历史]`，放用户消息是
`[系统提示] + [历史含报告]`，**同一回合内 token 完全相同**。rs 的报告进了历史，后续每轮
照样带着，并非只出现一次。

真正的差别在跨回合：`currentTurnRouteSteering` 在下一回合被重置，旧报告自动消失；写进
历史的报告则**永久累积**。因此现行实现（系统提示 + 每回合重置）反而更省，不应改向 rs 那条路。

真实成本在报告本身：子 Agent 报告上限 32K 字符（≈8K token），放哪都贵。已加
`injectedReportCharacterLimit = 6000` 的注入上限，超出部分截断并**明说被截断**——
静默截断会让根模型把「报告里没提」当成「仓库里没有」。

---

## 5. 指标

`AgentSkillWorkerKPIs`（`AgentUsageStats.swift:195`）已统计 `deepRunCount`，
补一个 **Deep Share = deepRunCount / (narrowRunCount + deepRunCount)** 的展示口径，
目标 ≤ 5%（与 rs 的 `agent-metrics` 同口径，便于两端横向对比）。

这个数字是判断第 4 步的自动预检该不该默认打开的**唯一依据**——
在只有引导注入的版本上跑一段时间，Deep Share 和 Skill Coverage 说了算。

**状态：已做（1.273.0-rc4）。** `AgentSkillWorkerKPIs.deepShare` +
统计面板 Worker KPI 带的第四格「动用 1M 档」。

分母是**子运行数**（`narrowRunCount + deepRunCount`），刻意与 `skillCoverage` 不同：
后者含 `parentTurnCount`，问的是「有多少活流向了更便宜的地方」；Deep Share 问的是
「已经派出去的活里，有多少非用贵档不可」——父轮次根本不是 1M 档的候选，算进去只会把
数字稀释成永远好看。这与 rs `agent-metrics` 的 `deep_share = deep / children.len()`
同分母（Xedit 的子运行非 deep 即 narrow），两端可直接横向对比。

无子运行时显示 `—` 而非 `0%`：什么都没派出去的会话，0% 会被读成「稀缺档控制得很好」。

---

## 6. 与 willdeep-rs 的配置共用（1.273.0-rc3）

`~/.willdeep/config.toml` 不是新通道：`[notifications]` 段自 rs 0.29.0-rc1 起就是两端共用的，
Xedit 侧的读写在 `AgentAttentionPreferencesStore`（行级 TOML，段级替换，保留其他段与注释——
与 rs 0.38.0-rc1「只修改受管键」是同一思路）。路径解析含 `WILLDEEP_HOME` 环境变量覆盖，
与 rs 一致。

rs 0.37.0-rc1 新增的三个路由开关落在 `[agent]` 段，因此 Xedit 也读它：

| key | 含义 | Xedit 侧行为 |
|---|---|---|
| `small_model_routing` | 是否做请求级路由 | `false` 即不注入引导；缺省=开（对齐 rs 默认） |
| `auto_dispatch_read_only` | 高置信只读活是否先跑 worker | **仅解析不生效**——执行半边尚未接线，先认下键名与语义，避免两端漂移 |
| `max_deep_calls_per_harness` | L 档准入预算 | 直接作为 deep 预算；rs 的单位是 harness，Xedit 用会话，是它最接近的等价单位 |

优先级：`config.toml` 显式值 > Xedit 自身设置 > 内置默认。手工编辑过的文件是更审慎的配置，
也是两端唯一都看得见的那份。越界值夹取到 0–16，不照单全收。

**`[agent]` 段只读不写。** 该段与其注释归 CLI 所有；App 读它零风险，而回写一个没有完整建模的
段，有丢掉「CLI 认识、我们不认识」的键的风险。`[notifications]` 继续可写，因为那部分 UI 归 App。

**尚未共用的**：`[subagents.<trade>]` 的 provider/model/context_window（Xedit 的工种绑定存在
`AgentProfileStore` 的 UserDefaults 里，与 TOML 是两套模型，合并需要先定义冲突语义）、
`[providers.*]`（Xedit 有自己的 Provider 库与钥匙串凭据，不适合从明文 TOML 取）。

## 7. 风险与明确不做

**风险**

1. `classify()` 是关键词匹配，中文误判是必然的。第一版只做引导注入正是为了让误判的代价
   停留在「多了一段没用的提示」，而不是「跑了一个没用的 worker」。
2. 第 1 步改 Root 默认模型，对新用户是可感知的能力变化。M 档能不能扛住日常编码，
   要靠 Skill Coverage 与升档率验证，不能只看账单。
3. 未知 profile 不再回落 deep 是破坏性变更，`profileID` 的默认值链路必须先盘干净。

**明确不做**

- 不搬技能索引 4KB 上限与 MCP 按需加载——Xedit 两处都已是按需，搬过来是负优化。
- 不新建 `/routing` 面板。Xedit 已有工种设置界面，新开关进去即可。
- 不改内置 workflow 的手标 profile。它们是 Swift 代码、不经过技能系统，
  「按 tier 自动选档」适用的地方是 `list_skills` 命中与 `spawn_agent` 派工，两处都已自动化。

---

## 8. 版本与 Git 流程

- 功能新增，`1.272.0-rc11` → **`1.273.0-rc1`**，rc 重置。
- 四步各走一个从 `develop` 拉出的分支，顺序固定：**跑单测 → 提交 → 合回 develop**。
- 版本 bump 涉及多处 canonical 源，push 前跑 `scripts/version_consistency.rb` 确认 `failures=0`。
- 仓库常有并行会话共用 working tree：提交前先查并发，精确 `git add`，不要 `git add -A`。
