# 小上下文 Skill Worker 拆分设计（skill-workers.v1）

> 状态：已确认方向，规划完毕（实施任务见 `docs/SKILL_WORKERS_TASK_PLAN.md`，等待「开始」指令）
> 日期：2026-08-14
> 输入：《AI_Coding_Agent_Skill商业闭环方案》（外部整理稿）+ 仓库现状盘点
> 关联文档：`docs/SUBAGENT_PROFILES_DESIGN.md`（工种体系，已实现）、`docs/COST_ENGINE_DESIGN.md`（成本引擎，提案）、`docs/GOAL_TEAMS_ROLES_DESIGN.md`（执行期角色）、`docs/ORCHESTRATOR_DESIGN.md`（调度台）、`docs/SOME_IM_MANAGED_ROUTING_DESIGN.md`、`docs/SOMEIM_WORKER_VIRTUAL_MODELS.md`（服务端虚拟模型与提示词）、`docs/SKILL_WORKERS_TASK_PLAN.md`（任务清单）
> 一句话：**在既有工种体系上，把「可自动验证」的编程小任务拆成一批 32K～64K 小模型 Worker，用 Task Packet 喂进去、用 Verifier 判结果，让小模型的露脸次数和成功次数都上一个量级。**

---

## 0. 商业闭环方案的核心主张（整理）

原方案 36 节，压缩成五层 + 三条纪律 + 三个北极星：

**五层架构**

| 层 | 职责 | 一句话 |
|---|---|---|
| Main Agent | Planner + Router + Supervisor | 管 What / Why，不亲自 grep |
| Task Compiler | 把 200K 大问题编译成 8K～32K 小任务包 | **整个体系最关键的一层** |
| Skill Worker | 8K～64K 小模型，局部闭环 | 管 How，可以笨但可以重试 |
| Runtime | grep / test / git / exit code 等确定性动作 | 有些事根本不需要模型 |
| Verifier | 判断 Done / Not Done | 模型不自证，程序来证 |

**三条纪律**

1. **越容易自动验证的任务，越可以大胆用弱模型**（hard to generate, easy to verify）。
2. **平均 Context 要小**：max 64K 不等于 avg 64K；理想分布 P50 8～16K / P80 24～32K / P95 48K。
3. **Skill 从真实流量里长出来**，不要拍脑袋先设计 50 个；真实分布里 test / search / log / typecheck / bugfix / git 前几项就覆盖 60～70% 调用。

**三个北极星（第一阶段）**

```text
Skill Coverage        前 5~10 个 Skill 覆盖 ≥ 50% 模型调用
Worker Verified Success   ≥ 85%
Main Escalation Rate      ≤ 15%
```

成熟后再追 Token Downshift ≥ 70%、Hybrid Cost Ratio ≤ 0.65。核心 KPI 是 **Cost per Verified Task**，不是 token 单价——这与 `docs/COST_ENGINE_DESIGN.md` 的北极星完全一致。第一阶段全部用 API 模拟 Worker（强制 64K 窗 + Task Packet + Verifier），**不买卡**；把「架构是否成立」和「自建 GPU 是否划算」两个风险拆开验证。

---

## 1. Xedit 现状对照：地基七成已有

方案讲的六大长期资产，逐项对照仓库现状：

| 方案资产 | Xedit 现状 | 结论 |
|---|---|---|
| Skill Worker | `AgentSubagentProfile` 工种体系（scout / reader / editor / tester / reviewer / deep），cheapBinding = some.im glm-5，工具白名单只能交集收窄，`toolPayloadCharacterLimit` 按窗口配 | ✅ 骨架已有，但只有定位/阅读/单文件编辑真正下沉了便宜模型 |
| Model Router | `SomeIMManagedRouting`（someim-judge 档位裁判 + 只升不降 floor + 输出质量裁判）；dispatch 静态执行器规则 | ✅ 档位路由有先例，❌ 无 per-skill 路由表 |
| 升级兜底 | `AgentSubagentEscalation.retryWithParentModel`（换父模型重跑，不续小模型脏 transcript；升档必须可见） | ✅ 完整 |
| Verifier | 任务契约（执行器证据→只读复核→独立验收）只用于外部 CLI 委派；goal-teams `validator != self` 硬拦截；`structured_output` schema 校验回灌重试 | ⚠️ 有零件，**但子代理循环里没有 Verifier**：升档触发是爆窗/轮满/短报告，不是「测试没过」 |
| Task Compiler | 无。`spawn_agent` 只有自由文本 prompt | ❌ 最大缺口 |
| Replay Dataset | `AgentSubagentTranscript` 逐轮落盘（prompt / model / rounds / toolCalls / usageTokens / escalatedFromModel）已是 replay case 的 80% | ⚠️ 缺 repo commit 锚点和 verifier 命令两个字段 |
| 遥测 | usage sidecar 按消息记 token；`AgentSubagentUsageRow` 已能按工种统计调用次数 | ⚠️ **子代理自身消耗的 token 不进 usage sidecar**；无 verified_success；无 per-request ledger |

结论：**不需要新架构，需要的是在工种体系上补三块——Task Packet（喂料）、Verifier 闭环（判定）、遥测（记账），然后按可验证性拆一批新工种。**

## 2. 32K～64K 窗口的换算纪律

现有 cheapBinding 面向 128K～200K 的 glm-5；要让 32K 窗模型活下来，预算必须重钉。以 32K 窗为例（1 token ≈ 3 chars，CJK 感知估算见 `AppStateAgentRequestEstimates.estimateTextTokens`）：

```text
32K 窗预算分配（目标：P50 用一半窗口就收工）
  system prompt（不变量段+职能段）     ~0.8K tokens
  工具 schema（3~5 个工具）            ~1.5K tokens
  Task Packet（含内联相关文件）         6~12K tokens
  工具往返（N 轮 × payload 上限）       8~12K tokens
  输出余量                             ~4K tokens
```

落到 profile 参数：

| 参数 | 128K 档（现状） | 32K 档（新） | 64K 档（新） |
|---|---:|---:|---:|
| `contextWindowTokens` | 128_000 | 32_768 | 65_536 |
| `toolPayloadCharacterLimit` | 8_000 | **4_000** | 6_000 |
| `maxRounds` | 8～12 | **6** | 8 |
| 相关文件内联上限（Task Packet） | — | 24K chars | 48K chars |

两条硬规则：

1. **相关文件由主模型内联，Worker 不自己找**。Worker 每一轮 grep 都在烧窗口；Task Packet 直接带 `relevant_files` 的内容切片，Worker 起手就是热的。
2. **工具输出先由 Runtime 确定性消化**。测试日志走「失败聚焦段 + tail」提取（纯 Swift 代码，非模型），Worker 只见消化后的摘要 + 原始失败断言原文（COST_ENGINE §2.6 规则 2：断言原文不许转述）。

## 3. Task Packet：`spawn_agent` 的结构化扩展

`spawn_agent` 新增可选参数 `task`（不破坏现有自由文本用法；无 `task` 的调用行为逐字节不变）：

```jsonc
{
  "profile": "test_fixer",
  "task": {
    "goal": "修复 AgentGoalTeamRoleTests.testCrossSignOff 失败",
    "relevant_files": ["XeditTests/AgentGoalTeamRoleTests.swift", "Xedit/AgentGoalTeamRole.swift"],
    "known_facts": ["失败始于 caba8df7", "错误是 canSignOff 对空 roster 返回 true"],
    "constraints": ["不改 AgentGoalTeamRoster 公开接口"],
    "verifier": { "command": "xcodebuild test -only-testing ...", "expected": "exit 0" },
    "max_attempts": 4
  }
}
```

运行时处理（`executeSpawnAgentToolCall` 内）：

1. `relevant_files` 由 runner 读取并内联进 Worker 初始 user 消息（按 §2 的内联上限截断，超限时保留 goal 相关切片并明示截断）。
2. `verifier.command` 过 `AgentSafeCommand` 白名单校验（只允许测试/构建/lint 类只读-可重复命令），并作为 Worker 唯一允许的 `run_command` 形态之一。
3. `constraints` 拼进职能 prompt 尾部；`max_attempts` 覆盖 profile 默认值（上限 clamp）。

**Task Packet 的编译质量决定 Worker 成功率**，所以主模型 system prompt 需补一段「派工前先收集 known_facts、点名 relevant_files、给出可执行 verifier」的指引（`AgentContextBuilder` 稳定前缀区，编译期常量，不破坏缓存）。

## 4. Verifier 闭环：Worker 不自证

runner 层（`AgentSubagentRunner.run`）新增判定循环，对带 `verifier` 的运行生效：

```text
Worker 改动 → 声称完成
  ↓
runner 拦截：verifier 命令由 Runtime 执行（不占模型轮次）
  ↓
exit 0 → 运行成功，报告 + verified=true 落 transcript
exit ≠0 → 失败输出经确定性消化后回灌 Worker，attempt+1
  ↓
attempt 打满 max_attempts → 触发 escalation（换父模型重跑或报告失败）
```

要点：

- **verifier 的准入不是「必须只读」（2026-08-15 修正）**。诚实的 verifier 本来就会写：build 产出目标文件、测试写 fixture。一刀切只读会把用户推回「相信模型自称通过」，比放行更危险。改成两段门禁：确定性判定为 read 档的命令直接放行；其余交给 **security_guard 裁判**（即 `safetyJudgeApproval` 这个全局收口，与 `run_command`、MCP、终端同一条路），裁判不放行才拒绝并明确告知。**唯一不可退让的是「不能没有门禁」**——子代理没有审批 UI，无人值守的命令必须有人判。
- **「没跑过 verifier 的 done 不算 done」**：Worker 报完成但从未跑过 verifier 时，runner 自动代跑一次再判定。
- escalation 触发条件从现有三条（爆窗 / 轮满 / 报告过短）**升级为四条**：加「verifier 连败满额」。
- verifier 结果写入 `AgentSubagentTranscript` 新字段（`verifierCommand` / `verifierPassed` / `attemptCount`，optional decode 兼容旧 sidecar）。**这三个字段就是 Worker Verified Success 指标的数据源。**
- 报告型工种（无副作用）的 verifier 是 `structured_output` schema 校验本身，现成机制不动。

## 5. 第一批 Worker 拆分清单

按「调用频率 × 可自动验证性」排序。前三个是方案 §7 五星区里 Xedit 尚未拆出的：

| 工种 id | 职能 | 工具白名单 | 窗口档 | Verifier | 写通道 | 升档 |
|---|---|---|---|---|---|---|
| `test_fixer` **新** | 修失败测试到绿（改测试或改实现） | `read_file` `apply_patch` `run_command`（限 verifier 命令） | 32K～64K | 测试命令 exit 0 | **文件集锁**（见 §6） | verifier 连败→父模型 |
| `build_fixer` **新** | 修编译/类型/lint 错误 | 同上 | 32K | build/lint exit 0 | 文件集锁 | 同上 |
| `log_inspector` **新** | 报错/日志聚类解释，输出结构化结论 | `read_file`（读预处理产物） | 8～16K | structured_output schema | 无 | none（报告型） |
| `git_detective` **新** | 回归定位（bisect 由 Runtime 驱动）、commit 解释 | `run_command`（git 只读白名单）`read_file` | 16～32K | bisect 结果本身确定 + schema | 无 | retryWithParentModel |
| `scout` 已有 | 定位文件/符号 | 现状不变 | **下调至 32K 档** | —（报告型） | 无 | 现状 |
| `reader` 已有 | 阅读总结 | 现状不变 | 下调至 32K 档 | — | 无 | 现状 |
| `editor` 已有 | 单文件机械编辑 | 现状不变 | 下调至 32K 档 | **新增可选 verifier**（如 build） | 单文件锁（现状） | 现状 |
| `reviewer` 改造 | 局部 diff 风险审查 | 现状只读集 | 64K | findings schema + 主模型抽检 | 无 | none |
| `security_guard` **新** | 判断单条命令能否无人值守执行 | **无工具** | 8K | 结构化裁决 | 无 | retryWithParentModel |
| `judge` **新** | 路由/质检等有界裁决 | **无工具** | 8～16K | 调用方指定的格式 | 无 | retryWithParentModel |

两个裁判工种刻意**不给任何工具**：它们回答的是「就手上这份材料下结论」，给工具只会让小模型跑去找更多证据，而一个去找证据的裁判就是一个不再回答问题的裁判。同样刻意的是 `maxRounds: 1`——裁决不需要第二轮。

刻意不拆的（方案 §6「更适合 Main」区）：跨模块重构、架构设计、产品语义模糊的任务——继续走 `deep` / 主模型 / 调度台。

**小活旁路（side-call，不走 `spawn_agent`）**——露脸次数的最大来源，直接采纳 COST_ENGINE §2.6 清单：commit message、会话/任务标题、长工具输出摘要、错误归类、diff 摘要。每个 50 轮会话有几十次，全部绑 flash/32K 档，独立旁路请求不进主上下文、不砸缓存前缀。落地时与本设计共用同一个「便宜档绑定解析」（`AppStateSubagentProfiles.resolvedSubagentConfiguration` 同款回退链）。

## 6. 写通道扩展：文件集锁

`test_fixer` / `build_fixer` 必须能同时改测试文件和实现文件，现有 editor 单文件锁不够。扩展方案复用 editor 的三道门，把「单文件」推广为「声明式文件集」：

1. **spawn 即审批**：审批对象是「允许子代理编辑 `relevant_files` 中的 N 个文件」，一次审批整个集合（集合在审批卡上逐行列出）。
2. **逐条 diff 路径校验**：`apply_patch` 落点必须在集合内，越界 Denied 并提示「如需扩大范围请报告父模型重新派工」。
3. **文件集互斥锁**：同一父会话内，两个 Worker 的文件集有交集时后者排队（沿用「并行会话撞车」教训）；失败/取消即放锁。

`AgentSubagentWriteAccess` 从 `targetFile: String` 泛化为 `targetFiles: Set<String>`，editor 是集合大小为 1 的特例——一条通路，不开第二套。

## 7. 露脸机制：不能只靠主模型自觉

四个触发点，按确定性从高到低：

1. **确定性触发（Runtime 层）**：主循环里 `run_command` 返回测试/构建失败（`commandExitCode != 0` 且命令匹配测试/构建特征）时，工具结果尾部附一行结构化提示：「此失败适合派 `test_fixer`/`build_fixer` 处理，相关文件与失败摘要已就绪」。不强制、但把派工成本降到一句话。长工具输出超阈值时自动走小活摘要旁路（不问主模型）。
2. **Workflow 引擎**：`WorkflowEngine.agent()` 调用全部显式指定 profile；BugHunt / CodeReview / PRReview 等内置 workflow 的 fan-out 步骤改绑窄工种（它们本来就绕开 3 并发上限，是批量露脸的天然场地）。
3. **调度台静态规则**：`AgentDispatchExecutorResolver` 的规则表扩一列「任务特征 → 建议工种」，测试补齐类任务默认派 `test_fixer` 而非整个执行器。
4. **主模型 prompt 引导**：`spawn_agent` description 更新工种清单与选择指引（现有「prefer the narrowest profile」一句扩成按任务特征的一行决策表）。

排序依据：方案 §19 的教训——小模型的工具放大是真实风险，**触发点越确定性，露脸增长越不以成本失控为代价**。

## 8. 遥测与 KPI（Phase 0，先于一切）

方案 §34 Phase 0「先补观测」，对应 Xedit 的三个具体缺口：

1. **子代理 token 计入 usage sidecar**：`AgentSubagentTranscript.usageTokens` 已有数据，但统计面板的 model usage 表看不到 Worker 成本。在 `AgentUsageSessionSnapshot` 增加 per-run 汇总行（profileID / model / tokens / verified），面板才能算 Token Downshift。
2. **transcript 补 verifier 与锚点字段**：`verifierCommand` / `verifierPassed` / `attemptCount` / `repoCommit`。前三个撑 KPI，加上 `repoCommit` 后**一条 transcript 就是一个 Replay Case**（initial_state + task + trajectory + verdict 齐了），未来换模型回放测「14B vs 30B vs 主模型」。
3. **统计面板三个新指标**（数据源全在本地，不依赖服务端）：

| 指标 | 口径 | 目标 |
|---|---|---:|
| Skill Coverage | 窄工种 spawn 次数 / （窄工种 + deep + 主模型内联轮次） | ≥ 50% |
| Worker Verified Success | verifierPassed / 有 verifier 的运行数 | ≥ 85% |
| Main Escalation Rate | escalatedFromModel 非空 / 窄工种运行数 | ≤ 15% |
| Citation Accuracy（2026-08-16 新增，回流自 willdeep-rs） | 报告里核实存在的引用 / 被核实的引用总数（仅只读工种） | ≥ 90% |

### 8.1 只读工种的弱验证（回流自 willdeep-rs）

`test_fixer` 有退出码，`scout` 没有。在此之前只读工种（`scout` / `reader` /
`log_inspector` / `git_detective`）的 `verifierPassed` 永远是 nil——**永远
「未验证」，于是在三个 KPI 里永远隐身，而隐身读起来就像没问题**。

它们的答案并非不可证伪：一个位置要么存在，要么不存在。运行结束后 runner 对
报告做一次确定性抽查（`AgentSubagentCitationAudit`，纯代码，不花模型、不占轮次）：

| 引用形态 | 核对方式 |
|---|---|
| `Sources/Foo.swift` | 文件在不在 |
| `Sources/Foo.swift:42` | 文件在不在 + 行号是否越过文件末尾 |
| 7–40 位十六进制 | `git cat-file -e <sha>^{commit}` 能否解析 |

结果两处落地：报告尾部追加 `<citation-check checked="N" unverifiable="M">`
（点名对不上的条目，父代理直接看得见），transcript 与 usage 记录带上
`citationsChecked` / `citationsUnverifiable`，统计面板据此算 Citation Accuracy。

三条边界：

1. **它只证伪「地名是编的」，不证明「答对了」**。一个 Worker 可以引用十个真实
   文件同时完全答非所问，所以靶场把「引用准确率」和「答对率」分成两列算。
2. **认不出来的 token 一律不计**，否则量的是解析器不是 Worker。
3. **`checked = 0` 不进分子也不进分母**——「没引用任何位置」和「引用全对」是
   两件事，正如「没验证」不是「通过」。

### 8.2 实弹靶场（回流自 willdeep-rs）

KPI 只能算「已经派出去的工」的成绩。**「32B 到底修不修得动」这个问题，靶场
才能回答**：`XeditTests/AgentSubagentLiveFireRangeTests.swift` 现建五个带真实
缺陷的 SwiftPM 仓库（三个编译错误派 `build_fixer`，两个只读样本派 `scout` 与
`git_detective`），用真 Provider 派工、真 `swift build` 退出码判定；驱动器
`scripts/skill_worker_range.rb` 产出 JSON + Markdown 两份报告。

```bash
ruby scripts/skill_worker_range.rb
ruby scripts/skill_worker_range.rb --cases scout_finds_the_symbol
ruby scripts/skill_worker_range.rb --report-only   # 不花钱，重渲染
```

**不进 CI**：要真凭据、要网络、要花钱，没有 `XEDIT_RANGE_API_KEY` 时整个 suite
自己跳过。两条判定纪律与 rs 侧逐字一致：

1. **成功 = verifier 通过 且 靶子没被搬走**。退出码只知道绿了，不知道绿得干不
   干净——把出问题的函数删掉一样能让 `swift build` 变绿，所以另查公开 API 还在。
2. **派工前先确认靶子是红的**。绿着的靶子测不出任何东西，报告会点名这类无效样本。

Xedit 侧首轮实测当场打出两个真问题，都不是模型的问题：

1. **`apply_patch` 在没有补丁通道的上下文里直接报「只在交互式会话里可用」**。
   Worker 第一轮就诊断对了（`let` → `var`，连 diff 都给了），补丁却落不了地，
   而报告读起来像是模型不会修。靶场因此必须自带一条落盘 sink，解析与应用仍
   走产线的 `AgentPatchApplier`——靶场自己写一套 diff 应用逻辑，量到的就会是
   那套逻辑。
2. **嵌套沙盒：`swift build` 在 Agent 沙盒里必然失败**。SwiftPM 编译 manifest
   时自己要调 `sandbox-exec`，而 verifier 已经跑在 seatbelt 里，内核直接拒
   （`sandbox_apply: Operation not permitted`），报出来的失败与源码毫无关系。
   **这条对真实用户同样成立**：在 SwiftPM 工程里派 `build_fixer` 并把
   `swift build` 当 verifier，会稳定收到一个与代码无关的红。verifier 要写成
   `swift build --disable-sandbox`（或直接 `swiftc -typecheck`）。改完同一样本
   一次通过、16.6 秒。

实测（`glm-5`）：

| | Xedit（5 样本，2026-08-16） | willdeep-rs（12 样本，2026-08-16） |
|---|---|---|
| Worker Verified Success | **3/3（100%）**，均 1 次尝试 | **10/10（100%）**，均 1.00 次尝试 |
| 作弊 | 0 | 0 |
| 只读工种引用准确率 | **6/6** | **4/4** |
| 只读工种答对率 | **2/2** | **2/2** |
| 总耗时 | 84 秒 | 227 秒 |

**这组数字只支持一条结论**：形状有界、失败可由退出码判定的局部修复，以及有界
的定位类问题，交给 32K 档够用。它**不支持**「小模型能替代主模型」——样本是十几
个几十行的独立小仓库，是难度谱系最容易的一端。要把结论往难处推，先往靶场里加
难样本。

## 9. 模型档位：先 API 模拟，不买卡

沿方案 §29 的两风险拆分：

- **一期（已定，2026-08-14）**：some.im relay 建基础档 **`someim-32b`**（背后 glm-5；glm-4.7 已下架）+ 七个工种档 `someim-32b-<skill>`（服务端托管职能段 prompt，prepend 模式），完整定义见 `docs/SOMEIM_WORKER_VIRTUAL_MODELS.md`。客户端 profile 绑定对应虚拟模型并把 `contextWindowTokens` 钉死 32_768——**32b 是参数档位名，小上下文纪律由客户端执行，用 API 价格攒真实的成功率/上下文分布数据**。relay 不可用时回退链照旧（父模型 + 本地职能段）。
- **二期**：拿一期攒出的 avg context / GPU 秒 / 调用量数据，再算租卡/买卡；GPU utilization < 25% 不自建（方案 §30）。届时只改 `target_models` 后备链，客户端零改动。

`ModelBinding.contextWindowTokens` 已支持 per-profile 窗口，这一步没有代码障碍，是纯配置 + relay 后台动作。服务端侧的具体分工见 §13。

## 10. 分期落地

| 阶段 | 内容 | 验收 |
|---|---|---|
| **Phase 0 观测**（1～2 周） | §8 三件事：worker token 进 sidecar、transcript 补字段、面板三 KPI | 面板能回答「今天窄工种露脸几次、成功率多少」 |
| **Phase 1 闭环**（核心） | Task Packet（§3）+ Verifier 闭环（§4）+ 文件集锁（§6）+ `test_fixer` `build_fixer` 两个工种 + relay 32K 档 | 1,000 次 test_fixer 类任务中 ≥85% Worker 独立完成（方案 §29 的判据） |
| **Phase 2 露脸** | §7 四个触发点 + 小活旁路第一批（摘要/标题/commit message） | Skill Coverage ≥ 50% |
| **Phase 3 扩面** | `log_inspector` `git_detective` `reviewer` 改造 + Replay 回放工具 + per-skill 路由表（与 COST_ENGINE 阶段 2 合流） | Replay ≥ 1,000 cases，路由表数据驱动 |

每期照常：feature 分支 → 全量单测绿 → bump 版本 + CHANGELOG → 合回 develop。

## 10.5 运维类场景扩面（2026-08-16 补充，源于派工率盘点）

2026-08-16 盘点实测：358 个会话侧车里仅 5 个派过工（1.4%），近 5 天 86 个会话 0 次。
第一刀已切（workflow fan-out 绑窄工种，见 1.263.0-rc1），下一批候选按"机械程度 ×
工具可得性"排序如下。共同前提：**1.262.0-rc2 的凭证沙箱档已解开钥匙问题**，无人
值守任务能用 `~/.ssh` / `~/.npmrc`，这类场景才第一次变得可行。

### 三个用户点名的场景，判定各不相同

| 场景 | 判定 | 依据 |
|---|---|---|
| **侧边栏终端操作** | ✅ 最适合，缺的只是一个工种 | `terminal_list_tabs / select_tab / snapshot / send_command / send_control` 五件套现成；"发命令 → 读屏 → 汇报"是纯机械闭环，上下文天然小（一屏 snapshot ≪ 4K payload 上限），32B 干这个绰绰有余 |
| **在线服务发布** | ✅ 可以，但只当"执行员"不当"决策者" | 发布 = 跑一个**已知脚本**（`release.rb run` / `deploy.sh`）+ 盯退出码 + 转述失败摘要，正是 Task Packet + verifier 闭环的形状（§3/§4）。前提：脚本由主模型/用户选定，Worker 只执行与转述；回滚决策必须升档或问人 |
| **k8s 管理** | ⚠️ 拆开看：查询可以，变更不行 | `kubectl get/describe/logs`、`helm status` 是只读 shell 查询，机械且高频，适合小模型；`apply/delete/rollout` 是危险档，审批与决策留在主模型/用户。小模型的价值在"先把现场信息收齐"，不在"决定动手术" |

### 由此推出的两个新工种（1.263.0-rc1 已实现 v1）

1. **`ops_runner`（只读 shell 查询员）**：工具 = `run_command` + `read_file` +
   `grep_files` + `list_directory`。吃下 `kubectl get/logs`、`gh run watch`、
   `gh issue list`、`gh pr view` 这类纯抓取步骤。实现零新增安全面：子代理执行层
   "只许 read 风险"的既有死门自动实现"查询可以、变更不行"。
2. **`terminal_operator`（侧边栏终端操作员）**：工具 = `terminal_list_tabs` /
   `select_tab` / `snapshot` / `send_command` + `read_file`。终端工具照 editor
   写工具先例**按工种专属放行**（`AgentSubagentProfileCatalog.terminalOperatorToolNames`，
   不进全局白名单）；`send_command` 在执行层加第二道闸——命令文本必须分类为只读。
   v1 刻意不给 `send_control`（打断用户前台任务）与捷径写工具。终端 controller
   仅随该工种从 spawn 点下发。
   两者 cheapBinding（glm-5 / 32K），未进 relay 托管名单——服务端补
   `someim-32b-ops-runner` / `someim-32b-terminal-operator` 档后再进
   `hostedTradeIDs`。

### 单命令授权通道（target_command，同期落地）

"发布执行员"场景的钥匙孔：`spawn_agent(profile: "ops_runner",
target_command: "<确切命令>", task: {verifier: …})`。

- **授权语义**：带 target_command 的 spawn 升 write 档过审批卡，用户批准的
  就是那条命令本身。执行层修剪后精确匹配放行，可重复执行（verifier 重试
  依赖脚本幂等，deployment.md 的既有硬约束）。
- **沙箱**：命令按自身分类拿档。`ruby scripts/release.rb` → ruby 属
  networkCapableBuildHeads → `workspaceWriteNetworkCredentialed`，凭证沙箱
  的 `~/.ssh` / `~/.npmrc` 可用——1.262.0-rc2 那刀是这条通道的前置。
- **触发**：AgentWorkerDispatchHint 新增 releaseMarkers（release.rb / deploy /
  helm upgrade / kubectl apply / npm publish 等），失败带退出码时附提示；
  发布检测优先于构建检测。提示写死边界：worker 只"重试并盯梢"，诊断、
  回滚、不可逆决策留在主会话。
- **连带修复**：子代理 run_command 的沙箱档从死钉 .readOnly 改为按命令
  分类（查询 → readOnlyNetwork；授权单命令 → 分类应得档）。不修这个,
  ops_runner 的 kubectl/gh 查询全部死于 deny network 的假 DNS 失败。

两者都遵守 §19 教训：触发点确定性优先——由 workflow / 调度台 / 确定性提示派活，
不指望主模型自觉。危险命令边界不因工种便宜而放松：`AgentSafeCommand` 分类、
审批闸门、typed confirm 原样适用。

### 32B 的能力边界（据此选活，不是拍脑袋）

适合：固定流程执行、退出码/日志的模式识别与转述、单文件小改（有 verifier 兜底）、
一屏内的状态判读。
不适合：开放式排障（要跨多处线索推理）、严格 JSON schema 输出（DeepResearch 5 处
结构化步骤因此暂不下放）、不可逆操作的决策（回滚、删除、对外发布的"按不按钮"）。

## 11. 风险

| 风险 | 缓解 |
|---|---|
| 主模型懒得派工，露脸上不去 | §7 确定性触发不依赖模型自觉；面板 Skill Coverage 可审计 |
| 32K 档爆窗率高 | §2 预算换算 + 内联上限 + payload 4K；爆窗即升档且可见 |
| Worker 工具放大（grep 25 次） | 相关文件内联使 Worker 基本不需要搜索；transcript 的 toolCalls 数可算放大比，超 1.5x 报警 |
| verifier 命令被滥用（危险命令） | `AgentSafeCommand` 白名单 + 现有沙箱；verifier 只许测试/构建/lint 类 |
| 文件集写通道破坏只读地基 | §6 三道门与 editor 同一条通路；spawn 审批列全集合 |
| 便宜档质量差拖累体验 | 只升不降升档现成；verified success 掉线时面板可见，用户可一键改绑定 |
| 遥测口径漂移 | verified success 只认 verifier exit code，不认模型自述 |

## 12. 待确认问题（2026-08-14 已全部落定）

1. **第一批先做哪两个工种？** ✅ `test_fixer` + `build_fixer` 先行（实施顺序见任务清单 C5），七个工种的服务端虚拟模型一次性配齐。
2. **32K 模拟档用什么模型？** ✅ relay 新建虚拟档 `someim-32b`（背后 glm-5）+ 七个工种档，服务端托管职能段；见 `docs/SOMEIM_WORKER_VIRTUAL_MODELS.md`。
3. **文件集写通道是否一期就开？** ✅ 一期开（任务 C4），否则 `test_fixer` 无法闭环。
4. **verified success 等遥测是否上报 some.im？** ✅ verdict 回执端点后置到 Phase 3（任务 E4）；BYOK 用户 opt-in（沿 COST_ENGINE §3.6 隐私红线）。

## 13. 附：muchtoken 服务端分工（2026-08-14 现状盘点后补充）

> muchtoken（`~/Sites/muchtoken`，自研 Go 网关，MySQL 8，origin + edge 两级部署）是所有主模型 + Worker 请求的必经咽喉。盘点结论：**账本已完备（`usage_records` 默认永久保留，含 request_model / actual_model / 缓存与推理 token / 延迟 / 错误码 / session_id / 客户端元数据），大头是把现有通道用起来，不是新写收集代码。**

### 13.1 零服务端代码就能拿到的

| 目标 | 用什么 | 前提 |
|---|---|---|
| Worker 露脸次数、token 分布、缓存命中、错误率（按工种） | **每个 Worker 档独立虚拟模型名**（`someim-worker-32k` 等）→ `usage_records.request_model` 天然分组，`/admin/usage-analytics` 现成报表 | `platform_virtual_model_chains` + `model_pricing` 各插一行（后台 API，免发版） |
| skill / attempt / 父子归因等细粒度标注 | 客户端带 `X-Api-Tag: role=worker, skill=test_fixer, attempt=2, parent=<request_id>` → `usage_record_tags` 多维宽表 | 给 WillDeep 租户打 `extended_billing` 标签；≤8 对、value ≤64 字符 |
| 会话归因（主 Agent 与 Worker 串同一会话） | `X-Playground-Session-ID` → `usage_records.session_id`（已落库） | 客户端统一带上 |
| Context P50/P95（按工种） | `input_tokens` 已逐请求落库，按 request_model 算分位数即可 | 管理侧加一条查询/preset，不动写入路径 |

### 13.2 唯一值得新写的服务端增量：verdict 回执

**verified success 是服务端永远看不到的标签**（verifier 在客户端跑），却是飞轮里最值钱的数据——「这个档位够不够」的 ground truth。建议加一个轻量回执端点：

```text
POST /api/v1/task-verdicts
{ request_id 或 session_id+skill, verified: bool, attempts: n, escalated: bool }
```

一张小表即可，与 `usage_records` 按 request_id 关联后，Skill Coverage / Worker Verified Success / Escalation Rate 三个北极星在服务端报表里就能按天出——这就是方案 §31「Skill → Context → Model → Verifier → Success Rate 知识库」的服务端落点。

### 13.3 两个现成的意外之喜

1. **Worker 职能 prompt 可服务端托管**：`platform_virtual_model_chains.system_prompt` + `someim-security-guard` 的 replace 模式已是完整样板（服务端独占信任边界、prompt 热更新免发版）。Worker prompt 的「不变量段」仍留客户端（安全规则不外置），**职能段**可放服务端，skill prompt 迭代不用等 App 发版。
2. **`target_models` 有序后备链 = Model Router 雏形**：Worker 档可配 `[30B 上游, glm-5, deepseek-v4]` 服务端自动 failover。但必须与客户端升档划清语义：**服务端 failover 是同档可用性兜底，客户端 escalation 是能力升档**——两层都动模型，若不划清会出现「升了档但用户不可见」，违反升档必须可见的既有原则。`failover_from` 列已记录服务端换链，客户端 transcript 记录能力升档，两边口径分开统计。

### 13.4 明确不做的

- **不给客户租户开 prompt 正文审计**（`SOMEAPI_AUDIT_ENABLED` 默认关保持）。Replay 数据集留在客户端（transcript + repoCommit + verifier），服务端只收指标——与 COST_ENGINE §1「服务端只见元数据不见源码」铁律一致。若要离线评估 Worker 输出质量，仅对自有测试租户开旁路审计，且设 `retention_until`。
- **不急着做服务端 per-skill 智能路由**（`routing_strategy` 扩展要写代码）；先用虚拟链 + 回执数据攒够样本，路由表有据可依后再动。
